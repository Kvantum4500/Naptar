import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/notify/summary_plan.dart';
import 'package:kvantum_core/kvantum_core.dart';

const bp = 'Europe/Budapest';

DateTime at(int y, int mo, int d, int h, [int mi = 0]) =>
    resolveWallClock(bp, floating(y, mo, d, h, mi));

Occurrence occ(
  String title,
  DateTime startUtc,
  DateTime endUtc, {
  bool allDay = false,
  bool shift = false,
}) => Occurrence(
  eventId: title,
  title: title,
  startUtc: startUtc,
  endUtc: endUtc,
  originalStart: floating(2026, 11, 16),
  allDay: allDay,
  isShift: shift,
);

TaskView task(
  String title, {
  DateTime? due,
  bool done = false,
  bool deleted = false,
}) => TaskView(
  SyncRecord(id: title, kind: kindTask).edit(
    {...taskFields(title: title, due: due, done: done), 'deleted': deleted},
    ts: 1,
    dev: 'd',
  ),
);

void main() {
  setUpAll(ensureTimeZones);

  // Monday 16 November 2026, 06:00 in Budapest
  final now = at(2026, 11, 16, 6);
  final monday = floating(2026, 11, 16);
  List<String> lines(Map<DateTime, DaySummary> m, DateTime day) =>
      m[day]!.body.split('\n');

  group('events', () {
    test('each lands on its own day', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          occ('Fogorvos', at(2026, 11, 16, 14), at(2026, 11, 16, 15)),
          occ('Edzés', at(2026, 11, 17, 18), at(2026, 11, 17, 19)),
        ],
        tasks: const [],
      );
      expect(lines(m, monday), ['14:00 Fogorvos']);
      expect(lines(m, floating(2026, 11, 17)), ['18:00 Edzés']);
      expect(m.length, 2);
    });

    test('an overnight shift is on both days, told as it is on each', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          occ(
            'Éjszakai műszak',
            at(2026, 11, 16, 18),
            at(2026, 11, 17, 6),
            shift: true,
          ),
        ],
        tasks: const [],
      );
      expect(lines(m, monday), ['18:00 Éjszakai műszak']);
      expect(lines(m, floating(2026, 11, 17)), ['06:00-ig: Éjszakai műszak']);
    });

    test('a shift that began yesterday is in today\'s summary', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          occ('Éjszakai műszak', at(2026, 11, 15, 18), at(2026, 11, 16, 6)),
        ],
        tasks: const [],
      );
      expect(lines(m, monday), ['06:00-ig: Éjszakai műszak']);
    });

    test(
      'an all-day event is on every day it lasts (the end is exclusive)',
      () {
        final m = summariesFor(
          nowUtc: now,
          occurrences: [
            occ(
              'Szabadság',
              floating(2026, 11, 17),
              floating(2026, 11, 20),
              allDay: true,
            ),
          ],
          tasks: const [],
        );
        expect(m.keys, [
          floating(2026, 11, 17),
          floating(2026, 11, 18),
          floating(2026, 11, 19),
        ]);
        expect(lines(m, floating(2026, 11, 18)), ['Egész nap: Szabadság']);
      },
    );

    test('a day with nothing has no summary', () {
      expect(
        summariesFor(nowUtc: now, occurrences: const [], tasks: const []),
        isEmpty,
      );
    });

    test('reaches today and the next seven days, no further', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          for (var i = 0; i <= 9; i++)
            occ('E$i', at(2026, 11, 16 + i, 10), at(2026, 11, 16 + i, 11)),
        ],
        tasks: const [],
      );
      expect(m.length, 8);
      expect(m.keys.first, monday);
      expect(m.keys.last, floating(2026, 11, 23));
    });

    test('the number of days can be changed', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          for (var i = 0; i <= 3; i++)
            occ('E$i', at(2026, 11, 16 + i, 10), at(2026, 11, 16 + i, 11)),
        ],
        tasks: const [],
        days: 1,
      );
      expect(m.length, 2);
    });

    test('"today" is the day in the display zone, not in UTC', () {
      // 23:30 UTC on the 16th is already 00:30 on the 17th in Budapest
      final late = DateTime.utc(2026, 11, 16, 23, 30);
      final m = summariesFor(
        nowUtc: late,
        occurrences: [
          occ('Reggeli', at(2026, 11, 17, 8), at(2026, 11, 17, 9)),
          occ('Tegnapi', at(2026, 11, 16, 8), at(2026, 11, 16, 9)),
        ],
        tasks: const [],
      );
      expect(m.keys.first, floating(2026, 11, 17));
      expect(m.keys, isNot(contains(monday)));
    });
  });

  group('tasks', () {
    test('due on the day; on today also the overdue, oldest first', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: const [],
        tasks: [
          task('Mai', due: monday),
          task('Holnapi', due: floating(2026, 11, 17)),
          task('Régebbi', due: floating(2026, 11, 10)),
          task('Tegnapi', due: floating(2026, 11, 15)),
        ],
      );
      expect(lines(m, monday), [
        'Feladat (lejárt): Régebbi',
        'Feladat (lejárt): Tegnapi',
        'Feladat: Mai',
      ]);
      // the overdue ones are told once, on today only
      expect(lines(m, floating(2026, 11, 17)), ['Feladat: Holnapi']);
    });

    test('done, deleted and undated tasks are left out', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: const [],
        tasks: [
          task('Kész', due: monday, done: true),
          task('Törölt', due: monday, deleted: true),
          task('Határidő nélkül'),
        ],
      );
      expect(m, isEmpty);
    });
  });

  group('the special day and the weather', () {
    test('a holiday gets a summary of its own', () {
      final m = summariesFor(
        nowUtc: at(2026, 12, 20, 6),
        occurrences: const [],
        tasks: const [],
      );
      expect(m.keys, [
        floating(2026, 12, 24),
        floating(2026, 12, 25),
        floating(2026, 12, 26),
      ]);
      expect(lines(m, floating(2026, 12, 24)), ['Munkaszüneti nap: Szenteste']);
    });

    test('the weather line joins a day that has something else', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          occ('Fogorvos', at(2026, 11, 16, 14), at(2026, 11, 16, 15)),
        ],
        tasks: const [],
        forecast: [
          DayWeather(day: monday, tMin: 4, tMax: 11, code: 3),
          DayWeather(day: floating(2026, 11, 17), tMin: 1, tMax: 9, code: 61),
        ],
      );
      expect(lines(m, monday), ['Időjárás: felhős, 4–11 °C', '14:00 Fogorvos']);
      // a day with the weather only has no summary
      expect(m.containsKey(floating(2026, 11, 17)), isFalse);
    });

    test('no forecast, no weather line', () {
      final m = summariesFor(
        nowUtc: now,
        occurrences: [
          occ('Fogorvos', at(2026, 11, 16, 14), at(2026, 11, 16, 15)),
        ],
        tasks: const [],
      );
      expect(lines(m, monday), ['14:00 Fogorvos']);
    });
  });
}
