import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

CalEvent weekly(String rule) => CalEvent(
  id: 'm',
  calendarId: 'naptar',
  title: 'Heti',
  tzid: 'Europe/Budapest',
  start: floating(2026, 5, 4, 9),
  end: floating(2026, 5, 4, 10),
  rrule: rule,
);

List<String> days(CalEvent e) => [
  for (final o in expand(e, DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 1)))
    '${o.originalStart.month}-${o.originalStart.day}',
];

void main() {
  setUpAll(ensureTimeZones);

  group('repeat rules written by other calendars', () {
    test('WKST=SU (Google web UI, Apple, Outlook) is readable', () {
      expect(
        () => parseRule('FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE'),
        returnsNormally,
      );
      expect(
        () => parseRule('RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE'),
        returnsNormally,
      );
      expect(
        () => parseRule('FREQ=WEEKLY;BYDAY=MO;wkst=su;COUNT=4'),
        returnsNormally,
      );
    });

    test('the events are the same as with the rule written without WKST', () {
      expect(
        days(weekly('FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE;COUNT=6')),
        days(weekly('FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6')),
      );
      expect(days(weekly('FREQ=WEEKLY;WKST=SU;BYDAY=MO;COUNT=3')).length, 3);
    });

    test('WKST=MO keeps working', () {
      expect(
        days(weekly('FREQ=WEEKLY;WKST=MO;BYDAY=MO;COUNT=3')),
        days(weekly('FREQ=WEEKLY;BYDAY=MO;COUNT=3')),
      );
    });

    test('a really broken rule still throws, so callers must isolate it', () {
      expect(() => parseRule('FREQ=NONSENSE'), throwsA(anything));
      expect(() => parseRule(''), throwsA(anything));
    });
  });
}
