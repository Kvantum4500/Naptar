import 'dart:math';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

typedef Ev = ({String title, String notes, DateTime start, DateTime end});

Ev shift(
  DateTime start,
  DateTime end, {
  String notes = kShiftMarker,
  String title = 'Műszak',
}) => (title: title, notes: notes, start: start, end: end);

/// A shift of [hours] hours (and [extra] minutes) from [h]:[m] on the day.
Ev at(int y, int mo, int d, int h, int hours, {int m = 0, int extra = 0}) {
  final start = floating(y, mo, d, h, m);
  return shift(start, start.add(Duration(hours: hours, minutes: extra)));
}

const s = PaySettings(
  hourly: 2000,
  eveningPct: 30,
  nightPct: 40,
  saturdayPct: 20,
  sundayPct: 50,
  holidayPct: 100,
);

PayEstimate pay(
  List<Ev> events, {
  int year = 2026,
  int month = 11,
  PaySettings settings = s,
}) => estimatePay(events, year: year, month: month, settings: settings);

/// Minute by minute, the slow and obvious way: what [estimatePay] must equal.
Map<PayKind, int> oracle(List<Ev> events, int year, int month) {
  final out = {for (final k in PayKind.values) k: 0};
  for (final e in events) {
    if (!isShiftNotes(e.notes)) continue;
    if (e.start.year != year || e.start.month != month) continue;
    for (
      var t = e.start;
      t.isBefore(e.end);
      t = t.add(const Duration(minutes: 1))
    ) {
      out[PayKind.base] = out[PayKind.base]! + 1;
      if (t.hour < 6 || t.hour >= 22) {
        out[PayKind.night] = out[PayKind.night]! + 1;
      } else if (t.hour >= 18) {
        out[PayKind.evening] = out[PayKind.evening]! + 1;
      }
      final info = huDayInfo(t);
      PayKind? kind;
      if (info?.kind == HuDayKind.holiday) {
        kind = PayKind.holiday;
      } else if (t.weekday == DateTime.sunday) {
        kind = PayKind.sunday;
      } else if (t.weekday == DateTime.saturday &&
          info?.kind != HuDayKind.workSaturday) {
        kind = PayKind.saturday;
      }
      if (kind != null) out[kind] = out[kind]! + 1;
    }
  }
  return out;
}

