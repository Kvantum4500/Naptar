import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_repository.dart';
import '../data/record_repository.dart';
import 'ai_settings.dart';
import 'handbook_store.dart';
import 'llm_provider.dart';

const _tools = <ToolDecl>[
  ToolDecl(
    'get_events',
    'A naptár eseményei egy időszakban (helyi napok, a záró nap is benne van).',
    {
      'type': 'object',
      'properties': {
        'from': {
          'type': 'string',
          'description': 'Első nap, YYYY-MM-DD. Alapból ma.',
        },
        'to': {
          'type': 'string',
          'description': 'Utolsó nap, YYYY-MM-DD. Alapból 14 nappal később.',
        },
      },
    },
  ),
  ToolDecl(
    'get_tasks',
    'A nyitott feladatok (határidő, becsült idő, prioritás, energiaigény).',
    {'type': 'object', 'properties': <String, Object?>{}},
  ),
  ToolDecl(
    'get_checkins',
    'A napi check-inek (fizikai/mentális energia, hangulat, alvás, 1–5).',
    {
      'type': 'object',
      'properties': {
        'days': {
          'type': 'integer',
          'description': 'Hány napra visszamenőleg (1–30). Alapból 7.',
        },
      },
    },
  ),
  ToolDecl(
    'find_free_slots',
    'Szabad idősávok (alvási sávon kívül, a meglévő események és a puffer nélkül).',
    {
      'type': 'object',
      'properties': {
        'from': {
          'type': 'string',
          'description': 'Első nap, YYYY-MM-DD. Alapból ma.',
        },
        'to': {
          'type': 'string',
          'description': 'Utolsó nap, YYYY-MM-DD. Alapból 7 nappal később.',
        },
        'minutes': {
          'type': 'integer',
          'description':
              'Legalább ennyi perces szabad rész (15–480). Alapból 60.',
        },
      },
    },
  ),
  ToolDecl(
    'propose_events',
    'A végső terv leadása. Csak ÚJ eseményeket javasolhat; a felhasználó jóváhagyása után kerülnek a naptárba.',
    {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '1–2 mondat a tervről.'},
        'proposals': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'start': {
                'type': 'string',
                'description': 'Helyi idő zóna nélkül: 2026-05-04T18:00:00',
              },
              'end': {
                'type': 'string',
                'description': 'Helyi idő zóna nélkül.',
              },
              'tzid': {'type': 'string', 'description': 'Pl. Europe/Budapest'},
              'kind': {
                'type': 'string',
                'enum': ['workout', 'task', 'rest', 'other'],
              },
              'hard': {'type': 'boolean', 'description': 'Nehéz edzés-e.'},
              'reason': {'type': 'string', 'description': 'Miért ide került.'},
            },
            'required': ['title', 'start', 'end'],
          },
        },
        'questions': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Visszakérdezések, ha kevés az adat.',
        },
      },
      'required': ['proposals'],
    },
  ),
];

/// What the assistant came back with.
class AssistantOutcome {
  const AssistantOutcome({
    this.text = '',
    this.summary = '',
    this.items = const [],
    this.dropped = const [],
    this.questions = const [],
    this.calls = 0,
  });

  /// Plain answer (e.g. a question) when no plan was proposed.
  final String text;
  final String summary;

  /// Proposals that passed every rule; only these can be accepted.
  final List<ProposalItem> items;

  /// Why parts of the answer were not offered (parse problems, rule violations).
  final List<String> dropped;
  final List<String> questions;
  final int calls;

