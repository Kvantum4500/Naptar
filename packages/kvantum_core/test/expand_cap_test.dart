import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(ensureTimeZones);

  CalEvent series(DateTime start, {String rule = 'FREQ=DAILY'}) => CalEvent(
    id: 'm',
    calendarId: 'c',
    title: 'Sorozat',
    tzid: 'Europe/Budapest',
    start: start,
    end: start.add(const Duration(hours: 1)),
    rrule: rule,
  );

  group('the safety limit of expand() is reported', () {
    // The walk is capped at 20 000 instances: about 54.8 years of a daily rule.
    // (Walking that far is slow, so only this one test does it.)
    test('a window beyond the 20 000th instance calls onCapped once', () {
      var calls = 0;
      final got = expand(
        series(floating(1970, 1, 1, 9)),
        DateTime.utc(2030, 1, 1),
        DateTime.utc(2030, 2, 1),
        onCapped: () => calls++,
      );
      expect(calls, 1);
      expect(got, isEmpty, reason: 'the walk stopped before the window');
    });

    test('a window inside the limit does not call it, and finds its days', () {
      var calls = 0;
      final got = expand(
        series(floating(1970, 1, 1, 9)),
        DateTime.utc(1971, 1, 1),
        DateTime.utc(1971, 1, 8),
        onCapped: () => calls++,
      );
      expect(calls, 0);
      expect(got, hasLength(7));
    });

    test('an ordinary series, a single event and a finished one do not', () {
      var calls = 0;
      void count() => calls++;
      final from = DateTime.utc(2026, 5, 1), to = DateTime.utc(2026, 6, 1);
      expand(series(floating(2026, 1, 1, 9)), from, to, onCapped: count);
      expand(
        series(floating(2026, 1, 1, 9), rule: 'FREQ=WEEKLY;COUNT=3'),
        from,
        to,
        onCapped: count,
      );
      final start = floating(2026, 5, 4, 9);
      expand(
        CalEvent(
          id: 's',
          calendarId: 'c',
          title: 'Egyszeri',
          tzid: 'Europe/Budapest',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
        from,
        to,
        onCapped: count,
      );
      expect(calls, 0);
    });
  });
}
