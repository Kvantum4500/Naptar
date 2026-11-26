import 'dart:convert';

import 'hu_calendar.dart';
import 'shift_pattern.dart';
import 'sync_record.dart';

/// A gross estimate of what the shifts of a month pay, from the hourly wage and
/// the premiums the user enters. It is an ESTIMATE from the plan, not a payroll:
/// no overtime, no bonuses, no tax or contributions, and the rules are the ones
/// the settings say - nothing here claims what the law or a contract says.
///
/// How the minutes are told apart (the same everywhere):
/// - a shift belongs to the month it STARTS in (as in [summarizeShifts]), and
///   lasts as long as its wall clock says (a night with a clock change is not
///   corrected);
/// - every minute has a time of day: evening (18:00-22:00), night (22:00-6:00)
///   or neither (the two together are the 18:00-6:00 of a rotating shift; whoever
///   is paid one rate for all of it sets both percentages alike), and a kind of
///   day by its own calendar date: a public holiday, else a Sunday, else a
///   Saturday (a Saturday that is an ordinary working day by decree is none of
///   these);
/// - the premium of the time of day and the premium of the kind of day ADD UP
///   (whoever is paid differently sets the percentages to fit).
class PaySettings {
  const PaySettings({
    this.hourly = 0,
    this.eveningPct = 0,
    this.nightPct = 0,
    this.saturdayPct = 0,
    this.sundayPct = 0,
    this.holidayPct = 0,
  });

  /// Gross forints per hour (0 = not set).
  final int hourly;

  /// Premiums in percent of the hourly wage.
  final int eveningPct;
  final int nightPct;
  final int saturdayPct;
  final int sundayPct;
  final int holidayPct;

  /// The largest values taken (a slip of a finger must not make a billion).
  static const maxHourly = 1000000;
  static const maxPercent = 1000;

  bool get isSet => hourly > 0;

  PaySettings copyWith({
    int? hourly,
    int? eveningPct,
    int? nightPct,
    int? saturdayPct,
    int? sundayPct,
    int? holidayPct,
  }) => PaySettings(
    hourly: hourly ?? this.hourly,
    eveningPct: eveningPct ?? this.eveningPct,
    nightPct: nightPct ?? this.nightPct,
    saturdayPct: saturdayPct ?? this.saturdayPct,
    sundayPct: sundayPct ?? this.sundayPct,
    holidayPct: holidayPct ?? this.holidayPct,
  );

  Map<String, Object?> toJson() => {
    'hourly': hourly,
    'evening': eveningPct,
    'night': nightPct,
    'saturday': saturdayPct,
    'sunday': sundayPct,
    'holiday': holidayPct,
  };

  /// The settings out of the values [value] gives by field name; whatever is
  /// missing, not a number or out of range is "not set" (0) or the largest
  /// value taken. One place for the device text and the synced record, so the
  /// two cannot read the same numbers differently.
  static PaySettings _read(Object? Function(String field) value) {
    int whole(Object? v, int max) =>
        v is num && v.isFinite ? v.round().clamp(0, max) : 0;
    return PaySettings(
      hourly: whole(value('hourly'), maxHourly),
      eveningPct: whole(value('evening'), maxPercent),
      nightPct: whole(value('night'), maxPercent),
      saturdayPct: whole(value('saturday'), maxPercent),
      sundayPct: whole(value('sunday'), maxPercent),
      holidayPct: whole(value('holiday'), maxPercent),
    );
  }

  /// What a text of the device holds; anything unreadable is "not set". (Where
  /// the settings were kept before they were synced: read once, to take them
  /// over.)
  static PaySettings decode(String? text) {
    if (text == null || text.isEmpty) return const PaySettings();
    try {
      final j = jsonDecode(text);
      if (j is! Map) return const PaySettings();
      return _read((field) => j[field]);
    } catch (_) {
      return const PaySettings();
    }
  }

  /// The settings of the synced record `settings/pay` ([kindSettings]); no
  /// record, or one that says nothing, is "not set". Never throws: the record
  /// may come from another device.
  static PaySettings fromRecord(SyncRecord? record) =>
      record == null ? const PaySettings() : _read((field) => record[field]);

  /// What to write into the record, field by field (a write of a field that did
  /// not change keeps its stamp, so only what was edited can win over the other
  /// device's edit).
  Map<String, Object?> toFields() => toJson();

  /// The text to keep on the device; null when nothing is set. (The old home of
  /// the settings; kept for the tests of the take-over.)
  String? encode() => this == const PaySettings() ? null : jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is PaySettings &&
      other.hourly == hourly &&
      other.eveningPct == eveningPct &&
      other.nightPct == nightPct &&
      other.saturdayPct == saturdayPct &&
      other.sundayPct == sundayPct &&
      other.holidayPct == holidayPct;

  @override
  int get hashCode => Object.hash(
    hourly,
    eveningPct,
    nightPct,
    saturdayPct,
    sundayPct,
    holidayPct,
  );
}

enum PayKind { base, evening, night, saturday, sunday, holiday }

