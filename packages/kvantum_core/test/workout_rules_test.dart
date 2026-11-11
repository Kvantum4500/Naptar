import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

// 2026-05-04 is a Monday: the week of 4–10 May.
const bp = 'Europe/Budapest';
const rules = PlanRules();

DateTime at(int d, int h, [int m = 0]) =>
    resolveWallClock(bp, floating(2026, 5, d, h, m));

ProposedBlock block(
  int d,
  int h, {
  int minutes = 60,
  bool hard = false,
  bool workout = true,
  String title = 'Gym',
}) => ProposedBlock(
  title: title,
  startUtc: at(d, h),
  endUtc: at(d, h).add(Duration(minutes: minutes)),
  isWorkout: workout,
  isHard: hard,
);

Occurrence booked(
  String title,
  int d,
  int h, {
  int minutes = 60,
  bool shift = false,
  bool allDay = false,
  bool ai = false,
}) => Occurrence(
  eventId: '$title$d$h',
  title: title,
  startUtc: at(d, h),
  endUtc: at(d, h).add(Duration(minutes: minutes)),
  originalStart: floating(2026, 5, d, h),
  allDay: allDay,
  tzid: bp,
  isShift: shift,
  aiGenerated: ai,
);

List<String> codes(List<Violation> v) => [for (final x in v) x.code];

ProposalItem item(
  String title, {
  int minutes = 60,
  String kind = 'workout',
  bool hard = false,
}) => ProposalItem(
  title: title,
  startWall: floating(2026, 5, 5, 18),
  endWall: floating(2026, 5, 5, 18).add(Duration(minutes: minutes)),
  tzid: bp,
  kind: kind,
  hard: hard,
  reason: '',
);

