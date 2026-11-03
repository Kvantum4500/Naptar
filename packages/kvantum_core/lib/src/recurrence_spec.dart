import 'package:rrule/rrule.dart';

import 'event.dart';
import 'recurrence.dart';

enum RepeatFreq { daily, weekly, monthly, yearly }

enum MonthlyMode { dayOfMonth, nthWeekday, lastWeekday }

enum RepeatEnd { never, count, until }

const _dayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// Structured, editable form of the repeat rules the UI offers. It is turned
/// into an RFC 5545 RRULE for storage/sync and parsed back for editing. Rules
/// outside this vocabulary parse to `null` (the UI then keeps the raw rule).
class RecurrenceSpec {
  const RecurrenceSpec({
    required this.freq,
    this.interval = 1,
    this.weekdays = const {},
    this.monthlyMode = MonthlyMode.dayOfMonth,
    this.end = RepeatEnd.never,
    this.count,
    this.until,
  }) : assert(interval >= 1);

  final RepeatFreq freq;
  final int interval;

  /// 1 = Monday .. 7 = Sunday (weekly rules). Empty = the start's weekday.
  final Set<int> weekdays;
  final MonthlyMode monthlyMode;
  final RepeatEnd end;
  final int? count;

  /// Last day (floating date) on which an occurrence may still start.
  final DateTime? until;

  RecurrenceSpec copyWith({
    RepeatFreq? freq,
    int? interval,
    Set<int>? weekdays,
    MonthlyMode? monthlyMode,
    RepeatEnd? end,
    int? count,
    DateTime? until,
  }) => RecurrenceSpec(
    freq: freq ?? this.freq,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    monthlyMode: monthlyMode ?? this.monthlyMode,
    end: end ?? this.end,
    count: count ?? this.count,
    until: until ?? this.until,
  );

  /// Validation message (Hungarian) or null when the spec is usable.
  String? validate() {
    if (interval < 1 || interval > 999) {
      return 'Az ismétlési köz 1 és 999 között lehet.';
    }
    if (end == RepeatEnd.count &&
        (count == null || count! < 1 || count! > 5000)) {
      return 'Az alkalmak száma 1 és 5000 között lehet.';
    }
    if (end == RepeatEnd.until && until == null) {
      return 'Adj meg befejező dátumot.';
    }
    return null;
  }

