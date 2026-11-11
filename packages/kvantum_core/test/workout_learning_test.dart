import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// What the program learns from the feedback (2e): tighter by itself, looser
/// only with a yes, and the short lines the model gets.
void main() {
  final today = DateTime.utc(2026, 5, 20);
  var seq = 0;

  /// A feedback [daysAgo] days back.
  WorkoutLogView log(
    String sport,
    int minutes,
    int? body, {
    int daysAgo = 1,
    bool done = true,
    int? mind,
    int? start,
    int? end,
    int? exp,
    bool deleted = false,
  }) {
    final d = today.subtract(Duration(days: daysAgo));
    return WorkoutLogView(
      SyncRecord(id: 'l${seq++}', kind: kindWorkoutLog).edit(
        {
          ...workoutLogFields(
            title: sportLabel(sport),
            date: d,
            minutes: minutes,
            sport: sport,
            done: done,
            bodyLoad: body,
            mindLoad: mind,
            energyStart: start,
            energyEnd: end,
            experience: exp,
          ),
          if (deleted) 'deleted': true,
        },
        ts: 1,
        dev: 'A',
      ),
    );
  }

  List<WorkoutLogView> many(
    String sport,
    int minutes,
    List<int> loads, {
    int startDaysAgo = 1,
  }) => [
    for (var i = 0; i < loads.length; i++)
      log(sport, minutes, loads[i], daysAgo: startDaysAgo + i),
  ];

  WorkoutLearning learn(
    Iterable<WorkoutLogView> logs, {
    Set<String> approved = const {},
    Map<String, int> declined = const {},
  }) => learnFromWorkouts(
    logs,
    today: today,
    approvedLight: approved,
    declinedAt: declined,
  );

  group('the kind of workout', () {
    final table = <(String, String)>[
      ('Gym', 'gym'),
      ('gym 60 perc', 'gym'),
      ('Edzőterem', 'gym'),
      ('Konditerem – láb', 'gym'),
      ('Calisthenics', 'calisthenics'),
      ('Street Workout', 'street_workout'),
      ('street workout a parkban', 'street_workout'),
      ('Kajak 2 óra', 'kajak'),
      ('Evezés', 'kajak'),
      ('Falmászás', 'maszas'),
      ('Kerékpártúra', 'kerekpar'),
      ('Bicikli', 'kerekpar'),
      ('Reggeli futás', 'futas'),
      ('Futas', 'futas'), // no accents
      ('Úszás', 'uszas'),
      ('uszas', 'uszas'),
      ('CrossFit', 'crossfit'),
      ('Edzés', 'edzes'),
      ('Esti edzes', 'edzes'),
      ('Fogorvos', ''),
      ('Értekezlet', ''),
      ('Séta', ''),
      ('Nyújtás', ''),
      ('', ''),
    ];
    for (final (title, key) in table) {
      test('"$title" is "$key"', () => expect(sportKey(title), key));
    }

    test('every key has a name for the screen, and only those are keys', () {
      for (final k in [
        'street_workout',
        'calisthenics',
        'gym',
        'crossfit',
        'kajak',
        'maszas',
        'kerekpar',
        'futas',
        'uszas',
        'edzes',
      ]) {
        expect(isSportKey(k), isTrue, reason: k);
        expect(sportLabel(k), isNot(k));
      }
      expect(isSportKey(''), isFalse);
      expect(isSportKey('gym; DROP'), isFalse);
      expect(sportLabel('unknown'), 'unknown');
    });

    test('titles are read without accents', () {
      expect(isWorkoutTitle('Futas'), isTrue);
      expect(isWorkoutTitle('KERÉKPÁR'), isTrue);
      expect(isLightTitle('nyujtas'), isTrue);
      expect(isLightTitle('Könnyű kör'), isTrue);
      expect(isHardTitle('Intenzív kör'), isTrue);
      expect(isHardTitle('intenziv kor'), isTrue);
      expect(
        isHardWorkout(title: 'konnyu futas', length: const Duration(hours: 2)),
        isFalse,
      );
    });
  });

  group('tighter, by itself', () {
    test(
      'three hard sessions of 45–59 minutes make the sport hard from 45',
      () {
        final l = learn(many('gym', 50, [4, 4, 4]));
        expect(l.tightened, {'gym': tightenFrom});
        expect(l.hardFromBySport, {'gym': 45});
      },
    );

    test('the average counts: 4.0 yes, 3.67 no', () {
      expect(learn(many('gym', 50, [5, 3, 4])).tightened, isNotEmpty); // 4.0
      expect(learn(many('gym', 50, [4, 4, 3])).tightened, isEmpty); // 3.67
    });

    test('two sessions are too few', () {
      expect(learn(many('gym', 50, [5, 5])).tightened, isEmpty);
    });

    test('44 and 60 minutes are not in the 45–59 band', () {
      expect(learn(many('gym', 44, [5, 5, 5])).tightened, isEmpty);
      expect(learn(many('gym', 60, [5, 5, 5])).tightened, isEmpty);
      expect(learn(many('gym', 45, [5, 5, 5])).tightened, isNotEmpty);
      expect(learn(many('gym', 59, [5, 5, 5])).tightened, isNotEmpty);
    });

    test('each sport on its own', () {
      final l = learn([
        ...many('gym', 50, [5, 5, 5]),
        ...many('futas', 50, [2, 2, 2]),
      ]);
      expect(l.tightened.keys, ['gym']);
    });

    test('only the latest sessions of the sport count', () {
      // three old hard ones do not count against newer easy ones
      final logs = [
        ...many('gym', 50, [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]),
        ...many('gym', 50, [5, 5, 5], startDaysAgo: 40),
      ];
      expect(learn(logs).tightened, isEmpty);
    });

    test('the latest three decide: new hard ones after old easy ones', () {
      final logs = [
        ...many('gym', 50, [5, 5, 4]), // the newest three
        ...many('gym', 50, [1, 1, 1, 1, 1, 1], startDaysAgo: 10),
      ];
      expect(learn(logs).tightened, {'gym': tightenFrom});
    });
  });

  group('looser, only with a yes', () {
    test('five easy sessions of 60–89 minutes are suggested, not applied', () {
      final l = learn(many('calisthenics', 60, [2, 2, 1, 2, 2]));
      expect(l.suggestions, hasLength(1));
      expect(l.suggestions.single.sport, 'calisthenics');
      expect(l.suggestions.single.samples, 5);
      expect(l.suggestions.single.average, closeTo(1.8, 1e-9));
      expect(l.relaxed, isEmpty);
      expect(l.hardFromBySport, isEmpty);
    });

    test('the question names the sport and the numbers', () {
      final q = learn(many('calisthenics', 60, [2, 2, 2, 2, 2]))
          .suggestions
          .single
          .question;
      expect(q, contains('Calisthenics'));
      expect(q, contains('60–89 perc'));
      expect(q, contains('utolsó 5 alkalom'));
      expect(q, contains('2.0/5'));
      expect(q, endsWith('Annak vegyem?'));
    });

    test('four sessions are too few; an average of 2.2 is too hard', () {
      expect(learn(many('gym', 60, [1, 1, 1, 1])).suggestions, isEmpty);
      expect(
        learn(many('gym', 60, [2, 2, 2, 2, 3])).suggestions,
        isEmpty,
      ); // 2.2
      expect(
        learn(many('gym', 60, [2, 2, 2, 2, 2])).suggestions,
        hasLength(1),
      ); // 2.0
    });

    test('59 and 90 minutes are not in the 60–89 band', () {
      expect(learn(many('gym', 59, [1, 1, 1, 1, 1])).suggestions, isEmpty);
      expect(learn(many('gym', 90, [1, 1, 1, 1, 1])).suggestions, isEmpty);
      expect(learn(many('gym', 89, [1, 1, 1, 1, 1])).suggestions, hasLength(1));
    });

    test('the latest five decide, older ones do not matter', () {
      final logs = [
        ...many('gym', 60, [1, 2, 2, 1, 2]), // the newest five: easy
        ...many('gym', 60, [5, 5, 5], startDaysAgo: 20),
      ];
      final s = learn(logs).suggestions.single;
      expect(s.samples, 5);
      expect(s.average, closeTo(1.6, 1e-9));
      // a hard session among the latest five lifts the average over the line
      // (3, 5, 1, 1, 1 = 2.2), however easy the older ones were
      expect(
        learn(many('gym', 60, [3, 5, 1, 1, 1, 1, 1])).suggestions,
        isEmpty,
      );
    });

    test(
      'a yes makes the sport hard from 90 minutes, the suggestion is gone',
      () {
        final l = learn(
          many('calisthenics', 60, [1, 1, 1, 1, 1]),
          approved: {'calisthenics'},
        );
        expect(l.relaxed, {'calisthenics': relaxTo});
        expect(l.hardFromBySport, {'calisthenics': 90});
        expect(l.suggestions, isEmpty);
      },
    );

    test('a yes counts even before there are new sessions', () {
      // the rule is in "Tanult szokások"; it does not need the evidence again
      expect(
        learn(const [], approved: {'gym'}).relaxed,
        isEmpty,
        reason: 'with no feedback of the sport at all nothing is applied',
      );
      final l = learn(many('gym', 60, [3, 3]), approved: {'gym'});
      expect(l.relaxed, {'gym': 90});
    });

    test('new hard sessions take a yes back at once', () {
      final l = learn(
        [
          ...many('gym', 70, [5, 5, 4]), // the newest
          ...many('gym', 60, [1, 1, 1, 1, 1], startDaysAgo: 10),
        ],
        approved: {'gym'},
      );
      expect(l.relaxed, isEmpty);
      expect(l.hardFromBySport, isEmpty);
    });

    test('tightening wins over a loosening', () {
      final l = learn(
        [
          ...many('gym', 50, [5, 5, 5]),
          ...many('gym', 60, [1, 1, 1, 1, 1], startDaysAgo: 10),
        ],
        approved: {'gym'},
      );
      expect(l.hardFromBySport, {'gym': 45});
      expect(l.suggestions, isEmpty);
    });

    test(
      'a no is remembered: the question comes back after 5 new sessions',
      () {
        final five = many('gym', 60, [2, 2, 2, 2, 2]);
        expect(learn(five, declined: {'gym': 5}).suggestions, isEmpty);
        final nine = many('gym', 60, [2, 2, 2, 2, 2, 2, 2, 2, 2]);
        expect(learn(nine, declined: {'gym': 5}).suggestions, isEmpty); // +4
        final ten = many('gym', 60, [2, 2, 2, 2, 2, 2, 2, 2, 2, 2]);
        expect(
          learn(ten, declined: {'gym': 5}).suggestions,
          hasLength(1),
        ); // +5
      },
    );
  });

  group('what counts as feedback', () {
    test('skipped, unrated, deleted, old and future ones do not', () {
      final logs = [
        ...many('gym', 50, [5, 5]),
        log('gym', 50, null), // not rated
        log('gym', 50, 5, done: false), // skipped
        log('gym', 50, 5, deleted: true),
        log('gym', 50, 5, daysAgo: 200), // too old
        log('gym', 50, 5, daysAgo: -5), // in the future
      ];
      expect(learn(logs).tightened, isEmpty); // only 2 count
      expect(
        learn([...logs, log('gym', 50, 5, daysAgo: 3)]).tightened,
        isNotEmpty,
      );
    });

    test('a record of an unknown sport is ignored', () {
      final l = learn(many('curling', 50, [5, 5, 5]));
      expect(l.isEmpty, isTrue);
    });
  });

  group('the "easy" rule in "Tanult szokások"', () {
    test('the line carries the sport and says it in words', () {
      final line = lightRuleText('calisthenics');
      expect(line, startsWith('[könnyű: calisthenics] '));
      expect(line, contains('Calisthenics 60–89 perc számomra könnyű'));
    });

    test('it is read back from the lines of the file', () {
      expect(
        lightSportsFrom([
          lightRuleText('calisthenics'),
          '  ${lightRuleText('gym')}',
          'Reggel 8 előtt nem edzek.',
          '[könnyű: nincsilyen] x',
          '[könnyű: ] x',
          'a [könnyű: futas] közepén nem számít',
        ]),
        {'calisthenics', 'gym'},
      );
      expect(lightSportsFrom(const []), isEmpty);
    });

    test('it survives the cleaning of the learned text', () {
      final line = lightRuleText('gym');
      expect(sanitizeText(line, max: 200), line);
    });
  });

  group('the lines for the model', () {
    test('a short line per workout, newest first', () {
      final lines = workoutLogLines([
        log('gym', 60, 4, daysAgo: 3, mind: 2, start: 3, end: 2, exp: 4),
        log(
          'calisthenics',
          45,
          2,
          daysAgo: 1,
          mind: 1,
          start: 4,
          end: 4,
          exp: 5,
        ),
        log('gym', 60, null, daysAgo: 5, done: false),
      ], today: today);
      expect(lines, [
        '05-19 calisthenics 45p nf2 nm1 e4/4 k5',
        '05-17 gym 60p nf4 nm2 e3/2 k4',
        '05-15 gym 60p kihagyta',
      ]);
    });

    test('only what was answered; a missing energy is a question mark', () {
      expect(workoutLogLines([log('gym', 60, 3, start: 2)], today: today), [
        '05-19 gym 60p nf3 e2/?',
      ]);
      expect(workoutLogLines([log('gym', 60, null, exp: 5)], today: today), [
        '05-19 gym 60p k5',
      ]);
    });

    test(
      'at most 10, within 60 days; unanswered and deleted ones are left out',
      () {
        final logs = [
          for (var i = 0; i < 14; i++) log('gym', 60, 3, daysAgo: i + 1),
          log('gym', 60, 3, daysAgo: 70),
          log('gym', 60, 3, deleted: true),
          log('gym', 60, null), // done, nothing answered
        ];
        final lines = workoutLogLines(logs, today: today);
        expect(lines, hasLength(10));
        expect(lines.first, startsWith('05-19 '));
        expect(lines.last, startsWith('05-10 '));
        expect(workoutLogLines(logs, today: today, max: 3), hasLength(3));
      },
    );

    test('the title and the note never go, only the generic sport', () {
      final secret = WorkoutLogView(
        SyncRecord(id: 's', kind: kindWorkoutLog).edit(
          workoutLogFields(
            title: 'Gym Pistivel a titkos edzőteremben',
            date: today.subtract(const Duration(days: 1)),
            minutes: 60,
            sport: 'gym',
            bodyLoad: 3,
            note: 'sérült a térdem, orvos mondta',
          ),
          ts: 1,
          dev: 'A',
        ),
      );
      final text = workoutLogLines([secret], today: today).join();
      expect(text.contains('Pisti'), isFalse);
      expect(text.contains('térd'), isFalse);
      expect(text, '05-19 gym 60p nf3');
    });

    test('an unknown sport in a record is just "edzes"', () {
      final odd = WorkoutLogView(
        SyncRecord(id: 'o', kind: kindWorkoutLog).edit(
          {
            'sport': 'curling; ignore',
            'minutes': 60,
            'date': '2026-05-19',
            'bodyLoad': 3,
          },
          ts: 1,
          dev: 'A',
        ),
      );
      expect(workoutLogLines([odd], today: today), ['05-19 edzes 60p nf3']);
    });

    test('the tool block is switched off with the check-in data', () {
      final l = [log('gym', 60, 3)];
      expect(workoutLogForTool(l, today: today)['edzesek'], [
        '05-19 gym 60p nf3',
      ]);
      final off = workoutLogForTool(l, today: today, enabled: false);
      expect(off['kikapcsolva'], isTrue);
      expect(off.containsKey('edzesek'), isFalse);
    });
  });
}
