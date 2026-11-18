import 'hu_calendar.dart';
import 'text_safety.dart';

const _weekdays = [
  'hétfő',
  'kedd',
  'szerda',
  'csütörtök',
  'péntek',
  'szombat',
  'vasárnap',
];

const _months = [
  'jan.',
  'febr.',
  'márc.',
  'ápr.',
  'máj.',
  'jún.',
  'júl.',
  'aug.',
  'szept.',
  'okt.',
  'nov.',
  'dec.',
];

/// "hétfő, nov. 16." for a floating date.
String huDateLabel(DateTime day) =>
    '${_weekdays[day.weekday - 1]}, ${_months[day.month - 1]} ${day.day}.';

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One event on the day, as the summary needs it. The times are floating
/// wall-clock times in the display zone.
class SummaryEvent {
  const SummaryEvent({
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
  });
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
}

/// A task that is due on the day (or overdue).
class SummaryTask {
  const SummaryTask(this.title, {this.overdue = false});
  final String title;
  final bool overdue;
}

/// The text of one morning notification.
class DaySummary {
  const DaySummary(this.title, this.body);
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is DaySummary && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'DaySummary($title)';
}

/// The morning summary of [day] (a floating date), or null when there is
/// nothing to say: no event, no task, no special day. The weather alone does
/// not make a notification.
///
/// Lines: the special day (holiday, working Saturday), the weather, the
/// events (all-day first, then by time; at most [maxEvents]), the tasks (at
/// most [maxTasks]). The titles are the user's own text: cleaned of control
/// and invisible characters and cut at [maxTitle].
DaySummary? buildDaySummary({
  required DateTime day,
  required List<SummaryEvent> events,
  List<SummaryTask> tasks = const [],
  HuDay? special,
  String? weather,
  int maxEvents = 4,
  int maxTasks = 3,
  int maxTitle = 40,
}) {
  if (events.isEmpty && tasks.isEmpty && special == null) return null;
  String clean(String t) => sanitizeText(t, max: maxTitle);

  final dayStart = DateTime.utc(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));

  // all-day events first, then by start (one that began earlier first)
  final sorted = [...events]
    ..sort((a, b) {
      if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.title.compareTo(b.title);
    });

  String eventLine(SummaryEvent e) {
    final title = clean(e.title);
    if (e.allDay) return 'Egész nap: $title';
    if (!e.start.isBefore(dayStart)) return '${_hhmm(e.start)} $title';
    // began on an earlier day
    if (e.end.isAfter(dayEnd)) return 'Egész nap: $title';
    return '${_hhmm(e.end)}-ig: $title';
  }

  final lines = <String>[
    if (special != null) special.label,
    if (weather != null && weather.trim().isNotEmpty)
      'Időjárás: ${weather.trim()}',
    for (final e in sorted.take(maxEvents)) eventLine(e),
    if (sorted.length > maxEvents)
      '+${sorted.length - maxEvents} további esemény',
    for (final t in tasks.take(maxTasks))
      t.overdue
          ? 'Feladat (lejárt): ${clean(t.title)}'
          : 'Feladat: ${clean(t.title)}',
    if (tasks.length > maxTasks) '+${tasks.length - maxTasks} további feladat',
  ];
  return DaySummary('Ma: ${huDateLabel(day)}', lines.join('\n'));
}
