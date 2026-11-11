import 'package:kvantum_core/kvantum_core.dart';

const defaultTz = 'Europe/Budapest';

DateTime dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Today's date (a floating y/m/d) in the display zone [tz]: the day the
/// calendar draws, wherever the device thinks it is (a phone abroad, a PC set
/// to another zone).
DateTime todayIn(DateTime now, {String tz = defaultTz}) =>
    dateOnly(toWallClock(tz, now.toUtc()));

/// Calendar days (floating dates, in [tz]) that an occurrence touches.
/// All-day events are zone-independent; their end date is exclusive.
List<DateTime> daysOf(Occurrence o, {String tz = defaultTz}) {
  final DateTime first;
  final DateTime last;
  if (o.allDay) {
    first = dateOnly(o.startUtc);
    last = dateOnly(o.endUtc.subtract(const Duration(days: 1)));
  } else {
    first = dateOnly(toWallClock(tz, o.startUtc));
    final endWall = toWallClock(tz, o.endUtc);
    // An event ending exactly at midnight does not touch the next day.
    final lastWall = endWall.isAfter(toWallClock(tz, o.startUtc))
        ? endWall.subtract(const Duration(seconds: 1))
        : endWall;
    last = dateOnly(lastWall);
  }
  final out = <DateTime>[];
  for (var d = first; !d.isAfter(last); d = d.add(const Duration(days: 1))) {
    out.add(d);
  }
  return out.isEmpty ? [first] : out;
}

/// UTC instants covering the calendar days [from]..[toExclusive] in [tz].
(DateTime, DateTime) windowOf(
  DateTime from,
  DateTime toExclusive, {
  String tz = defaultTz,
}) => (resolveWallClock(tz, from), resolveWallClock(tz, toExclusive));

/// 42-cell month grid (6 weeks), Monday-based.
List<DateTime> monthGrid(DateTime month, {int weekStart = DateTime.monday}) {
  final first = DateTime.utc(month.year, month.month, 1);
  final start = startOfWeek(first, weekStart: weekStart);
  return List.generate(42, (i) => start.add(Duration(days: i)));
}