  /// RRULE body (without the "RRULE:" prefix) for an event starting at [start].
  String toRrule(DateTime start) {
    final p = <String>[
      'FREQ=${switch (freq) {
        RepeatFreq.daily => 'DAILY',
        RepeatFreq.weekly => 'WEEKLY',
        RepeatFreq.monthly => 'MONTHLY',
        RepeatFreq.yearly => 'YEARLY',
      }}',
    ];
    if (interval > 1) p.add('INTERVAL=$interval');
    if (freq == RepeatFreq.weekly) {
      final days = (weekdays.isEmpty ? {start.weekday} : weekdays).toList()
        ..sort();
      p.add('BYDAY=${days.map((d) => _dayCodes[d - 1]).join(',')}');
    }
    if (freq == RepeatFreq.monthly) {
      final nth = (start.day - 1) ~/ 7 + 1;
      switch (monthlyMode) {
        case MonthlyMode.dayOfMonth:
          p.add('BYMONTHDAY=${start.day}');
        case MonthlyMode.nthWeekday:
          // A "5th" weekday only exists in some months; treat it as "last".
          p.add(
            nth >= 5
                ? 'BYDAY=-1${_dayCodes[start.weekday - 1]}'
                : 'BYDAY=$nth${_dayCodes[start.weekday - 1]}',
          );
        case MonthlyMode.lastWeekday:
          p.add('BYDAY=-1${_dayCodes[start.weekday - 1]}');
      }
    }
    switch (end) {
      case RepeatEnd.never:
        break;
      case RepeatEnd.count:
        p.add('COUNT=$count');
      case RepeatEnd.until:
        final u = until!;
        p.add('UNTIL=${_ymd(u)}T235959Z');
    }
    return p.join(';');
  }

  /// Parses [rrule]; null when it uses features this editor cannot express.
  static RecurrenceSpec? fromRrule(String rrule, DateTime start) {
    final RecurrenceRule r;
    try {
      r = parseRule(rrule);
    } catch (_) {
      return null;
    }
    final RepeatFreq freq;
    switch (r.frequency) {
      case Frequency.daily:
        freq = RepeatFreq.daily;
      case Frequency.weekly:
        freq = RepeatFreq.weekly;
      case Frequency.monthly:
        freq = RepeatFreq.monthly;
      case Frequency.yearly:
        freq = RepeatFreq.yearly;
      default:
        return null;
    }
    if (r.byMonths.isNotEmpty ||
        r.byWeeks.isNotEmpty ||
        r.byYearDays.isNotEmpty ||
        r.byHours.isNotEmpty ||
        r.byMinutes.isNotEmpty ||
        r.bySeconds.isNotEmpty) {
      return null;
    }
    var mode = MonthlyMode.dayOfMonth;
    var weekdays = <int>{};
    if (freq == RepeatFreq.weekly) {
      if (r.byMonthDays.isNotEmpty || r.bySetPositions.isNotEmpty) return null;
      if (r.byWeekDays.any((e) => e.occurrence != null)) return null;
      weekdays = {for (final e in r.byWeekDays) e.day};
    } else if (freq == RepeatFreq.monthly) {
      if (r.byWeekDays.isEmpty && r.byMonthDays.isEmpty) {
        // plain FREQ=MONTHLY = same day of month
      } else if (r.byMonthDays.length == 1 && r.byWeekDays.isEmpty) {
        if (r.byMonthDays.first != start.day) return null;
      } else if (r.byWeekDays.length == 1 && r.byMonthDays.isEmpty) {
        final e = r.byWeekDays.first;
        if (e.day != start.weekday) return null;
        if (e.occurrence == -1) {
          mode = MonthlyMode.lastWeekday;
        } else if (e.occurrence != null &&
            e.occurrence == (start.day - 1) ~/ 7 + 1) {
          mode = MonthlyMode.nthWeekday;
        } else {
          return null;
        }
        if (r.bySetPositions.isNotEmpty) return null;
      } else {
        return null;
      }
    } else {
      if (r.byWeekDays.isNotEmpty ||
          r.byMonthDays.isNotEmpty ||
          r.bySetPositions.isNotEmpty) {
        return null;
      }
    }
    final end = r.count != null
        ? RepeatEnd.count
        : (r.until != null ? RepeatEnd.until : RepeatEnd.never);
    return RecurrenceSpec(
      freq: freq,
      interval: r.interval ?? 1,
      weekdays: weekdays,
      monthlyMode: mode,
      end: end,
      count: r.count,
      until: r.until == null
          ? null
          : DateTime.utc(r.until!.year, r.until!.month, r.until!.day),
    );
  }

  /// Next [n] occurrence start times (floating) for an event starting at [start].
  List<DateTime> preview(DateTime start, {int n = 10}) {
    final rule = parseRule(toRrule(start));
    return rule.getInstances(start: start).take(n).toList();
  }
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

/// Human readable (Hungarian) one-line summary of an rrule, for lists/chips.
String describeRrule(String? rrule, DateTime start) {
  if (rrule == null || rrule.isEmpty) return 'Nem ismétlődik';
  final s = RecurrenceSpec.fromRrule(rrule, start);
  if (s == null) return 'Egyedi ismétlődés';
  const days = [
    'hétfő',
    'kedd',
    'szerda',
    'csütörtök',
    'péntek',
    'szombat',
    'vasárnap',
  ];
  final n = s.interval;
  final b = StringBuffer();
  switch (s.freq) {
    case RepeatFreq.daily:
      b.write(n == 1 ? 'Naponta' : '$n naponta');
    case RepeatFreq.weekly:
      final w = (s.weekdays.isEmpty ? {start.weekday} : s.weekdays).toList()
        ..sort();
      b.write(n == 1 ? 'Hetente' : '$n hetente');
      b.write(' (${w.map((d) => days[d - 1]).join(', ')})');
    case RepeatFreq.monthly:
      b.write(n == 1 ? 'Havonta' : '$n havonta');
      switch (s.monthlyMode) {
        case MonthlyMode.dayOfMonth:
          b.write(' (${start.day}.)');
        case MonthlyMode.nthWeekday:
          b.write(' (${(start.day - 1) ~/ 7 + 1}. ${days[start.weekday - 1]})');
        case MonthlyMode.lastWeekday:
          b.write(' (utolsó ${days[start.weekday - 1]})');
      }
    case RepeatFreq.yearly:
      b.write(n == 1 ? 'Évente' : '$n évente');
  }
  switch (s.end) {
    case RepeatEnd.never:
      break;
    case RepeatEnd.count:
      b.write(', ${s.count} alkalom');
    case RepeatEnd.until:
      b.write(', ${s.until!.year}.${s.until!.month}.${s.until!.day}-ig');
  }
  return b.toString();
}

/// Convenience for UIs: parsed spec of an event, or null if not recurring/unsupported.
RecurrenceSpec? specOf(CalEvent e) =>
    e.isRecurring ? RecurrenceSpec.fromRrule(e.rrule!, e.start) : null;
