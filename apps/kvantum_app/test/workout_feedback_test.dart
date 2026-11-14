import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/workout_providers.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/workout_feedback.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/turns.dart';

/// The question after a workout and the "is it easy for you?" card (2e).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  // 2026-05-05 22:00 in Budapest; the clock can be moved by a test
  var clock = DateTime.utc(2026, 5, 5, 20);
  late AppDatabase db;
  late EventRepository events;

  ProviderContainer ref0(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  Future<void> boot(WidgetTester tester) async {
    useSize(tester);
    db = await newDb();
    events = EventRepository(db);
    clock = DateTime.utc(2026, 5, 5, 20);
    await tester.pumpWidget(
      app(
        const Scaffold(body: WorkoutFeedbackBanner()),
        db,
        extra: [
          workoutClockProvider.overrideWithValue(() => clock),
          handbookStoreProvider.overrideWith(
            (ref) => HandbookStore(
              ref.watch(recordRepoProvider),
              loader: (p) async => 'H[$p]',
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A workout on the 5th, from [hour] o'clock in Budapest, one hour long.
  Future<void> gym(
    WidgetTester tester, {
    String title = 'Gym',
    int hour = 18,
    int minutes = 60,
  }) => tester.runAsync(
    () => events.saveLocal(
      evt(
        'g$hour',
        title,
        floating(2026, 5, 5, hour),
        len: Duration(minutes: minutes),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    // the providers read the database for real: let them finish, then draw
    await tester.runAsync(turns);
    await tester.pumpAndSettle();
  }

  final bar = find.byKey(const Key('workout-feedback'));
  final id = workoutLogId('g18', floating(2026, 5, 5, 18));

  Future<WorkoutLogView?> saved(WidgetTester tester, [String? logId]) async {
    final r = await tester.runAsync(
      () =>
          ref0(tester)
              .read(recordRepoProvider)
              .get(kindWorkoutLog, logId ?? id),
    );
    return r == null ? null : WorkoutLogView(r);
  }

  group('the question after a workout', () {
    testWidgets('nothing to ask: nothing on the screen', (tester) async {
      await boot(tester);
      await settle(tester);
      expect(bar, findsNothing);
      expect(find.byKey(const Key('workout-relax')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a workout that has ended: a bar with its name and time', (
      tester,
    ) async {
      await boot(tester);
      await gym(tester);
      await settle(tester);
      expect(bar, findsOneWidget);
      expect(
        find.textContaining('Hogy ment: Gym (18:00–19:00)?'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('one that is still going, or is no workout, asks nothing', (
      tester,
    ) async {
      await boot(tester);
      await gym(tester, title: 'Fogorvos');
      await gym(tester, hour: 21, minutes: 90); // runs until 22:30
      await settle(tester);
      expect(bar, findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the answers are saved: only what was tapped', (tester) async {
      await boot(tester);
      await gym(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('workout-open')));
      await tester.pumpAndSettle();
      expect(find.text('Hogy ment: Gym?'), findsOneWidget);
      expect(find.textContaining('60 perc'), findsOneWidget);
      for (final k in [
        'bodyLoad-4',
        'energyStart-3',
        'energyEnd-2',
        'experience-5',
      ]) {
        await tester.tap(find.byKey(Key(k)));
      }
      await tester.pump();
      await tester.enterText(find.byKey(const Key('workout-note')), 'jó volt');
      await tester.tap(find.byKey(const Key('feedback-save')));
      await tester.pumpAndSettle();
      expect(find.text('Hogy ment: Gym?'), findsNothing);

      final v = (await saved(tester))!;
      expect((v.title, v.sport, v.minutes, v.done), ('Gym', 'gym', 60, true));
      expect(v.date, DateTime.utc(2026, 5, 5));
      expect((v.bodyLoad, v.mindLoad), (4, null));
      expect((v.energyStart, v.energyEnd, v.experience), (3, 2, 5));
      expect(v.note, 'jó volt');
      // answered: the bar is gone
      await settle(tester);
      expect(bar, findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('an empty form is not saved', (tester) async {
      await boot(tester);
      await gym(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('workout-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('feedback-save')));
      await tester.pumpAndSettle();
      expect(find.text('Válaszolj legalább egy kérdésre.'), findsOneWidget);
      expect(find.text('Hogy ment: Gym?'), findsOneWidget); // still open
      expect(await saved(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('"Kihagytam": a record that says it did not happen', (
      tester,
    ) async {
      await boot(tester);
      await gym(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('workout-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bodyLoad-5'))); // ignored
      await tester.tap(find.byKey(const Key('feedback-skipped')));
      await tester.pumpAndSettle();
      final v = (await saved(tester))!;
      expect(v.done, isFalse);
      expect(v.bodyLoad, isNull);
      await settle(tester);
      expect(bar, findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('"Később" on the bar hides it and saves nothing', (
      tester,
    ) async {
      await boot(tester);
      await gym(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('workout-later')));
      await settle(tester);
      expect(bar, findsNothing);
      expect(await saved(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets(
      '"Később" in the form closes it, hides the bar, saves nothing',
      (tester) async {
        await boot(tester);
        await gym(tester);
        await settle(tester);
        await tester.tap(find.byKey(const Key('workout-open')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bodyLoad-2')));
        await tester.tap(find.byKey(const Key('feedback-later')));
        await settle(tester);
        expect(find.text('Hogy ment: Gym?'), findsNothing);
        expect(bar, findsNothing);
        expect(await saved(tester), isNull);
        await shutdown(tester, db);
      },
    );

    testWidgets('switched off in the settings: no question', (tester) async {
      await boot(tester);
      await gym(tester);
      await tester.runAsync(
        () =>
            ref0(tester)
                .read(aiSettingsStoreProvider)
                .save(const AiSettings(workoutFeedback: false)),
      );
      ref0(tester).invalidate(aiSettingsProvider);
      await settle(tester);
      expect(bar, findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('it looks again when the app comes back to the front', (
      tester,
    ) async {
      await boot(tester);
      // the workout ends at 22:30, the clock still says 22:00
      await tester.runAsync(
        () => events.saveLocal(evt('g21', 'Gym', floating(2026, 5, 5, 21, 30))),
      );
      await settle(tester);
      expect(bar, findsNothing);
      clock = DateTime.utc(2026, 5, 5, 21); // 23:00, an hour later
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(bar, findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('...and every few minutes while it is open', (tester) async {
      await boot(tester);
      await tester.runAsync(
        () => events.saveLocal(evt('g21', 'Gym', floating(2026, 5, 5, 21, 30))),
      );
      await settle(tester);
      expect(bar, findsNothing);
      clock = DateTime.utc(2026, 5, 5, 21);
      await tester.pump(workoutLookEvery + const Duration(seconds: 1));
      await settle(tester);
      expect(bar, findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('both the bar and the form fit a phone screen', (tester) async {
      await boot(tester);
      useSize(tester, size: const Size(360, 700));
      await gym(tester, title: 'Street Workout a parkban, hosszú név');
      await settle(tester);
      expect(bar, findsOneWidget);
      await tester.tap(find.byKey(const Key('workout-open')));
      await tester.pumpAndSettle();
      // every scale is reachable by scrolling the form, nothing overflows
      await tester.ensureVisible(find.byKey(const Key('experience-5')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feedback-save')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('the timer is gone with the widget', (tester) async {
      await boot(tester);
      await tester.pumpWidget(const SizedBox());
      // a pending timer would fail the test at its end
      await tester.pump(workoutLookEvery * 2);
      await shutdown(tester, db);
    });
  });

  group('"is it easy for you?"', () {
    final card = find.byKey(const Key('workout-relax'));

    /// [count] easy sessions of 60 minutes, the newest [firstDaysAgo] days
    /// back. One write at a time, each followed by a pause: the providers read
    /// the database in the test's own zone, and the next write would wait for
    /// them (in the app there is one zone and no such wait).
    Future<void> easy(
      WidgetTester tester, {
      int count = 5,
      int firstDaysAgo = 1,
    }) async {
      final repo = ref0(tester).read(recordRepoProvider);
      for (var i = 0; i < count; i++) {
        await tester.runAsync(
          () => repo.edit(
            kindWorkoutLog,
            'old-$firstDaysAgo-$i',
            workoutLogFields(
              title: 'Calisthenics',
              date: DateTime.utc(
                2026,
                5,
                5,
              ).subtract(Duration(days: firstDaysAgo + i)),
              minutes: 60,
              sport: 'calisthenics',
              bodyLoad: 2,
            ),
          ),
        );
        await settle(tester);
      }
    }

    testWidgets('five easy sessions: the question, with the numbers', (
      tester,
    ) async {
      await boot(tester);
      await easy(tester);
      await settle(tester);
      expect(card, findsOneWidget);
      expect(
        find.textContaining('Calisthenics (60–89 perc) számodra könnyű'),
        findsOneWidget,
      );
      expect(
        find.textContaining('utolsó 5 alkalom átlagosan 2.0/5'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('fewer than five: no question', (tester) async {
      await boot(tester);
      await easy(tester, count: 4);
      await settle(tester);
      expect(card, findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('"Igen": the rule goes to the learned habits, the card goes', (
      tester,
    ) async {
      await boot(tester);
      await easy(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('relax-yes')));
      await settle(tester);
      expect(card, findsNothing);
      expect(
        find.textContaining('Rögzítve a Tanult szokások közé'),
        findsOneWidget,
      );
      final rules = await tester.runAsync(
        () => ref0(tester).read(handbookStoreProvider).learnedRules(),
      );
      expect(rules!.single, startsWith('[könnyű: calisthenics] '));
      await shutdown(tester, db);
    });

    testWidgets('"Nem": nothing is written, the card goes, and stays away', (
      tester,
    ) async {
      await boot(tester);
      await easy(tester);
      await settle(tester);
      await tester.tap(find.byKey(const Key('relax-no')));
      await settle(tester);
      expect(card, findsNothing);
      final rules = await tester.runAsync(
        () => ref0(tester).read(handbookStoreProvider).learnedRules(),
      );
      expect(rules, isEmpty);
      // the same sessions do not bring it back ...
      ref0(tester).invalidate(workoutLearningProvider);
      await settle(tester);
      expect(card, findsNothing);
      // ... five newer ones do
      await easy(tester, count: 5, firstDaysAgo: 0);
      await settle(tester);
      expect(card, findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the card fits a phone screen', (tester) async {
      await boot(tester);
      useSize(tester, size: const Size(360, 700));
      await easy(tester);
      await settle(tester);
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('both the bar and the card can be there at once', (
      tester,
    ) async {
      await boot(tester);
      await gym(tester);
      await easy(tester);
      await settle(tester);
      expect(bar, findsOneWidget);
      expect(card, findsOneWidget);
      await shutdown(tester, db);
    });
  });
}
