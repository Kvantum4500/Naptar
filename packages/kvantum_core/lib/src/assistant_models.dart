import 'event.dart';
import 'rules.dart';
import 'time.dart';

/// One event proposed by the AI assistant (as understood by the app).
class ProposalItem {
  const ProposalItem({
    required this.title,
    required this.startWall,
    required this.endWall,
    required this.tzid,
    required this.kind,
    required this.hard,
    required this.reason,
    this.taskId,
    this.taskTitle,
    this.taskDue,
    this.taskEstimateMin,
    this.taskEnergy,
  });

  /// Task this block works on (named by the model, details filled in by the
  /// app from the real task record).
  final String? taskId;
  final String? taskTitle;
  final DateTime? taskDue; // floating date
  final int? taskEstimateMin;
  final int? taskEnergy;

  ProposalItem withTask({
    required String title,
    DateTime? due,
    int? estimateMin,
    int? energy,
  }) => ProposalItem(
    title: this.title,
    startWall: startWall,
    endWall: endWall,
    tzid: tzid,
    kind: kind,
    hard: hard,
    reason: reason,
    taskId: taskId,
    taskTitle: title,
    taskDue: due,
    taskEstimateMin: estimateMin,
    taskEnergy: energy,
  );

  final String title;
  final DateTime startWall; // floating
  final DateTime endWall;
  final String tzid;

  /// workout | task | rest | other
  final String kind;
  final bool hard;
  final String reason;

  DateTime get startUtc => resolveWallClock(tzid, startWall);
  DateTime get endUtc => resolveWallClock(tzid, endWall);

  ProposedBlock toBlock() => ProposedBlock(
    title: title,
    startUtc: startUtc,
    endUtc: endUtc,
    isWorkout: kind == 'workout',
    isHard: hard,
    taskId: taskId,
    taskDue: taskDue,
    taskEstimateMin: taskEstimateMin,
    taskEnergy: taskEnergy,
  );
}

class ParsedProposal {
  const ParsedProposal({
    required this.summary,
    required this.items,
    required this.problems,
    required this.questions,
  });
  final String summary;
  final List<ProposalItem> items;

  /// Human-readable reasons why entries of the model's answer were dropped.
  final List<String> problems;

  /// Questions the model wants answered before it can plan.
  final List<String> questions;
}

const _kinds = {'workout', 'task', 'rest', 'other'};

/// Strictly reads the `propose_events` arguments the model produced. It never
/// throws: unusable entries are dropped and explained in [ParsedProposal.problems],
/// so one bad item cannot take the whole answer down (or sneak into the calendar).
ParsedProposal parseProposal(
  Object? json, {
  String defaultTz = 'Europe/Budapest',
}) {
  final problems = <String>[];
  final items = <ProposalItem>[];
  if (json is! Map) {
    return ParsedProposal(
      summary: '',
      items: const [],
      problems: const ['A modell válasza nem értelmezhető (nem objektum).'],
      questions: const [],
    );
  }
  final summary = _text(json['summary'], 400);
  final questions = [
    for (final q
        in (json['questions'] is List ? json['questions'] as List : const []))
      if (_text(q, 300).isNotEmpty) _text(q, 300),
  ];
  final raw = json['proposals'];
  if (raw != null && raw is! List) {
    problems.add('A „proposals” mező nem lista.');
  }
  final list = raw is List ? raw : const [];
  for (var i = 0; i < list.length; i++) {
    final n = i + 1;
    final it = list[i];
    if (it is! Map) {
      problems.add('$n. javaslat: nem objektum.');
      continue;
    }
    final title = _text(it['title'], 120);
    if (title.isEmpty) {
      problems.add('$n. javaslat: hiányzik a cím.');
      continue;
    }
    final tz = _text(it['tzid'], 60).isEmpty
        ? defaultTz
        : _text(it['tzid'], 60);
    try {
      locationOf(tz);
    } catch (_) {
      problems.add('$n. javaslat („$title”): ismeretlen időzóna: $tz.');
      continue;
    }
    final s = _wall(it['start'], tz);
    final e = _wall(it['end'], tz);
    if (s == null || e == null) {
      problems.add(
        '$n. javaslat („$title”): hibás vagy hiányzó kezdés/befejezés.',
      );
      continue;
    }
    if (!e.isAfter(s)) {
      problems.add(
        '$n. javaslat („$title”): a befejezés nem a kezdés után van.',
      );
      continue;
    }
    if (e.difference(s) > const Duration(hours: 12)) {
      problems.add('$n. javaslat („$title”): 12 óránál hosszabb.');
      continue;
    }
    final kind = _kinds.contains(it['kind']) ? it['kind'] as String : 'workout';
    items.add(
      ProposalItem(
        title: title,
        startWall: s,
        endWall: e,
        tzid: tz,
        kind: kind,
        hard: it['hard'] == true,
        reason: _text(it['reason'], 300),
        taskId: _text(it['taskId'], 100).isEmpty
            ? null
            : _text(it['taskId'], 100),
      ),
    );
  }
  return ParsedProposal(
    summary: summary,
    items: items,
    problems: problems,
    questions: questions,
  );
}