void main() {
  test('the days the examples are about', () {
    // (the expected sums below were worked out for these weekdays)
    expect(DateTime.utc(2026, 11, 10).weekday, DateTime.tuesday);
    expect(DateTime.utc(2026, 11, 14).weekday, DateTime.saturday);
    expect(DateTime.utc(2026, 11, 15).weekday, DateTime.sunday);
    expect(DateTime.utc(2026, 11, 1).weekday, DateTime.sunday);
    expect(DateTime.utc(2026, 8, 20).weekday, DateTime.thursday);
    expect(DateTime.utc(2026, 8, 8).weekday, DateTime.saturday);
    expect(DateTime.utc(2026, 8, 15).weekday, DateTime.saturday);
    expect(DateTime.utc(2026, 10, 31).weekday, DateTime.saturday);
    expect(huDayInfo(DateTime.utc(2026, 8, 20))?.kind, HuDayKind.holiday);
    expect(huDayInfo(DateTime.utc(2026, 11, 1))?.kind, HuDayKind.holiday);
    expect(huDayInfo(DateTime.utc(2026, 8, 8))?.kind, HuDayKind.workSaturday);
    expect(huDayInfo(DateTime.utc(2026, 8, 15)), isNull);
  });

  group('one shift', () {
    test('a day on a weekday: the base pay and nothing else', () {
      final e = pay([at(2026, 11, 10, 6, 12)]);
      expect(e.lines, [
        const PayLine(
          kind: PayKind.base,
          minutes: 720,
          percent: 100,
          amount: 24000,
        ),
      ]);
      expect(e.total, 24000);
      expect((e.shifts, e.minutes, e.hours), (1, 720, 12.0));
    });

    test('a night over midnight: evening until 22:00, night after it', () {
      final e = pay([at(2026, 11, 10, 18, 12)]);
      expect(e.minutesOf(PayKind.evening), 240); // 18:00-22:00
      expect(e.minutesOf(PayKind.night), 480); // 22:00-6:00
      expect(e.lines.map((l) => (l.kind, l.minutes, l.percent, l.amount)), [
        (PayKind.base, 720, 100, 24000),
        (PayKind.evening, 240, 30, 2400),
        (PayKind.night, 480, 40, 6400),
      ]);
      expect(e.total, 32800);
    });

    test('a Sunday: the whole day', () {
      final e = pay([at(2026, 11, 15, 6, 12)]);
      expect(e.minutesOf(PayKind.sunday), 720);
      expect(e.minutesOf(PayKind.saturday), 0);
      expect(e.minutesOf(PayKind.evening), 0);
      expect(e.total, 24000 + 12000);
    });

    test('Saturday night into Sunday: each minute by its own date', () {
      final e = pay([at(2026, 11, 14, 18, 12)]);
      expect(e.minutesOf(PayKind.saturday), 360); // 18:00-24:00
      expect(e.minutesOf(PayKind.sunday), 360); // 0:00-6:00
      expect(e.minutesOf(PayKind.evening), 240);
      expect(e.minutesOf(PayKind.night), 480);
      expect(e.lines.map((l) => (l.kind, l.amount)), [
        (PayKind.base, 24000),
        (PayKind.evening, 2400),
        (PayKind.night, 6400),
        (PayKind.saturday, 2400),
        (PayKind.sunday, 6000),
      ]);
      expect(e.total, 41200);
    });

    test('a public holiday on a weekday', () {
      final e = pay([at(2026, 8, 20, 6, 12)], month: 8);
      expect(e.minutesOf(PayKind.holiday), 720);
      expect(e.total, 24000 + 24000);
    });

    test('a holiday on a Sunday is a holiday, not both', () {
      final e = pay([at(2026, 11, 1, 6, 12)]);
      expect(e.minutesOf(PayKind.holiday), 720);
      expect(e.minutesOf(PayKind.sunday), 0);
      expect(e.total, 24000 + 24000);
    });

    test('an ordinary Saturday has the Saturday premium', () {
      final e = pay([at(2026, 8, 15, 6, 12)], month: 8);
      expect(e.minutesOf(PayKind.saturday), 720);
      expect(e.total, 24000 + 4800);
    });

    test('a Saturday that is a working day by decree has none', () {
      final e = pay([at(2026, 8, 8, 6, 12)], month: 8);
      expect(e.minutesOf(PayKind.saturday), 0);
      expect(e.total, 24000);
    });

    test('a bridge day off is an ordinary day for the pay', () {
      // (2026-08-21 is such a Friday)
      final e = pay([at(2026, 8, 21, 6, 12)], month: 8);
      expect(e.minutesOf(PayKind.holiday), 0);
      expect(e.total, 24000);
    });

    test('only the hours from 18:00 to 6:00 have a time premium', () {
      final day = pay([at(2026, 11, 10, 6, 12)]); // 6:00-18:00
      expect(day.lines, hasLength(1));
      final late = pay([at(2026, 11, 10, 14, 8)]); // 14:00-22:00
      expect(late.minutesOf(PayKind.evening), 240); // 18:00-22:00
      expect(late.minutesOf(PayKind.night), 0);
      final early = pay([at(2026, 11, 10, 22, 8)]); // 22:00-6:00
      expect(early.minutesOf(PayKind.evening), 0);
      expect(early.minutesOf(PayKind.night), 480);
    });

    test('the same rate all night is both percentages alike', () {
      final e = pay([
        at(2026, 11, 10, 18, 12),
      ], settings: s.copyWith(eveningPct: 30, nightPct: 30));
      // 12 hours at 30 % on top of the base pay
      expect(e.total, 24000 + 7200);
    });
  });

  group('which shifts count', () {
    test('by the month they start in', () {
      final over = at(2026, 11, 30, 18, 12); // ends on 1 December
      expect(pay([over]).shifts, 1);
      expect(pay([over]).minutes, 720);
      expect(pay([over], month: 12).shifts, 0);
      expect(pay([over], month: 12).total, 0);
      // a shift that starts in October is October's, with its 1 November hours
      final october = at(2026, 10, 31, 18, 12); // Saturday -> Sunday holiday
      expect(pay([october]).shifts, 0);
      final e = pay([october], month: 10);
      expect(e.minutesOf(PayKind.saturday), 360);
      expect(e.minutesOf(PayKind.holiday), 360);
      expect(e.minutesOf(PayKind.sunday), 0);
      expect(e.total, 24000 + 2400 + 6400 + 2400 + 12000);
    });

    test('only shifts: other events are not pay', () {
      final e = pay([
        at(2026, 11, 10, 6, 12),
        shift(
          floating(2026, 11, 11, 10),
          floating(2026, 11, 11, 11),
          notes: 'fogorvos',
        ),
        shift(
          floating(2026, 11, 12, 10),
          floating(2026, 11, 12, 11),
          notes: '',
        ),
      ]);
      expect(e.shifts, 1);
      expect(e.minutes, 720);
    });

    test('a shift the user changed still counts', () {
      final e = pay([
        shift(
          floating(2026, 11, 10, 6),
          floating(2026, 11, 10, 18),
          notes: kShiftEditedMarker,
        ),
      ]);
      expect(e.shifts, 1);
      expect(e.total, 24000);
    });

    test('a shift that does not last is no shift', () {
      final e = pay([
        shift(floating(2026, 11, 10, 6), floating(2026, 11, 10, 6)),
        shift(floating(2026, 11, 10, 18), floating(2026, 11, 10, 6)),
      ]);
      expect((e.shifts, e.minutes, e.total), (0, 0, 0));
    });

    test('no shifts, no pay, and the base line is still there', () {
      final e = pay(const []);
      expect((e.shifts, e.minutes, e.total, e.hours), (0, 0, 0, 0.0));
      expect(e.lines, hasLength(1));
      expect(e.lines.single.kind, PayKind.base);
    });
  });

  group('a month of the usual cycle', () {
    // 3 nights, 3 off, 3 days, 3 off from 2 November: nights on 2, 3, 4, 14,
    // 15, 16, 26, 27, 28; days on 8, 9, 10, 20, 21, 22 - 15 shifts, 180 hours.
    // The evening hours are those of the 9 nights (4 h each), the night hours
    // 8 h of each night.
    final plan = generateShiftPlan(
      defaultShiftCycle,
      startDay: floating(2026, 11, 2),
      untilDay: floating(2026, 12, 1),
    );
    final events = [
      for (final p in plan) shift(p.start, p.end, title: p.title),
    ];

    test('the sum worked out by hand', () {
      final e = pay(events);
      expect(e.shifts, 15);
      expect(e.minutes, 10800);
      // weekend hours: Saturday 14 (night 18-24), 21 (day), 28 (night 18-24)
      // and the 0-6 part of the 28th (from the 27th) = 30 h; Sunday 15 (two
      // shifts' parts), 29, 8, 22 = 42 h
      expect(e.minutesOf(PayKind.evening), 2160);
      expect(e.minutesOf(PayKind.night), 4320);
      expect(e.minutesOf(PayKind.saturday), 1800);
      expect(e.minutesOf(PayKind.sunday), 2520);
      expect(e.minutesOf(PayKind.holiday), 0);
      expect(e.lines.map((l) => l.amount), [
        360000,
        21600,
        57600,
        12000,
        42000,
      ]);
      expect(e.total, 493200);
    });

    test('the hours are those of the Shifts page', () {
      final summary = summarizeShifts(events, year: 2026, month: 11);
      final e = pay(events);
      expect(e.hours, summary.hours);
      expect(e.shifts, summary.counts.values.fold(0, (a, b) => a + b));
    });
  });

  group('the money', () {
    test('without a wage there is nothing to pay, but the hours are known', () {
      final e = pay([at(2026, 11, 14, 18, 12)], settings: const PaySettings());
      expect(e.total, 0);
      expect(e.minutes, 720);
      // premiums at 0 % are not lines
      expect(e.lines.map((l) => l.kind), [PayKind.base]);
    });

    test('a premium of 0 % is left out, one that was not worked too', () {
      // a night: the evening hours would pay nothing at 0 %, and no Sunday
      // was worked
      final e = pay([
        at(2026, 11, 10, 18, 12),
      ], settings: s.copyWith(eveningPct: 0, sundayPct: 90));
      expect(e.lines.map((l) => l.kind), [PayKind.base, PayKind.night]);
    });

    test(
      'each line is rounded to the forint, halves up, the total adds up',
      () {
        // 7 h 30 min from 14:00: 2333 * 7.5 = 17497.5
        final e = pay([
          at(2026, 11, 10, 14, 7, extra: 30),
        ], settings: const PaySettings(hourly: 2333, eveningPct: 30));
        expect(e.minutes, 450);
        // 18:00-21:30 = 210 minutes at 30 %: 2333 * 3.5 * 0.3 = 2449.65
        expect(e.lines.map((l) => l.amount), [17498, 2450]);
        expect(e.total, 19948);
      },
    );

    test('just below a half is rounded down, exactly a half up', () {
      // 1 h at 1 forint an hour and 30 %: 0.3 forint
      final down = pay([
        at(2026, 11, 10, 18, 1),
      ], settings: const PaySettings(hourly: 1, eveningPct: 30));
      expect(down.lines.map((l) => l.amount), [1, 0]);
      expect(down.total, 1);
      // 1 h at 2 forints an hour and 25 %: exactly 0.5 forint
      final half = pay([
        at(2026, 11, 10, 18, 1),
      ], settings: const PaySettings(hourly: 2, eveningPct: 25));
      expect(half.lines.map((l) => l.amount), [2, 1]);
      expect(half.total, 3);
    });

    test('just under half a forint is rounded down', () {
      // 2999 forints an hour, one minute, 1 %: 2999 / 6000 = 0.4998 forint
      final e = pay([
        shift(floating(2026, 11, 10, 18), floating(2026, 11, 10, 18, 1)),
      ], settings: const PaySettings(hourly: 2999, eveningPct: 1));
      expect(e.minutesOf(PayKind.evening), 1);
      expect(e.lines.map((l) => l.amount), [50, 0]);
    });

    test('the settings are all that sets the amounts', () {
      final a = pay([at(2026, 11, 14, 18, 12)]);
      final b = pay([
        at(2026, 11, 14, 18, 12),
      ], settings: s.copyWith(hourly: 4000));
      expect(b.total, a.total * 2);
      expect(b.minutes, a.minutes);
    });
  });

  group('against the slow way', () {
    test('thousands of minutes of random shifts add up the same', () {
      final rnd = Random(20261113);
      final months = [
        (2026, 1),
        (2026, 3),
        (2026, 8),
        (2026, 10),
        (2026, 11),
        (2026, 12),
        (2027, 1),
      ];
      for (final (y, mo) in months) {
        final events = <Ev>[];
        for (var i = 0; i < 40; i++) {
          final start = floating(
            y,
            mo,
            1 + rnd.nextInt(28),
            rnd.nextInt(24),
            rnd.nextInt(12) * 5,
          );
          events.add(
            shift(
              start,
              start.add(Duration(minutes: 15 * (1 + rnd.nextInt(64)))),
              notes: rnd.nextInt(8) == 0 ? 'más' : kShiftMarker,
            ),
          );
        }
        final want = oracle(events, y, mo);
        final got = pay(events, year: y, month: mo);
        for (final k in PayKind.values) {
          expect(got.minutesOf(k), want[k], reason: '$y-$mo $k');
        }
        expect(got.minutes, want[PayKind.base], reason: '$y-$mo');
      }
    });

    test('shifts as long as a whole day, and over several days', () {
      final long = [
        shift(floating(2026, 11, 13, 20), floating(2026, 11, 16, 5)),
        shift(floating(2026, 11, 20), floating(2026, 11, 21)),
      ];
      final want = oracle(long, 2026, 11);
      final got = pay(long);
      for (final k in PayKind.values) {
        expect(got.minutesOf(k), want[k], reason: '$k');
      }
    });
  });

  group('the settings', () {
    test('a text on the device and back', () {
      expect(PaySettings.decode(s.encode()), s);
      expect(s.encode(), contains('"hourly":2000'));
      expect(s.encode(), contains('"evening":30'));
    });

    test('nothing set is no text', () {
      expect(const PaySettings().encode(), isNull);
      expect(PaySettings.decode(null), const PaySettings());
      expect(PaySettings.decode(''), const PaySettings());
    });

    test('unreadable text is nothing set, odd values are put right', () {
      expect(PaySettings.decode('nem json'), const PaySettings());
      expect(PaySettings.decode('[1]'), const PaySettings());
      expect(PaySettings.decode('{"hourly":"x"}'), const PaySettings());
      final odd = PaySettings.decode(
        '{"hourly":-5,"evening":99999,"night":12.6,"sunday":null}',
      );
      expect(odd.hourly, 0);
      expect(odd.eveningPct, PaySettings.maxPercent);
      expect(odd.nightPct, 13);
      expect(odd.sundayPct, 0);
      expect(
        PaySettings.decode('{"hourly":99999999999}').hourly,
        PaySettings.maxHourly,
      );
    });

    test('a number too large to be one costs only its own field', () {
      // (1e999 reads as infinity)
      final p = PaySettings.decode('{"hourly":1e999,"night":40}');
      expect(p.hourly, 0);
      expect(p.nightPct, 40);
    });

    test('is it set: a wage', () {
      expect(const PaySettings().isSet, isFalse);
      expect(const PaySettings(nightPct: 40).isSet, isFalse);
      expect(const PaySettings(hourly: 1).isSet, isTrue);
    });

    test('copyWith changes only what it is told to', () {
      expect(s.copyWith(), s);
      expect(s.copyWith(hourly: 1).hourly, 1);
      expect(s.copyWith(hourly: 1).nightPct, 40);
      expect(s.copyWith(eveningPct: 1).eveningPct, 1);
      expect(s.copyWith(nightPct: 1).nightPct, 1);
      expect(s.copyWith(saturdayPct: 1).saturdayPct, 1);
      expect(s.copyWith(sundayPct: 1).sundayPct, 1);
      expect(s.copyWith(holidayPct: 1).holidayPct, 1);
    });

    test('equality looks at every field', () {
      expect(
        s,
        const PaySettings(
          hourly: 2000,
          eveningPct: 30,
          nightPct: 40,
          saturdayPct: 20,
          sundayPct: 50,
          holidayPct: 100,
        ),
      );
      expect(s.hashCode, s.copyWith().hashCode);
      expect(s == s.copyWith(hourly: 1), isFalse);
      expect(s == s.copyWith(eveningPct: 1), isFalse);
      expect(s == s.copyWith(nightPct: 1), isFalse);
      expect(s == s.copyWith(saturdayPct: 1), isFalse);
      expect(s == s.copyWith(sundayPct: 1), isFalse);
      expect(s == s.copyWith(holidayPct: 1), isFalse);
    });
  });

  group('the words', () {
    test('the names of the lines', () {
      expect(payKindLabel(PayKind.base), 'Alapbér');
      expect(payKindLabel(PayKind.evening), 'Esti pótlék (18–22)');
      expect(payKindLabel(PayKind.night), 'Éjszakai pótlék (22–6)');
      expect(payKindLabel(PayKind.saturday), 'Szombati pótlék');
      expect(payKindLabel(PayKind.sunday), 'Vasárnapi pótlék');
      expect(payKindLabel(PayKind.holiday), 'Ünnepnapi pótlék');
    });

    test('a line can be compared and read', () {
      PayLine line({
        PayKind kind = PayKind.night,
        int minutes = 60,
        int percent = 40,
        int amount = 800,
      }) => PayLine(
        kind: kind,
        minutes: minutes,
        percent: percent,
        amount: amount,
      );
      final a = line();
      expect(a, line());
      expect(a.hashCode, line().hashCode);
      expect(a == line(kind: PayKind.sunday), isFalse);
      expect(a == line(minutes: 61), isFalse);
      expect(a == line(percent: 41), isFalse);
      expect(a == line(amount: 801), isFalse);
      expect(a.toString(), 'PayLine(night, 60 min, 40 %, 800)');
    });
  });
}
