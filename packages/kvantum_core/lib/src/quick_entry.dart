import 'recurrence_spec.dart';
import 'text_safety.dart';
import 'time.dart';

part 'quick_entry/day_phase.dart';
part 'quick_entry/repeat_phase.dart';
part 'quick_entry/source.dart';
part 'quick_entry/time_phase.dart';
part 'quick_entry/words.dart';

/// What a line of free text turned out to be.
enum QuickKind { event, task }

/// A line typed (or dictated) into the quick entry, taken apart: what it is,
/// when, how long, how often, and what is left as the title.
///
/// Nothing here is a guess the user cannot see: [assumptions] says in words
/// what was decided for them ("a 5-kort délutáninak vettem"), and the app
/// shows it next to the result before anything is saved.
class QuickEntry {
  const QuickEntry({
    required this.kind,
    required this.title,
    this.date,
    this.startMinute,
    this.durationMinutes,
    this.allDay = false,
    this.rrule,
    this.repeatText,
    this.assumptions = const [],
  });

  final QuickKind kind;

  /// What is left of the line when everything about time is taken out; empty
  /// when nothing is (then there is nothing to save).
  final String title;

  /// Floating date: the day of the event, or the due date of the task.
  final DateTime? date;

  /// Minutes after midnight; null for an all-day event and for a task.
  final int? startMinute;

  /// Length of an event with a time (60 when the line says nothing).
  final int? durationMinutes;
  final bool allDay;

  /// RFC 5545 rule body for the first occurrence, or null.
  final String? rrule;

  /// The words that said it repeats ("minden hétfőn").
  final String? repeatText;

  /// Hungarian sentences: what was taken for granted.
  final List<String> assumptions;

  bool get hasTitle => title.isNotEmpty;
  bool get repeats => rrule != null;

  /// Floating start of a timed event.
  DateTime? get start => date == null || startMinute == null
      ? null
      : date!.add(Duration(minutes: startMinute!));

  /// Floating end of a timed event.
  DateTime? get end => start?.add(Duration(minutes: durationMinutes ?? 60));

  QuickEntry withKind(QuickKind k) => k == kind
      ? this
      : QuickEntry(
          kind: k,
          title: title,
          date: date,
          startMinute: startMinute,
          durationMinutes: durationMinutes,
          allDay: allDay,
          rrule: rrule,
          repeatText: repeatText,
          assumptions: assumptions,
        );

  @override
  String toString() =>
      'QuickEntry($kind, "$title", $date, $startMinute, $durationMinutes, '
      'allDay: $allDay, $rrule)';
}

