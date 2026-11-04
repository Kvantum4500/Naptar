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
  });

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
