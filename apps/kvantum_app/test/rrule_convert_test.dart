import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/google/rrule_convert.dart';
import 'package:kvantum_core/kvantum_core.dart';

const bp = 'Europe/Budapest';

void main() {
  setUpAll(ensureTimeZones);

  group('Google -> local', () {
    test(
      'UTC UNTIL becomes the floating wall-clock limit (summer + winter)',
      () {
        expect(
          rruleFromGoogle(
            'FREQ=DAILY;UNTIL=20260510T070000Z',
            bp,
            allDay: false,
          ),
          'FREQ=DAILY;UNTIL=20260510T090000Z',
        ); // CEST
        expect(
          rruleFromGoogle(
            'FREQ=DAILY;UNTIL=20261201T080000Z',
            bp,
            allDay: false,
          ),
          'FREQ=DAILY;UNTIL=20261201T090000Z',
        ); // CET
      },
    );
    test('date-only UNTIL (all-day) covers the whole day', () {
      expect(
        rruleFromGoogle('FREQ=WEEKLY;UNTIL=20261231', null, allDay: true),
        'FREQ=WEEKLY;UNTIL=20261231T235959Z',
      );
    });
    test('rules without UNTIL are untouched', () {
      expect(
        rruleFromGoogle('FREQ=DAILY;COUNT=3', bp, allDay: false),
        'FREQ=DAILY;COUNT=3',
      );
    });
  });

  group('local -> Google', () {
    final start = floating(2026, 5, 4, 9);
    test('timed: UNTIL = UTC instant of the last allowed occurrence', () {
      expect(
        rruleToGoogle(
          'FREQ=DAILY;UNTIL=20260510T235959Z',
          start,
          bp,
          allDay: false,
        ),
        'FREQ=DAILY;UNTIL=20260510T070000Z',
      );
    });
    test('an event right after local midnight cannot slip past UNTIL via the UTC offset', () {
      // 00:30 local on 11.05 is 22:30Z on 10.05, which a naive UTC UNTIL would include.
      final s = floating(2026, 5, 4, 0, 30);
      final out = rruleToGoogle(
        'FREQ=DAILY;UNTIL=20260510T235959Z',
        s,
        bp,
        allDay: false,
      );
      expect(
        out,
        'FREQ=DAILY;UNTIL=20260509T223000Z',
      ); // last = 10.05 00:30 local
    });
    test('all-day: date form', () {
      expect(
        rruleToGoogle(
          'FREQ=WEEKLY;UNTIL=20261231T235959Z',
          floating(2026, 5, 4),
          null,
          allDay: true,
        ),
        'FREQ=WEEKLY;UNTIL=20261231',
      );
    });
    test('round trip keeps the same occurrences', () {
      const local = 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20260601T235959Z';
      final g = rruleToGoogle(local, start, bp, allDay: false);
      final back = rruleFromGoogle(g, bp, allDay: false);
      List<DateTime> occ(String r) =>
          parseRule(r).getInstances(start: start).toList();
      expect(occ(back), occ(local));
    });
    test('no UNTIL: unchanged', () {
      expect(
        rruleToGoogle('FREQ=DAILY;COUNT=3', start, bp, allDay: false),
        'FREQ=DAILY;COUNT=3',
      );
    });
  });
}