/// Takes a Hungarian line apart.
///
/// [now] is the wall clock of the display zone (a floating date and time):
/// "kedden" is the Tuesday after today, an hour that has already gone by
/// today means tomorrow.
QuickEntry parseQuickEntry(String input, {required DateTime now}) {
  final today = floating(now.year, now.month, now.day);
  final nowMinute = now.hour * 60 + now.minute;
  final src = _Src(input);
  final notes = <String>[];

  // Each step takes what it understands out of [src], in this order (what is
  // taken out cannot be taken for something else later).
  final explicit = _takeKindWord(src);
  final allDay = _takeAllDay(src);
  final rep = _takeRepeat(src);
  var dueWord = _takeDeadlineWord(src);
  final day = _takeDay(src, today, notes);
  if (day.due) dueWord = true;
  var date = day.date;
  final dateIsToday = day.isToday;
  final soon = _takeMinutesFromNow(src, today, nowMinute, date);
  date = soon.date;
  var duration = _takeDuration(src);
  final hour = _takeHour(src, notes, date, soon.startMin);
  final startMin = hour.startMin;
  final endMin = hour.endMin;
  duration = _takeLengthAfterStart(src, duration, startMin);
  final repeat = rep.spec;
  final repeatDays = rep.days;
  final repeatText = rep.text;
  final monthDay = rep.monthDay;

  if (endMin != null && startMin != null) {
    final span = endMin > startMin
        ? endMin - startMin
        : endMin + 24 * 60 - startMin;
    duration = span;
  }

  // ---- the day, when the line does not say
  final timed = startMin != null && !allDay;
  if (repeat != null && date == null) {
    date = _firstOccurrence(
      repeat,
      repeatDays,
      monthDay,
      today,
      timed ? startMin : null,
      nowMinute,
    );
  }
  if (date == null && timed) {
    if (startMin <= nowMinute) {
      date = _addDays(today, 1);
      notes.add('Az időpont ma már elmúlt, ezért holnapra vettem.');
    } else {
      date = today;
    }
  } else if (date != null && dateIsToday && timed && startMin <= nowMinute) {
    notes.add('Az időpont ma már elmúlt.');
  }

  // ---- what it is
  var kind = explicit;
  if (kind == null) {
    if (dueWord) {
      kind = QuickKind.task;
    } else if (timed || allDay) {
      kind = QuickKind.event;
    } else if (repeat != null && repeat.freq != RepeatFreq.yearly) {
      kind = QuickKind.task;
      notes.add('Időpont nélkül ismétlődő feladatot vettem fel.');
    } else if (date != null) {
      kind = _looksLikeTodo(src.rest) ? QuickKind.task : QuickKind.event;
      if (kind == QuickKind.event) {
        notes.add('Nincs időpont, ezért egész napos eseményt vettem fel.');
      }
    } else {
      kind = QuickKind.task;
    }
  }
  if (kind == QuickKind.task && timed) {
    notes.add('A feladatnak nincs időpontja, csak határideje.');
  }
  if (kind == QuickKind.event && date == null) {
    date = today;
    notes.add('Nincs dátum, ezért a mai napra vettem.');
  }
  final isEvent = kind == QuickKind.event;

  // ---- the rest is the title
  var title = src.rest
      .replaceAll(RegExp(r'(^|\s)-[^\s]{1,5}(?=\s|$)'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  title = title.replaceAll(RegExp(r'^[\s,;:.\-–—/]+|[\s,;:\-–—/]+$'), '');
  title = sanitizeText(title, max: 80);
  if (title.isNotEmpty) {
    title = title[0].toUpperCase() + title.substring(1);
  }

  final anchor = date;
  return QuickEntry(
    kind: kind,
    title: title,
    date: anchor,
    startMinute: isEvent && timed ? startMin : null,
    durationMinutes: isEvent && timed ? (duration ?? 60) : null,
    allDay: isEvent && !timed,
    rrule: repeat == null || anchor == null
        ? null
        : repeat.toRrule(
            repeat.freq == RepeatFreq.monthly && monthDay != null
                ? floating(anchor.year, anchor.month, monthDay)
                : anchor,
          ),
    repeatText: repeat == null ? null : repeatText,
    assumptions: notes,
  );
}

/// The first day on which a rule given without a date happens: today (when
/// the hour is still ahead), or the first matching day after.
DateTime _firstOccurrence(
  RecurrenceSpec spec,
  Set<int> days,
  int? monthDay,
  DateTime today,
  int? startMinute,
  int nowMinute,
) {
  bool todayStillOpen() => startMinute == null || startMinute > nowMinute;
  switch (spec.freq) {
    case RepeatFreq.daily:
      return todayStillOpen() ? today : today.add(const Duration(days: 1));
    case RepeatFreq.weekly:
      final set = days.isEmpty ? {today.weekday} : days;
      for (var i = 0; i < 8; i++) {
        final d = today.add(Duration(days: i));
        if (set.contains(d.weekday) && (i > 0 || todayStillOpen())) return d;
      }
      return today;
    case RepeatFreq.monthly:
      final day = monthDay ?? today.day;
      for (var i = 0; i < 14; i++) {
        final y = today.year + (today.month - 1 + i) ~/ 12;
        final mo = (today.month - 1 + i) % 12 + 1;
        final d = floating(y, mo, day);
        if (d.month != mo) continue;
        if (d.isAfter(today) || (d == today && todayStillOpen())) return d;
      }
      return today;
    case RepeatFreq.yearly:
      return todayStillOpen() ? today : today.add(const Duration(days: 1));
  }
}

/// A word that says what it is: "feladat: ...", "esemény: ...".
QuickKind? _takeKindWord(_Src src) {
  QuickKind? explicit;
  var m = src.find(r'^\s*(feladat|teendo|todo|to-do)\s*[:\-–]?\s');
  if (m != null) {
    explicit = QuickKind.task;
    src.takeMatch(m);
  } else {
    m = src.find(r'^\s*(esemeny|talalkozo)\s*:\s*');
    if (m != null) {
      explicit = QuickKind.event;
      src.takeMatch(m);
    }
  }
  return explicit;
}

/// "egész nap", "egésznapos".
bool _takeAllDay(_Src src) {
  var allDay = false;
  RegExpMatch? m;
  m = src.find(r'\b(egesz\s+nap(?:ra|os|ig)?|egesznapos)\b');
  if (m != null) {
    allDay = true;
    src.takeMatch(m);
  }
  return allDay;
}

/// "határidő" (a deadline, not an event).
bool _takeDeadlineWord(_Src src) {
  var dueWord = false;
  RegExpMatch? m;
  m = src.find(r'\bhatarid(?:o|ovel|oig)\s*[:\-]?\s*');
  if (m != null) {
    dueWord = true;
    src.takeMatch(m);
  }
  return dueWord;
}
