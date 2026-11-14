part of '../assistant_service.dart';

/// A request that asks to change the existing events by hand ("kézzel")
/// may only touch what the user entered by hand.
final _manualOnly = RegExp(r'kézzel|kézi|manuális');

// What the model proposed, checked by code before the user sees it: the
// hard rules, the references, the deletions and the moves. Part of the
// library of AssistantService (it works on the service's own state).
extension _ProposalChecks on AssistantService {
  Future<({AssistantOutcome? outcome, Map<String, Object?>? feedback})>
  _propose(Map<String, Object?> args, {required int repairsLeft}) async {
    final raw = parseProposal(args, defaultTz: _tz);
    final dropped = [...raw.problems];
    // what the screen shows as "hard" is the code's verdict (the model's word
    // is one vote), the one the rules below judge by
    final linked = [
      for (final i in _withinHorizon(
        await _attachTasks(raw.items, dropped),
        dropped,
      ))
        i.withHard(i.isHardSession(rules: _rules)),
    ];
    final parsed = ParsedProposal(
      summary: raw.summary,
      items: linked,
      problems: raw.problems,
      questions: raw.questions,
    );

    // Without the user's own edit request any attempt to delete / move is a
    // refusal below, never a reason for a repair round (a plan carries no
    // references, so an invented one could only be "repaired" into more cost).
    final wantsDeletes = _editIntent
        ? parseDeletions(args).items.isNotEmpty ||
              parseMoves(args, defaultTz: _tz).items.isNotEmpty
        : _asked(args, 'deletions') || _asked(args, 'moves');
    if (parsed.items.isEmpty) {
      if (repairsLeft > 0 && parsed.questions.isEmpty && !wantsDeletes) {
        // everything that was wrong goes back, the deletion / move problems
        // (a garbled or made-up reference) included
        final problems = [
          ...dropped,
          if (_editIntent) ...parseDeletions(args).problems,
          if (_editIntent) ...parseMoves(args, defaultTz: _tz).problems,
        ];
        return (
          outcome: null,
          feedback: {
            'hibak': problems.isEmpty
                ? ['Nem érkezett egyetlen használható javaslat sem.']
                : [for (final p in problems) sanitizeText(p, max: 200)],
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

    final doomed = _editIntent
        ? {for (final d in parseDeletions(args).items) d.ref}
        : <String>{};
    final existing = [
      for (final o in await _existingAround(parsed.items))
        // events the user is asked to delete do not block the new plan
        if (!doomed.contains(occurrenceRef(o))) o,
    ];
    // The rules look further than the data window (the weeks and the 48 hours
    // around the proposal): a typed-in event found there is "foglalt" in what
    // goes back to the model as well, though the model never saw it.
    if (!_editIntent) {
      for (final o in existing) {
        if (titleHiddenWhenPlanning(o)) {
          _hiddenTitles
            ..add(o.title)
            ..add(sanitizeText(o.title, max: 300));
        }
      }
    }
    final energy = await _energyByDate();
    final forecast = await _forecastFor(_settings);
    final weatherByDate = {
      for (final w in forecast ?? <DayWeather>[]) w.day: w,
    };
    List<Violation> check(List<ProposalItem> items) => validateProposal(
      [for (final i in items) i.toBlock(rules: _rules)],
      existing: existing,
      rules: _rules,
      energyByDate: energy,
      weatherByDate: weatherByDate,
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
          'szabalysertesek': {
            for (final v in all)
              _mask(
                v.forModel(
                  events: _settings.events,
                  checkins: _settings.checkins,
                ),
              ),
          }.toList(),
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
      // Per-item reasons are already listed; add only what concerns the set
      // as a whole (rest between hard sessions, weekly cap, overlaps).
      for (final v in rest) {
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

  /// Text going back to the model with a typed-in event's real title in it
  /// ("„Fogorvos” ütközik …") gets the same "foglalt" the data had.
  String _mask(String text) {
    var t = text;
    for (final h in _hiddenTitles) {
      if (h.isNotEmpty) t = t.replaceAll('„$h”', '„$busyTitle”');
    }
    return t;
  }

  /// The model put something into the list [key] of its answer (whatever it
  /// is, before it is parsed).
  bool _asked(Map<String, Object?> args, String key) {
    final v = args[key];
    return v is List && v.isNotEmpty;
  }

  /// Turns the model's `ref`s into real occurrences. Anything that does not
  /// exist (made up, already gone) is dropped with a note; sharing events off
  /// means no deletions at all.
  Future<
    ({List<DeletionProposal> items, List<String> notes, List<String> fixable})
  >
  _resolveDeletions(Map<String, Object?> args, AiSettings settings) async {
    final parsed = parseDeletions(args);
    final notes = [...parsed.problems];
    // the notes a better answer of the model could clear (a garbled or made-up
    // reference); the others are refusals
    final fixable = [...parsed.problems];
    final out = <DeletionProposal>[];
    if (_asked(args, 'deletions') && !_editIntent) {
      return (
        items: out,
        notes: const [
          'Törlést csak akkor javaslok, ha kifejezetten kéred (pl. „töröld a holnapi edzést”).',
        ],
        fixable: const <String>[],
      );
    }
    if (parsed.items.isNotEmpty && !settings.events) {
      return (
        items: out,
        notes: [
          ...notes,
          'Törlés nem javasolható, mert az események megosztása ki van kapcsolva.',
        ],
        fixable: const <String>[],
      );
    }
    for (final d in parsed.items) {
      final ref = parseOccurrenceRef(d.ref)!;
      final around = await events.occurrences(
        ref.originalStart.subtract(const Duration(days: 1)),
        ref.originalStart.add(const Duration(days: 2)),
      );
      final hit = around.where((o) => occurrenceRef(o) == d.ref).firstOrNull;
      if (hit == null) {
        const gone =
            'A törlésre javasolt esemény nem található (talán már törölve van).';
        notes.add(gone);
        fixable.add(gone);
      } else if (hit.isShift) {
        // generated shifts are managed on the Beosztás page, never here
        notes.add(
          '„${hit.title}” műszak, azt a Beosztás oldalon lehet törölni.',
        );
      } else if (hit.aiGenerated && _manualOnly.hasMatch(_prompt)) {
        notes.add(
          '„${hit.title}” egy korábbi asszisztens-javaslat, nem kézzel felvett esemény, ezért nem javasoltam törlésre.',
        );
      } else {
        out.add(DeletionProposal(hit, d.reason));
      }
    }
    return (items: out, notes: notes, fixable: fixable);
  }

  /// Fills in the real task details (deadline, estimate, energy) for blocks
  /// that name a task. A task that does not exist, is done or deleted drops
  /// the block with a note, so a made-up id can never be scheduled.
  Future<List<ProposalItem>> _attachTasks(
    List<ProposalItem> items,
    List<String> notes,
  ) async {
    if (items.every((i) => i.taskId == null)) return items;
    final tasks = {
      for (final r in await records.all(kindTask)) r.id: TaskView(r),
    };
    final out = <ProposalItem>[];
    for (final i in items) {
      if (i.taskId == null) {
        out.add(i);
        continue;
      }
      // the model names a task by the short alias it was given (t1, t2 ...)
      final id = _taskAliasToId[i.taskId!.trim().toLowerCase()] ?? i.taskId!;
      final t = tasks[id];
      if (t == null || t.done || t.deleted) {
        notes.add(
          '„${i.title}”: a hivatkozott feladat nem található vagy már kész, ezért kihagytam.',
        );
        continue;
      }
      out.add(
        i.withTask(
          title: t.title,
          id: id,
          due: t.due,
          estimateMin: t.estimateMin,
          energy: t.energyNeed,
        ),
      );
    }
    return out;
  }

  /// Turns the model's move requests into real occurrences with a conflict
  /// check. Shifts and all-day events are never moved; a move that would
  /// overlap another event is dropped with a note.
  Future<({List<MoveProposal> items, List<String> notes, List<String> fixable})>
  _resolveMoves(Map<String, Object?> args, AiSettings settings) async {
    final parsed = parseMoves(args, defaultTz: _tz);
    final notes = [...parsed.problems];
    final fixable = [...parsed.problems];
    final out = <MoveProposal>[];
    if (_asked(args, 'moves') && !_editIntent) {
      return (
        items: out,
        notes: const [
          'Áthelyezést csak akkor javaslok, ha kifejezetten kéred (pl. „told át az edzést 19 órára”).',
        ],
        fixable: const <String>[],
      );
    }
    if (parsed.items.isNotEmpty && !settings.events) {
      return (
        items: out,
        notes: [
          ...notes,
          'Áthelyezés nem javasolható, mert az események megosztása ki van kapcsolva.',
        ],
        fixable: const <String>[],
      );
    }
    final doomed = {for (final d in parseDeletions(args).items) d.ref};
    for (final m in parsed.items) {
      final ref = parseOccurrenceRef(m.ref)!;
      final around = await events.occurrences(
        ref.originalStart.subtract(const Duration(days: 1)),
        ref.originalStart.add(const Duration(days: 2)),
      );
      final hit = around.where((o) => occurrenceRef(o) == m.ref).firstOrNull;
      if (hit == null) {
        const gone =
            'Az áthelyezésre javasolt esemény nem található (talán már törölve van).';
        notes.add(gone);
        fixable.add(gone);
        continue;
      }
      if (hit.isShift) {
        notes.add('„${hit.title}” műszak, azt nem lehet áthelyezni.');
        continue;
      }
      if (hit.allDay) {
        notes.add('„${hit.title}” egész napos, azt nem helyezem át.');
        continue;
      }
      final newOcc = ProposedBlock(
        title: hit.title,
        startUtc: m.startUtc,
        endUtc: m.endUtc,
        isWorkout: false,
        isHard: false,
      );
      final others = [
        for (final o in await events.occurrences(
          m.startUtc.subtract(const Duration(days: 1)),
          m.endUtc.add(const Duration(days: 1)),
        ))
          if (occurrenceRef(o) != m.ref && !doomed.contains(occurrenceRef(o)))
            o,
      ];
      final bad = validateProposal(
        [newOcc],
        existing: others,
        rules: rules,
      ).where((v) => v.code == 'conflict' || v.code == 'bad_range').toList();
      if (bad.isNotEmpty) {
        // a clash is the model's to fix: it can pick another time
        final clash = bad.map((v) => v.message).join('; ');
        notes.add(clash);
        fixable.add(clash);
        continue;
      }
      out.add(MoveProposal(hit, m.startWall, m.endWall, m.reason));
    }
    return (items: out, notes: notes, fixable: fixable);
  }

  /// Deleting / moving where nothing usable came out and every reason is one
  /// the model can fix (a made-up or garbled reference, a clash): the reasons
  /// go back to it instead of an empty answer. Nothing goes back when any
  /// reason is a refusal (shift, all-day event, "manual only"), when it asked a
  /// question, or when the events are not shared.
  Map<String, Object?>? _refFeedback(
    AssistantOutcome o,
    ({List<DeletionProposal> items, List<String> notes, List<String> fixable})
    del,
    ({List<MoveProposal> items, List<String> notes, List<String> fixable}) mv, {
    required int repairsLeft,
  }) {
    if (repairsLeft <= 0 || !_editIntent || !_settings.events) return null;
    if (o.items.isNotEmpty || o.questions.isNotEmpty) return null;
    if (del.items.isNotEmpty || mv.items.isNotEmpty) return null;
    final fixable = [...del.fixable, ...mv.fixable];
    final all = [...del.notes, ...mv.notes];
    if (fixable.isEmpty || all.length != fixable.length) return null;
    return {
      'hibak': [for (final f in fixable) _mask(sanitizeText(f, max: 200))],
      'feladat': 'Javítsd a hivatkozásokat (az r érték a kapott eseményadatból való), és hívd újra a propose_events eszközt.',
    };
  }

  /// Proposals must lie ahead of "now" and within 60 days: a wrong year or a
  /// runaway list can never reach the calendar with one tap.
  List<ProposalItem> _withinHorizon(
    List<ProposalItem> items,
    List<String> notes,
  ) {
    final from = _nowUtc;
    final to = from.add(const Duration(days: 60));
    final keep = <ProposalItem>[];
    for (final i in items) {
      if (!i.endUtc.isAfter(from)) {
        notes.add(
          '„${i.title}”: a javasolt időpont már elmúlt, ezért kihagytam.',
        );
      } else if (i.startUtc.isAfter(to)) {
        notes.add(
          '„${i.title}”: a javasolt időpont több mint 60 nap múlva van, ezért kihagytam.',
        );
      } else {
        keep.add(i);
      }
    }
    return keep;
  }

  /// What the rules compare a proposal with: the day before and after (buffer,
  /// shifts), 48 hours around it (rest between hard sessions) and the whole
  /// ISO weeks it touches (the weekly workout cap counts what is booked).
  Future<List<Occurrence>> _existingAround(List<ProposalItem> items) {
    var from = items.first.startUtc, to = items.first.endUtc;
    for (final i in items) {
      if (i.startUtc.isBefore(from)) from = i.startUtc;
      if (i.endUtc.isAfter(to)) to = i.endUtc;
    }
    final a = toWallClock(_tz, from), b = toWallClock(_tz, to);
    final monday = resolveWallClock(
      _tz,
      floating(a.year, a.month, a.day).subtract(Duration(days: a.weekday - 1)),
    );
    final nextMonday = resolveWallClock(
      _tz,
      floating(b.year, b.month, b.day).add(Duration(days: 8 - b.weekday)),
    );
    final near = from.subtract(const Duration(days: 2));
    final far = to.add(const Duration(days: 2));
    return events.occurrences(
      monday.isBefore(near) ? monday : near,
      nextMonday.isAfter(far) ? nextMonday : far,
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
