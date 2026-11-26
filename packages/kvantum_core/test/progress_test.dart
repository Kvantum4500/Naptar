import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

CheckInView check(
  DateTime day, {
  int? physical,
  int? mental,
  int? mood,
  int? sleep,
  bool deleted = false,
}) => CheckInView(
  SyncRecord(id: checkInId(day), kind: kindCheckIn).edit(
    {
      ...checkInFields(
        physical: physical,
        mental: mental,
        mood: mood,
        sleep: sleep,
      ),
      'deleted': deleted,
    },
    ts: 1,
    dev: 'd',
  ),
);

WorkoutLogView log(
  String id,
  DateTime day, {
  int minutes = 60,
  String sport = 'gym',
  bool done = true,
  int? body,
  int? mind,
  int? energyStart,
  int? energyEnd,
  int? experience,
  bool deleted = false,
}) => WorkoutLogView(
  SyncRecord(id: id, kind: kindWorkoutLog).edit(
    {
      ...workoutLogFields(
        title: 'Edzés',
        date: day,
        minutes: minutes,
        sport: sport,
        done: done,
        bodyLoad: body,
        mindLoad: mind,
        energyStart: energyStart,
        energyEnd: energyEnd,
        experience: experience,
      ),
      'deleted': deleted,
    },
    ts: 1,
    dev: 'd',
  ),
);

/// A workout that was rated on one device and then marked "skipped" on
/// another: what the first one answered is still in the record.
WorkoutLogView skippedButRated(String id, DateTime day) => WorkoutLogView(
  SyncRecord(id: id, kind: kindWorkoutLog)
      .edit(
        workoutLogFields(
          title: 'Edzés',
          date: day,
          minutes: 60,
          sport: 'gym',
          bodyLoad: 1,
          mindLoad: 1,
          energyStart: 1,
          energyEnd: 1,
          experience: 1,
        ),
        ts: 1,
        dev: 'a',
      )
      .edit({'done': false}, ts: 2, dev: 'b'),
);

/// A feedback whose record has no length (another version left it out).
WorkoutLogView withoutLength(String id, DateTime day) {
  final fields = {
    ...workoutLogFields(title: 'Edzés', date: day, minutes: 60, sport: 'gym'),
  }..remove('minutes');
  return WorkoutLogView(
    SyncRecord(id: id, kind: kindWorkoutLog).edit(fields, ts: 1, dev: 'd'),
  );
}

