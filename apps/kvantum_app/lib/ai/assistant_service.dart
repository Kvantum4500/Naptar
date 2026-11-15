import 'dart:async';

import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_repository.dart';
import '../data/finance_repository.dart';
import '../data/record_repository.dart';
import 'ai_settings.dart';
import 'handbook_store.dart';
import 'llm_provider.dart';
import 'service/assistant_outcome.dart';
import 'service/prepared_request.dart';
import 'service/tool_decls.dart' show assistantToolsFor;
import 'weather_service.dart';

export 'service/assistant_outcome.dart';
export 'service/prepared_request.dart';
export 'service/tool_decls.dart' show assistantToolsFor;

part 'service/local_planning.dart';
part 'service/proposal_checks.dart';
part 'service/request_data.dart';

/// What a request is made of; the budget guard turns these down one by one.
class _Knobs {
  _Knobs(this.days);
  bool weather = true;
  bool slots = true;
  int taskMax = 40;
  int days;
  bool workouts = true;
  bool learned = true;
}

/// The user's request goes to the model at most this long.
const maxPromptLength = 500;

/// Runs the conversation with the model: it asks for data through tools that
/// execute HERE on the device (respecting the user's sharing switches), and
/// every proposal is checked by code against the hard rules before the user
/// ever sees it.
class AssistantService {
  AssistantService({
    required this.provider,
    required this.events,
    required this.records,
    required this.handbook,
    required this.settingsStore,
    this.rules = const PlanRules(),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.maxCalls = 7,
    this.maxRepairs = 2,
    this.weather,
    this.finance,
    this.deadline = const Duration(seconds: 90),
    Duration Function()? sinceStart,
    this.providerId = 'ai',
    this.tokenBudget,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future.delayed,
       _sinceOverride = sinceStart;

  final LLMProvider provider;
  final EventRepository events;
  final RecordRepository records;
  final HandbookStore handbook;
  final AiSettingsStore settingsStore;
  final PlanRules rules;

  /// Forecast source; null means the assistant works without weather.
  final WeatherService? weather;

  /// Money data source; null means the assistant has no finance block.
  final FinanceRepository? finance;

  /// Whose usage the answered calls are counted under.
  final String providerId;

  /// How many tokens the first request may have by the program's estimate; a
  /// bigger one is made smaller before it is sent (null: no limit).
  final int? tokenBudget;
  final int maxCalls;
  final int maxRepairs;

  /// The whole request (waits and retries included) gets this long; then it
  /// ends with a clear message instead of hanging.
  final Duration deadline;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Duration Function()? _sinceOverride;

  /// Time since the request started (tests replace it).
  Duration Function() _since = () => Duration.zero;

  bool _cancelled = false;
  final _cancelSignal = Completer<void>();

  /// Stops the running [ask] (it ends with [LlmCancelled]): at once if a model
  /// call is in flight (whether or not the provider manages to abort it), else
  /// at the next step. A service serves ONE request of the user (the retries
  /// and the other-model tries of that request included): once cancelled, it
  /// stays cancelled, so a later step of the same request cannot restart it.
  void cancel() {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  void _live() {
    if (_cancelled) throw const LlmCancelled();
  }

  String get _tz => rules.tzid;

  // The rules of THIS request: the configured ones with the limits the user's
  // own workouts have taught (see [learnFromWorkouts]), and the feedback they
  // come from.
  PlanRules? _learnedRules;
  PlanRules get _rules => _learnedRules ?? rules;
  List<WorkoutLogView> _workoutLogs = const [];

  Future<void> _learn() async {
    _workoutLogs = [
      for (final r in await records.all(kindWorkoutLog))
        if (!r.deleted) WorkoutLogView(r),
    ];
    final learning = learnFromWorkouts(
      _workoutLogs,
      today: _today,
      approvedLight: await handbook.lightSports(),
    );
    _learnedRules = learning.isEmpty
        ? rules
        : rules.withHardFrom({
            ...rules.hardFromBySport,
            ...learning.hardFromBySport,
          });
  }

  DateTime get _nowUtc => _now().toUtc();
  DateTime get _today {
    final w = toWallClock(_tz, _nowUtc);
    return floating(w.year, w.month, w.day);
  }

  /// [context] is the local answer a further question builds on: it goes to
  /// the model as data, but only where the user's sharing switches allow it.
  Future<AssistantOutcome> ask(
    String prompt, {
    required String model,
    required AiSettings settings,
    void Function(String status)? onStatus,
    LocalAnswer? context,
  }) async {
    _context = context;
    final clock = Stopwatch()..start();
    _since = _sinceOverride ?? (() => clock.elapsed);
    _onStatus = onStatus;
    _usage = LlmUsage.zero;
    // What the request is about is decided ONCE, from its wording. It drives
    // the data in the first message, the tools offered and whether deleting /
    // moving is allowed at all.
    final scope = _begin(prompt, settings);
    try {
      return (await _run(prompt, model, settings, scope)).withCost(
        usage: _usage.isZero ? null : _usage,
        estimatedTokens: _estimate,
      );
    } on LlmException catch (e) {
      // "Too big" or "could not write the call": one more try with the least
      // data. Anything else (or nothing left to take away) is the answer.
      if (!(e is LlmTooLarge || e is LlmToolFailed) || !scope.canNarrow) {
        rethrow;
      }
      _live();
      _onStatus?.call('Kisebb adattal próbálom újra…');
      final out = await _run(prompt, model, settings, scope.narrowed());
      return out
          .withCost(
            usage: _usage.isZero ? null : _usage,
            estimatedTokens: _estimate,
          )
          .withNotice(
            e is LlmTooLarge
                ? 'A kérés túl nagynak bizonyult, ezért csak a következő ${AskScope.narrowDays} nap eseményeivel dolgoztam. Ha többre van szükséged, kérdezz kevesebb napra egyszerre, vagy válassz másik modellt.'
                : 'A modell elsőre nem tudta összeállítani a tervet, ezért kisebb adattal (a következő ${AskScope.narrowDays} nap eseményeivel) próbáltam újra.',
          );
    }
  }

  static const _cutNote =
      'A válasz a hosszkeret miatt levágódott, ezért lehet, hogy nem minden javaslat érkezett meg. Kérj kevesebb napot vagy kevesebb tételt.';

  Future<AssistantOutcome> _run(
    String prompt,
    String model,
    AiSettings settings,
    AskScope scope,
  ) async {
    // The usual data goes into the first message, so a normal request needs
    // ONE model call instead of a chain of tool calls (the free tier allows
    // only a few requests per minute). Other ranges are still available as tools.
    final req = await _prepare(prompt, scope, settings);
    _estimate = req.estimatedTokens;
    final system = req.system;
    final tools = req.tools;
    final turns = <LlmTurn>[
      LlmTurn('user', [LlmText(req.firstMessage)]),
    ];
    // what the budget made smaller is said with the answer
    final reduced = req.reductions.isEmpty
        ? null
        : 'A kérés a méretkorlát miatt kisebb adattal ment, kimaradt: ${req.reductions.join('; ')}.';
    final done = reduced == null
        ? (AssistantOutcome o) => o
        : (AssistantOutcome o) => o.withNotice(reduced);
    var repairs = 0;
    for (var call = 1; call <= maxCalls; call++) {
      _live();
      final reply = await _generate(
        model,
        LlmRequest(
          system: system,
          turns: List.unmodifiable(turns),
          tools: tools,
        ),
      );
      _live();
      turns.add(LlmTurn('model', reply.parts));
      final calls = reply.toolCalls;
      // A reply cut off by the length cap is never sent back for repair (the
      // second try would be cut off again, at the price of the whole talk).
      final repairsLeft = reply.truncated ? 0 : maxRepairs - repairs;
      if (calls.isEmpty) {
        return done(
          AssistantOutcome(
            text: reply.truncated ? '${reply.text}\n\n$_cutNote' : reply.text,
            calls: call,
          ),
        );
      }

      final results = <LlmPart>[];
      for (final c in calls) {
        _live();
        if (c.name == 'propose_events') {
          final args = _expandRefs(c.args);
          final r = await _propose(args, repairsLeft: repairsLeft);
          if (r.outcome != null) {
            final o = r.outcome!;
            final del = await _resolveDeletions(args, settings);
            final mv = await _resolveMoves(args, settings);
            _live();
            final again = _refFeedback(o, del, mv, repairsLeft: repairsLeft);
            if (again != null) {
              repairs++;
              results.add(LlmToolResult('propose_events', again, id: c.id));
              continue;
            }
            return done(
              AssistantOutcome(
                text: reply.text,
                summary: o.summary,
                items: o.items,
                dropped: [
                  ...o.dropped,
                  ...del.notes,
                  ...mv.notes,
                  if (reply.truncated) _cutNote,
                ],
                questions: o.questions,
                deletions: del.items,
                moves: mv.items,
                calls: call,
              ),
            );
          }
          repairs++;
          results.add(LlmToolResult('propose_events', r.feedback!, id: c.id));
        } else {
          results.add(
            LlmToolResult(c.name, await _runTool(c, settings), id: c.id),
          );
        }
      }
      turns.add(LlmTurn('user', results));
    }
    return done(
      AssistantOutcome(
        text: 'Nem sikerült érvényes tervet összeállítanom a megengedett lépésszámon belül. Próbáld pontosabban megfogalmazni a kérést.',
        calls: maxCalls,
      ),
    );
  }

  // ----------------------------------------------------------- local answers

  /// The local answer a further question builds on (see [ask]).
  LocalAnswer? _context;

  /// Whether the user's sharing switches let the text of a local answer go to
  /// the model: the budget needs the money data on, the agenda the events and
  /// the tasks (it holds both). A text of a switched-off notice never goes.
  bool _mayShare(LocalKind kind, AiSettings s) => switch (kind) {
    LocalKind.budget => s.finance,
    LocalKind.agenda => s.events && s.tasks,
    LocalKind.switchedOff => false,
    // (a plan is no answer to build a question on)
    LocalKind.plan => false,
  };

  /// The local answer as a data block of the first message of a follow-up
  /// question (null: none, or the user does not share what it is made of).
  /// Typed-in short events are "foglalt" in it, as in the events block.
  String? _contextBlock(AiSettings s) {
    final c = _context;
    if (c == null || !_mayShare(c.kind, s)) return null;
    final lines = [
      for (final l in c.modelText.split('\n'))
        if (l.trim().isNotEmpty) sanitizeText(l, max: 200),
    ].take(40).toList();
    return dataBlock('helyi_valasz', {
      'megjegyzes': 'A program korábbi saját válasza a felhasználónak.',
      'sorok': lines,
    });
  }

  /// What the program answers by itself, with no model and no key: the budget
  /// and the agenda of a day, from the data on the device (whatever the sharing
  /// switches say, nothing leaves the device); and the plain notice that a
  /// request needs a source the user switched off, instead of sending it just
  /// to be told so. Null when the request is a question for the model.
  Future<AssistantOutcome?> localOutcome(
    String prompt, {
    required AiSettings settings,
  }) async {
    final q = localQuestionFor(prompt, _today);
    if (q == null) return _switchedOff(prompt, settings);
    switch (q.kind) {
      case LocalKind.budget:
        final repo = finance;
        if (repo == null) return null;
        final a = budgetAnswer(
          today: _today,
          txs: await repo.txs(),
          categories: await repo.categories(),
          budgets: await repo.budgets(),
          recurring: await repo.recurring(),
          goals: await repo.goals(),
          deposits: await repo.deposits(),
        );
        return AssistantOutcome(text: a.text, localAnswer: a);
      case LocalKind.agenda:
        final first = _today.add(Duration(days: q.offset));
        final occ = await events.occurrences(
          resolveWallClock(_tz, first.subtract(const Duration(days: 1))),
          resolveWallClock(_tz, first.add(Duration(days: q.days + 1))),
        );
        // (the forecast is public data; it is only used when it is switched on)
        _forecastFuture = null;
        final a = agendaAnswer(
          today: _today,
          first: first,
          days: q.days,
          tz: _tz,
          occurrences: occ,
          tasks: topLevelTasks([
            for (final r in await records.all(kindTask)) TaskView(r),
          ]),
          forecast: await _forecastFor(settings),
        );
        return AssistantOutcome(text: a.text, localAnswer: a);
      case LocalKind.switchedOff:
      case LocalKind.plan:
        return null;
    }
  }

  /// The workout plan the program makes by itself ("Terv AI nélkül"): the next
  /// [localPlanDays] days from tomorrow, from the sports and wishes in [prefs],
  /// every session checked by the same rules as a model's proposal. Nothing
  /// is sent anywhere (the forecast, when it is switched on, is the one thing
  /// fetched).
  Future<AssistantOutcome> localPlan(
    LocalPlanPrefs prefs, {
    required AiSettings settings,
  }) => _planLocally(prefs, settings);

  AssistantOutcome? _switchedOff(String prompt, AiSettings s) {
    final scope = scopeFor(prompt, _today);
    final String? why;
    if (scope.kind == PromptKind.money && !s.finance) {
      why = 'A pénzügyi adatok megosztása ki van kapcsolva, ezért ezt a kérdést nem küldöm el a modellnek. Kapcsold be a Beállításokban („Mit láthat az asszisztens?”), vagy kérdezz a költségkeretről („Hogy állok a költségkerettel?”): arra helyben, modell nélkül is válaszolok.';
    } else if (scope.edit && !s.events) {
      why = 'A naptáresemények megosztása ki van kapcsolva, ezért nem tudom, melyik eseményt töröljem vagy helyezzem át. Kapcsold be a Beállításokban („Mit láthat az asszisztens?”).';
    } else {
      why = null;
    }
    return why == null
        ? null
        : AssistantOutcome(
            text: why,
            localAnswer: LocalAnswer(LocalKind.switchedOff, why),
          );
  }

  // ------------------------------------------------------------ preparation

  /// What the request is about, and the per-request state that goes with it.
  AskScope _begin(String prompt, AiSettings settings) {
    _prompt = prompt.toLowerCase();
    _settings = settings;
    return scopeFor(prompt, _today);
  }

  /// Exactly what [ask] sends first, without sending anything: for the "Mit
  /// küldünk?" panel. Built by the same code as the real request.
  Future<PreparedRequest> preview(
    String prompt, {
    required AiSettings settings,
  }) async {
    final scope = _begin(prompt, settings);
    return _prepare(prompt, scope, settings);
  }

  /// The first request. With a token budget, data is taken out step by step
  /// (weather, the free-slot list, all but the 8 most urgent tasks, a shorter
  /// window, the learned habits) until the estimate fits, and the steps are
  /// listed in [PreparedRequest.reductions]. If it still does not fit, it goes
  /// as it is: the provider's own answer then triggers the smaller second try.
  Future<PreparedRequest> _prepare(
    String prompt,
    AskScope scope,
    AiSettings settings,
  ) async {
    await _learn();
    final knobs = _Knobs(scope.days);
    final taken = <String>[];
    var req = await _build(prompt, scope, settings, knobs);
    final budget = tokenBudget;
    while (budget != null && req.estimatedTokens > budget) {
      final step = _tighten(knobs, scope, settings);
      if (step == null) break;
      final next = await _build(prompt, scope, settings, knobs);
      // a step that saved nothing (no tasks to cut, no habits to drop) is not
      // worth mentioning
      if (next.estimatedTokens < req.estimatedTokens) taken.add(step);
      req = next;
    }
    return taken.isEmpty ? req : req.withReductions(taken);
  }

  /// Turns one knob down; returns what was taken out, or null when nothing is
  /// left to take.
  String? _tighten(_Knobs k, AskScope scope, AiSettings s) {
    if (k.weather &&
        scope.slots &&
        s.weather &&
        s.place != null &&
        weather != null) {
      k.weather = false;
      return 'időjárás';
    }
    if (k.slots && scope.slots) {
      k.slots = false;
      return 'szabad idősávok (a find_free_slots eszköz megmarad)';
    }
    if (scope.tasks && k.taskMax > 8) {
      k.taskMax = 8;
      return 'feladatok (csak a 8 legsürgősebb)';
    }
    if (scope.events && k.days > 4) {
      k.days = k.days > 7 ? 7 : 4;
      return 'időablak (${k.days} nap)';
    }
    if (k.workouts && scope.checkins && s.checkins) {
      k.workouts = false;
      return 'edzésnapló';
    }
    if (k.learned && scope.kind == PromptKind.plan && s.handbook) {
      k.learned = false;
      return 'Tanult szokások';
    }
    return null;
  }

  Future<PreparedRequest> _build(
    String prompt,
    AskScope scope,
    AiSettings settings,
    _Knobs k,
  ) async {
    _aliasToRef.clear();
    _refToAlias.clear();
    _taskAliasToId.clear();
    _taskIdToAlias.clear();
    _hiddenTitles.clear();
    _editIntent = scope.edit;
    _forecastFuture = null;
    _taskMax = k.taskMax;
    // The feedback on the latest workouts goes with the check-in data (the
    // same switch), and only when there is something to say.
    final shareWorkouts = scope.checkins && k.workouts && settings.checkins;
    final workoutLines = shareWorkouts
        ? workoutLogLines(_workoutLogs, today: _today)
        : const <String>[];
    // No clock in here: the system prompt and the tool list stay the same from
    // one request to the next (providers with prefix caching reuse them).
    final system = buildSystemPrompt(
      handbook: await _handbookFor(
        scope.kind,
        settings,
        learned: k.learned,
        mixed: scope.mixed,
      ),
      rules: _rules,
      kind: scope.kind,
      finance: scope.finance,
      mixed: scope.mixed,
      workoutLog:
          workoutLines.isNotEmpty ||
          (shareWorkouts && _rules.hardFromBySport.isNotEmpty),
    );
    return PreparedRequest(
      scope: scope,
      system: system,
      tools: assistantToolsFor(scope),
      firstMessage: await _firstMessage(
        prompt,
        scope,
        settings,
        days: k.days,
        weather: k.weather,
        slots: k.slots,
        workoutLines: workoutLines,
      ),
    );
  }

  /// The handbook files a kind of request needs: planning all of them,
  /// deleting / moving only what is fixed and what is movable in the calendar,
  /// a money question none.
  /// With the user's handbook switch off nothing of it goes out.
  Future<String> _handbookFor(
    PromptKind kind,
    AiSettings settings, {
    bool learned = true,
    bool mixed = false,
  }) {
    if (!settings.handbook) return Future.value('');
    return switch (kind) {
      PromptKind.plan => handbook.combined(skip: learned ? null : {'learned'}),
      // (deleting and planning in one request: the user's planning rules too)
      PromptKind.edit when mixed => handbook.combined(
        skip: learned ? null : {'learned'},
      ),
      PromptKind.edit => handbook.combined(only: const {'calendar-semantics'}),
      PromptKind.money => Future.value(''),
    };
  }

  // ------------------------------------------------------------- model call

  void Function(String status)? _onStatus;

  String _prompt = '';
  AiSettings _settings = const AiSettings();

  // What the answered calls of this request cost, and the estimate of the first
  // request (for the line "Utolsó kérés" and for the usage totals).
  var _usage = LlmUsage.zero;
  int? _estimate;

  // How many tasks the data carries (the budget guard turns it down).
  int _taskMax = 40;

  // Titles of typed-in events that were shown to the model as "foglalt": the
  // text sent back with a rule violation must not give them away either.
  final _hiddenTitles = <String>{};

  /// The user's own words asked to delete / move / change something. Without
  /// that, anything the model proposes in that direction is dropped (a hostile
  /// event title must not be able to summon a deletion card).
  bool _editIntent = false;
  Future<List<DayWeather>?>? _forecastFuture;

  /// The forecast for the next two weeks, asked for once per request (the
  /// service keeps a fetched one for a few hours, so the next request does not
  /// ask again). It is started as the data is read and awaited where it is
  /// used. Null when weather is off, no place is set, or the service is
  /// unreachable.
  Future<List<DayWeather>?> _forecastFor(AiSettings s) {
    final svc = weather;
    final place = s.place;
    if (svc == null || !s.weather || place == null) return Future.value(null);
    return _forecastFuture ??= svc.forecast(place, days: 14);
  }

  // Short per-request aliases (e1, e2, ...) for event references: the long
  // `<id>@<time>` form costs tokens and is easy for a model to garble.
  final _aliasToRef = <String, String>{};
  final _refToAlias = <String, String>{};

  // The same for tasks (t1, t2, ...): the record ids are long.
  final _taskAliasToId = <String, String>{};
  final _taskIdToAlias = <String, String>{};

  String _taskAliasFor(TaskView t) => _taskIdToAlias.putIfAbsent(t.id, () {
    final a = 't${_taskIdToAlias.length + 1}';
    _taskAliasToId[a] = t.id;
    return a;
  });

  String _aliasFor(Occurrence o) {
    final full = occurrenceRef(o);
    return _refToAlias.putIfAbsent(full, () {
      final a = 'e${_refToAlias.length + 1}';
      _aliasToRef[a] = full;
      return a;
    });
  }

  /// Replaces the aliases in `deletions[].ref` / `moves[].ref` with the real
  /// references. Anything that is not a known alias is left as it came and is
  /// judged (and probably rejected) by the normal parsing.
  Map<String, Object?> _expandRefs(Map<String, Object?> args) {
    List<Object?>? fix(Object? list) {
      if (list is! List) return null;
      return [
        for (final it in list)
          if (it is Map && it['ref'] is String)
            {
              ...it.cast<String, Object?>(),
              'ref':
                  _aliasToRef[(it['ref'] as String).trim().toLowerCase()] ??
                  it['ref'],
            }
          else
            it,
      ];
    }

    final d = fix(args['deletions']);
    final m = fix(args['moves']);
    if (d == null && m == null) return args;
    return {...args, 'deletions': ?d, 'moves': ?m};
  }

  static const _netBackoff = [
    Duration(milliseconds: 1500),
    Duration(seconds: 4),
  ];

  /// Whether a wait of [d] still fits into the request's deadline.
  bool _fits(Duration d) => deadline - _since() > d;

  /// One model call with what can be waited out:
  /// - a short per-minute limit is waited out (twice at most); a missing or
  ///   used up quota is not, waiting would not help there;
  /// - a transient server-side failure (timeout, 502/503/504 ...) is tried
  ///   again twice, after 1.5 s and 4 s;
  /// - nothing may run past the request's [deadline] or after [cancel].
  Future<LlmReply> _generate(String model, LlmRequest req) async {
    var rateWaits = 0;
    var netRetries = 0;
    final deadlineMsg =
        'Az asszisztens nem készült el időben (${deadline.inSeconds} másodperc). Próbáld újra, vagy kérj kevesebbet (pl. kevesebb napot).';
    for (;;) {
      _live();
      final left = deadline - _since();
      if (left <= Duration.zero) throw LlmTimeout(deadlineMsg);
      try {
        // The call races the user's "Mégse": a provider that is slow to give
        // up (or cannot) must not keep the request alive.
        final reply = await Future.any<LlmReply>([
          provider.generate(model, req),
          _cancelSignal.future.then<LlmReply>(
            (_) => throw const LlmCancelled(),
          ),
        ]).timeout(left, onTimeout: () => throw LlmTimeout(deadlineMsg));
        // Only an ANSWERED call is counted (a rate limit or a server error
        // used nothing), with what the service said it cost.
        _usage = _usage + (reply.usage ?? LlmUsage.zero);
        await settingsStore.recordCall(
          provider: providerId,
          model: model,
          usage: reply.usage,
        );
        return reply;
      } on LlmRateLimit catch (e) {
        final wait = e.retryAfter;
        if (rateWaits < 2 &&
            e.transient &&
            wait != null &&
            wait <= const Duration(seconds: 60) &&
            _fits(wait + const Duration(seconds: 1))) {
          rateWaits++;
          _onStatus?.call(
            'Limit miatt várok ${wait.inSeconds + 1} másodpercet…',
          );
          await _delay(wait + const Duration(seconds: 1));
          _live();
          _onStatus?.call('Újra próbálom…');
          continue;
        }
        rethrow;
      } on LlmNetwork catch (e) {
        // closing the connection to cancel fails the call: not a reason to retry
        _live();
        if (e.retryable &&
            netRetries < _netBackoff.length &&
            _fits(_netBackoff[netRetries])) {
          final wait = _netBackoff[netRetries++];
          _onStatus?.call('A szolgáltatás nem válaszolt, újra próbálom…');
          await _delay(wait);
          _live();
          continue;
        }
        rethrow;
      }
    }
  }
}
