import 'dart:math';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

import 'support/reference_expand.dart';

String line(Occurrence o) =>
    '${o.eventId}|${o.title}|${o.startUtc.toIso8601String()}|'
    '${o.endUtc.toIso8601String()}|${o.originalStart.toIso8601String()}|'
    '${o.allDay}|${o.tzid}|${o.isOverride}|${o.colorId}|${o.recurring}|'
    '${o.isShift}|${o.aiGenerated}';

List<String> lines(List<Occurrence> l) => [for (final o in l) line(o)];

void main() {
  setUpAll(ensureTimeZones);

  CalEvent series(
    String rule,
    DateTime start, {
    Duration len = const Duration(hours: 1),
    String tz = 'Europe/Budapest',
    bool allDay = false,
    List<DateTime> ex = const [],
    String notes = '',
  }) => CalEvent(
    id: 'm',
    calendarId: 'c',
    title: 'Sorozat',
    tzid: allDay ? null : tz,
    allDay: allDay,
    start: start,
    end: start.add(len),
    rrule: rule,
    exdates: ex,
    notes: notes,
    colorId: '3',
  );

  void agree(
    CalEvent master,
    DateTime from,
    DateTime to, {
    List<CalEvent> overrides = const [],
    String? why,
  }) {
    final want = lines(referenceExpand(master, from, to, overrides: overrides));
    final got = lines(expand(master, from, to, overrides: overrides));
    expect(got, want, reason: why ?? '${master.rrule} $from..$to');
  }

  group('edges of the window (instances that just touch it)', () {
    final s = floating(2026, 5, 4, 9);

    test(
      'an occurrence ending exactly at the start is out, a moment earlier in',
      () {
        // 09:00-10:00 Budapest = 07:00-08:00 UTC
        final m = series('FREQ=DAILY;COUNT=3', s);
        final end = DateTime.utc(2026, 5, 4, 8);
        const two = Duration(hours: 2);
        const moment = Duration(microseconds: 1);
        expect(expand(m, end, end.add(two)), isEmpty);
        expect(expand(m, end.subtract(moment), end.add(two)), hasLength(1));
        agree(m, end, end.add(two));
        agree(m, end.subtract(moment), end.add(two));
        // the other edge: starting exactly where the window ends is out
        final begin = DateTime.utc(2026, 5, 4, 7);
        expect(expand(m, begin.subtract(two), begin), isEmpty);
        expect(expand(m, begin.subtract(two), begin.add(moment)), hasLength(1));
        agree(m, begin.subtract(two), begin);
        agree(m, begin.subtract(two), begin.add(moment));
      },
    );

    test('all-day: the day after the window start still counts, the one before not', () {
      final m = series(
        'FREQ=DAILY;COUNT=5',
        floating(2026, 5, 4),
        len: const Duration(days: 1),
        allDay: true,
      );
      final from = DateTime.utc(2026, 5, 6);
      final out = expand(m, from, from.add(const Duration(days: 1)));
      expect(out.map((o) => o.originalStart.day), [6]);
      agree(m, from, from.add(const Duration(days: 1)));
      agree(
        m,
        from.add(const Duration(microseconds: 1)),
        DateTime.utc(2026, 5, 9),
      );
    });

    test('a west-of-UTC evening event reaches into the next UTC day', () {
      // 20:00-22:00 in Los Angeles is 03:00-05:00 UTC the next day
      final m = series(
        'FREQ=DAILY;COUNT=4',
        floating(2026, 5, 4, 20),
        len: const Duration(hours: 2),
        tz: 'America/Los_Angeles',
      );
      final from = DateTime.utc(2026, 5, 6, 4); // inside the 2nd occurrence
      final out = expand(m, from, from.add(const Duration(hours: 1)));
      expect(out, hasLength(1));
      agree(m, from, from.add(const Duration(hours: 1)));
      // and the easternmost zone, where the instant is a day before the wall
      final k = series(
        'FREQ=DAILY;COUNT=4',
        floating(2026, 5, 4, 1),
        len: const Duration(hours: 2),
        tz: 'Pacific/Kiritimati',
      );
      for (var h = 0; h < 96; h += 3) {
        final f = DateTime.utc(2026, 5, 3).add(Duration(hours: h));
        agree(k, f, f.add(const Duration(hours: 1)));
      }
    });

    test('a five-day event is seen from the middle of its run', () {
      final m = series(
        'FREQ=WEEKLY;COUNT=4',
        floating(2026, 5, 4, 9),
        len: const Duration(days: 5),
      );
      final from = DateTime.utc(2026, 5, 7, 12);
      final out = expand(m, from, from.add(const Duration(hours: 1)));
      expect(out.single.originalStart, floating(2026, 5, 4, 9));
      agree(m, from, from.add(const Duration(hours: 1)));
    });

    test(
      'a zero-length event is found only when it lies inside the window',
      () {
        final m = series('FREQ=DAILY;COUNT=6', s, len: Duration.zero);
        for (var d = 3; d < 12; d++) {
          final from = DateTime.utc(2026, 5, d, 7);
          agree(m, from, from.add(const Duration(hours: 1)));
          agree(m, from.subtract(const Duration(microseconds: 1)), from);
        }
      },
    );
  });

  group('daylight saving', () {
    test('the spring gap and the autumn overlap resolve as before', () {
      final gap = series(
        'FREQ=DAILY',
        floating(2026, 3, 27, 2, 30),
        len: const Duration(minutes: 45),
      );
      agree(gap, DateTime.utc(2026, 3, 27), DateTime.utc(2026, 4, 2));
      final overlap = series(
        'FREQ=DAILY',
        floating(2026, 10, 23, 2, 30),
        len: const Duration(minutes: 45),
      );
      agree(overlap, DateTime.utc(2026, 10, 23), DateTime.utc(2026, 10, 29));
      // the occurrence on the switch day keeps the real duration of the first
      final out = expand(
        gap,
        DateTime.utc(2026, 3, 29),
        DateTime.utc(2026, 3, 30),
      );
      expect(out, hasLength(1));
      expect(
        out.single.endUtc.difference(out.single.startUtc),
        const Duration(minutes: 45),
      );
    });

    test('a night shift across the switch', () {
      final night = series(
        'FREQ=DAILY;COUNT=10',
        floating(2026, 3, 24, 18),
        len: const Duration(hours: 12),
      );
      agree(night, DateTime.utc(2026, 3, 20), DateTime.utc(2026, 4, 5));
      final autumn = series(
        'FREQ=DAILY;COUNT=10',
        floating(2026, 10, 21, 18),
        len: const Duration(hours: 12),
      );
      agree(autumn, DateTime.utc(2026, 10, 20), DateTime.utc(2026, 11, 5));
    });
  });

  group('overrides, exceptions and the scan limit', () {
    test('moved, cancelled and far-moved instances agree', () {
      final m = series(
        'FREQ=DAILY',
        floating(2026, 5, 1, 9),
        ex: [floating(2026, 5, 6, 9)],
      );
      CalEvent over(int day, {bool cancelled = false, int moveHours = 3}) =>
          CalEvent(
            id: 'o$day',
            calendarId: 'c',
            title: 'Átrakva $day',
            tzid: 'Europe/Budapest',
            start: floating(2026, 5, day, 9 + moveHours),
            end: floating(2026, 5, day, 10 + moveHours),
            recurringEventId: 'm',
            originalStart: floating(2026, 5, day, 9),
            cancelled: cancelled,
          );
      final far = CalEvent(
        id: 'far',
        calendarId: 'c',
        title: 'Messziről',
        tzid: 'Europe/Budapest',
        start: floating(2026, 5, 10, 15),
        end: floating(2026, 5, 10, 16),
        recurringEventId: 'm',
        originalStart: floating(2026, 9, 1, 9),
      );
      final overrides = [over(3), over(4, cancelled: true), over(8), far];
      for (var d = 1; d < 14; d++) {
        final from = DateTime.utc(2026, 5, d);
        agree(m, from, from.add(const Duration(days: 2)), overrides: overrides);
      }
      expect(
        expand(
          m,
          DateTime.utc(2026, 5, 10),
          DateTime.utc(2026, 5, 11),
          overrides: overrides,
        ).map((o) => o.title),
        contains('Messziről'),
      );
    });

    test('the iteration cap cuts both versions at the same instance', () {
      final hourly = series(
        'FREQ=HOURLY',
        floating(2023, 1, 1),
        len: const Duration(minutes: 30),
      );
      // 20 000 hours are about 2.3 years: the window beyond is empty in both
      for (final from in [
        DateTime.utc(2023, 6, 1),
        DateTime.utc(2025, 3, 1),
        DateTime.utc(2025, 4, 1),
        DateTime.utc(2026, 1, 1),
      ]) {
        agree(hourly, from, from.add(const Duration(days: 2)));
      }
    });

    test('a series with notes of a shift keeps its marker', () {
      final m = series(
        'FREQ=DAILY;COUNT=3',
        floating(2026, 5, 4, 6),
        notes: kShiftMarker,
      );
      final out = expand(m, DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 1));
      expect(out.every((o) => o.isShift), isTrue);
      agree(m, DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 1));
    });

    test('non-recurring and cancelled events', () {
      final one = CalEvent(
        id: 's',
        calendarId: 'c',
        title: 'Egyszeri',
        tzid: 'Europe/Budapest',
        start: floating(2026, 5, 4, 9),
        end: floating(2026, 5, 4, 10),
      );
      agree(one, DateTime.utc(2026, 5, 4), DateTime.utc(2026, 5, 5));
      agree(one, DateTime.utc(2026, 5, 5), DateTime.utc(2026, 5, 6));
      expect(
        expand(
          one.copyWith(cancelled: true),
          DateTime.utc(2026),
          DateTime.utc(2027),
        ),
        isEmpty,
      );
    });
  });

  group('random series against the reference', () {
    final zones = [
      'Europe/Budapest',
      'America/New_York',
      'America/Los_Angeles',
      'Australia/Lord_Howe',
      'Pacific/Kiritimati',
      'Etc/GMT+12',
      'Asia/Kolkata',
      'UTC',
    ];
    final spans = [
      Duration.zero,
      const Duration(minutes: 15),
      const Duration(hours: 1),
      const Duration(minutes: 90),
      const Duration(hours: 23),
      const Duration(hours: 25),
      const Duration(days: 2),
      const Duration(days: 5),
    ];
    String rule(Random r) {
      final dayOfMonth = 1 + r.nextInt(28);
      final list = [
        'FREQ=DAILY',
        'FREQ=DAILY;INTERVAL=${2 + r.nextInt(2)}',
        'FREQ=DAILY;COUNT=${1 + r.nextInt(40)}',
        'FREQ=WEEKLY;BYDAY=MO,WE,FR',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;WKST=SU',
        'FREQ=WEEKLY;UNTIL=2026${(1 + r.nextInt(12)).toString().padLeft(2, '0')}15T000000Z',
        'FREQ=MONTHLY;BYMONTHDAY=$dayOfMonth',
        'FREQ=MONTHLY;BYDAY=1MO',
        'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
        'FREQ=YEARLY',
      ];
      return list[r.nextInt(list.length)];
    }

    final special = [
      floating(2026, 3, 28, 1, 30),
      floating(2026, 3, 29, 2, 30),
      floating(2026, 10, 24, 2, 30),
      floating(2026, 10, 25, 2, 30),
      floating(2026, 3, 8, 2, 30),
      floating(2026, 11, 1, 1, 30),
      floating(2026, 4, 4, 1, 45),
      floating(2026, 10, 4, 2, 15),
    ];

    test('1500 scenarios agree, field for field', () {
      final r = Random(20261111);
      var compared = 0;
      for (var i = 0; i < 1500; i++) {
        final allDay = r.nextInt(4) == 0;
        final tz = zones[r.nextInt(zones.length)];
        final start = r.nextInt(5) == 0
            ? special[r.nextInt(special.length)]
            : floating(
                2023 + r.nextInt(4),
                1 + r.nextInt(12),
                1 + r.nextInt(28),
                allDay ? 0 : r.nextInt(24),
                allDay ? 0 : r.nextInt(4) * 15,
              );
        final start0 = allDay
            ? floating(start.year, start.month, start.day)
            : start;
        final len = allDay
            ? Duration(days: 1 + r.nextInt(3))
            : spans[r.nextInt(spans.length)];
        final ruleText = rule(r);
        // a few of the instances become exdates or exceptions
        final first = referenceParse(ruleText)
            .getInstances(start: start0)
            .take(60)
            .toList();
        final ex = <DateTime>[
          for (var k = 0; k < r.nextInt(3); k++)
            if (first.isNotEmpty) first[r.nextInt(first.length)],
        ];
        final master = series(
          ruleText,
          start0,
          len: len,
          tz: tz,
          allDay: allDay,
          ex: ex,
        );
        final overrides = <CalEvent>[];
        for (var k = 0; k < r.nextInt(4) && first.isNotEmpty; k++) {
          final at = first[r.nextInt(first.length)];
          final move = r.nextBool()
              ? Duration(hours: 1 + r.nextInt(30))
              : Duration(days: 1 + r.nextInt(6));
          final cancelled = r.nextInt(3) == 0;
          final ns = allDay
              ? floating(
                  at.year,
                  at.month,
                  at.day,
                ).add(Duration(days: r.nextInt(5)))
              : at.add(move);
          overrides.add(
            CalEvent(
              id: 'o$k',
              calendarId: 'c',
              title: 'Kivétel $k',
              tzid: allDay ? null : tz,
              allDay: allDay,
              start: ns,
              end: ns.add(allDay ? const Duration(days: 1) : len),
              recurringEventId: 'm',
              originalStart: at,
              cancelled: cancelled,
            ),
          );
        }
        for (var w = 0; w < 4; w++) {
          final base = start0.add(Duration(days: r.nextInt(1500) - 60));
          final from = DateTime.utc(
            base.year,
            base.month,
            base.day,
            r.nextInt(24),
          );
          final span = [
            const Duration(hours: 1),
            const Duration(days: 1),
            const Duration(days: 7),
            const Duration(days: 42),
          ][r.nextInt(4)];
          agree(
            master,
            from,
            from.add(span),
            overrides: overrides,
            why: 'scenario $i: $ruleText $tz $start0 +$len window $from +$span',
          );
          compared++;
        }
      }
      expect(compared, 6000);
    });
  });

  group('the parsed rules are remembered', () {
    test('the same text gives the same rule, a bad one throws every time', () {
      final a = parseRule('RRULE:FREQ=DAILY;COUNT=3');
      expect(identical(parseRule('RRULE:FREQ=DAILY;COUNT=3'), a), isTrue);
      expect(() => parseRule('FREQ=NONSENSE'), throwsA(anything));
      expect(() => parseRule('FREQ=NONSENSE'), throwsA(anything));
    });

    test('a week start other than Monday is ignored, as ever', () {
      final r = parseRule('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;WKST=SU');
      final d = r.getInstances(start: floating(2026, 5, 5)).take(3).toList();
      expect(d, [
        floating(2026, 5, 5),
        floating(2026, 5, 19),
        floating(2026, 6, 2),
      ]);
    });

    test('the memory is bounded and stays correct beyond its size', () {
      final first = parseRule('FREQ=DAILY;COUNT=7');
      for (var i = 1; i <= 600; i++) {
        parseRule('FREQ=DAILY;COUNT=${i + 7}');
      }
      // the first one was dropped meanwhile: a fresh parse, equal in effect
      final again = parseRule('FREQ=DAILY;COUNT=7');
      expect(identical(again, first), isFalse);
      expect(
        again.getInstances(start: floating(2026, 5, 4)).length,
        first.getInstances(start: floating(2026, 5, 4)).length,
      );
    });

    test('a rule used again stays while older ones go', () {
      final keep = parseRule('FREQ=DAILY;COUNT=2');
      for (var i = 0; i < 400; i++) {
        parseRule('FREQ=DAILY;COUNT=${100 + i}');
        parseRule('FREQ=DAILY;COUNT=2'); // used all the time
      }
      expect(identical(parseRule('FREQ=DAILY;COUNT=2'), keep), isTrue);
    });
  });
}
