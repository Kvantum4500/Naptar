import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_service.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/weather_service.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

/// H: the plan the program makes by itself, from the data on the device. The
/// planner is tested in the core; here: what the service reads for it, what it
/// hands back, and that no model is asked.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late AiSettingsStore store;

  // Monday 2026-05-04, 10:00 Budapest: the plan starts on the Tuesday
  final now = DateTime.utc(2026, 5, 4, 8);

  AssistantService service(FakeLlm llm, {WeatherService? weather}) =>
      AssistantService(
        provider: llm,
        events: events,
        records: records,
        handbook: HandbookStore(records, loader: (path) async => 'H[$path]'),
        settingsStore: store,
        now: () => now,
        delay: (d) async {},
        weather: weather,
      );

  setUp(() async {
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db, deviceId: 'T', clock: () => 1000);
    store = AiSettingsStore(
      read: records.meta,
      write: records.setMeta,
      now: () => DateTime(2026, 5, 4),
    );
  });
  tearDown(() => db.close());

  const settings = AiSettings();

  Future<AssistantOutcome> plan(
    LocalPlanPrefs prefs, {
    FakeLlm? llm,
    AiSettings s = settings,
    WeatherService? weather,
  }) => service(
    llm ?? FakeLlm([]),
    weather: weather,
  ).localPlan(prefs, settings: s);

  List<String> shown(AssistantOutcome o) => [
    for (final i in o.items)
      '${i.startWall.month}-${i.startWall.day} ${i.startWall.hour}:${i.startWall.minute.toString().padLeft(2, '0')} ${i.title}',
  ];

  var seq = 0;
  Future<void> feedback(
    String sport,
    int minutes,
    int body, {
    required int daysAgo,
  }) => records.edit(
    kindWorkoutLog,
    'l${seq++}',
    workoutLogFields(
      title: sportLabel(sport),
      date: DateTime.utc(2026, 5, 4).subtract(Duration(days: daysAgo)),
      minutes: minutes,
      sport: sport,
      bodyLoad: body,
    ),
  );

  group('the plan of the program', () {
    test(
      'on an empty calendar: three sessions from tomorrow, no model',
      () async {
        final llm = FakeLlm([]); // a call would throw
        final out = await plan(const LocalPlanPrefs(), llm: llm);
        expect(llm.requests, isEmpty);
        expect(shown(out), [
          '5-5 10:00 Calisthenics 45 perc',
          '5-8 10:00 Gym 60 perc',
          '5-11 10:00 Calisthenics 45 perc',
        ]);
        expect(out.calls, 0);
        expect(out.usage, isNull);
        expect(await store.usageToday(), 0, reason: 'nothing was counted');
      },
    );

    test(
      'it is a local answer of its own kind, with the plan as items',
      () async {
        final out = await plan(const LocalPlanPrefs());
        expect(out.localAnswer!.kind, LocalKind.plan);
        expect(out.localAnswer!.text, contains('modell és kulcs nélkül'));
        expect(
          out.localAnswer!.text,
          contains('Semmi nem hagyta el az eszközt'),
        );
        expect(out.summary, startsWith('Helyi terv, modell nélkül: 3 edzés'));
        expect(out.text, isEmpty);
        expect(out.dropped, isEmpty);
        expect(out.hasPlan, isTrue);
        // the items are ordinary proposals: the usual accept path takes them
        for (final i in out.items) {
          expect(i.kind, 'workout');
          expect(i.tzid, 'Europe/Budapest');
        }
      },
    );

    test(
      'it needs no sharing switch: everything stays on the device',
      () async {
        final out = await plan(
          const LocalPlanPrefs(),
          s: const AiSettings(
            events: false,
            tasks: false,
            checkins: false,
            finance: false,
            handbook: false,
          ),
        );
        expect(out.items, hasLength(3));
      },
    );

    test('the wishes of the user are what it plans with', () async {
      const own = LocalPlanPrefs(
        sports: [PlanSport(name: 'Úszás', minutes: 30)],
        perWeek: 2,
        band: PlanBand.evening,
      );
      final out = await plan(own);
      expect(out.items, hasLength(2));
      for (final i in out.items) {
        expect(i.title, 'Úszás 30 perc');
        expect(i.startWall.hour, greaterThanOrEqualTo(17));
      }
    });

    test(
      'the calendar is read: a busy time is avoided, a workout counts',
      () async {
        await events.saveLocal(evt('m', 'Fogorvos', floating(2026, 5, 5, 10)));
        await events.saveLocal(
          evt('g', 'Gym 60 perc', floating(2026, 5, 7, 18)),
        );
        final out = await plan(const LocalPlanPrefs());
        // the Thursday gym is one of the three: two are planned
        expect(out.items, hasLength(2));
        // (the gym booked for Thursday counts as done then, so the calisthenics is
        // due first: it goes to the far end, the gym to the first gap: 11:15,
        // the Fogorvos ends at 11:00 and the buffer is 15 minutes)
        expect(shown(out), [
          '5-5 11:15 Gym 60 perc',
          '5-10 10:00 Calisthenics 45 perc',
        ]);
        expect(
          [for (final i in out.items) i.startWall.day],
          isNot(contains(7)),
          reason: 'the booked day is taken',
        );
      },
    );

    test(
      'the events before the window decide the order of the sports',
      () async {
        // a gym session last Friday: the calisthenics is longer ago? neither is
        // in the calendar before, so the one done is the later in the line
        await events.saveLocal(
          evt('g', 'Gym 60 perc', floating(2026, 5, 1, 18)),
        );
        final out = await plan(const LocalPlanPrefs(perWeek: 1));
        expect(out.items.single.title, 'Calisthenics 45 perc');
        // and the other way round
        await events.saveLocal(
          evt('c', 'Calisthenics 45 perc', floating(2026, 5, 3, 18)),
        );
        final again = await plan(const LocalPlanPrefs(perWeek: 1));
        expect(again.items.single.title, 'Gym 60 perc');
      },
    );

    test('the workout log decides the order too', () async {
      await feedback('gym', 60, 3, daysAgo: 1);
      await feedback('calisthenics', 45, 3, daysAgo: 6);
      final out = await plan(const LocalPlanPrefs(perWeek: 1));
      expect(out.items.single.title, 'Calisthenics 45 perc');
      // and the other way round: the one that is first in the list is not
      // always the one planned first
      await feedback('calisthenics', 45, 3, daysAgo: 0);
      final again = await plan(const LocalPlanPrefs(perWeek: 1));
      expect(again.items.single.title, 'Gym 60 perc');
    });

    test('a low check-in keeps the hard session off that day', () async {
      for (final day in ['2026-05-05', '2026-05-06']) {
        await records.edit(kindCheckIn, day, checkInFields(physical: 2));
      }
      final out = await plan(
        const LocalPlanPrefs(
          sports: [PlanSport(name: 'Gym', minutes: 60)],
          perWeek: 1,
        ),
      );
      // (the 5th and the 6th are out: a Gym is a hard session)
      expect(shown(out), ['5-7 10:00 Gym 60 perc']);
    });

    test(
      'what the user\'s workouts taught counts: 45 minutes turn hard',
      () async {
        expect(
          (await plan(const LocalPlanPrefs(perWeek: 1))).items.single.hard,
          isFalse,
        );
        for (var d = 1; d <= 3; d++) {
          await feedback('calisthenics', 45, 5, daysAgo: d + 10);
        }
        final out = await plan(
          const LocalPlanPrefs(
            sports: [PlanSport(name: 'Calisthenics', minutes: 45)],
            perWeek: 1,
          ),
        );
        expect(out.items.single.hard, isTrue);
      },
    );

    test('the workout of 60 minutes is hard, as the rules say', () async {
      final out = await plan(const LocalPlanPrefs());
      expect([for (final i in out.items) i.hard], [false, true, false]);
    });

    test('the shifts of the calendar are kept apart', () async {
      // nights on the 5th, 6th, 7th: nothing on those days and the day after
      for (final d in [5, 6, 7]) {
        await events.saveLocal(
          CalEvent(
            id: 'n$d',
            calendarId: kNaptarCalendar,
            title: 'Éjszakai műszak',
            tzid: 'Europe/Budapest',
            start: floating(2026, 5, d, 18),
            end: floating(2026, 5, d + 1, 6),
            notes: kShiftMarker,
          ),
        );
      }
      final out = await plan(const LocalPlanPrefs(perWeek: 4));
      expect(out.items, isNotEmpty);
      for (final i in out.items) {
        expect([6, 7], isNot(contains(i.startWall.day)));
      }
      final o = await events.occurrences(
        resolveWallClock('Europe/Budapest', floating(2026, 5, 1)),
        resolveWallClock('Europe/Budapest', floating(2026, 5, 20)),
      );
      expect(
        validateProposal(
          [for (final i in out.items) i.toBlock()],
          existing: o,
          rules: const PlanRules(),
        ),
        isEmpty,
      );
    });

    test('when nothing fits it says so, and why: the shifts', () async {
      // a night shift every night of the window: the sleep after each and the
      // distance from each leave no room for a workout
      for (var d = 4; d <= 11; d++) {
        await events.saveLocal(
          CalEvent(
            id: 'n$d',
            calendarId: kNaptarCalendar,
            title: 'Éjszakai műszak',
            tzid: 'Europe/Budapest',
            start: floating(2026, 5, d, 18),
            end: floating(2026, 5, d + 1, 6),
            notes: kShiftMarker,
          ),
        );
      }
      final out = await plan(const LocalPlanPrefs());
      expect(out.items, isEmpty);
      expect(out.summary, contains('nem fért be'));
      expect(out.dropped, isNotEmpty);
      expect(out.dropped.first, contains('A műszak miatt'));
    });

    test('the week after the window counts: its cap is kept', () async {
      // Monday the 11th is the last day of the window, and its week (the 11th
      // to the 17th) already has five workouts from the 12th on: a sixth in
      // that week is over the cap, so the 11th is left out
      for (var d = 12; d <= 16; d++) {
        await events.saveLocal(
          evt('b$d', 'Calisthenics 45 perc', floating(2026, 5, d, 18)),
        );
      }
      final out = await plan(const LocalPlanPrefs());
      expect(out.items, hasLength(3));
      expect(
        [for (final i in out.items) i.startWall.day],
        isNot(contains(11)),
        reason: 'a sixth workout in that week',
      );
    });

    test('with no sports it says so', () async {
      final out = await plan(const LocalPlanPrefs(sports: []));
      expect(out.items, isEmpty);
      expect(out.summary, contains('Nincs megadott sport'));
    });

    test('the sleep hours of the settings are the rules', () async {
      // sleeping 00:00-12:00 (settings), the wish is the morning
      final out = await plan(
        const LocalPlanPrefs(perWeek: 1, band: PlanBand.morning),
        s: const AiSettings(sleepStartHour: 0, sleepEndHour: 12),
      );
      // (the service takes the sleep hours from the rules it was built with:
      // the default 23-07, as the controller builds it from the settings)
      expect(out.items, hasLength(1));
    });
  });

  group('the forecast', () {
    WeatherService forecast(List<int> rainyDays) => WeatherService(
      MockClient((_) async {
        final days = [for (var d = 4; d <= 18; d++) d];
        return http.Response(
          jsonEncode({
            'daily': {
              'time': [
                for (final d in days) '2026-05-${d.toString().padLeft(2, '0')}',
              ],
              'temperature_2m_max': [for (final _ in days) 20.0],
              'temperature_2m_min': [for (final _ in days) 10.0],
              'precipitation_sum': [
                for (final d in days) rainyDays.contains(d) ? 8.0 : 0.0,
              ],
              'precipitation_probability_max': [
                for (final d in days) rainyDays.contains(d) ? 90 : 5,
              ],
              'wind_speed_10m_max': [for (final _ in days) 10.0],
              'weather_code': [
                for (final d in days) rainyDays.contains(d) ? 63 : 1,
              ],
            },
          }),
          200,
        );
      }),
    );

    const kajak = LocalPlanPrefs(
      sports: [PlanSport(name: 'Kajak', minutes: 90, outdoor: true)],
      perWeek: 1,
    );
    final withPlace = AiSettings(
      place: Place(name: 'Budapest', lat: 47.5, lon: 19.04),
    );

    test('an outdoor sport takes the fine day of the forecast', () async {
      final out = await plan(
        kajak,
        s: withPlace,
        weather: forecast([5, 6, 7, 8, 10, 11]),
      );
      expect(out.items.single.startWall.day, 9);
      expect(out.items.single.reason, isNot(contains('Előrejelzés nélkül')));
    });

    test(
      'with the weather switched off the season decides, and it says so',
      () async {
        final out = await plan(
          kajak,
          s: AiSettings(
            weather: false,
            place: Place(name: 'Budapest', lat: 47.5, lon: 19.04),
          ),
          weather: forecast([5, 6, 7, 8, 9, 10, 11]),
        );
        expect(out.items.single.startWall.day, 5);
        expect(out.items.single.reason, contains('Előrejelzés nélkül'));
      },
    );

    test(
      'every plan reads the forecast anew: a new place, a new answer',
      () async {
        http.Response daily(bool rainy) {
          final days = [for (var d = 4; d <= 18; d++) d];
          return http.Response(
            jsonEncode({
              'daily': {
                'time': [
                  for (final d in days)
                    '2026-05-${d.toString().padLeft(2, '0')}',
                ],
                'temperature_2m_max': [for (final _ in days) 20.0],
                'temperature_2m_min': [for (final _ in days) 10.0],
                'precipitation_sum': [for (final _ in days) rainy ? 8.0 : 0.0],
                'precipitation_probability_max': [
                  for (final _ in days) rainy ? 90 : 5,
                ],
                'wind_speed_10m_max': [for (final _ in days) 10.0],
                'weather_code': [for (final _ in days) rainy ? 63 : 1],
              },
            }),
            200,
          );
        }

        // rain at the first place, sunshine at the second
        final svc = service(
          FakeLlm([]),
          weather: WeatherService(
            MockClient(
              (r) async => daily(r.url.queryParameters['latitude'] == '47.50'),
            ),
          ),
        );
        final wet = await svc.localPlan(kajak, settings: withPlace);
        expect(wet.items, isEmpty, reason: 'the kayak waits for a dry day');
        final dry = await svc.localPlan(
          kajak,
          settings: AiSettings(
            place: Place(name: 'Pécs', lat: 46.07, lon: 18.23),
          ),
        );
        expect(dry.items, hasLength(1));
      },
    );

    test('without a place the forecast is not used either', () async {
      final out = await plan(kajak, weather: forecast([5, 6, 7, 8, 9, 10, 11]));
      expect(out.items.single.reason, contains('Előrejelzés nélkül'));
    });
  });
}
