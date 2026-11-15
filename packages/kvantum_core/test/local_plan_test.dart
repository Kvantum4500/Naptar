import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

// H: the workout planner that needs no model. 2026-05-04 is a Monday; the
// window starts on the Tuesday, so it runs Tue 05-05 .. Mon 05-11 (two ISO
// weeks: the cap is counted per week).
const bp = 'Europe/Budapest';
const rules = PlanRules();

DateTime at(int d, int h, [int m = 0, int month = 5]) =>
    resolveWallClock(bp, floating(2026, month, d, h, m));

final tuesday = floating(2026, 5, 5);

Occurrence event(
  String title,
  DateTime start,
  DateTime end, {
  bool shift = false,
  bool allDay = false,
}) => Occurrence(
  eventId: '$title${start.millisecondsSinceEpoch}',
  title: title,
  startUtc: start,
  endUtc: end,
  originalStart: toWallClock(bp, start),
  allDay: allDay,
  tzid: bp,
  isShift: shift,
);

Occurrence night(int d) =>
    event('Éjszakai műszak', at(d, 18), at(d + 1, 6), shift: true);

Occurrence day(int d) =>
    event('Nappali műszak', at(d, 6), at(d, 18), shift: true);

Occurrence booked(String title, int d, int h, {int minutes = 60}) =>
    event(title, at(d, h), at(d, h).add(Duration(minutes: minutes)));

var _seq = 0;

/// The feedback on a workout of [sport] on May [d] (or [month]).
WorkoutLogView logOf(String sport, int d, {int month = 5, bool done = true}) =>
    WorkoutLogView(
      SyncRecord(id: 'l${_seq++}', kind: kindWorkoutLog).edit(
        workoutLogFields(
          title: sportLabel(sport),
          date: floating(2026, month, d),
          minutes: 45,
          sport: sport,
          done: done,
        ),
        ts: 1,
        dev: 'A',
      ),
    );

LocalPlan plan({
  DateTime? from,
  int days = 7,
  LocalPlanPrefs prefs = const LocalPlanPrefs(),
  PlanRules r = rules,
  List<Occurrence> existing = const [],
  List<WorkoutLogView> log = const [],
  Map<DateTime, int> energy = const {},
  Map<DateTime, DayWeather> weather = const {},
  DateTime? now,
}) => planWorkoutsLocally(
  from: from ?? tuesday,
  days: days,
  prefs: prefs,
  rules: r,
  existing: existing,
  log: log,
  energyByDate: energy,
  weatherByDate: weather,
  nowUtc: now,
);

String hm(DateTime w) =>
    '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// "05-05 10:00 Calisthenics 45 perc" per item, in time order.
List<String> shown(LocalPlan p) => [
  for (final i in p.items)
    '${i.startWall.month.toString().padLeft(2, '0')}-${i.startWall.day.toString().padLeft(2, '0')} ${hm(i.startWall)} ${i.title}',
];

/// What the rules say about the whole plan (it must be nothing).
List<Violation> judged(LocalPlan p, List<Occurrence> existing) =>
    validateProposal(
      [for (final i in p.items) i.toBlock(rules: rules)],
      existing: existing,
      rules: rules,
    );

DayWeather fine(DateTime d) =>
    DayWeather(day: d, code: 1, tMin: 10, tMax: 22, precipProb: 5);

DayWeather rainy(DateTime d) =>
    DayWeather(day: d, code: 63, tMin: 8, tMax: 14, precipProb: 90);

