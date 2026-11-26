import 'package:rrule/rrule.dart';

import 'event.dart';
import 'shift_pattern.dart';
import 'time.dart';

const _maxIterations = 20000; // hard stop for runaway/infinite rules

/// How many parsed rules are remembered (the views ask for the same few
/// rules again and again; a handful of series is the normal case).
const _maxCachedRules = 256;
final _parsedRules = <String, RecurrenceRule>{};

/// Parses an RRULE. The `rrule` package only understands `WKST=MO`, while
/// other calendars (Google's web UI, Apple, Outlook) routinely write
/// `WKST=SU`. The week start only changes the result of weekly rules with an
/// interval above 1, so it is ignored instead of letting one such event make
/// every calendar view throw.
///
/// The result is remembered (the least recently used one is dropped after
/// [_maxCachedRules]); an unreadable rule throws every time and is never
/// remembered.
RecurrenceRule parseRule(String rule) {
  final known = _parsedRules.remove(rule);
  if (known != null) {
    _parsedRules[rule] = known; // most recently used goes last
    return known;
  }
  var s = rule.trim();
  if (s.startsWith('RRULE:')) s = s.substring('RRULE:'.length);
  final parts = s.split(';').where((p) {
    final u = p.trim().toUpperCase();
    return !(u.startsWith('WKST=') && u != 'WKST=MO');
  });
  final parsed = RecurrenceRule.fromString('RRULE:${parts.join(';')}');
  _parsedRules[rule] = parsed;
  if (_parsedRules.length > _maxCachedRules) {
    _parsedRules.remove(_parsedRules.keys.first);
  }
  return parsed;
}

/// Expands [master] (+ its exception instances) into occurrences overlapping
/// [from]..[to] (UTC instants).
///
/// Recurrence is evaluated on FLOATING wall-clock time and converted to
/// instants per occurrence, so "every Monday 09:00" stays 09:00 across DST.
/// Duration of timed events is real elapsed time (1 h stays 1 h over a switch).
///
/// A series is walked from its first instance, but only the instances that can
/// touch the window are turned into occurrences: converting a wall-clock time
/// to an instant needs zone lookups, and a series that started years ago has
/// hundreds of instances before the window.
///
/// The walk stops after a fixed number of instances (a safety net against
/// runaway rules). When that happens before the window's end was reached, the
/// occurrences after that point are missing; [onCapped] tells the caller so
/// (it is called at most once per call).
List<Occurrence> expand(
  CalEvent master,
  DateTime from,
  DateTime to, {
  List<CalEvent> overrides = const [],
  void Function()? onCapped,
}) {
  if (master.cancelled) return const [];
  assert(from.isUtc && to.isUtc);

  // What is the same for every instance is worked out once.
  final recurring = master.isRecurring;
  final isShift = isShiftNotes(master.notes);
  final Duration span = master.allDay
      ? master.end.difference(master.start)
      : master.endUtc.difference(master.startUtc);

  Occurrence ofMaster(DateTime wall) {
    if (master.allDay) {
      return Occurrence(
        eventId: master.id,
        title: master.title,
        startUtc: wall,
        endUtc: wall.add(span),
        originalStart: wall,
        allDay: true,
        colorId: master.colorId,
        recurring: recurring,
        isShift: isShift,
        aiGenerated: master.aiGenerated,
      );
    }
    final s = resolveWallClock(master.tzid!, wall);
    return Occurrence(
      eventId: master.id,
      title: master.title,
      startUtc: s,
      endUtc: s.add(span),
      originalStart: wall,
      allDay: false,
      tzid: master.tzid,
      colorId: master.colorId,
      recurring: recurring,
      isShift: isShift,
      aiGenerated: master.aiGenerated,
    );
  }

  Occurrence ofOverride(CalEvent e, DateTime original) => Occurrence(
    eventId: e.id,
    title: e.title,
    startUtc: e.startUtc,
    endUtc: e.endUtc,
    originalStart: original,
    allDay: e.allDay,
    tzid: e.tzid,
    isOverride: true,
    colorId: e.colorId,
    recurring: true,
    isShift: isShiftNotes(e.notes),
    aiGenerated: e.aiGenerated,
  );

  if (!recurring) {
    final o = ofMaster(master.start);
    return o.overlaps(from, to) ? [o] : const [];
  }

  final byOriginal = <DateTime, CalEvent>{
    for (final o in overrides)
      if (o.originalStart != null) o.originalStart!: o,
  };
  final exdates = master.exdates.toSet();
  final out = <Occurrence>[];

  // A wall-clock time is at most a day away from its instant (zone offsets
  // stay within +-14 h, a DST gap shifts by an hour), so an instance whose
  // wall time plus that day plus the duration is not after [from] has
  // surely ended before the window and needs no conversion at all.
  final skipUpTo = from.subtract(
    span + (master.allDay ? Duration.zero : const Duration(days: 1)),
  );

  // +-1 day slack covers every zone offset between wall-clock and UTC.
  final limit = to.add(const Duration(days: 2));
  var n = 0;
  for (final wall in parseRule(
    master.rrule!,
  ).getInstances(start: master.start)) {
    if (wall.isAfter(limit)) break;
    if (++n > _maxIterations) {
      onCapped?.call();
      break;
    }
    if (exdates.contains(wall)) continue;
    final override = byOriginal[wall];
    if (override != null) {
      if (override.cancelled) continue;
      final o = ofOverride(override, wall);
      if (o.overlaps(from, to)) out.add(o);
      continue;
    }
    if (!wall.isAfter(skipUpTo)) continue; // ended before the window
    final o = ofMaster(wall);
    if (o.overlaps(from, to)) out.add(o);
  }
  // Overrides moved INTO the window from an original date outside the scan.
  for (final o in overrides) {
    if (o.cancelled || o.originalStart == null) continue;
    if (out.any((x) => x.originalStart == o.originalStart)) continue;
    if (o.originalStart!.isAfter(limit)) {
      final occ = ofOverride(o, o.originalStart!);
      if (occ.overlaps(from, to)) out.add(occ);
    }
  }
  out.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  return out;
}

/// "This and following": ends [master]'s series right before [splitAt]
/// (floating original start of the first changed instance) and returns the
/// truncated master. COUNT rules are converted so totals stay correct.
/// Returns null if [splitAt] is the very first instance (series is replaced).
CalEvent? truncateSeries(CalEvent master, DateTime splitAt) {
  final rule = parseRule(master.rrule!);
  final before = rule
      .getInstances(start: master.start)
      .takeWhile((d) => d.isBefore(splitAt))
      .take(_maxIterations)
      .toList();
  if (before.isEmpty) return null;
  final truncated = RecurrenceRule(
    frequency: rule.frequency,
    interval: rule.interval,
    count: rule.count == null ? null : before.length,
    until: rule.count == null ? before.last : null,
    byWeekDays: rule.byWeekDays,
    byMonthDays: rule.byMonthDays,
    byMonths: rule.byMonths,
    byWeeks: rule.byWeeks,
    byYearDays: rule.byYearDays,
    bySetPositions: rule.bySetPositions,
    byHours: rule.byHours,
    byMinutes: rule.byMinutes,
    bySeconds: rule.bySeconds,
    weekStart: rule.weekStart,
  );
  return master.copyWith(rrule: truncated.toString());
}
