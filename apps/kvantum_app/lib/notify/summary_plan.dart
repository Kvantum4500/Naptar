import 'package:kvantum_core/kvantum_core.dart';

import '../ui/day_utils.dart';

/// How many days after today get a morning summary (today included: eight
/// notifications at most). The text of a notification is fixed when it is
/// scheduled, so the further a day lies ahead, the more the calendar can
/// change before it comes; the plan is made again at every change.
const summaryHorizonDays = 7;

/// What one day holds, before it is put into words.
class DayContent {
  const DayContent({
    required this.day,
    required this.events,
    required this.tasks,
    required this.special,
  });

  /// Floating date in the display zone.
  final DateTime day;
  final List<SummaryEvent> events;
  final List<SummaryTask> tasks;

  /// A holiday or a moved working day.
  final HuDay? special;
}

/// What today and the next [days] days hold (every day, empty ones too):
///
///  * events: every occurrence that touches the day (in [tzid]);
///  * tasks: the open ones due on the day; on today also the overdue ones;
///  * the special day (holiday, working Saturday).
List<DayContent> dayContents({
  required DateTime nowUtc,
  required List<Occurrence> occurrences,
  required List<TaskView> tasks,
  String tzid = defaultTz,
  int days = summaryHorizonDays,
}) {
  final today = todayIn(nowUtc, tz: tzid);

  // the days each occurrence touches, worked out once
  final touching = <DateTime, List<SummaryEvent>>{};
  for (final o in occurrences) {
    final ev = SummaryEvent(
      title: o.title,
      start: o.allDay ? dateOnly(o.startUtc) : toWallClock(tzid, o.startUtc),
      end: o.allDay ? dateOnly(o.endUtc) : toWallClock(tzid, o.endUtc),
      allDay: o.allDay,
    );
    for (final d in daysOf(o, tz: tzid)) {
      (touching[d] ??= []).add(ev);
    }
  }

  final open = [
    for (final t in tasks)
      if (!t.done && !t.deleted && t.due != null) t,
  ];

  return [
    for (var i = 0; i <= days; i++)
      () {
        final day = today.add(Duration(days: i));
        final overdue = i == 0
            ? ([
                for (final t in open)
                  if (dateOnly(t.due!).isBefore(day)) t,
              ]..sort((a, b) => a.due!.compareTo(b.due!)))
            : const <TaskView>[];
        return DayContent(
          day: day,
          events: touching[day] ?? const [],
          tasks: [
            for (final t in overdue) SummaryTask(t.title, overdue: true),
            for (final t in open)
              if (dateOnly(t.due!) == day) SummaryTask(t.title),
          ],
          special: huDayInfo(day),
        );
      }(),
  ];
}

/// The morning summaries of today and the next [days] days, by floating date.
/// A day with nothing to say has none. The weather line of a day comes from
/// [forecast], when it has the day.
Map<DateTime, DaySummary> summariesFor({
  required DateTime nowUtc,
  required List<Occurrence> occurrences,
  required List<TaskView> tasks,
  List<DayWeather>? forecast,
  String tzid = defaultTz,
  int days = summaryHorizonDays,
}) {
  final out = <DateTime, DaySummary>{};
  for (final c in dayContents(
    nowUtc: nowUtc,
    occurrences: occurrences,
    tasks: tasks,
    tzid: tzid,
    days: days,
  )) {
    DayWeather? w;
    for (final f in forecast ?? const <DayWeather>[]) {
      if (dateOnly(f.day) == c.day) w = f;
    }
    final line = w == null ? '' : weatherLine(w);
    final summary = buildDaySummary(
      day: c.day,
      events: c.events,
      tasks: c.tasks,
      special: c.special,
      weather: line.isEmpty ? null : line,
    );
    if (summary != null) out[c.day] = summary;
  }
  return out;
}