/// A move the model asked for: ONE existing occurrence gets a new time.
/// It only becomes a proposal the user must confirm with a button.
class MoveRequest {
  const MoveRequest({
    required this.ref,
    required this.startWall,
    required this.endWall,
    required this.tzid,
    required this.reason,
  });
  final String ref;
  final DateTime startWall; // floating
  final DateTime endWall;
  final String tzid;
  final String reason;

  DateTime get startUtc => resolveWallClock(tzid, startWall);
  DateTime get endUtc => resolveWallClock(tzid, endWall);
}

/// Reads the optional `moves` list of the `propose_events` arguments.
/// Never throws; at most [max] distinct references are kept.
({List<MoveRequest> items, List<String> problems}) parseMoves(
  Object? json, {
  String defaultTz = 'Europe/Budapest',
  int max = 20,
}) {
  final problems = <String>[];
  final out = <MoveRequest>[];
  final raw = json is Map ? json['moves'] : null;
  if (raw == null) return (items: out, problems: problems);
  if (raw is! List) {
    return (items: out, problems: const ['A „moves” mező nem lista.']);
  }
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final n = i + 1;
    final it = raw[i];
    final ref = it is Map && it['ref'] is String
        ? (it['ref'] as String).trim()
        : '';
    if (parseOccurrenceRef(ref) == null) {
      problems.add('$n. áthelyezés: hibás hivatkozás.');
      continue;
    }
    final m = it as Map;
    final tz = _text(m['tzid'], 60).isEmpty ? defaultTz : _text(m['tzid'], 60);
    try {
      locationOf(tz);
    } catch (_) {
      problems.add('$n. áthelyezés: ismeretlen időzóna: $tz.');
      continue;
    }
    final s = _wall(m['start'], tz);
    final e = _wall(m['end'], tz);
    if (s == null || e == null) {
      problems.add('$n. áthelyezés: hibás vagy hiányzó kezdés/befejezés.');
      continue;
    }
    if (!e.isAfter(s)) {
      problems.add('$n. áthelyezés: a befejezés nem a kezdés után van.');
      continue;
    }
    if (!seen.add(ref)) continue;
    if (out.length >= max) {
      problems.add(
        'Egyszerre legfeljebb $max áthelyezés javasolható; a többit kihagytam.',
      );
      break;
    }
    out.add(
      MoveRequest(
        ref: ref,
        startWall: s,
        endWall: e,
        tzid: tz,
        reason: _text(m['reason'], 300),
      ),
    );
  }
  return (items: out, problems: problems);
}

String _text(Object? v, int max) {
  final s = (v is String ? v : '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > max ? s.substring(0, max) : s;
}

/// Accepts "2026-05-04T18:00[:00]" (local wall clock) and, tolerantly, values
/// with a zone/offset, which are converted to the wall clock of [tz].
DateTime? _wall(Object? v, String tz) {
  if (v is! String) return null;
  final s = v.trim();
  final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(s);
  final d = DateTime.tryParse(s);
  if (d == null) return null;
  if (hasZone) return toWallClock(tz, d.toUtc());
  return DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
}

/// Stable reference to ONE occurrence of an event, handed to the model in the
/// calendar data so it can name what should be deleted: `<eventId>@<original start>`.
String occurrenceRef(Occurrence o) =>
    '${o.eventId}@${o.originalStart.toIso8601String()}';

({String eventId, DateTime originalStart})? parseOccurrenceRef(String ref) {
  final i = ref.lastIndexOf('@');
  if (i <= 0 || i == ref.length - 1) return null;
  final id = ref.substring(0, i);
  final t = DateTime.tryParse(ref.substring(i + 1));
  if (t == null || id.length > 100) return null;
  return (
    eventId: id,
    originalStart: DateTime.utc(
      t.year,
      t.month,
      t.day,
      t.hour,
      t.minute,
      t.second,
    ),
  );
}

/// A deletion the model asked for. It only ever becomes a proposal the user
/// must confirm with a button; nothing is deleted from this alone.
class DeletionRequest {
  const DeletionRequest(this.ref, this.reason);
  final String ref;
  final String reason;
}

/// Reads the optional `deletions` list of the `propose_events` arguments.
/// Never throws; at most [max] distinct references are kept.
({List<DeletionRequest> items, List<String> problems}) parseDeletions(
  Object? json, {
  int max = 20,
}) {
  final problems = <String>[];
  final out = <DeletionRequest>[];
  final raw = json is Map ? json['deletions'] : null;
  if (raw == null) return (items: out, problems: problems);
  if (raw is! List) {
    return (items: out, problems: const ['A „deletions” mező nem lista.']);
  }
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final it = raw[i];
    final ref = it is Map && it['ref'] is String
        ? (it['ref'] as String).trim()
        : '';
    if (parseOccurrenceRef(ref) == null) {
      problems.add('${i + 1}. törlés: hibás hivatkozás.');
      continue;
    }
    if (!seen.add(ref)) continue;
    if (out.length >= max) {
      problems.add(
        'Egyszerre legfeljebb $max törlés javasolható; a többit kihagytam.',
      );
      break;
    }
    out.add(DeletionRequest(ref, _text((it as Map)['reason'], 300)));
  }
  return (items: out, problems: problems);
}