String payKindLabel(PayKind kind) => switch (kind) {
  PayKind.base => 'Alapbér',
  PayKind.evening => 'Esti pótlék (18–22)',
  PayKind.night => 'Éjszakai pótlék (22–6)',
  PayKind.saturday => 'Szombati pótlék',
  PayKind.sunday => 'Vasárnapi pótlék',
  PayKind.holiday => 'Ünnepnapi pótlék',
};

/// One line of the estimate: [minutes] worked in this way, at [percent] of the
/// hourly wage on top (100 for the base pay itself), [amount] forints.
class PayLine {
  const PayLine({
    required this.kind,
    required this.minutes,
    required this.percent,
    required this.amount,
  });
  final PayKind kind;
  final int minutes;
  final int percent;
  final int amount;

  @override
  bool operator ==(Object other) =>
      other is PayLine &&
      other.kind == kind &&
      other.minutes == minutes &&
      other.percent == percent &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(kind, minutes, percent, amount);

  @override
  String toString() =>
      'PayLine(${kind.name}, $minutes min, $percent %, $amount)';
}

class PayEstimate {
  const PayEstimate({
    required this.year,
    required this.month,
    required this.shifts,
    required this.minutes,
    required this.lines,
  });
  final int year;
  final int month;

  /// How many shifts started in the month.
  final int shifts;

  /// All the minutes of those shifts.
  final int minutes;

  /// The base pay first, then the premiums that were worked and are not 0 %.
  final List<PayLine> lines;

  double get hours => minutes / 60;

  /// The lines add up exactly: each is rounded to a forint, the total is their
  /// sum.
  int get total => lines.fold(0, (sum, l) => sum + l.amount);

  /// The minutes of one kind (0 when it did not come up).
  int minutesOf(PayKind kind) {
    for (final l in lines) {
      if (l.kind == kind) return l.minutes;
    }
    return 0;
  }
}

/// The estimate of [year]/[month] for [events] (the shifts among them are the
/// ones with a shift marker in their notes; [start] and [end] are wall-clock
/// times, as in [summarizeShifts]).
PayEstimate estimatePay(
  Iterable<({String title, String notes, DateTime start, DateTime end})>
  events, {
  required int year,
  required int month,
  required PaySettings settings,
}) {
  var shifts = 0, total = 0;
  final worked = {for (final k in PayKind.values) k: 0};
  final dayKinds = <DateTime, PayKind?>{};
  PayKind? kindOfDay(DateTime day) => dayKinds.putIfAbsent(day, () {
    final info = huDayInfo(day);
    if (info?.kind == HuDayKind.holiday) return PayKind.holiday;
    if (day.weekday == DateTime.sunday) return PayKind.sunday;
    if (day.weekday == DateTime.saturday &&
        info?.kind != HuDayKind.workSaturday) {
      return PayKind.saturday;
    }
    return null;
  });

  for (final e in events) {
    if (!isShiftNotes(e.notes)) continue;
    if (e.start.year != year || e.start.month != month) continue;
    if (!e.end.isAfter(e.start)) continue;
    shifts++;
    var left = e.end.difference(e.start).inMinutes;
    var cursor = e.start;
    while (left > 0) {
      final day = DateTime.utc(cursor.year, cursor.month, cursor.day);
      final from = cursor.hour * 60 + cursor.minute;
      // the next place where the time of day changes (or the day ends)
      final cut = _cuts.firstWhere((c) => c > from);
      final to = from + left < cut ? from + left : cut;
      final minutes = to - from;
      total += minutes;
      worked[PayKind.base] = worked[PayKind.base]! + minutes;
      if (from >= _nightFrom || from < _nightUntil) {
        worked[PayKind.night] = worked[PayKind.night]! + minutes;
      } else if (from >= _eveningFrom) {
        worked[PayKind.evening] = worked[PayKind.evening]! + minutes;
      }
      final dayKind = kindOfDay(day);
      if (dayKind != null) {
        worked[dayKind] = worked[dayKind]! + minutes;
      }
      left -= minutes;
      cursor = day.add(Duration(minutes: to));
    }
  }

  int pct(PayKind k) => switch (k) {
    PayKind.base => 100,
    PayKind.evening => settings.eveningPct,
    PayKind.night => settings.nightPct,
    PayKind.saturday => settings.saturdayPct,
    PayKind.sunday => settings.sundayPct,
    PayKind.holiday => settings.holidayPct,
  };
  final lines = <PayLine>[];
  for (final k in PayKind.values) {
    final minutes = worked[k]!;
    final percent = pct(k);
    if (k != PayKind.base && (minutes == 0 || percent == 0)) continue;
    // (rounded to the nearest forint, halves up)
    final amount = (settings.hourly * minutes * percent + 3000) ~/ 6000;
    lines.add(
      PayLine(kind: k, minutes: minutes, percent: percent, amount: amount),
    );
  }
  return PayEstimate(
    year: year,
    month: month,
    shifts: shifts,
    minutes: total,
    lines: lines,
  );
}

// Minutes after midnight where the time of day changes.
const _nightUntil = 6 * 60;
const _eveningFrom = 18 * 60;
const _nightFrom = 22 * 60;
const _cuts = [_nightUntil, _eveningFrom, _nightFrom, 24 * 60];
