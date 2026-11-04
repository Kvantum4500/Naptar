import 'event.dart';
import 'rules.dart';
import 'time.dart';

class TimeSlot {
  const TimeSlot(this.startUtc, this.endUtc);
  final DateTime startUtc;
  final DateTime endUtc;
  Duration get length => endUtc.difference(startUtc);
  @override
  String toString() => 'TimeSlot($startUtc..$endUtc)';
}

class _Iv {
  _Iv(this.s, this.e);
  final DateTime s;
  final DateTime e;
}

/// Free windows between [fromUtc] and [toUtc] where something of at least
/// [minLength] fits: outside the sleep window, and clear of every existing
/// timed event including the rule buffer. All-day events do not block.
///
/// Computed on local wall-clock days of [PlanRules.tzid] and converted to
/// instants per boundary, so 23/25-hour DST days come out right.
List<TimeSlot> findFreeSlots({
  required List<Occurrence> busy,
  required DateTime fromUtc,
  required DateTime toUtc,
  Duration minLength = const Duration(minutes: 30),
  required PlanRules rules,
}) {
  assert(fromUtc.isUtc && toUtc.isUtc);
  if (!toUtc.isAfter(fromUtc)) return const [];

  // 1) awake intervals, day by day (a day before/after the window is included
  //    so a sleep window that wraps midnight is handled at the edges)
  final firstDay = toWallClock(rules.tzid, fromUtc);
  final lastDay = toWallClock(rules.tzid, toUtc);
  final awake = <_Iv>[];
  var day = floating(firstDay.year, firstDay.month, firstDay.day);
  final end = floating(lastDay.year, lastDay.month, lastDay.day);
  while (!day.isAfter(end)) {
    final next = day.add(const Duration(days: 1));
    DateTime at(DateTime d, int h) =>
        resolveWallClock(rules.tzid, floating(d.year, d.month, d.day, h));
    DateTime midnight(DateTime d) =>
        resolveWallClock(rules.tzid, floating(d.year, d.month, d.day));
    if (rules.sleepStartHour > rules.sleepEndHour) {
      // usual: sleep 23:00 -> 07:00, awake 07:00..23:00 the same day
      awake.add(
        _Iv(at(day, rules.sleepEndHour), at(day, rules.sleepStartHour)),
      );
    } else {
      // sleep lies inside the day (e.g. 01:00..09:00): awake before and after
      awake.add(_Iv(midnight(day), at(day, rules.sleepStartHour)));
      awake.add(_Iv(at(day, rules.sleepEndHour), midnight(next)));
    }
    day = next;
  }

  // 2) clip to the window
  var free = <_Iv>[
    for (final a in awake)
      if (a.e.isAfter(fromUtc) && a.s.isBefore(toUtc))
        _Iv(
          a.s.isBefore(fromUtc) ? fromUtc : a.s,
          a.e.isAfter(toUtc) ? toUtc : a.e,
        ),
  ];

  // 3) subtract busy events (+ buffer on both sides)
  final buffer = Duration(minutes: rules.bufferMinutes);
  final blocks = [
    for (final b in busy)
      if (!b.allDay) _Iv(b.startUtc.subtract(buffer), b.endUtc.add(buffer)),
  ]..sort((a, b) => a.s.compareTo(b.s));
  for (final b in blocks) {
    final next = <_Iv>[];
    for (final f in free) {
      if (!b.e.isAfter(f.s) || !b.s.isBefore(f.e)) {
        next.add(f);
        continue;
      }
      if (b.s.isAfter(f.s)) next.add(_Iv(f.s, b.s));
      if (b.e.isBefore(f.e)) next.add(_Iv(b.e, f.e));
    }
    free = next;
  }

  return [
    for (final f in free)
      if (f.e.difference(f.s) >= minLength) TimeSlot(f.s, f.e),
  ]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
}
