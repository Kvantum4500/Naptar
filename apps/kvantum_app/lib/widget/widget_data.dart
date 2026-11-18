import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';

import '../notify/summary_plan.dart';
import '../ui/day_utils.dart';

/// How many days after today the snapshot holds. The widget shows the day it
/// finds for the moment it is drawn, so it moves on to the next day by itself,
/// even if the app is not opened for a few days.
const widgetDays = 6;

/// How many of the next shifts the snapshot holds.
const widgetShifts = 3;

/// What the home-screen widget shows, as JSON text (the Android side only
/// reads it; see TodayWidgetContent.kt):
///
///     {"v":1,"tz":"Europe/Budapest",
///      "days":[{"from":ms,"to":ms,"label":"hétfő, nov. 16.",
///               "special":"Munkaszüneti nap: Újév"|null,
///               "lines":["08:00 Műszak","Feladat: ..."]}, ...],
///      "shifts":[{"at":ms,"text":"kedd, nov. 17. 18:00 Éjszakai műszak"}, ...]}
///
/// A day lasts from [from] to [to] (epoch milliseconds, in [tzid]); the lines
/// are its events and tasks, as in the morning summary. There is no time of
/// writing in it, so that an unchanged calendar gives the same text and the
/// widget is not asked to redraw for nothing.
String widgetSnapshot({
  required DateTime nowUtc,
  required List<Occurrence> occurrences,
  required List<TaskView> tasks,
  String tzid = defaultTz,
}) {
  final days = <Map<String, Object?>>[];
  for (final c in dayContents(
    nowUtc: nowUtc,
    occurrences: occurrences,
    tasks: tasks,
    tzid: tzid,
    days: widgetDays,
  )) {
    final summary = buildDaySummary(
      day: c.day,
      events: c.events,
      tasks: c.tasks,
      maxEvents: 5,
      maxTasks: 2,
    );
    days.add({
      'from': resolveWallClock(tzid, c.day).millisecondsSinceEpoch,
      'to': resolveWallClock(
        tzid,
        c.day.add(const Duration(days: 1)),
      ).millisecondsSinceEpoch,
      'label': huDateLabel(c.day),
      'special': c.special?.label,
      'lines': summary == null ? const <String>[] : summary.body.split('\n'),
    });
  }

  final shifts = [
    for (final o in occurrences)
      if (o.isShift && !o.allDay && o.startUtc.isAfter(nowUtc)) o,
  ]..sort((a, b) => a.startUtc.compareTo(b.startUtc));

  return jsonEncode({
    'v': 1,
    'tz': tzid,
    'days': days,
    'shifts': [
      for (final o in shifts.take(widgetShifts))
        {'at': o.startUtc.millisecondsSinceEpoch, 'text': _shiftText(o, tzid)},
    ],
  });
}

String _shiftText(Occurrence o, String tzid) {
  final w = toWallClock(tzid, o.startUtc);
  final hh = w.hour.toString().padLeft(2, '0');
  final mm = w.minute.toString().padLeft(2, '0');
  return '${huDateLabel(w)} $hh:$mm ${sanitizeText(o.title, max: 40)}';
}
