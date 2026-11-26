import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

void main() {
  group('Easter', () {
    // (checked against the Gauss algorithm and dateutil)
    const known = {
      2000: '04-23',
      2001: '04-15',
      2002: '03-31',
      2003: '04-20',
      2004: '04-11',
      2005: '03-27',
      2006: '04-16',
      2007: '04-08',
      2008: '03-23',
      2009: '04-12',
      2010: '04-04',
      2011: '04-24',
      2012: '04-08',
      2013: '03-31',
      2014: '04-20',
      2015: '04-05',
      2016: '03-27',
      2017: '04-16',
      2018: '04-01',
      2019: '04-21',
      2020: '04-12',
      2021: '04-04',
      2022: '04-17',
      2023: '04-09',
      2024: '03-31',
      2025: '04-20',
      2026: '04-05',
      2027: '03-28',
      2028: '04-16',
      2029: '04-01',
      2030: '04-21',
      2031: '04-13',
      2032: '03-28',
      2033: '04-17',
      2034: '04-09',
      2035: '03-25',
      2036: '04-13',
      2037: '04-05',
      2038: '04-25',
      2039: '04-10',
      2040: '04-01',
    };

    test('the date of Easter Sunday in forty-one years', () {
      for (final e in known.entries) {
        final got = easterSunday(e.key);
        final text =
            '${got.month.toString().padLeft(2, '0')}-${got.day.toString().padLeft(2, '0')}';
        expect(text, e.value, reason: '${e.key}');
        expect(got.year, e.key);
        expect(got.weekday, DateTime.sunday, reason: '${e.key}');
      }
    });

    test('a floating date (UTC-flagged, midnight)', () {
      final e = easterSunday(2026);
      expect(e.isUtc, isTrue);
      expect(e.hour, 0);
      expect(e, d(2026, 4, 5));
    });
  });

  group('the holidays by law', () {
    List<String> list(int year) => [
      for (final e in (huHolidays(
        year,
      ).entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        '${e.key.month}-${e.key.day}',
    ];

    test('2026: fourteen days, Christmas Eve among them', () {
      expect(list(2026), [
        '1-1', '3-15', '4-3', '4-5', '4-6', '5-1', '5-24', '5-25', //
        '8-20', '10-23', '11-1', '12-24', '12-25', '12-26',
      ]);
    });

    test('2027 and 2028 follow the same rules', () {
      expect(list(2027), [
        '1-1', '3-15', '3-26', '3-28', '3-29', '5-1', '5-16', '5-17', //
        '8-20', '10-23', '11-1', '12-24', '12-25', '12-26',
      ]);
      expect(list(2028), [
        '1-1', '3-15', '4-14', '4-16', '4-17', '5-1', '6-4', '6-5', //
        '8-20', '10-23', '11-1', '12-24', '12-25', '12-26',
      ]);
    });

    test('2025: thirteen, Christmas Eve is not a holiday by law yet', () {
      final days = list(2025);
      expect(days.length, 13);
      expect(days, isNot(contains('12-24')));
      expect(days, containsAll(['4-18', '4-20', '4-21', '6-8', '6-9']));
    });

    test('before 2017 Good Friday was not a holiday', () {
      final days = list(2016);
      expect(days, isNot(contains('3-25')));
      expect(days, containsAll(['3-27', '3-28']));
      expect(list(2017), contains('4-14'));
    });

    test('the movable days hang on Easter: -2, 0, +1, +49, +50', () {
      for (final y in [2024, 2026, 2030, 2038]) {
        final e = easterSunday(y);
        final h = huHolidays(y);
        expect(h[e.subtract(const Duration(days: 2))], 'Nagypéntek');
        expect(h[e], 'Húsvétvasárnap');
        expect(h[e.add(const Duration(days: 1))], 'Húsvéthétfő');
        expect(h[e.add(const Duration(days: 49))], 'Pünkösdvasárnap');
        expect(h[e.add(const Duration(days: 50))], 'Pünkösdhétfő');
        expect(e.add(const Duration(days: 49)).weekday, DateTime.sunday);
      }
    });

    test('every name is there', () {
      expect(huHolidays(2026).values, everyElement(isNotEmpty));
      expect(huHolidays(2026)[d(2026, 1, 1)], 'Újév');
      expect(huHolidays(2026)[d(2026, 12, 24)], 'Szenteste');
      expect(huHolidays(2026)[d(2026, 12, 26)], 'Karácsony másnapja');
    });
  });

  group('huDayInfo', () {
    test('an ordinary day is nothing special', () {
      expect(huDayInfo(d(2026, 11, 16)), isNull);
      expect(huDayInfo(d(2027, 6, 3)), isNull);
    });

    test('a holiday, whatever the clock says', () {
      final h = huDayInfo(d(2026, 1, 1))!;
      expect(h.kind, HuDayKind.holiday);
      expect(h.name, 'Újév');
      expect(h.isDayOff, isTrue);
      // the fields y/m/d decide, not the zone or the time of day
      expect(huDayInfo(DateTime(2026, 1, 1, 23, 59))?.name, 'Újév');
      expect(huDayInfo(DateTime.utc(2026, 1, 1, 12))?.name, 'Újév');
    });

    test('the bridge days and the working Saturdays of 2026', () {
      expect(huDayInfo(d(2026, 1, 2))?.kind, HuDayKind.restDay);
      expect(huDayInfo(d(2026, 8, 21))?.kind, HuDayKind.restDay);
      expect(huDayInfo(d(2026, 1, 10))?.kind, HuDayKind.workSaturday);
      expect(huDayInfo(d(2026, 8, 8))?.kind, HuDayKind.workSaturday);
      expect(huDayInfo(d(2026, 1, 2))!.isDayOff, isTrue);
      expect(huDayInfo(d(2026, 1, 10))!.isDayOff, isFalse);
    });

    test('12 December 2026 is an ordinary Saturday (the law cancelled it)', () {
      expect(huDayInfo(d(2026, 12, 12)), isNull);
      expect(d(2026, 12, 12).weekday, DateTime.saturday);
      // and 24 December is a holiday instead of a bridge day
      expect(huDayInfo(d(2026, 12, 24))?.kind, HuDayKind.holiday);
    });

    test('the bridge days are Fridays, the worked days Saturdays', () {
      for (final day in [d(2026, 1, 2), d(2026, 8, 21)]) {
        expect(day.weekday, DateTime.friday);
      }
      for (final day in [d(2026, 1, 10), d(2026, 8, 8)]) {
        expect(day.weekday, DateTime.saturday);
      }
    });

    test('years without a decree show nothing but the holidays', () {
      expect(huDayInfo(d(2027, 1, 2)), isNull);
      expect(huDayInfo(d(2028, 1, 8)), isNull);
      expect(huDayInfo(d(2027, 12, 25))?.name, 'Karácsony');
    });

    test(
      'the short label is for a small place: the name, or what kind of day',
      () {
        expect(huDayInfo(d(2026, 1, 1))!.shortLabel, 'Újév');
        expect(huDayInfo(d(2026, 1, 2))!.shortLabel, 'Pihenőnap');
        expect(huDayInfo(d(2026, 1, 10))!.shortLabel, 'Munkanap');
      },
    );

    test('labels for a screen', () {
      expect(huDayInfo(d(2026, 1, 1))!.label, 'Munkaszüneti nap: Újév');
      expect(huDayInfo(d(2026, 1, 2))!.label, 'Áthelyezett pihenőnap');
      expect(
        huDayInfo(d(2026, 1, 10))!.label,
        'Áthelyezett munkanap (szombat)',
      );
    });

    test('equal when kind and name are', () {
      expect(huDayInfo(d(2026, 1, 1)), huDayInfo(d(2026, 1, 1)));
      expect(huDayInfo(d(2026, 1, 1)), isNot(huDayInfo(d(2026, 3, 15))));
      expect(
        huDayInfo(d(2026, 1, 1)).hashCode,
        huDayInfo(d(2026, 1, 1)).hashCode,
      );
    });

    test('the year the table was checked is stated', () {
      expect(huCalendarCheckedOn, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });
  });
}
