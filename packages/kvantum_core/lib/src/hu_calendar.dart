import 'time.dart';

/// What kind of special day a date is in Hungary.
enum HuDayKind {
  /// Munkaszüneti nap: a public holiday by law (Mt. 102. §).
  holiday,

  /// Áthelyezett pihenőnap: a bridge day off, set by the yearly decree of the
  /// minister (the working Saturday that pays for it is [workSaturday]).
  restDay,

  /// Áthelyezett munkanap: a Saturday that is a working day.
  workSaturday,
}

/// A special day: what it is, and its name for the screen.
class HuDay {
  const HuDay(this.kind, this.name);
  final HuDayKind kind;
  final String name;

  /// No work is expected (a holiday or a bridge day off).
  bool get isDayOff => kind != HuDayKind.workSaturday;

  /// A few words for a small place (a calendar cell): the name of the
  /// holiday, or what kind of day it is.
  String get shortLabel => switch (kind) {
    HuDayKind.holiday => name,
    HuDayKind.restDay => 'Pihenőnap',
    HuDayKind.workSaturday => 'Munkanap',
  };

  /// One line for a screen or a notification.
  String get label => switch (kind) {
    HuDayKind.holiday => 'Munkaszüneti nap: $name',
    HuDayKind.restDay => 'Áthelyezett pihenőnap',
    HuDayKind.workSaturday => 'Áthelyezett munkanap (szombat)',
  };

  @override
  bool operator ==(Object other) =>
      other is HuDay && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(kind, name);

  @override
  String toString() => 'HuDay($kind, $name)';
}

/// The date up to which the table of decreed bridge days below was checked
/// against the news (the decree of a year is published in the spring of the
/// year before; a change of law can still move days, as it did for Christmas
/// Eve in 2026).
const huCalendarCheckedOn = '2026-11-13';

/// Easter Sunday of [year] in the Gregorian calendar (the anonymous
/// Meeus/Jones/Butcher algorithm), as a floating date.
DateTime easterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = ((h + l - 7 * m + 114) % 31) + 1;
  return floating(year, month, day);
}

/// The public holidays (munkaszüneti napok) of [year] by law: New Year, 15
/// March, Good Friday (since 2017), Easter Sunday and Monday, 1 May, Whit
/// Sunday and Monday, 20 August, 23 October, All Saints, Christmas Eve (since
/// 2026: the law of 3 November 2026 made it one), Christmas and Boxing Day.
/// Keyed by floating date.
Map<DateTime, String> huHolidays(int year) {
  final easter = easterSunday(year);
  DateTime fromEaster(int days) => easter.add(Duration(days: days));
  return {
    floating(year, 1, 1): 'Újév',
    floating(year, 3, 15): 'Az 1848-as forradalom ünnepe',
    if (year >= 2017) fromEaster(-2): 'Nagypéntek',
    easter: 'Húsvétvasárnap',
    fromEaster(1): 'Húsvéthétfő',
    floating(year, 5, 1): 'A munka ünnepe',
    fromEaster(49): 'Pünkösdvasárnap',
    fromEaster(50): 'Pünkösdhétfő',
    floating(year, 8, 20): 'Az államalapítás ünnepe',
    floating(year, 10, 23): 'Az 1956-os forradalom ünnepe',
    floating(year, 11, 1): 'Mindenszentek',
    if (year >= 2026) floating(year, 12, 24): 'Szenteste',
    floating(year, 12, 25): 'Karácsony',
    floating(year, 12, 26): 'Karácsony másnapja',
  };
}

/// The bridge days and the working Saturdays that pay for them, from the
/// decrees. Only years whose decree was read are here; for the others there
/// is nothing to show (and a year whose holidays all fall on a Monday, a
/// Friday or the weekend, like 2027, has no bridge days at all).
///
/// 2026 (10/2025. (IV. 30.) NGM rendelet): 2 January and 21 August are days
/// off, 10 January and 8 August are working Saturdays. The third pair of the
/// decree (24 December off, 12 December worked) is not here: the law of 3
/// November 2026 made 24 December a holiday, and 12 December is not worked
/// any more.
final Map<DateTime, HuDay> _decreed = {
  floating(2026, 1, 2): const HuDay(HuDayKind.restDay, 'Áthelyezett pihenőnap'),
  floating(2026, 1, 10): const HuDay(
    HuDayKind.workSaturday,
    'Áthelyezett munkanap',
  ),
  floating(2026, 8, 8): const HuDay(
    HuDayKind.workSaturday,
    'Áthelyezett munkanap',
  ),
  floating(2026, 8, 21): const HuDay(
    HuDayKind.restDay,
    'Áthelyezett pihenőnap',
  ),
};

final Map<int, Map<DateTime, String>> _holidayCache = {};

/// What is special about [date] (its y/m/d fields count), or null on an
/// ordinary day. A holiday wins over a decreed day.
HuDay? huDayInfo(DateTime date) {
  final day = floating(date.year, date.month, date.day);
  final name = (_holidayCache[day.year] ??= huHolidays(day.year))[day];
  if (name != null) return HuDay(HuDayKind.holiday, name);
  return _decreed[day];
}