void main() {
  group('a point of a series', () {
    test('is the same as another of the same day and value, and no other', () {
      final a = DayValue(d(2026, 11, 16), 3);
      expect(a, DayValue(d(2026, 11, 16), 3));
      expect(a.hashCode, DayValue(d(2026, 11, 16), 3).hashCode);
      expect(a, isNot(DayValue(d(2026, 11, 17), 3)));
      expect(a, isNot(DayValue(d(2026, 11, 16), 4)));
    });
  });

  group('the answers of the check-in, day by day', () {
    final all = [
      check(d(2026, 11, 2), physical: 3, sleep: 4),
      check(d(2026, 11, 4), physical: 5, mood: 2),
      check(d(2026, 11, 3), physical: 1),
      check(d(2026, 11, 9), physical: 4),
      check(d(2026, 11, 5), sleep: 2),
      check(d(2026, 11, 6), physical: 2, deleted: true),
    ];

    List<DayValue> series(
      CheckInMetric m, {
      required DateTime from,
      required DateTime to,
    }) => checkInSeries(all, m, from: from, to: to);

    test('only the days that answered, oldest first', () {
      expect(
        series(
          CheckInMetric.physical,
          from: d(2026, 11, 1),
          to: d(2026, 11, 30),
        ),
        [
          DayValue(d(2026, 11, 2), 3),
          DayValue(d(2026, 11, 3), 1),
          DayValue(d(2026, 11, 4), 5),
          DayValue(d(2026, 11, 9), 4),
        ],
      );
    });

    test('each metric reads its own answer', () {
      expect(
        series(CheckInMetric.sleep, from: d(2026, 11, 1), to: d(2026, 11, 30)),
        [DayValue(d(2026, 11, 2), 4), DayValue(d(2026, 11, 5), 2)],
      );
      expect(
        series(CheckInMetric.mood, from: d(2026, 11, 1), to: d(2026, 11, 30)),
        [DayValue(d(2026, 11, 4), 2)],
      );
      expect(
        series(CheckInMetric.mental, from: d(2026, 11, 1), to: d(2026, 11, 30)),
        isEmpty,
      );
    });

    test('both ends of the range are in, what is outside is not', () {
      expect(
        series(
          CheckInMetric.physical,
          from: d(2026, 11, 3),
          to: d(2026, 11, 4),
        ).map((p) => p.day.day),
        [3, 4],
      );
    });

    test('a deleted check-in is not there', () {
      expect(
        series(
          CheckInMetric.physical,
          from: d(2026, 11, 6),
          to: d(2026, 11, 6),
        ),
        isEmpty,
      );
    });

    test('a time of day on the range ends does not matter', () {
      expect(
        series(
          CheckInMetric.physical,
          from: floating(2026, 11, 3, 18),
          to: floating(2026, 11, 4, 6),
        ),
        hasLength(2),
      );
    });

    test('the labels are the names on the screen', () {
      expect(
        [for (final m in CheckInMetric.values) m.label],
        ['Fizikai energia', 'Mentális energia', 'Hangulat', 'Alvás'],
      );
    });
  });

  group('the trend: the average of the last days', () {
    test('each point is the mean of its week, from the days that answered', () {
      final points = [
        DayValue(d(2026, 11, 1), 2),
        DayValue(d(2026, 11, 2), 4),
        DayValue(d(2026, 11, 8), 5),
      ];
      final avg = trailingAverage(points);
      expect(avg.map((p) => p.value), [2, 3, (4 + 5) / 2]);
      expect(avg.map((p) => p.day), points.map((p) => p.day));
    });

    test('the window is seven days, the day itself counted', () {
      final points = [
        DayValue(d(2026, 11, 1), 1),
        DayValue(d(2026, 11, 7), 5), // 6 days later: still the same window
        DayValue(d(2026, 11, 8), 3), // 7 days after the first: it is out
      ];
      final avg = trailingAverage(points);
      expect(avg[1].value, 3);
      expect(avg[2].value, 4);
    });

    test('another window', () {
      final points = [
        DayValue(d(2026, 11, 1), 1),
        DayValue(d(2026, 11, 2), 3),
        DayValue(d(2026, 11, 3), 5),
      ];
      expect(trailingAverage(points, window: 2).map((p) => p.value), [1, 2, 4]);
    });

    test('nothing in, nothing out', () {
      expect(trailingAverage(const []), isEmpty);
    });

    test('mean of nothing is nothing, not zero', () {
      expect(mean(const <num>[]), isNull);
      expect(mean([1, 2, 6]), 3);
    });
  });

  group('the weeks of training', () {
    // Wednesday 2026-11-18: the week of Monday 2026-11-16
    final today = d(2026, 11, 18);

    test('the last weeks, oldest first, the empty ones too', () {
      final weeks = weeklyVolumes(const [], today: today, weeks: 4);
      expect(weeks.map((w) => w.monday), [
        d(2026, 10, 26),
        d(2026, 11, 2),
        d(2026, 11, 9),
        d(2026, 11, 16),
      ]);
      expect(weeks.every((w) => w.isEmpty), isTrue);
      expect(weeks.every((w) => w.minutes == 0 && w.sessions == 0), isTrue);
      expect(weeks.every((w) => w.bodyLoad == null), isTrue);
    });

    test('twelve weeks by default', () {
      expect(weeklyVolumes(const [], today: today), hasLength(12));
    });

    test('a workout counts in its own week, Monday and Sunday alike', () {
      final weeks = weeklyVolumes(
        [
          log('a', d(2026, 11, 16)), // Monday
          log('b', d(2026, 11, 22)), // Sunday
          log('c', d(2026, 11, 15)), // the Sunday before
          log('d', d(2026, 11, 9)),
        ],
        today: today,
        weeks: 3,
      );
      expect(weeks.map((w) => w.sessions), [0, 2, 2]);
    });

    test('the minutes add up, by sport, too', () {
      final w = weeklyVolumes(
        [
          log('a', d(2026, 11, 16), minutes: 60, sport: 'gym'),
          log('b', d(2026, 11, 17), minutes: 45, sport: 'gym'),
          log('c', d(2026, 11, 18), minutes: 30, sport: 'futas'),
          log('x', d(2026, 11, 18), minutes: 30, sport: ''),
        ],
        today: today,
        weeks: 1,
      ).single;
      expect(w.minutes, 165);
      expect(w.sessions, 4);
      expect(w.minutesBySport, {'gym': 105, 'futas': 30, 'edzes': 30});
    });

    test('a workout that did not happen is a skipped one, with no minutes', () {
      final w = weeklyVolumes(
        [
          log('a', d(2026, 11, 16), minutes: 60),
          log('b', d(2026, 11, 17), minutes: 90, done: false),
        ],
        today: today,
        weeks: 1,
      ).single;
      expect(w.sessions, 1);
      expect(w.skipped, 1);
      expect(w.minutes, 60);
      expect(w.isEmpty, isFalse);
    });

    test('only skipped is not empty, and has no ratings', () {
      final w = weeklyVolumes(
        [log('b', d(2026, 11, 17), done: false)],
        today: today,
        weeks: 1,
      ).single;
      expect(w.isEmpty, isFalse);
      expect(w.sessions, 0);
      expect(w.bodyLoad, isNull);
    });

    test('a deleted feedback and an older week are not there', () {
      final weeks = weeklyVolumes(
        [
          log('a', d(2026, 11, 17), deleted: true),
          log('b', d(2026, 10, 1)),
          log('c', d(2026, 11, 30)), // next week: not yet
        ],
        today: today,
        weeks: 2,
      );
      expect(weeks.every((w) => w.isEmpty), isTrue);
    });

    test('the ratings are averaged over the sessions that gave them', () {
      final w = weeklyVolumes(
        [
          log(
            'a',
            d(2026, 11, 16),
            body: 4,
            mind: 2,
            energyStart: 4,
            energyEnd: 2,
            experience: 5,
          ),
          log(
            'b',
            d(2026, 11, 17),
            body: 2,
            energyStart: 5,
            energyEnd: 4,
            experience: 3,
          ),
          log('c', d(2026, 11, 18)), // nothing rated
        ],
        today: today,
        weeks: 1,
      ).single;
      expect(w.bodyLoad, 3);
      expect(w.mindLoad, 2);
      expect(w.energyStart, 4.5);
      expect(w.energyEnd, 3);
      expect(w.energyDrop, 1.5);
      expect(w.experience, 4);
    });

    test('no drop without both ends of the energy', () {
      final w = weeklyVolumes(
        [log('a', d(2026, 11, 16), energyStart: 4)],
        today: today,
        weeks: 1,
      ).single;
      expect(w.energyStart, 4);
      expect(w.energyDrop, isNull);
    });

    test('a feedback without a length is a session of no minutes', () {
      final none = withoutLength('n', d(2026, 11, 17));
      expect(none.minutes, isNull);
      final w = weeklyVolumes(
        [none, log('a', d(2026, 11, 16), minutes: 45)],
        today: today,
        weeks: 1,
      ).single;
      expect(w.sessions, 2);
      expect(w.minutes, 45);
      expect(w.minutesBySport, {'gym': 45});
    });

    test('what a skipped workout was once rated is not counted', () {
      final w = weeklyVolumes(
        [
          log(
            'a',
            d(2026, 11, 16),
            body: 4,
            mind: 3,
            energyStart: 4,
            energyEnd: 2,
            experience: 5,
          ),
          skippedButRated('b', d(2026, 11, 17)),
        ],
        today: today,
        weeks: 1,
      ).single;
      expect(w.sessions, 1);
      expect(w.skipped, 1);
      expect(w.bodyLoad, 4);
      expect(w.mindLoad, 3);
      expect(w.energyStart, 4);
      expect(w.energyEnd, 2);
      expect(w.experience, 5);
    });
  });

  group('the words', () {
    test('one decimal, a comma', () {
      expect(oneDecimal(3.25), '3,3');
      expect(oneDecimal(4), '4,0');
      expect(oneDecimal(2.04), '2,0');
    });

    test('minutes in words', () {
      expect(minutesText(45), '45 perc');
      expect(minutesText(60), '1 óra');
      expect(minutesText(165), '2 óra 45 perc');
      expect(minutesText(0), '0 perc');
    });

    test('a change of 0,3 is a change, less is not', () {
      expect(trendWord(3.5, 3.0), 'javult');
      expect(trendWord(3.3, 3.0), 'javult');
      expect(trendWord(3.2, 3.0), 'nagyjából ugyanannyi');
      expect(trendWord(3.0, 3.2), 'nagyjából ugyanannyi');
      expect(trendWord(3.0, 3.3), 'romlott');
      expect(trendWord(2.0, 3.0), 'romlott');
    });

    test('the numbers are judged as they are shown, with one decimal', () {
      // 3,25 is shown as 3,3: three tenths above 3,0 (and 3,0 three below it)
      expect(trendWord(3.25, 3.0), 'javult');
      expect(trendWord(3.0, 3.25), 'romlott');
      expect(trendWord(3.5, 3.25), 'nagyjából ugyanannyi');
    });
  });

  group('the summary of a week', () {
    WeekVolume week({
      int sessions = 0,
      int skipped = 0,
      int minutes = 0,
      double? body,
      double? mind,
      double? es,
      double? ee,
      double? xp,
    }) => WeekVolume(
      monday: d(2026, 11, 16),
      sessions: sessions,
      skipped: skipped,
      minutes: minutes,
      bodyLoad: body,
      mindLoad: mind,
      energyStart: es,
      energyEnd: ee,
      experience: xp,
    );

    test('an empty week says so', () {
      expect(weekSummary(week: week()), ['Ebben a héten még nem volt edzés.']);
    });

    test('an empty week with a skipped workout says that, too', () {
      expect(weekSummary(week: week(skipped: 2)), [
        'Ebben a héten még nem volt edzés.',
        'Kihagyott edzés: 2.',
      ]);
      expect(weekSummary(week: week(skipped: 1)), [
        'Ebben a héten még nem volt edzés.',
        'Kihagyott edzés: 1.',
      ]);
    });

    test('the sessions and the minutes, and the week before', () {
      expect(
        weekSummary(
          week: week(sessions: 3, minutes: 165),
          before: week(sessions: 4, minutes: 190),
        ),
        [
          '3 edzés, összesen 2 óra 45 perc '
              '(az előző héten 4 edzés, 3 óra 10 perc).',
        ],
      );
    });

    test('the week before is left out when it had nothing', () {
      expect(
        weekSummary(
          week: week(sessions: 1, minutes: 45),
          before: week(),
        ).single,
        '1 edzés, összesen 45 perc.',
      );
      expect(
        weekSummary(week: week(sessions: 1, minutes: 45)).single,
        '1 edzés, összesen 45 perc.',
      );
    });

    test('a week before with one workout is told', () {
      expect(
        weekSummary(
          week: week(sessions: 2, minutes: 90),
          before: week(sessions: 1, minutes: 45),
        ).single,
        '2 edzés, összesen 1 óra 30 perc (az előző héten 1 edzés, 45 perc).',
      );
    });

    test('the difficulty: both, or the one that was given', () {
      expect(
        weekSummary(week: week(sessions: 1, minutes: 60, body: 3.25, mind: 2)),
        contains(
          'Az edzések nehézsége átlagosan: fizikailag 3,3/5, szellemileg 2,0/5.',
        ),
      );
      expect(
        weekSummary(week: week(sessions: 1, minutes: 60, mind: 4)),
        contains('Az edzések nehézsége átlagosan: szellemileg 4,0/5.'),
      );
    });

    test('the energy: it dropped, it grew, it did not change', () {
      List<String> energy(double es, double ee) => weekSummary(
        week: week(sessions: 1, minutes: 60, es: es, ee: ee),
      );
      expect(
        energy(4, 2.8),
        contains(
          'Az energiád az edzések alatt átlagosan csökkent '
          '(4,0 → 2,8 az 5-ös skálán).',
        ),
      );
      expect(
        energy(2, 3.5),
        contains(
          'Az energiád az edzések alatt átlagosan nőtt '
          '(2,0 → 3,5 az 5-ös skálán).',
        ),
      );
      expect(
        energy(3, 3.05),
        contains('Az energiád az edzések alatt nem változott (3,0/5).'),
      );
      // a tenth and a half is a change, seven hundredths is not
      expect(
        energy(3, 2.85),
        contains(
          'Az energiád az edzések alatt átlagosan csökkent '
          '(3,0 → 2,9 az 5-ös skálán).',
        ),
      );
      expect(
        energy(3, 3.07),
        contains('Az energiád az edzések alatt nem változott (3,0/5).'),
      );
    });

    test('the energy needs both ends', () {
      final lines = weekSummary(week: week(sessions: 1, minutes: 60, es: 4));
      expect(lines.where((l) => l.contains('energiád')), isEmpty);
    });

    test('the experience', () {
      expect(
        weekSummary(week: week(sessions: 1, minutes: 60, xp: 4.5)),
        contains('Az élmény átlaga 4,5/5.'),
      );
    });

    test('a skipped workout is told next to the ones that happened', () {
      expect(
        weekSummary(week: week(sessions: 2, minutes: 90, skipped: 1)),
        contains('Kihagyott edzés: 1.'),
      );
    });

    test('the check-in averages come with their trend', () {
      final lines = weekSummary(
        week: week(),
        checkIns: {
          CheckInMetric.sleep: 3.6,
          CheckInMetric.mood: 4,
          CheckInMetric.physical: 2.5,
          CheckInMetric.mental: null,
        },
        checkInsBefore: {
          CheckInMetric.sleep: 3.1,
          CheckInMetric.physical: 3.5,
          CheckInMetric.mood: null,
        },
      );
      expect(lines.skip(1), [
        'Fizikai energia: átlag 2,5/5 (az előző héten 3,5/5: romlott).',
        'Hangulat: átlag 4,0/5.',
        'Alvás: átlag 3,6/5 (az előző héten 3,1/5: javult).',
      ]);
    });

    test('a metric nobody answered is not mentioned', () {
      final lines = weekSummary(week: week());
      expect(lines, hasLength(1));
    });
  });

  group('everything the page needs', () {
    // Wednesday 2026-11-18, in the week of Monday 2026-11-16
    final today = d(2026, 11, 18);

    test('nothing at all: no data, and the week says so', () {
      final p = buildProgress(logs: const [], checkIns: const [], today: today);
      expect(p.hasData, isFalse);
      expect(p.weeks, hasLength(12));
      expect(p.summary, ['Ebben a héten még nem volt edzés.']);
      expect(p.from, d(2026, 8, 31));
      expect(p.to, today);
    });

    test('a workout alone is data, so is a check-in alone', () {
      expect(
        buildProgress(
          logs: [log('a', d(2026, 11, 17))],
          checkIns: const [],
          today: today,
        ).hasData,
        isTrue,
      );
      expect(
        buildProgress(
          logs: const [],
          checkIns: [check(d(2026, 11, 17), mood: 4)],
          today: today,
        ).hasData,
        isTrue,
      );
    });

    test('a workout that did not happen is data, too', () {
      expect(
        buildProgress(
          logs: [log('a', d(2026, 11, 17), done: false)],
          checkIns: const [],
          today: today,
        ).hasData,
        isTrue,
      );
    });

    test('the check-ins are cut to the range', () {
      final p = buildProgress(
        logs: const [],
        checkIns: [
          check(d(2026, 11, 17), physical: 4),
          check(d(2026, 8, 31), physical: 2), // the first day of 12 weeks
          check(d(2026, 8, 30), physical: 1), // a day too early
          check(d(2026, 11, 19), physical: 5), // tomorrow: not yet
        ],
        today: today,
        weeks: 12,
      );
      expect(p.days[CheckInMetric.physical]!.map((v) => v.value), [2, 4]);
      // (months apart: each is its own week)
      expect(p.trend[CheckInMetric.physical]!.map((v) => v.value), [2, 4]);
    });

    test('this week against the week before, in the summary', () {
      final p = buildProgress(
        logs: [
          log('a', d(2026, 11, 16), minutes: 60, body: 4),
          log('b', d(2026, 11, 9), minutes: 90),
          log('c', d(2026, 11, 10), minutes: 30),
        ],
        checkIns: [
          check(d(2026, 11, 16), sleep: 4),
          check(d(2026, 11, 17), sleep: 3),
          check(d(2026, 11, 18), sleep: 4),
          check(d(2026, 11, 19), sleep: 1), // tomorrow
          check(d(2026, 11, 9), sleep: 2),
          check(d(2026, 11, 15), sleep: 3), // Sunday of the week before
          check(d(2026, 11, 8), sleep: 5), // the week before that: not counted
        ],
        today: today,
      );
      expect(p.summary, [
        '1 edzés, összesen 1 óra (az előző héten 2 edzés, 2 óra).',
        'Az edzések nehézsége átlagosan: fizikailag 4,0/5.',
        'Alvás: átlag 3,7/5 (az előző héten 2,5/5: javult).',
      ]);
    });

    test('with one week there is no week before', () {
      final p = buildProgress(
        logs: [log('a', d(2026, 11, 16))],
        checkIns: [
          check(d(2026, 11, 16), mood: 4),
          check(d(2026, 11, 9), mood: 1),
        ],
        today: today,
        weeks: 1,
      );
      expect(p.weeks, hasLength(1));
      expect(p.summary.last, 'Hangulat: átlag 4,0/5.');
      expect(p.from, d(2026, 11, 16));
    });

    test('the number of weeks is kept sensible', () {
      expect(
        buildProgress(
          logs: const [],
          checkIns: const [],
          today: today,
          weeks: 0,
        ).weeks,
        hasLength(1),
      );
      expect(
        buildProgress(
          logs: const [],
          checkIns: const [],
          today: today,
          weeks: 99,
        ).weeks,
        hasLength(52),
      );
    });

    test('the trend is the average of the last seven days', () {
      // nine days of answers: seven 1s, then two 5s
      final answers = [
        for (var day = 10; day <= 18; day++)
          check(d(2026, 11, day), physical: day >= 17 ? 5 : 1),
      ];
      final p = buildProgress(
        logs: const [],
        checkIns: answers,
        today: today,
        weeks: 4,
      );
      final physical = p.trend[CheckInMetric.physical]!;
      expect(physical, trailingAverage(p.days[CheckInMetric.physical]!));
      // 12.–18.: five 1s and two 5s
      expect(physical.last.value, closeTo(15 / 7, 1e-9));
    });

    test('a time of day on today does not matter', () {
      final p = buildProgress(
        logs: const [],
        checkIns: [check(d(2026, 11, 18), mood: 5)],
        today: floating(2026, 11, 18, 23, 59),
        weeks: 2,
      );
      expect(p.to, today);
      expect(p.days[CheckInMetric.mood], hasLength(1));
    });
  });
}