void main() {
  group('hard or not: decided in code', () {
    bool hardOf(String title, int minutes, {bool model = false}) =>
        isHardWorkout(
          title: title,
          length: Duration(minutes: minutes),
          modelSaysHard: model,
        );

    test('60 minutes is the line', () {
      expect(hardOf('Gym', 59), isFalse);
      expect(hardOf('Gym', 60), isTrue);
      expect(hardOf('Calisthenics', 90), isTrue);
      expect(hardOf('Calisthenics', 45), isFalse);
    });

    test('a light title is light, whatever the length or the model says', () {
      for (final t in [
        'Könnyű edzés',
        'könnyed futás',
        'Nyújtás',
        'Mobilitás',
        'Relax jóga',
        'Regeneráló úszás',
        'Séta',
      ]) {
        expect(hardOf(t, 120), isFalse, reason: t);
        expect(hardOf(t, 120, model: true), isFalse, reason: t);
      }
    });

    test('the model can make a short session hard, a keyword too', () {
      expect(hardOf('Gym', 30, model: true), isTrue);
      expect(hardOf('Intenzív intervall futás', 30), isTrue);
      expect(hardOf('HIIT', 20), isTrue);
      expect(hardOf('Futás', 30), isFalse);
    });

    test('what the name alone says is a workout', () {
      for (final t in [
        'Gym',
        'Calisthenics 45 perc',
        'Street Workout',
        'Kajak a Dunán',
        'Falmászás',
        'Kerékpártúra',
        'Edzés',
        'Reggeli futás',
        'Úszás',
      ]) {
        expect(isWorkoutTitle(t), isTrue, reason: t);
      }
      for (final t in [
        'Fogorvos',
        'Értekezlet',
        'Séta',
        'Nyújtás',
        'Vásárlás',
      ]) {
        expect(isWorkoutTitle(t), isFalse, reason: t);
      }
    });
  });

  group('the proposal item, as the rules see it', () {
    test(
      'a plain workout name under "other" still counts (and is hard at 60)',
      () {
        final i = item('Gym', kind: 'other');
        expect(i.isWorkout, isTrue);
        expect(i.isHardSession(), isTrue);
        expect(i.toBlock().isWorkout, isTrue);
        expect(i.toBlock().isHard, isTrue);
      },
    );

    test('a walk, a rest and a task are no workouts', () {
      expect(item('Séta', minutes: 90, kind: 'other').isWorkout, isFalse);
      expect(item('Pihenő – nincs edzés', kind: 'rest').isWorkout, isFalse);
      expect(item('Edzésterv írása', kind: 'task').isWorkout, isFalse);
    });

    test('stretching is a workout of the week but never a hard one', () {
      final i = item('Nyújtás', minutes: 90, hard: true);
      expect(i.isWorkout, isTrue);
      expect(i.isHardSession(), isFalse);
    });

    test(
      'the model saying "light" does not make a 60-minute session light',
      () {
        expect(item('Gym', minutes: 60, hard: false).isHardSession(), isTrue);
        expect(item('Gym', minutes: 45, hard: false).isHardSession(), isFalse);
      },
    );
  });

  group('distance from a shift', () {
    final night = booked(
      'Éjszakai műszak',
      4,
      18,
      minutes: 12 * 60,
      shift: true,
    );
    // the shift ends 5 May 06:00; 8 hours later is 14:00

    test('a workout of 45 minutes or more keeps it, hard or not', () {
      expect(
        codes(
          validateProposal([block(5, 13)], existing: [night], rules: rules),
        ),
        ['shift_rest'],
      );
      expect(
        codes(
          validateProposal(
            [block(5, 13, hard: true)],
            existing: [night],
            rules: rules,
          ),
        ),
        ['shift_rest'],
      );
    });

    test('44 minutes of light movement does not need it, 45 does', () {
      expect(
        validateProposal(
          [block(5, 13, minutes: 44)],
          existing: [night],
          rules: rules,
        ),
        isEmpty,
      );
      expect(
        codes(
          validateProposal(
            [block(5, 13, minutes: 45)],
            existing: [night],
            rules: rules,
          ),
        ),
        ['shift_rest'],
      );
    });

    test('8 hours after the shift is fine; a non-workout is never checked', () {
      expect(
        validateProposal([block(5, 14)], existing: [night], rules: rules),
        isEmpty,
      );
      expect(
        validateProposal(
          [block(5, 7, workout: false, title: 'Számla')],
          existing: [night],
          rules: rules,
        ),
        isEmpty,
      );
    });
  });

  group('a day without a check-in is taken as 3/5', () {
    test('a hard session is allowed, unless the minimum is raised', () {
      expect(
        validateProposal(
          [block(5, 18, hard: true)],
          existing: [],
          rules: rules,
        ),
        isEmpty,
      );
      const strict = PlanRules(minEnergyForHard: 4);
      expect(
        codes(
          validateProposal(
            [block(5, 18, hard: true)],
            existing: [],
            rules: strict,
          ),
        ),
        ['no_data_hard'],
      );
    });

    test('a real check-in beats the assumption', () {
      final low = validateProposal(
        [block(5, 18, hard: true)],
        existing: [],
        rules: rules,
        energyByDate: {floating(2026, 5, 5): 2},
      );
      expect(codes(low), ['low_energy']);
      expect(
        validateProposal(
          [block(5, 18, hard: true)],
          existing: [],
          rules: rules,
          energyByDate: {floating(2026, 5, 5): 4},
        ),
        isEmpty,
      );
    });
  });

  group('the sleep window is judged as an interval', () {
    bool sleeps(int d, int h, int minutes, {int m = 0}) => codes(
      validateProposal(
        [
          ProposedBlock(
            title: 'x',
            startUtc: at(d, h, m),
            endUtc: at(d, h, m).add(Duration(minutes: minutes)),
            isWorkout: false,
          ),
        ],
        existing: [],
        rules: rules,
      ),
    ).contains('sleep_window');

    test(
      'a block over the whole night is caught (it starts and ends awake)',
      () {
        expect(sleeps(5, 22, 10 * 60), isTrue); // 22:00 -> 08:00
        expect(sleeps(5, 23, 8 * 60), isTrue); // exactly the window
        expect(sleeps(5, 21, 12 * 60), isTrue);
      },
    );

    test(
      'touching the window by a minute counts, touching its edge does not',
      () {
        expect(sleeps(5, 22, 61), isTrue); // 22:00 -> 23:01
        expect(sleeps(5, 22, 60), isFalse); // 22:00 -> 23:00
        expect(sleeps(5, 6, 61, m: 0), isTrue); // 06:00 -> 07:01
        expect(sleeps(5, 7, 60), isFalse); // 07:00 -> 08:00
        expect(sleeps(5, 12, 120), isFalse);
      },
    );

    test('a day sleeper (08:00–16:00) has the window inside the day', () {
      const day = PlanRules(sleepStartHour: 8, sleepEndHour: 16);
      bool daySleeps(int h, int minutes) => codes(
        validateProposal(
          [
            ProposedBlock(
              title: 'x',
              startUtc: at(5, h),
              endUtc: at(5, h).add(Duration(minutes: minutes)),
              isWorkout: false,
            ),
          ],
          existing: [],
          rules: day,
        ),
      ).contains('sleep_window');
      expect(daySleeps(6, 4 * 60), isTrue); // 06:00 -> 10:00
      expect(daySleeps(6, 2 * 60), isFalse); // 06:00 -> 08:00
      expect(daySleeps(14, 3 * 60), isTrue); // 14:00 -> 17:00
      expect(daySleeps(16, 60), isFalse);
    });
  });

  group('the weekly cap counts what is booked already', () {
    List<Occurrence> gyms(int n) => [
      for (var i = 0; i < n; i++) booked('Gym', 4 + i, 18, minutes: 50),
    ];

    test('3 booked + 3 proposed in the same week is one too many', () {
      final v = validateProposal(
        [
          block(8, 18, minutes: 50),
          block(9, 18, minutes: 50),
          block(10, 18, minutes: 50),
        ],
        existing: gyms(3),
        rules: rules,
      );
      final cap = v.where((x) => x.code == 'weekly_cap').toList();
      expect(cap, hasLength(1));
      expect(cap.single.message, contains('6 edzés'));
      expect(cap.single.message, contains('ebből 3 már a naptárban van'));
    });

    test('3 booked + 2 proposed is five: fine', () {
      expect(
        codes(
          validateProposal(
            [block(8, 18, minutes: 50), block(9, 18, minutes: 50)],
            existing: gyms(3),
            rules: rules,
          ),
        ),
        isNot(contains('weekly_cap')),
      );
    });

    test('another week, a shift, an all-day event, a stretch do not count', () {
      final other = [
        booked('Gym', 11, 18, minutes: 50), // next Monday
        booked('Műszak (Gym)', 5, 18, shift: true),
        booked('Gym nap', 6, 0, allDay: true),
        booked('Nyújtás', 7, 18, minutes: 20),
        booked('Fogorvos', 7, 9),
      ];
      expect(
        codes(
          validateProposal(
            [for (var d = 4; d <= 8; d++) block(d, 18, minutes: 50)],
            existing: other,
            rules: rules,
          ),
        ),
        isNot(contains('weekly_cap')),
      );
    });

    test('a week the proposal does not touch is not judged', () {
      // 6 workouts booked in the week of 11 May, the proposal is in the week of 4 May
      final crowded = [
        for (var d = 11; d <= 16; d++) booked('Gym', d, 18, minutes: 50),
      ];
      expect(
        validateProposal(
          [block(5, 18, minutes: 50)],
          existing: crowded,
          rules: rules,
        ),
        isEmpty,
      );
    });
  });

  group('48 hours between hard sessions, the booked ones included', () {
    final gym = booked('Gym', 5, 18, minutes: 90); // 5 May 18:00–19:30, hard

    test('a hard session less than 48 hours after a booked one', () {
      final v = validateProposal(
        [block(6, 18, hard: true)],
        existing: [gym],
        rules: rules,
      );
      expect(codes(v), ['rest']);
      expect(v.single.message, contains('„Gym”'));
    });

    test('and less than 48 hours before one', () {
      expect(
        codes(
          validateProposal(
            [block(4, 12, hard: true)],
            existing: [gym],
            rules: rules,
          ),
        ),
        ['rest'],
      );
    });

    test('48 hours and more is fine', () {
      // the booked one ends 5 May 19:30; 48 h later is 7 May 19:30
      expect(
        validateProposal(
          [block(7, 20, hard: true)],
          existing: [gym],
          rules: rules,
        ),
        isEmpty,
      );
      expect(
        codes(
          validateProposal(
            [block(7, 19, hard: true)],
            existing: [gym],
            rules: rules,
          ),
        ),
        ['rest'],
      );
    });

    test('a light proposal, or a light booked session, does not matter', () {
      expect(
        validateProposal(
          [block(6, 18, minutes: 30)],
          existing: [gym],
          rules: rules,
        ),
        isEmpty,
      );
      expect(
        validateProposal(
          [block(6, 18, hard: true)],
          existing: [booked('Nyújtás', 5, 18, minutes: 90)],
          rules: rules,
        ),
        isEmpty,
      );
    });

    test(
      'two booked hard sessions near each other are not the proposal\'s fault',
      () {
        expect(
          validateProposal(
            [block(9, 18, hard: true)],
            existing: [gym, booked('Gym', 6, 18, minutes: 90)],
            rules: rules,
          ),
          isEmpty,
        );
      },
    );
  });
}
