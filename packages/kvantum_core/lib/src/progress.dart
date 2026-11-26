/// What the progress page shows: the weeks of training, and how the days felt.
///
/// Everything here is arithmetic on the check-ins and the feedback after
/// workouts that are on the device already; nothing is guessed, and a number
/// that has nothing under it is `null` (never a zero that looks like data).
/// A week runs from Monday; a day is a floating date.
library;

import 'models.dart';
import 'week.dart';

/// The four things a daily check-in asks, 1 (bad) … 5 (great).
enum CheckInMetric {
  physical('Fizikai energia'),
  mental('Mentális energia'),
  mood('Hangulat'),
  sleep('Alvás');

  const CheckInMetric(this.label);

  /// For the screen.
  final String label;

  /// The answer of a check-in, or null when it was not given.
  int? of(CheckInView c) => switch (this) {
    CheckInMetric.physical => c.physical,
    CheckInMetric.mental => c.mental,
    CheckInMetric.mood => c.mood,
    CheckInMetric.sleep => c.sleep,
  };
}

/// One point of a series: a day and a value (an answer, or an average of
/// answers).
class DayValue {
  const DayValue(this.day, this.value);
  final DateTime day;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is DayValue && other.day == day && other.value == value;

  @override
  int get hashCode => Object.hash(day, value);

  @override
  String toString() => 'DayValue($day, $value)';
}

DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// The answers to [metric] on the days from [from] to [to] (both included),
/// oldest first. A deleted check-in and a day that did not answer are not
/// there.
List<DayValue> checkInSeries(
  Iterable<CheckInView> all,
  CheckInMetric metric, {
  required DateTime from,
  required DateTime to,
}) {
  final first = _day(from), last = _day(to);
  final out = <DayValue>[];
  for (final c in all) {
    if (c.deleted) continue;
    final day = c.date;
    final v = metric.of(c);
    if (day == null || v == null) continue;
    if (day.isBefore(first) || day.isAfter(last)) continue;
    out.add(DayValue(_day(day), v.toDouble()));
  }
  out.sort((a, b) => a.day.compareTo(b.day));
  return out;
}

/// For each point, the mean of the points of the [window] days that end on it
/// (the days without an answer are not counted as zeros: they are not there).
/// It smooths the ups and downs of single days into a trend.
List<DayValue> trailingAverage(List<DayValue> points, {int window = 7}) {
  final out = <DayValue>[];
  for (var i = 0; i < points.length; i++) {
    final start = points[i].day.subtract(Duration(days: window - 1));
    var sum = 0.0, n = 0;
    for (var j = i; j >= 0 && !points[j].day.isBefore(start); j--) {
      sum += points[j].value;
      n++;
    }
    out.add(DayValue(points[i].day, sum / n));
  }
  return out;
}

/// The mean of [values], or null when there is none.
double? mean(Iterable<num> values) {
  var sum = 0.0, n = 0;
  for (final v in values) {
    sum += v;
    n++;
  }
  return n == 0 ? null : sum / n;
}

/// One week of training, from the feedback after the workouts.
class WeekVolume {
  const WeekVolume({
    required this.monday,
    this.sessions = 0,
    this.skipped = 0,
    this.minutes = 0,
    this.minutesBySport = const {},
    this.bodyLoad,
    this.mindLoad,
    this.energyStart,
    this.energyEnd,
    this.experience,
  });

  /// The first day of the week.
  final DateTime monday;

  /// The workouts that happened, and the ones the user said did not.
  final int sessions;
  final int skipped;

  /// Their length together, and by kind of workout (see `sportKey`).
  final int minutes;
  final Map<String, int> minutesBySport;

  /// Averages over the sessions that were rated (1 … 5); null when none was.
  final double? bodyLoad;
  final double? mindLoad;
  final double? energyStart;
  final double? energyEnd;
  final double? experience;

  /// Nothing happened, nothing was skipped.
  bool get isEmpty => sessions == 0 && skipped == 0;

