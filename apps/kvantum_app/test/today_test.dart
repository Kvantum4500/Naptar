import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/ui/checkin.dart';
import 'package:kvantum_app/ui/day_utils.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('todayIn: the day of the display zone, not of the device', () {
    test('winter and summer offsets', () {
      // CET = UTC+1: 23:30 UTC is already half past midnight
      expect(
        todayIn(DateTime.utc(2026, 11, 11, 22, 59)),
        floating(2026, 11, 11),
      );
      expect(todayIn(DateTime.utc(2026, 11, 11, 23)), floating(2026, 11, 12));
      // CEST = UTC+2: the new day starts at 22:00 UTC
      expect(todayIn(DateTime.utc(2026, 7, 11, 21, 59)), floating(2026, 7, 11));
      expect(todayIn(DateTime.utc(2026, 7, 11, 22)), floating(2026, 7, 12));
    });

    test('year and month edges', () {
      expect(todayIn(DateTime.utc(2026, 12, 31, 23)), floating(2027, 1, 1));
      expect(todayIn(DateTime.utc(2026, 2, 28, 23)), floating(2026, 3, 1));
    });

    test('the zone is a parameter', () {
      final now = DateTime.utc(2026, 11, 11, 3);
      expect(todayIn(now), floating(2026, 11, 11));
      expect(todayIn(now, tz: 'America/New_York'), floating(2026, 11, 10));
    });
  });

  group('todayProvider', () {
    late ManualTimers timers;
    late DateTime clock;
    late ProviderContainer c;

    ProviderContainer make(DateTime start) {
      clock = start;
      timers = ManualTimers();
      return ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => clock),
          midnightTimerProvider.overrideWithValue(timers.make),
        ],
      );
    }

    tearDown(() => c.dispose());

    test('starts from the clock and waits for the next midnight', () {
      // 22:30 in Budapest
      c = make(DateTime.utc(2026, 11, 11, 21, 30));
      expect(c.read(todayProvider), floating(2026, 11, 11));
      expect(timers.live, 1);
      expect(
        timers.current.wait,
        const Duration(hours: 1, minutes: 30, seconds: 1),
      );
    });

    test('the wait follows the real length of the day', () {
      // spring: the 29th of March has 23 hours (clock 00:30 CET)
      c = make(DateTime.utc(2026, 3, 28, 23, 30));
      c.read(todayProvider);
      expect(
        timers.current.wait,
        const Duration(hours: 22, minutes: 30, seconds: 1),
      );
      c.dispose();
      // autumn: the 25th of October has 25 hours (clock 00:30 CEST)
      c = make(DateTime.utc(2026, 10, 24, 22, 30));
      c.read(todayProvider);
      expect(
        timers.current.wait,
        const Duration(hours: 24, minutes: 30, seconds: 1),
      );
    });

    test('at midnight the day changes and the next midnight is awaited', () {
      c = make(DateTime.utc(2026, 11, 11, 21, 30));
      final seen = <DateTime>[];
      c.listen(todayProvider, (_, now) => seen.add(now), fireImmediately: true);
      clock = DateTime.utc(2026, 11, 11, 23, 0, 1);
      timers.current.fire();
      expect(seen, [floating(2026, 11, 11), floating(2026, 11, 12)]);
      expect(timers.live, 1, reason: 'exactly one timer is waiting');
      expect(timers.current.wait, const Duration(hours: 24));
    });

    test('an early wake-up changes nothing and waits again', () {
      c = make(DateTime.utc(2026, 11, 11, 21, 30));
      c.read(todayProvider);
      clock = DateTime.utc(2026, 11, 11, 22, 59, 59);
      timers.current.fire();
      expect(c.read(todayProvider), floating(2026, 11, 11));
      expect(timers.live, 1);
      expect(timers.current.wait, const Duration(seconds: 2));
    });

    test('coming back to the front catches up with a clock that moved on', () {
      c = make(DateTime.utc(2026, 11, 11, 12));
      c.read(todayProvider);
      // the device slept for two days; the timer never fired
      clock = DateTime.utc(2026, 11, 13, 8);
      c.read(todayProvider.notifier).refresh();
      expect(c.read(todayProvider), floating(2026, 11, 13));
      expect(timers.live, 1);
    });

    test('leaving cancels the timer', () {
      c = make(DateTime.utc(2026, 11, 11, 12));
      c.read(todayProvider);
      expect(timers.live, 1);
      c.dispose();
      expect(timers.live, 0);
    });
  });

  group('who follows the new day', () {
    late ManualTimers timers;
    late DateTime clock;
    late ProviderContainer c;
    ProviderContainer make(DateTime start) {
      clock = start;
      timers = ManualTimers();
      return ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => clock),
          midnightTimerProvider.overrideWithValue(timers.make),
        ],
      );
    }

    void midnight(DateTime next) {
      clock = next;
      timers.current.fire();
    }

    tearDown(() => c.dispose());

    test('the day and the month that showed "today" move on with it', () {
      c = make(DateTime.utc(2026, 11, 30, 12));
      c.listen(selectedDayProvider, (_, _) {});
      c.listen(visibleMonthProvider, (_, _) {});
      expect(c.read(selectedDayProvider), floating(2026, 11, 30));
      expect(c.read(visibleMonthProvider), floating(2026, 11, 1));
      midnight(DateTime.utc(2026, 11, 30, 23, 0, 5));
      expect(c.read(selectedDayProvider), floating(2026, 12, 1));
      expect(c.read(visibleMonthProvider), floating(2026, 12, 1));
    });

    test('a day or month the user went to stays where it is', () {
      c = make(DateTime.utc(2026, 11, 30, 12));
      c.listen(selectedDayProvider, (_, _) {});
      c.listen(visibleMonthProvider, (_, _) {});
      c.read(selectedDayProvider.notifier).set(floating(2026, 11, 3));
      c.read(visibleMonthProvider.notifier).set(floating(2026, 9, 1));
      midnight(DateTime.utc(2026, 11, 30, 23, 0, 5));
      expect(c.read(selectedDayProvider), floating(2026, 11, 3));
      expect(c.read(visibleMonthProvider), floating(2026, 9, 1));
    });

    test('the month does not move when only the day changes inside it', () {
      c = make(DateTime.utc(2026, 11, 11, 12));
      c.listen(selectedDayProvider, (_, _) {});
      c.listen(visibleMonthProvider, (_, _) {});
      midnight(DateTime.utc(2026, 11, 11, 23, 0, 5));
      expect(c.read(selectedDayProvider), floating(2026, 11, 12));
      expect(c.read(visibleMonthProvider), floating(2026, 11, 1));
    });
  });

  group('the screens', () {
    late AppDatabase db;
    // 00:30 on the 12th in Budapest, still the 11th at UTC
    final lateEvening = DateTime.utc(2026, 11, 11, 23, 30);

    testWidgets('"Ma" goes to the day of the display zone', (tester) async {
      useSize(tester);
      db = await newDb();
      final timers = ManualTimers();
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          extra: [
            appClockProvider.overrideWithValue(() => lateEvening),
            midnightTimerProvider.overrideWithValue(timers.make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      expect(container.read(selectedDayProvider), floating(2026, 11, 12));

      container.read(selectedDayProvider.notifier).set(floating(2026, 11, 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ma'));
      await tester.pumpAndSettle();
      expect(container.read(selectedDayProvider), floating(2026, 11, 12));
      await shutdown(tester, db);
    });

    testWidgets('tasks and the check-in count the display-zone day', (
      tester,
    ) async {
      useSize(tester);
      db = await newDb();
      final repo = RecordRepository(db);
      await tester.pumpWidget(
        app(
          const Scaffold(
            body: Column(
              children: [
                CheckInBanner(),
                Expanded(child: TasksPage()),
              ],
            ),
          ),
          db,
          extra: [
            appClockProvider.overrideWithValue(() => lateEvening),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle(); // the first reads end before we write
      // one write per runAsync: two in one closure wait for each other, as the
      // first one's change notice needs the frames the closure holds back
      await tester.runAsync(
        () => repo.edit(
          kindTask,
          'a',
          taskFields(title: 'Tegnapi', due: floating(2026, 11, 11)),
        ),
      );
      await tester.runAsync(
        () => repo.edit(
          kindTask,
          'b',
          taskFields(title: 'Mai', due: floating(2026, 11, 12)),
        ),
      );
      await tester.pumpAndSettle();
      // at UTC it is still the 11th: by that count "Tegnapi" would be today
      expect(find.text('Késésben (1)'), findsOneWidget);
      expect(find.text('Ma (1)'), findsOneWidget);
      await tester.tap(find.text('Kitöltöm'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('physical-4')));
      await tester.pump();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(
        () => repo.get(kindCheckIn, checkInId(floating(2026, 11, 12))),
      );
      expect(saved, isNotNull, reason: 'the check-in is for the 12th');
      await shutdown(tester, db);
    });

    testWidgets('coming back to the front catches up with the day', (
      tester,
    ) async {
      useSize(tester);
      db = await newDb();
      var clock = DateTime.utc(2026, 11, 11, 12);
      await tester.pumpWidget(
        app(
          const RootShell(),
          db,
          extra: [
            appClockProvider.overrideWithValue(() => clock),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RootShell)),
      );
      expect(container.read(todayProvider), floating(2026, 11, 11));

      // the device slept for two days; the midnight timer never fired
      clock = DateTime.utc(2026, 11, 13, 8);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(container.read(todayProvider), floating(2026, 11, 13));
      await shutdown(tester, db);
    });
  });
}
