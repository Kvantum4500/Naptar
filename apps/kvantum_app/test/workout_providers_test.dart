import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/workout_providers.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// Which workout the app asks about, and what the answers teach (2e).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  // 2026-05-05 22:00 in Budapest
  final now = DateTime.utc(2026, 5, 5, 20);

  late AppDatabase db;
  late ProviderContainer c;
  late EventRepository events;

  ProviderContainer container() {
    final k = ProviderContainer(
      overrides: [
        ...baseOverrides(db),
        workoutClockProvider.overrideWithValue(() => now),
        handbookStoreProvider.overrideWith(
          (ref) => HandbookStore(
            ref.watch(recordRepoProvider),
            loader: (p) async => 'H[$p]',
          ),
        ),
      ],
    );
    addTearDown(k.dispose);
    return k;
  }

  setUp(() async {
    db = await newDb();
    events = EventRepository(db);
    c = container();
  });
  tearDown(() => db.close());

  /// A workout [hoursAgo] hours before "now" that lasted [minutes].
  Future<void> workout(
    String id,
    String title, {
    required double endedHoursAgo,
    int minutes = 60,
    bool allDay = false,
    bool shift = false,
    String? rrule,
  }) async {
    final end = now.subtract(Duration(minutes: (endedHoursAgo * 60).round()));
    final start = end.subtract(Duration(minutes: minutes));
    final wall = toWallClock(bp, start);
    final e = evt(
      id,
      title,
      floating(wall.year, wall.month, wall.day, wall.hour, wall.minute),
      len: Duration(minutes: minutes),
      allDay: allDay,
      rrule: rrule,
    );
    await events.saveLocal(shift ? e.copyWith(notes: kShiftMarker) : e);
  }

  // (Riverpod pauses a provider nobody listens to, as a widget does in the
  // app; the tests listen the same way)
  Future<PendingWorkout?> pending() async {
    c.listen(pendingWorkoutProvider, (_, _) {});
    await pumpEventQueue();
    c.invalidate(pendingWorkoutProvider);
    return c.read(pendingWorkoutProvider.future);
  }

  Future<void> answer(PendingWorkout w, {int body = 3}) =>
      c.read(workoutFeedbackActionsProvider).save(w, bodyLoad: body);

  group('which workout is asked about', () {
    test('one that ended a few hours ago, by its name', () async {
      await workout('g', 'Gym', endedHoursAgo: 3, minutes: 75);
      final p = (await pending())!;
      expect(p.title, 'Gym');
      expect(p.sport, 'gym');
      expect(p.minutes, 75);
      expect(p.day, DateTime.utc(2026, 5, 5));
      expect(p.id, startsWith('g-20260505'));
    });

    test('not one that is still going, nor one from days ago', () async {
      await workout('running', 'Gym', endedHoursAgo: -0.5);
      expect(await pending(), isNull);
      await workout('old', 'Gym', endedHoursAgo: 37);
      expect(await pending(), isNull);
      await workout('recent', 'Calisthenics', endedHoursAgo: 35);
      expect((await pending())!.title, 'Calisthenics');
    });

    test(
      'not a shift, an all-day event or something that is no workout',
      () async {
        await workout('s', 'Edzés műszak', endedHoursAgo: 2, shift: true);
        await workout('a', 'Edzés nap', endedHoursAgo: 2, allDay: true);
        await workout('f', 'Fogorvos', endedHoursAgo: 2);
        await workout('w', 'Séta', endedHoursAgo: 2);
        expect(await pending(), isNull);
      },
    );

    test(
      'the one that ended last, and the next after it is answered',
      () async {
        await workout('early', 'Futás', endedHoursAgo: 10, minutes: 30);
        await workout('late', 'Gym', endedHoursAgo: 2);
        final first = (await pending())!;
        expect(first.title, 'Gym');
        await answer(first);
        final second = (await pending())!;
        expect(second.title, 'Futás');
        await answer(second);
        expect(await pending(), isNull);
      },
    );

    test('"later" hides it for this run only', () async {
      await workout('g', 'Gym', endedHoursAgo: 2);
      final p = (await pending())!;
      c.read(workoutFeedbackActionsProvider).later(p);
      expect(await pending(), isNull);
      // the app is started again: the question comes back
      c = container();
      expect((await pending())!.title, 'Gym');
    });

    test('switched off: no question', () async {
      await workout('g', 'Gym', endedHoursAgo: 2);
      await c
          .read(aiSettingsStoreProvider)
          .save(const AiSettings(workoutFeedback: false));
      c.invalidate(aiSettingsProvider);
      expect(await pending(), isNull);
      await c.read(aiSettingsStoreProvider).save(const AiSettings());
      c.invalidate(aiSettingsProvider);
      expect(await pending(), isNotNull);
    });

    test('a recurring workout: one answer per day', () async {
      // yesterday's and today's session of the same series
      await events.saveLocal(
        evt(
          'daily',
          'Edzés',
          floating(2026, 5, 4, 18),
          rrule: 'FREQ=DAILY;COUNT=5',
        ),
      );
      final today = (await pending())!;
      expect(today.id, workoutLogId('daily', floating(2026, 5, 5, 18)));
      await answer(today);
      final yesterday = (await pending())!;
      expect(yesterday.id, workoutLogId('daily', floating(2026, 5, 4, 18)));
      expect(yesterday.id, isNot(today.id));
    });
  });

  group('what the answers are saved as', () {
    test(
      'only the given answers; the sport, the day and the length too',
      () async {
        await workout('g', 'Gym', endedHoursAgo: 2);
        final p = (await pending())!;
        await c
            .read(workoutFeedbackActionsProvider)
            .save(
              p,
              bodyLoad: 4,
              energyStart: 3,
              energyEnd: 2,
              note: ' fáradt voltam ',
            );
        final v = WorkoutLogView(
          (await c.read(recordRepoProvider).get(kindWorkoutLog, p.id))!,
        );
        expect(
          (v.title, v.sport, v.minutes, v.date),
          ('Gym', 'gym', 60, p.day),
        );
        expect((v.bodyLoad, v.mindLoad), (4, null));
        expect((v.energyStart, v.energyEnd, v.experience), (3, 2, null));
        expect((v.done, v.note), (true, 'fáradt voltam'));
      },
    );

    test('"skipped" is a feedback of its own', () async {
      await workout('g', 'Gym', endedHoursAgo: 2);
      final p = (await pending())!;
      await c.read(workoutFeedbackActionsProvider).save(p, done: false);
      final v = WorkoutLogView(
        (await c.read(recordRepoProvider).get(kindWorkoutLog, p.id))!,
      );
      expect(v.done, isFalse);
      expect(v.answered, isFalse);
      expect(await pending(), isNull);
    });
  });

  group('what the answers teach', () {
    /// [loads] feedback of [sport], [minutes] long, the newest first.
    Future<void> sessions(String sport, int minutes, List<int> loads) async {
      for (var i = 0; i < loads.length; i++) {
        await c
            .read(recordRepoProvider)
            .edit(
              kindWorkoutLog,
              '$sport-$minutes-$i-${loads.hashCode}',
              workoutLogFields(
                title: sportLabel(sport),
                date: DateTime.utc(2026, 5, 4).subtract(Duration(days: i)),
                minutes: minutes,
                sport: sport,
                bodyLoad: loads[i],
              ),
            );
      }
      await pumpEventQueue();
    }

    Future<WorkoutLearning> learning() async {
      c.listen(workoutLearningProvider, (_, _) {});
      await pumpEventQueue();
      c.invalidate(workoutLearningProvider);
      return c.read(workoutLearningProvider.future);
    }

    test('five easy sessions make a suggestion, not a rule', () async {
      await sessions('calisthenics', 60, [2, 1, 2, 2, 1]);
      final l = await learning();
      expect(l.suggestions.single.sport, 'calisthenics');
      expect(l.relaxed, isEmpty);
    });

    test('a yes writes the rule to "Tanult szokások" and applies it', () async {
      await sessions('calisthenics', 60, [2, 1, 2, 2, 1]);
      final s = (await learning()).suggestions.single;
      await c.read(workoutFeedbackActionsProvider).agreeLight(s);
      final rules = await c.read(handbookStoreProvider).learnedRules();
      expect(rules.single, startsWith('[könnyű: calisthenics] '));
      final l = await learning();
      expect(l.suggestions, isEmpty);
      expect(l.relaxed, {'calisthenics': 90});
    });

    test('deleting that line takes it back', () async {
      await sessions('calisthenics', 60, [2, 1, 2, 2, 1]);
      final s = (await learning()).suggestions.single;
      await c.read(workoutFeedbackActionsProvider).agreeLight(s);
      await c.read(handbookStoreProvider).save('learned', '(üres)\n');
      final l = await learning();
      expect(l.relaxed, isEmpty);
      expect(l.suggestions, hasLength(1)); // asked again
    });

    test(
      'a no is remembered; five more sessions bring the question back',
      () async {
        await sessions('gym', 60, [2, 2, 1, 2, 2]);
        final s = (await learning()).suggestions.single;
        await c.read(workoutFeedbackActionsProvider).declineLight(s);
        expect((await learning()).suggestions, isEmpty);
        // five more, newer, easy sessions
        for (var i = 0; i < 5; i++) {
          await c
              .read(recordRepoProvider)
              .edit(
                kindWorkoutLog,
                'new-$i',
                workoutLogFields(
                  title: 'Gym',
                  date: DateTime.utc(2026, 5, 5),
                  minutes: 60,
                  sport: 'gym',
                  bodyLoad: 2,
                ),
              );
        }
        expect((await learning()).suggestions, hasLength(1));
      },
    );

    test('hard sessions tighten by themselves', () async {
      await sessions('gym', 50, [5, 4, 4]);
      final l = await learning();
      expect(l.tightened, {'gym': 45});
      expect(l.suggestions, isEmpty);
    });

    test(
      'nothing is learned or asked when the feedback is switched off',
      () async {
        await sessions('calisthenics', 60, [2, 1, 2, 2, 1]);
        await c
            .read(aiSettingsStoreProvider)
            .save(const AiSettings(workoutFeedback: false));
        c.invalidate(aiSettingsProvider);
        expect((await learning()).suggestions, isEmpty);
      },
    );
  });

  test('the switch is saved, and on by default', () async {
    final store = c.read(aiSettingsStoreProvider);
    expect((await store.load()).workoutFeedback, isTrue);
    await store.save(const AiSettings(workoutFeedback: false));
    expect((await store.load()).workoutFeedback, isFalse);
    await store.save(const AiSettings());
    expect((await store.load()).workoutFeedback, isTrue);
  });

  test('a corrupt "no" memory is no memory', () async {
    await c.read(recordRepoProvider).setMeta('wl.declined', '{nem json');
    expect(await readDeclinedLight(c.read(recordRepoProvider).meta), isEmpty);
    await c
        .read(recordRepoProvider)
        .setMeta('wl.declined', '{"gym": 5, "x": "sok", "y": 2.5}');
    expect(await readDeclinedLight(c.read(recordRepoProvider).meta), {
      'gym': 5,
    });
  });
}