  /// How much energy the sessions took: the energy at the start minus at the
  /// end (positive: it dropped). Null unless both were rated.
  double? get energyDrop => energyStart == null || energyEnd == null
      ? null
      : energyStart! - energyEnd!;
}

/// The last [weeks] weeks up to the one that holds [today], oldest first, from
/// the feedback in [logs]. A week without a workout is there, empty (a gap in
/// the training is something to see). Feedback older than that is left out.
List<WeekVolume> weeklyVolumes(
  Iterable<WorkoutLogView> logs, {
  required DateTime today,
  int weeks = 12,
}) {
  final thisMonday = startOfWeek(today);
  final mondays = [
    for (var i = weeks - 1; i >= 0; i--)
      thisMonday.subtract(Duration(days: 7 * i)),
  ];
  final byWeek = <DateTime, List<WorkoutLogView>>{
    for (final m in mondays) m: [],
  };
  for (final l in logs) {
    final day = l.date;
    if (l.deleted || day == null) continue;
    byWeek[startOfWeek(day)]?.add(l);
  }
  return [for (final m in mondays) _volume(m, byWeek[m]!)];
}

WeekVolume _volume(DateTime monday, List<WorkoutLogView> logs) {
  final done = [
    for (final l in logs)
      if (l.done) l,
  ];
  final bySport = <String, int>{};
  var minutes = 0;
  for (final l in done) {
    final m = l.minutes ?? 0;
    minutes += m;
    final sport = l.sport.isEmpty ? 'edzes' : l.sport;
    bySport[sport] = (bySport[sport] ?? 0) + m;
  }
  return WeekVolume(
    monday: monday,
    sessions: done.length,
    skipped: logs.length - done.length,
    minutes: minutes,
    minutesBySport: bySport,
    bodyLoad: mean([for (final l in done) ?l.bodyLoad]),
    mindLoad: mean([for (final l in done) ?l.mindLoad]),
    energyStart: mean([for (final l in done) ?l.energyStart]),
    energyEnd: mean([for (final l in done) ?l.energyEnd]),
    experience: mean([for (final l in done) ?l.experience]),
  );
}

// ---------------------------------------------------------------- words