void main() {
  setUpAll(ensureTimeZones);

  group('the sports and the wishes of the user', () {
    test(
      'the first start: Calisthenics 45, Gym 60, three a week, any time',
      () {
        const p = LocalPlanPrefs();
        expect(p.sports, [
          const PlanSport(name: 'Calisthenics', minutes: 45),
          const PlanSport(name: 'Gym', minutes: 60),
        ]);
        expect(p.perWeek, 3);
        expect(p.band, PlanBand.any);
      },
    );

    test('the title says the sport and the time, and is a workout', () {
      expect(
        const PlanSport(name: 'Calisthenics', minutes: 45).title,
        'Calisthenics 45 perc',
      );
      expect(const PlanSport(name: 'Gym', minutes: 60).title, 'Gym 60 perc');
      // a name that does not say "workout" gets the word, or the calendar
      // would not count it later
      final own = const PlanSport(name: 'Pilates', minutes: 30);
      expect(own.title, 'Pilates edzés 30 perc');
      expect(isWorkoutTitle(own.title), isTrue);
      expect(
        const PlanSport(name: 'Kajak', minutes: 90, outdoor: true).title,
        'Kajak 90 perc',
      );
    });

    test('the key tells sports apart: the known ones, else the name', () {
      expect(const PlanSport(name: 'Gym', minutes: 60).key, 'gym');
      expect(
        const PlanSport(name: 'Calisthenics', minutes: 45).key,
        'calisthenics',
      );
      expect(const PlanSport(name: 'Kajak', minutes: 90).key, 'kajak');
      expect(const PlanSport(name: 'Pilates', minutes: 30).key, 'pilates');
      expect(const PlanSport(name: 'Árnyékbox', minutes: 30).key, 'arnyekbox');
    });

    test('what is typed in is read strictly', () {
      PlanSport? p(Object? j) => PlanSport.tryParse(j);
      expect(p({'name': ' Gym ', 'minutes': 60}), isNotNull);
      expect(p({'name': 'Gym', 'minutes': 60})!.name, 'Gym');
      expect(p({'name': 'Gym', 'minutes': 14}), isNull, reason: 'too short');
      expect(p({'name': 'Gym', 'minutes': 15}), isNotNull);
      expect(p({'name': 'Gym', 'minutes': 180}), isNotNull);
      expect(p({'name': 'Gym', 'minutes': 181}), isNull, reason: 'too long');
      expect(p({'name': 'Gym', 'minutes': 60.0}), isNull, reason: 'not whole');
      expect(p({'name': 'Gym', 'minutes': '60'}), isNull);
      expect(p({'name': '', 'minutes': 60}), isNull);
      expect(p({'name': '   ', 'minutes': 60}), isNull);
      expect(p({'name': 'x' * 40, 'minutes': 60}), isNotNull);
      expect(p({'name': 'x' * 41, 'minutes': 60}), isNull);
      expect(p('Gym'), isNull);
      expect(p(null), isNull);
      // line breaks and control characters become spaces
      expect(
        p({'name': 'Street\nWorkout', 'minutes': 45})!.name,
        'Street Workout',
      );
      expect(p({'name': 'Gym', 'minutes': 60})!.outdoor, isFalse);
      expect(
        p({'name': 'Kajak', 'minutes': 90, 'outdoor': true})!.outdoor,
        isTrue,
      );
      expect(
        p({'name': 'Kajak', 'minutes': 90, 'outdoor': 'igen'})!.outdoor,
        isFalse,
      );
    });

    test('saved and read back', () {
      const own = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Gym', minutes: 75),
          PlanSport(name: 'Kajak', minutes: 90, outdoor: true),
        ],
        perWeek: 4,
        band: PlanBand.evening,
      );
      final back = LocalPlanPrefs.decode(own.encode());
      expect(back.sports, own.sports);
      expect(back.perWeek, 4);
      expect(back.band, PlanBand.evening);
    });

    test('nothing saved, or damaged: the defaults', () {
      for (final t in [null, '', '   ', 'nem json', '[1,2]', '"x"', '12']) {
        final p = LocalPlanPrefs.decode(t);
        expect(p.sports, defaultPlanSports, reason: '$t');
        expect(p.perWeek, 3, reason: '$t');
        expect(p.band, PlanBand.any, reason: '$t');
      }
    });

    test('a list the user emptied stays empty; bad entries are dropped', () {
      expect(LocalPlanPrefs.decode('{"sports":[]}').sports, isEmpty);
      final p = LocalPlanPrefs.decode(
        '{"sports":[{"name":"Gym","minutes":60},{"name":"","minutes":60},'
        '{"name":"X","minutes":5},"Gym",null,{"name":"Úszás","minutes":30}]}',
      );
      expect([for (final s in p.sports) s.name], ['Gym', 'Úszás']);
      // no list at all: the first-start sports
      expect(LocalPlanPrefs.decode('{"perWeek":2}').sports, defaultPlanSports);
      // at most twelve
      final many = [
        for (var i = 0; i < 20; i++) '{"name":"Sport $i","minutes":30}',
      ];
      expect(
        LocalPlanPrefs.decode('{"sports":[${many.join(',')}]}').sports,
        hasLength(12),
      );
    });

    test('the weekly wish is kept between 1 and 7; an unknown band is any', () {
      int n(Object? v) =>
          LocalPlanPrefs.decode('{"sports":[],"perWeek":$v}').perWeek;
      expect(n(0), 1);
      expect(n(-3), 1);
      expect(n(1), 1);
      expect(n(7), 7);
      expect(n(9), 7);
      expect(n('"x"'), 3);
      expect(n(2.5), 3);
      expect(
        LocalPlanPrefs.decode('{"sports":[],"band":"night"}').band,
        PlanBand.any,
      );
      expect(
        LocalPlanPrefs.decode('{"sports":[],"band":7}').band,
        PlanBand.any,
      );
      for (final b in PlanBand.values) {
        expect(PlanBand.byId(b.id), b);
        expect(b.label, isNotEmpty);
        expect(b.fromHour, lessThan(b.toHour));
      }
      expect(PlanBand.byId(null), PlanBand.any);
    });
  });

  group('an empty calendar', () {
    final p = plan();

    test('three sessions in a week: spread out, the sports in turn', () {
      expect(shown(p), [
        '05-05 10:00 Calisthenics 45 perc',
        '05-08 10:00 Gym 60 perc',
        '05-11 10:00 Calisthenics 45 perc',
      ]);
      expect(p.dropped, isEmpty);
      expect(p.wanted, 3);
      expect(p.alreadyBooked, 0);
    });

    test('every session passes every rule, as a whole too', () {
      expect(judged(p, const []), isEmpty);
    });

    test('each is a workout of the planner, in the user\'s zone', () {
      for (final i in p.items) {
        expect(i.kind, 'workout');
        expect(i.tzid, bp);
        expect(i.reason, startsWith('Helyi terv:'));
        expect(i.taskId, isNull);
        expect(i.outdoor, isFalse);
      }
    });

    test('the hard verdict is the code\'s: 60 minutes is hard, 45 is not', () {
      expect([for (final i in p.items) i.hard], [false, true, false]);
    });

    test('the head tells how many and for how long', () {
      expect(
        p.summary,
        'Helyi terv, modell nélkül: 3 edzés a következő 7 napra.',
      );
    });

    test('never two in one day', () {
      final days = [
        for (final i in p.items) '${i.startWall.month}-${i.startWall.day}',
      ];
      expect(days.toSet(), hasLength(days.length));
    });

    test('the same input gives the same plan', () {
      expect(shown(plan()), shown(p));
      expect(plan().summary, p.summary);
    });
  });

  group('the weekly wish', () {
    test('one a week: one session, on the first day', () {
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 1));
      expect(shown(p), ['05-05 10:00 Calisthenics 45 perc']);
    });

    test('the workouts already in the calendar count toward it', () {
      final ex = [booked('Gym 60 perc', 7, 18)];
      final p = plan(existing: ex);
      expect(p.alreadyBooked, 1);
      expect(p.items, hasLength(2));
      // the booked day is taken
      expect([for (final i in p.items) i.startWall.day], isNot(contains(7)));
    });

    test('the wish is met already: nothing to add, and it says so', () {
      final ex = [
        booked('Gym 60 perc', 5, 18),
        booked('Calisthenics 45 perc', 7, 18),
        booked('Kajak 90 perc', 9, 10, minutes: 90),
      ];
      final p = plan(existing: ex);
      expect(p.items, isEmpty);
      expect(p.alreadyBooked, 3);
      expect(p.summary, contains('már ott van a heti cél'));
      expect(p.summary, contains('3 edzés'));
      expect(p.dropped, isEmpty);
    });

    test('more booked than wished: also nothing to add', () {
      final ex = [for (var d = 5; d <= 8; d++) booked('Gym 60 perc', d, 18)];
      final p = plan(existing: ex);
      expect(p.items, isEmpty);
      expect(p.alreadyBooked, 4);
    });

    test('only workouts count: a walk, a shift, an all-day event do not', () {
      final ex = [
        booked('Séta', 5, 18),
        night(6),
        event('Edzőtábor', at(7, 0), at(8, 0), allDay: true),
        booked('Fogorvos', 8, 18),
      ];
      final p = plan(existing: ex);
      expect(p.alreadyBooked, 0);
      expect(p.items, hasLength(3));
    });

    test('five a week is possible when the rules let it', () {
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 5));
      expect(p.items, hasLength(5));
      expect(judged(p, const []), isEmpty);
      // the hard ones keep their 48 hours: the later Gym starts later
      final gyms = [
        for (final i in p.items)
          if (i.hard) i,
      ];
      for (var i = 1; i < gyms.length; i++) {
        expect(
          gyms[i].startUtc.difference(gyms[i - 1].endUtc),
          greaterThanOrEqualTo(const Duration(hours: 48)),
        );
      }
    });

    test('seven a week: the weekly cap of the rules stops it', () {
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 7));
      expect(p.items.length, lessThan(7));
      expect(judged(p, const []), isEmpty);
      expect(p.dropped.join(' '), contains('a heti legfeljebb 5 edzés'));
    });
  });

  group('the sports in turn', () {
    test('the sport done longest ago comes first', () {
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('calisthenics', 3), logOf('gym', 1)],
      );
      // gym was done on the 1st, calisthenics on the 3rd: gym is older
      expect(shown(p), ['05-05 10:00 Gym 60 perc']);
      final q = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('calisthenics', 1), logOf('gym', 3)],
      );
      expect(shown(q), ['05-05 10:00 Calisthenics 45 perc']);
    });

    test('a sport never done goes before one done long ago', () {
      const three = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Gym', minutes: 60),
          PlanSport(name: 'Calisthenics', minutes: 45),
          PlanSport(name: 'Kerékpár', minutes: 60),
        ],
        perWeek: 1,
      );
      final p = plan(
        prefs: three,
        log: [logOf('gym', 1, month: 1), logOf('calisthenics', 2, month: 1)],
      );
      expect(p.items.single.title, 'Kerékpár 60 perc');
    });

    test('a tie keeps the order of the list', () {
      const rev = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Gym', minutes: 60),
          PlanSport(name: 'Calisthenics', minutes: 45),
        ],
        perWeek: 1,
      );
      expect(plan(prefs: rev).items.single.title, 'Gym 60 perc');
      expect(
        plan(
          prefs: rev,
          log: [logOf('gym', 2), logOf('calisthenics', 2)],
        ).items.single.title,
        'Gym 60 perc',
      );
    });

    test('a day the user did not train, or deleted, does not count', () {
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [
          logOf('calisthenics', 3),
          logOf('gym', 1, done: false), // did not happen
        ],
      );
      // gym was never really done: it is due first
      expect(p.items.single.title, 'Gym 60 perc');
    });

    test('the latest day of a sport counts, whatever the order of the log', () {
      final a = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('gym', 1), logOf('gym', 3), logOf('calisthenics', 2)],
      );
      // gym last on the 3rd, calisthenics on the 2nd: calisthenics is older
      expect(a.items.single.title, 'Calisthenics 45 perc');
      final b = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('gym', 3), logOf('gym', 1), logOf('calisthenics', 2)],
      );
      expect(b.items.single.title, 'Calisthenics 45 perc');
    });

    test('the calendar counts too: what is booked ahead goes to the back', () {
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 2),
        existing: [booked('Calisthenics 45 perc', 9, 18, minutes: 45)],
      );
      // calisthenics is booked: the planned one is Gym
      expect(p.items.single.title, 'Gym 60 perc');
    });

    test('a sport of the user\'s own is told apart from a plain "edzés"', () {
      const own = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Pilates', minutes: 30),
          PlanSport(name: 'Tánc', minutes: 45),
        ],
        perWeek: 1,
      );
      final p = plan(
        prefs: own,
        existing: [booked('Pilates edzés 30 perc', 3, 18, minutes: 30)],
      );
      // pilates was done on the 3rd: the dance is due
      expect(p.items.single.title, 'Tánc edzés 45 perc');
    });

    test('the reason says how long ago, or that the sport is new', () {
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('calisthenics', 1)],
      );
      // gym was never done
      expect(p.items.single.reason, contains('még nincs rögzített edzés'));
      final q = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        log: [logOf('calisthenics', 1), logOf('gym', 2)],
      );
      // calisthenics: last on May 1, planned on May 5
      expect(q.items.single.reason, contains('utoljára 4 napja'));
    });
  });

  group('the calendar around', () {
    test('a busy day: the gap after the event, buffer included', () {
      final ex = [booked('Fogorvos', 5, 10)];
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 1), existing: ex);
      // 10:00-11:00 plus the 15 minutes of buffer: the first free start
      expect(shown(p), ['05-05 11:15 Calisthenics 45 perc']);
    });

    test('a tight gap between two events is used', () {
      final ex = [
        booked('Reggeli megbeszélés', 5, 9), // 09:00-10:00
        booked('Ebéd', 5, 11, minutes: 60), // 11:00-12:00
      ];
      // 10:15 .. 10:45: 30 minutes: too short for 45; the next gap is after 12:15
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 1), existing: ex);
      expect(shown(p), ['05-05 12:15 Calisthenics 45 perc']);
    });

    test('an all-day event does not block', () {
      final ex = [event('Névnap', at(5, 0), at(6, 0), allDay: true)];
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 1), existing: ex);
      expect(shown(p), ['05-05 10:00 Calisthenics 45 perc']);
    });

    test('nothing is planned into the sleep window', () {
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 5));
      for (final i in p.items) {
        expect(i.startWall.hour, greaterThanOrEqualTo(7));
        expect(
          i.endWall.hour * 60 + i.endWall.minute,
          lessThanOrEqualTo(23 * 60),
        );
      }
    });

    test('the sleep hours of the user are respected', () {
      // sleeping 00:00-11:00: nothing before 11:00
      const late = PlanRules(sleepStartHour: 0, sleepEndHour: 11);
      final p = plan(
        r: late,
        prefs: const LocalPlanPrefs(perWeek: 1, band: PlanBand.morning),
      );
      expect(p.items.single.startWall.hour, greaterThanOrEqualTo(11));
    });

    test('the week cap counts what the calendar already has', () {
      // five workouts already in the week of the 4th (Mon-Sun): the cap is
      // reached, so the plan may only use the next week (Monday the 11th)
      final ex = [
        for (var d = 4; d <= 8; d++)
          booked('Gym 60 perc', d, d.isEven ? 7 : 20, minutes: 60),
      ];
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 7),
        existing: ex,
        days: 8,
      );
      for (final i in p.items) {
        expect(i.startWall.isAfter(floating(2026, 5, 10, 23, 59)), isTrue);
      }
    });
  });

  group('the shifts', () {
    // nights on 5, 6, 7 (Tue, Wed, Thu), off on 8, 9, 10, days on 11, 12, 13
    final cycle = [night(5), night(6), night(7), day(11), day(12), day(13)];

    test('a plan that keeps the distance from the shifts and the sleep', () {
      final p = plan(existing: cycle);
      expect(judged(p, cycle), isEmpty);
      expect(p.items, isNotEmpty);
      for (final i in p.items) {
        // not on a night shift day, nor the one after, and not on a day shift
        expect([6, 7, 11], isNot(contains(i.startWall.day)));
      }
    });

    test(
      'after the last night shift: not before the sleep and the distance',
      () {
        final p = plan(
          existing: cycle,
          prefs: const LocalPlanPrefs(perWeek: 1, band: PlanBand.morning),
        );
        // the wish is the morning, but the morning of the 8th is sleep and the
        // 6 o'clock end of the shift keeps 8 hours: the first start is 15:00
        // (or an earlier day with room)
        for (final i in p.items) {
          if (i.startWall.day == 8) {
            expect(i.startWall.hour, greaterThanOrEqualTo(15));
          }
        }
      },
    );

    test('too few windows: it says how many fit, and why', () {
      final p = plan(existing: cycle, prefs: const LocalPlanPrefs(perWeek: 6));
      expect(p.items.length, lessThan(6));
      expect(judged(p, cycle), isEmpty);
      expect(p.dropped.first, startsWith('A műszak miatt'));
      expect(p.dropped.first, contains('${p.items.length} edzés fér be'));
      expect(p.dropped.first, contains('a cél 6 lett volna'));
      expect(p.dropped.first, contains('kevés szabad ablak'));
      expect(p.dropped.last, contains('Ami a legtöbbször útban volt'));
      expect(p.dropped.last, contains('a műszakok'));
      // a clash with a shift is the shift's doing, not "the other events"
      expect(p.dropped.last, isNot(contains('a naptár többi eseménye')));
      expect(p.summary, contains('a heti cél 6 lett volna'));
    });

    test('the distance from a shift is waived for a short session', () {
      // 40 minutes is under the 45 that keep the distance: Wednesday has room
      // for it between the night shifts only at the sleep-free hours
      const short = LocalPlanPrefs(
        sports: [PlanSport(name: 'Calisthenics', minutes: 40)],
        perWeek: 3,
      );
      final p = plan(existing: cycle, prefs: short);
      expect(judged(p, cycle), isEmpty);
    });
  });

  group('the energy', () {
    test('a hard session needs the energy: a bad day gets a light one', () {
      const gymOnly = LocalPlanPrefs(
        sports: [PlanSport(name: 'Gym', minutes: 60)],
        perWeek: 1,
      );
      // energy 2 on the first days, 4 on the 9th
      final energy = {
        for (var d = 5; d <= 8; d++) floating(2026, 5, d): 2,
        floating(2026, 5, 9): 4,
      };
      final p = plan(prefs: gymOnly, energy: energy);
      expect(p.items.single.startWall.day, 9);
    });

    test('a light session does not need it', () {
      const light = LocalPlanPrefs(
        sports: [PlanSport(name: 'Calisthenics', minutes: 45)],
        perWeek: 1,
      );
      final energy = {for (var d = 5; d <= 11; d++) floating(2026, 5, d): 1};
      final p = plan(prefs: light, energy: energy);
      expect(p.items.single.startWall.day, 5);
    });

    test('with no energy known for a future day, 3 of 5 is assumed', () {
      const gymOnly = LocalPlanPrefs(
        sports: [PlanSport(name: 'Gym', minutes: 60)],
        perWeek: 1,
      );
      expect(plan(prefs: gymOnly).items, hasLength(1));
      // raise the bar to 4: now every day without data is light-only
      const strict = PlanRules(minEnergyForHard: 4);
      final p = plan(prefs: gymOnly, r: strict);
      expect(p.items, isEmpty);
      expect(p.dropped.join(' '), contains('az energiaszint'));
    });
  });

  group('outdoor sports', () {
    const kajak = LocalPlanPrefs(
      sports: [PlanSport(name: 'Kajak', minutes: 90, outdoor: true)],
      perWeek: 1,
    );

    test('in season and without a forecast: planned, and it says so', () {
      final p = plan(prefs: kajak);
      expect(p.items.single.title, 'Kajak 90 perc');
      expect(p.items.single.outdoor, isTrue);
      expect(p.items.single.reason, contains('Előrejelzés nélkül'));
    });

    test('the forecast picks the day: only the fine one is used', () {
      final weather = {
        for (var d = 5; d <= 11; d++)
          floating(2026, 5, d): d == 9
              ? fine(floating(2026, 5, d))
              : rainy(floating(2026, 5, d)),
      };
      final p = plan(prefs: kajak, weather: weather);
      expect(p.items.single.startWall.day, 9);
      expect(p.items.single.reason, isNot(contains('Előrejelzés nélkül')));
    });

    test('bad weather all week: nothing, and the weather is named', () {
      final weather = {
        for (var d = 5; d <= 11; d++)
          floating(2026, 5, d): rainy(floating(2026, 5, d)),
      };
      final p = plan(prefs: kajak, weather: weather);
      expect(p.items, isEmpty);
      expect(p.dropped.join(' '), contains('az időjárás'));
    });

    test('kajak is for May to September, the others spring to autumn', () {
      // 2026-01-12 is a Monday: winter
      final winter = plan(prefs: kajak, from: floating(2026, 1, 13));
      expect(winter.items, isEmpty);
      expect(winter.dropped.join(' '), contains('az évszak'));
      // April: not kajak, but cycling
      const bike = LocalPlanPrefs(
        sports: [PlanSport(name: 'Kerékpár', minutes: 60, outdoor: true)],
        perWeek: 1,
      );
      expect(plan(prefs: kajak, from: floating(2026, 4, 14)).items, isEmpty);
      expect(
        plan(prefs: bike, from: floating(2026, 4, 14)).items,
        hasLength(1),
      );
      expect(plan(prefs: bike, from: floating(2026, 3, 17)).items, isEmpty);
      expect(
        plan(prefs: bike, from: floating(2026, 10, 13)).items,
        hasLength(1),
      );
      expect(plan(prefs: bike, from: floating(2026, 11, 3)).items, isEmpty);
      // September is still kajak, October is not
      expect(
        plan(prefs: kajak, from: floating(2026, 9, 15)).items,
        hasLength(1),
      );
      expect(plan(prefs: kajak, from: floating(2026, 10, 6)).items, isEmpty);
    });

    test('in winter the indoor sport takes the turn', () {
      const mixed = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Kajak', minutes: 90, outdoor: true),
          PlanSport(name: 'Gym', minutes: 60),
        ],
        perWeek: 1,
      );
      final p = plan(prefs: mixed, from: floating(2026, 1, 13));
      expect(p.items.single.title, 'Gym 60 perc');
    });

    test('an indoor sport ignores the weather', () {
      const gym = LocalPlanPrefs(
        sports: [PlanSport(name: 'Gym', minutes: 60)],
        perWeek: 1,
      );
      final weather = {
        for (var d = 5; d <= 11; d++)
          floating(2026, 5, d): rainy(floating(2026, 5, d)),
      };
      expect(plan(prefs: gym, weather: weather).items, hasLength(1));
    });
  });

  group('the time of the day', () {
    const one = LocalPlanPrefs(perWeek: 1);
    String first(PlanBand b) =>
        shown(plan(prefs: one.copyWith(band: b))).single;

    test('each wish gets its own hour', () {
      expect(first(PlanBand.any), '05-05 10:00 Calisthenics 45 perc');
      expect(first(PlanBand.morning), '05-05 07:00 Calisthenics 45 perc');
      expect(first(PlanBand.forenoon), '05-05 09:00 Calisthenics 45 perc');
      expect(first(PlanBand.afternoon), '05-05 13:00 Calisthenics 45 perc');
      expect(first(PlanBand.evening), '05-05 17:00 Calisthenics 45 perc');
    });

    test('a session that would end outside the band starts earlier', () {
      // the evening band is 17-21: a 90-minute session fits from 17:00 to 18:30
      const long = LocalPlanPrefs(
        sports: [PlanSport(name: 'Gym', minutes: 90)],
        perWeek: 1,
        band: PlanBand.evening,
      );
      expect(shown(plan(prefs: long)).single, '05-05 17:00 Gym 90 perc');
    });

    test('when the band is full, the nearest free time is used', () {
      final ex = [booked('Munka', 5, 17, minutes: 240)]; // 17:00-21:00
      final p = plan(
        prefs: one.copyWith(band: PlanBand.evening),
        existing: ex,
      );
      // the first day has no room in the evening: a day with a free evening
      // wins over a late one on the busy day
      expect(p.items.single.startWall.day, isNot(5));
    });
  });

  group('the days', () {
    test('the sessions are spread out, not packed', () {
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 2));
      expect(shown(p), [
        '05-05 10:00 Calisthenics 45 perc',
        '05-08 10:00 Gym 60 perc',
      ]);
    });

    test('a booked workout is a neighbour: the new one keeps its distance', () {
      final ex = [booked('Gym 60 perc', 6, 18)];
      final p = plan(prefs: const LocalPlanPrefs(perWeek: 2), existing: ex);
      expect(p.items.single.startWall.day, 9);
    });

    test('the window is as long as asked, and not longer', () {
      final p = plan(days: 3, prefs: const LocalPlanPrefs(perWeek: 3));
      for (final i in p.items) {
        expect(i.startWall.day, inInclusiveRange(5, 7));
      }
      expect(p.summary, contains('a következő 3 napra'));
      final one = plan(days: 1, prefs: const LocalPlanPrefs(perWeek: 1));
      expect(shown(one), ['05-05 10:00 Calisthenics 45 perc']);
    });

    test('a window longer than two weeks is cut to two', () {
      final p = plan(days: 40, prefs: const LocalPlanPrefs(perWeek: 7));
      final last = p.items
          .map((i) => i.startWall.day)
          .reduce((a, b) => a > b ? a : b);
      expect(last, lessThanOrEqualTo(18));
      expect(p.summary, contains('14 napra'));
    });

    test('a window that starts today skips what is already past', () {
      // 12:20 on Tuesday: the first start is after 12:35
      final p = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        now: at(5, 12, 20),
      );
      expect(shown(p), ['05-05 13:00 Calisthenics 45 perc']);
      // exactly 15 minutes ahead is allowed
      final q = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        now: at(5, 9, 45),
      );
      expect(shown(q), ['05-05 10:00 Calisthenics 45 perc']);
      // a minute less is not
      final r = plan(
        prefs: const LocalPlanPrefs(perWeek: 1),
        now: at(5, 9, 46),
      );
      expect(shown(r), ['05-05 10:30 Calisthenics 45 perc']);
    });
  });

  group('when nothing is possible', () {
    test('no sports: a message, no plan', () {
      final p = plan(prefs: const LocalPlanPrefs(sports: []));
      expect(p.items, isEmpty);
      expect(p.summary, contains('Nincs megadott sport'));
      expect(p.summary, contains('Helyi terv'));
    });

    test('a calendar full of shifts: no session, and it says why', () {
      final shifts = [for (var d = 4; d <= 12; d++) night(d)];
      final p = plan(existing: shifts);
      expect(p.items, isEmpty);
      expect(p.summary, contains('nem fért be új edzés'));
      expect(p.dropped.first, startsWith('A műszak miatt'));
      expect(p.dropped.first, contains('0 edzés fér be'));
    });

    test('no room because of ordinary events: the rules are named', () {
      final busy = [
        for (var d = 5; d <= 11; d++) booked('Konferencia', d, 7, minutes: 960),
      ];
      final p = plan(existing: busy);
      expect(p.items, isEmpty);
      expect(p.dropped.first, startsWith('A szabályok miatt'));
      expect(p.dropped.last, contains('a naptár többi eseménye'));
    });

    test(
      'only what stood in the way most often is named, two things at most',
      () {
        final p = plan(
          existing: [
            for (var d = 5; d <= 11; d++)
              booked('Konferencia', d, 7, minutes: 960),
          ],
          prefs: const LocalPlanPrefs(perWeek: 2),
        );
        final named = RegExp('továbbá').allMatches(p.dropped.last).length;
        expect(named, lessThanOrEqualTo(1));
      },
    );
  });

  group('the head of the answer', () {
    test('fewer than wished: it says what the wish was', () {
      final shifts = [night(5), night(6), night(7), day(11)];
      final p = plan(existing: shifts, prefs: const LocalPlanPrefs(perWeek: 6));
      expect(
        p.summary,
        'Helyi terv, modell nélkül: ${p.items.length} edzés a következő 7 napra (a heti cél 6 lett volna).',
      );
    });

    test('as many as wished: no word about a shortfall', () {
      expect(plan().summary, isNot(contains('lett volna')));
    });
  });
}