  bool get hasPlan => items.isNotEmpty;
}

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
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future.delayed;

  final LLMProvider provider;
  final EventRepository events;
  final RecordRepository records;
  final HandbookStore handbook;
  final AiSettingsStore settingsStore;
  final PlanRules rules;
  final int maxCalls;
  final int maxRepairs;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  String get _tz => rules.tzid;
  DateTime get _nowUtc => _now().toUtc();
  DateTime get _today {
    final w = toWallClock(_tz, _nowUtc);
    return floating(w.year, w.month, w.day);
  }

  Future<AssistantOutcome> ask(
    String prompt, {
    required String model,
    required AiSettings settings,
  }) async {
    final system = buildSystemPrompt(
      handbook: await handbook.combined(),
      nowUtc: _nowUtc,
      rules: rules,
    );
    final turns = <LlmTurn>[
      LlmTurn('user', [LlmText(prompt)]),
    ];
    var repairs = 0;
    for (var call = 1; call <= maxCalls; call++) {
      final reply = await _generate(
        model,
        LlmRequest(
          system: system,
          turns: List.unmodifiable(turns),
          tools: _tools,
        ),
      );
      turns.add(LlmTurn('model', reply.parts));
      final calls = reply.toolCalls;
      if (calls.isEmpty) return AssistantOutcome(text: reply.text, calls: call);

      final results = <LlmPart>[];
      for (final c in calls) {
        if (c.name == 'propose_events') {
          final r = await _propose(c.args, repairsLeft: maxRepairs - repairs);
          if (r.outcome != null) {
            final o = r.outcome!;
            return AssistantOutcome(
              text: reply.text,
              summary: o.summary,
              items: o.items,
              dropped: o.dropped,
              questions: o.questions,
              calls: call,
            );
          }
          repairs++;
          results.add(LlmToolResult('propose_events', r.feedback!));
        } else {
          results.add(LlmToolResult(c.name, await _runTool(c, settings)));
        }
      }
      turns.add(LlmTurn('user', results));
    }
    return AssistantOutcome(
      text: 'Nem sikerült érvényes tervet összeállítanom a megengedett lépésszámon belül. Próbáld pontosabban megfogalmazni a kérést.',
      calls: maxCalls,
    );
  }

  // ------------------------------------------------------------- model call

  Future<LlmReply> _generate(String model, LlmRequest req) async {
    for (var attempt = 0; ; attempt++) {
      await settingsStore.bumpUsage();
      try {
        return await provider.generate(model, req);
      } on LlmRateLimit catch (e) {
        final wait = e.retryAfter;
        if (attempt == 0 &&
            wait != null &&
            wait <= const Duration(seconds: 30)) {
          await _delay(wait);
          continue;
        }
        rethrow;
      }
    }
  }

  // ------------------------------------------------------------------ tools

  Future<Map<String, Object?>> _runTool(LlmToolCall c, AiSettings s) async {
    switch (c.name) {
      case 'get_events':
        final from = _day(c.args['from'], _today);
        final to = _clampTo(
          from,
          _day(c.args['to'], from.add(const Duration(days: 14))),
          60,
        );
        final occ = await events.occurrences(
          resolveWallClock(_tz, from),
          resolveWallClock(_tz, to.add(const Duration(days: 1))),
        );
        return eventsForTool(occ, tz: _tz, enabled: s.events);
      case 'get_tasks':
        final tasks = [
          for (final r in await records.all(kindTask)) TaskView(r),
        ];
        return tasksForTool(tasks, today: _today, enabled: s.tasks);
      case 'get_checkins':
        final days = ((c.args['days'] as num?)?.toInt() ?? 7).clamp(1, 30);
        final list = [
          for (final r in await records.all(kindCheckIn)) CheckInView(r),
        ];
        return checkinsForTool(
          list,
          today: _today,
          days: days,
          enabled: s.checkins,
        );
      case 'find_free_slots':
        final from = _day(c.args['from'], _today);
        final to = _clampTo(
          from,
          _day(c.args['to'], from.add(const Duration(days: 7))),
          21,
        );
        final minutes = ((c.args['minutes'] as num?)?.toInt() ?? 60).clamp(
          15,
          480,
        );
        final fromUtc = resolveWallClock(_tz, from);
        final toUtc = resolveWallClock(_tz, to.add(const Duration(days: 1)));
        // With event sharing off the model must not learn when the user is busy:
        // slots then only reflect the sleep window, and the local rule check
        // rejects any clash with real events afterwards.
        final busy = s.events
            ? await events.occurrences(fromUtc, toUtc)
            : <Occurrence>[];
        final slots = findFreeSlots(
          busy: busy,
          fromUtc: fromUtc,
          toUtc: toUtc,
          minLength: Duration(minutes: minutes),
          rules: rules,
        );
        String hm(DateTime w) =>
            '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
        String ymd(DateTime w) =>
            '${w.year}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}';
        return {
          'adat_tipus': 'szabad_idosavok',
          'darab': slots.length,
          if (!s.events) 'megjegyzes': 'Az események nem láthatók; a javaslat ütközését a program ellenőrzi.',
          'idosavok': [
            for (final sl in slots.take(40))
              () {
                final a = toWallClock(_tz, sl.startUtc),
                    b = toWallClock(_tz, sl.endUtc);
                return {'nap': ymd(a), 'kezdes': hm(a), 'veg': hm(b)};
              }(),
          ],
        };
      default:
        return {'hiba': 'Ismeretlen eszköz: ${c.name}'};
    }
  }

  DateTime _day(Object? v, DateTime fallback) {
    if (v is! String) return fallback;
    final d = DateTime.tryParse(v.trim());
    return d == null ? fallback : floating(d.year, d.month, d.day);
  }

  DateTime _clampTo(DateTime from, DateTime to, int maxDays) {
    if (to.isBefore(from)) return from;
    final limit = from.add(Duration(days: maxDays - 1));
    return to.isAfter(limit) ? limit : to;
  }

  // ---------------------------------------------------------------- proposal

  Future<({AssistantOutcome? outcome, Map<String, Object?>? feedback})>
  _propose(Map<String, Object?> args, {required int repairsLeft}) async {
    final parsed = parseProposal(args, defaultTz: _tz);
    final dropped = [...parsed.problems];

    if (parsed.items.isEmpty) {
      if (repairsLeft > 0 && parsed.questions.isEmpty) {
        return (
          outcome: null,
          feedback: {
            'hibak': parsed.problems.isEmpty
                ? ['Nem érkezett egyetlen használható javaslat sem.']
                : parsed.problems,
            'feladat': 'Javítsd, és hívd újra a propose_events eszközt.',
          },
        );
      }
      return (
        outcome: AssistantOutcome(
          summary: parsed.summary,
          dropped: dropped,
          questions: parsed.questions,
        ),
        feedback: null,
      );
    }

    final existing = await _existingAround(parsed.items);
    final energy = await _energyByDate();
    List<Violation> check(List<ProposalItem> items) => validateProposal(
      [for (final i in items) i.toBlock()],
      existing: existing,
      rules: rules,
      energyByDate: energy,
    );

    final all = check(parsed.items);
    if (all.isEmpty) {
      return (
        outcome: AssistantOutcome(
          summary: parsed.summary,
          items: parsed.items,
          dropped: dropped,
          questions: parsed.questions,
        ),
        feedback: null,
      );
    }
    if (repairsLeft > 0) {
      return (
        outcome: null,
        feedback: {
          'szabalysertesek': [for (final v in all) v.message],
          'feladat': 'Javítsd a javaslatot úgy, hogy ne sértse a szabályokat (használd a find_free_slots eszközt), majd hívd újra a propose_events eszközt.',
        },
      );
    }

    // Out of repairs: keep only the items that are individually clean, and
    // offer them only if that remainder is clean as a whole.
    final clean = <ProposalItem>[];
    for (final i in parsed.items) {
      final own = check([i]);
      if (own.isEmpty) {
        clean.add(i);
      } else {
        dropped.add(
          '„${i.title}” nem fér a szabályokba: ${own.map((v) => v.message).join('; ')}',
        );
      }
    }
    final rest = clean.isEmpty ? <Violation>[] : check(clean);
    if (clean.isEmpty || rest.isNotEmpty) {
      for (final v in rest) {
        dropped.add(v.message);
      }
      for (final v in all) {
        if (!dropped.contains(v.message)) dropped.add(v.message);
      }
      return (
        outcome: AssistantOutcome(
          summary: parsed.summary,
          dropped: dropped,
          questions: parsed.questions,
        ),
        feedback: null,
      );
    }
    return (
      outcome: AssistantOutcome(
        summary: parsed.summary,
        items: clean,
        dropped: dropped,
        questions: parsed.questions,
      ),
      feedback: null,
    );
  }

  Future<List<Occurrence>> _existingAround(List<ProposalItem> items) {
    var from = items.first.startUtc, to = items.first.endUtc;
    for (final i in items) {
      if (i.startUtc.isBefore(from)) from = i.startUtc;
      if (i.endUtc.isAfter(to)) to = i.endUtc;
    }
    return events.occurrences(
      from.subtract(const Duration(days: 1)),
      to.add(const Duration(days: 1)),
    );
  }

  Future<Map<DateTime, int>> _energyByDate() async => {
    for (final r in await records.all(kindCheckIn))
      if (CheckInView(r).date != null &&
          CheckInView(r).physical != null &&
          !r.deleted)
        CheckInView(r).date!: CheckInView(r).physical!,
  };
}