/// 3,3 (one decimal, a comma).
String oneDecimal(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// "45 perc", "3 óra", "2 óra 45 perc".
String minutesText(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m perc';
  return m == 0 ? '$h óra' : '$h óra $m perc';
}

/// How much two averages differ, in tenths, before the words call it a change.
const trendTenths = 3;

/// "javult", "romlott" or "nagyjából ugyanannyi": for numbers where more is
/// better (energy, mood, sleep, the experience). It judges the numbers as they
/// are shown, with one decimal: 3,3 against 3,0 is a change, 3,2 is not.
String trendWord(double now, double before) {
  final d = (now * 10).round() - (before * 10).round();
  if (d >= trendTenths) return 'javult';
  if (d <= -trendTenths) return 'romlott';
  return 'nagyjából ugyanannyi';
}

/// The lines under "Ez a hét": what the week had and how it compares with the
/// one before. [checkIns] and [checkInsBefore] are the averages of the days of
/// the two weeks (null: no answer that week).
List<String> weekSummary({
  required WeekVolume week,
  WeekVolume? before,
  Map<CheckInMetric, double?> checkIns = const {},
  Map<CheckInMetric, double?> checkInsBefore = const {},
}) {
  final lines = <String>[];

  if (week.sessions == 0) {
    lines.add('Ebben a héten még nem volt edzés.');
    if (week.skipped > 0) lines.add('Kihagyott edzés: ${week.skipped}.');
  } else {
    final then = before != null && before.sessions > 0
        ? ' (az előző héten ${before.sessions} edzés, ${minutesText(before.minutes)})'
        : '';
    lines.add(
      '${week.sessions} edzés, összesen ${minutesText(week.minutes)}$then.',
    );
    if (week.skipped > 0) lines.add('Kihagyott edzés: ${week.skipped}.');
    final body = week.bodyLoad, mind = week.mindLoad;
    if (body != null || mind != null) {
      lines.add(
        'Az edzések nehézsége átlagosan: ${[if (body != null) 'fizikailag ${oneDecimal(body)}/5', if (mind != null) 'szellemileg ${oneDecimal(mind)}/5'].join(', ')}.',
      );
    }
    final start = week.energyStart, end = week.energyEnd;
    if (start != null && end != null) {
      final drop = start - end;
      final span = '${oneDecimal(start)} → ${oneDecimal(end)} az 5-ös skálán';
      lines.add(
        drop.abs() < 0.1
            ? 'Az energiád az edzések alatt nem változott (${oneDecimal(start)}/5).'
            : 'Az energiád az edzések alatt átlagosan '
                  '${drop > 0 ? 'csökkent' : 'nőtt'} ($span).',
      );
    }
    final fun = week.experience;
    if (fun != null) {
      lines.add('Az élmény átlaga ${oneDecimal(fun)}/5.');
    }
  }

  for (final m in CheckInMetric.values) {
    final now = checkIns[m];
    if (now == null) continue;
    final was = checkInsBefore[m];
    lines.add(
      was == null
          ? '${m.label}: átlag ${oneDecimal(now)}/5.'
          : '${m.label}: átlag ${oneDecimal(now)}/5 (az előző héten '
                '${oneDecimal(was)}/5: ${trendWord(now, was)}).',
    );
  }
  return lines;
}

// ------------------------------------------------------------- the page

/// Everything the progress page draws and says, for the last [weeks] weeks.
class ProgressData {
  const ProgressData({
    required this.weeks,
    required this.days,
    required this.trend,
    required this.summary,
    required this.from,
    required this.to,
  });

  /// The weeks, oldest first; the last is the week that holds [to].
  final List<WeekVolume> weeks;

  /// The answers of the check-in, by metric, day by day.
  final Map<CheckInMetric, List<DayValue>> days;

  /// The same, smoothed (the average of the last 7 days that answered).
  final Map<CheckInMetric, List<DayValue>> trend;

  /// The lines under "Ez a hét".
  final List<String> summary;

  /// The first day of the first week, and today.
  final DateTime from;
  final DateTime to;

  /// Whether there is anything to draw.
  bool get hasData =>
      weeks.any((w) => !w.isEmpty) || days.values.any((d) => d.isNotEmpty);
}

/// The progress of the last [weeks] weeks (1 … 52) up to [today], from the
/// workout feedback and the check-ins.
ProgressData buildProgress({
  required Iterable<WorkoutLogView> logs,
  required Iterable<CheckInView> checkIns,
  required DateTime today,
  int weeks = 12,
}) {
  final n = weeks.clamp(1, 52);
  final volumes = weeklyVolumes(logs, today: today, weeks: n);
  final from = volumes.first.monday;
  final to = DateTime.utc(today.year, today.month, today.day);
  final days = <CheckInMetric, List<DayValue>>{
    for (final m in CheckInMetric.values)
      m: checkInSeries(checkIns, m, from: from, to: to),
  };

  // the averages of this week so far, and of the whole week before
  final thisMonday = volumes.last.monday;
  final lastMonday = thisMonday.subtract(const Duration(days: 7));
  double? average(CheckInMetric m, DateTime first, DateTime last) => mean([
    for (final p in days[m]!)
      if (!p.day.isBefore(first) && !p.day.isAfter(last)) p.value,
  ]);
  final now = <CheckInMetric, double?>{};
  final before = <CheckInMetric, double?>{};
  for (final m in CheckInMetric.values) {
    now[m] = average(m, thisMonday, to);
    // (the week before is in the series only when the range reaches back to
    // it; when it does not there is nothing to average: null)
    before[m] = average(
      m,
      lastMonday,
      thisMonday.subtract(const Duration(days: 1)),
    );
  }

  return ProgressData(
    weeks: volumes,
    days: days,
    trend: {for (final m in CheckInMetric.values) m: trailingAverage(days[m]!)},
    summary: weekSummary(
      week: volumes.last,
      before: n > 1 ? volumes[volumes.length - 2] : null,
      checkIns: now,
      checkInsBefore: before,
    ),
    from: from,
    to: to,
  );
}
