import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/agenda_view.dart';
import 'package:kvantum_app/ui/day_utils.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/month_view.dart';
import 'package:kvantum_app/ui/swipe_nav.dart';
import 'package:kvantum_app/ui/time_grid.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('what counts as a swipe', () {
    test('a fast flick counts even when it is short', () {
      expect(swipeDirection(distance: -20, velocity: -900), 1);
      expect(swipeDirection(distance: 20, velocity: 900), -1);
    });

    test('a slow drag counts when it is long enough', () {
      expect(swipeDirection(distance: -100, velocity: -100), 1);
      expect(swipeDirection(distance: 100, velocity: 100), -1);
    });

    test('a short, slow drag is not a swipe', () {
      expect(swipeDirection(distance: -30, velocity: -100), 0);
      expect(swipeDirection(distance: 30, velocity: 100), 0);
      expect(swipeDirection(distance: 0, velocity: 0), 0);
    });

    test('the limits are exact', () {
      expect(swipeDirection(distance: -swipeMinDistance, velocity: 0), 1);
      expect(
        swipeDirection(distance: -(swipeMinDistance - 0.1), velocity: 0),
        0,
      );
      expect(swipeDirection(distance: 0, velocity: -swipeMinVelocity), 1);
      expect(swipeDirection(distance: 0, velocity: -(swipeMinVelocity - 1)), 0);
    });

    test('the speed decides over the distance', () {
      // dragged to the right, but flicked back to the left at the end
      expect(swipeDirection(distance: 90, velocity: -800), 1);
    });
  });

  test('the same day in another month is clipped to its length', () {
    final feb = DateTime.utc(2027, 2, 1);
    expect(
      sameDayIn(DateTime.utc(2027, 1, 31), feb),
      DateTime.utc(2027, 2, 28),
    );
    expect(
      sameDayIn(DateTime.utc(2028, 1, 31), DateTime.utc(2028, 2)),
      DateTime.utc(2028, 2, 29),
    );
    expect(
      sameDayIn(DateTime.utc(2026, 3, 31), DateTime.utc(2026, 4)),
      DateTime.utc(2026, 4, 30),
    );
    expect(
      sameDayIn(DateTime.utc(2026, 11, 13), DateTime.utc(2026, 12)),
      DateTime.utc(2026, 12, 13),
    );
    expect(
      sameDayIn(DateTime.utc(2026, 12, 15), DateTime.utc(2027, 1)),
      DateTime.utc(2027, 1, 15),
    );
    expect(
      sameDayIn(DateTime.utc(2026, 1, 1), DateTime.utc(2025, 12)),
      DateTime.utc(2025, 12, 1),
    );
  });

  group('on the calendar', () {
    late AppDatabase db;
    late EventRepository events;
    late ProviderContainer c;

    Future<void> boot(
      WidgetTester tester, {
      Size size = const Size(1280, 900),
      CalView view = CalView.month,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      events = EventRepository(db);
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          extra: [
            // Wednesday 2026-11-11, noon in Budapest
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 11, 11),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
      if (view != CalView.month) {
        c.read(viewModeProvider.notifier).set(view);
        await tester.pumpAndSettle();
      }
    }

    DateTime sel() => c.read(selectedDayProvider);
    DateTime month() => c.read(visibleMonthProvider);

    Future<void> flingLeft(WidgetTester tester, Finder f) async {
      await tester.fling(f, const Offset(-300, 0), 1200);
      await tester.pumpAndSettle();
    }

    Future<void> flingRight(WidgetTester tester, Finder f) async {
      await tester.fling(f, const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
    }

    group('the month', () {
      testWidgets(
        'a swipe to the left shows the next month, to the right the previous',
        (tester) async {
          await boot(tester);
          expect(month(), DateTime.utc(2026, 11));
          await flingLeft(tester, find.byType(MonthView));
          expect(month(), DateTime.utc(2026, 12));
          await flingLeft(tester, find.byType(MonthView));
          expect(month(), DateTime.utc(2027, 1));
          await flingRight(tester, find.byType(MonthView));
          await flingRight(tester, find.byType(MonthView));
          await flingRight(tester, find.byType(MonthView));
          expect(month(), DateTime.utc(2026, 10));
          await shutdown(tester, db);
        },
      );

      testWidgets('the chosen day goes with the month', (tester) async {
        await boot(tester);
        expect(sel(), DateTime.utc(2026, 11, 11));
        await flingLeft(tester, find.byType(MonthView));
        expect(sel(), DateTime.utc(2026, 12, 11));
        await shutdown(tester, db);
      });

      testWidgets('the arrows keep the chosen day in the month, too', (
        tester,
      ) async {
        await boot(tester);
        c.read(selectedDayProvider.notifier).set(DateTime.utc(2027, 1, 31));
        c.read(visibleMonthProvider.notifier).set(DateTime.utc(2027, 1));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Következő'));
        await tester.pumpAndSettle();
        expect(month(), DateTime.utc(2027, 2));
        expect(sel(), DateTime.utc(2027, 2, 28)); // February is shorter
        await tester.tap(find.byTooltip('Előző'));
        await tester.pumpAndSettle();
        expect(month(), DateTime.utc(2027, 1));
        expect(sel(), DateTime.utc(2027, 1, 28)); // and does not grow back
        await shutdown(tester, db);
      });

      testWidgets('the keyboard keeps it in the month, too', (tester) async {
        await boot(tester);
        c.read(selectedDayProvider.notifier).set(DateTime.utc(2026, 3, 31));
        c.read(visibleMonthProvider.notifier).set(DateTime.utc(2026, 3));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(sel(), DateTime.utc(2026, 4, 30));
        await shutdown(tester, db);
      });

      testWidgets('a short slow drag does not turn the month', (tester) async {
        await boot(tester);
        await tester.timedDrag(
          find.byType(MonthView),
          const Offset(-40, 0),
          const Duration(milliseconds: 600),
        );
        await tester.pumpAndSettle();
        expect(month(), DateTime.utc(2026, 11));
        await shutdown(tester, db);
      });

      testWidgets('a long slow drag does', (tester) async {
        await boot(tester);
        await tester.timedDrag(
          find.byType(MonthView),
          const Offset(-200, 0),
          const Duration(milliseconds: 800),
        );
        await tester.pumpAndSettle();
        expect(month(), DateTime.utc(2026, 12));
        await shutdown(tester, db);
      });

      // a drag of 300 px in 100 ms, in small steps (as a hand does it)
      Future<void> dragLeft(WidgetTester tester, PointerDeviceKind kind) async {
        final g = await tester.startGesture(
          tester.getCenter(find.byType(MonthView)),
          kind: kind,
        );
        for (var i = 0; i < 5; i++) {
          await g.moveBy(const Offset(-60, 0));
          await tester.pump(const Duration(milliseconds: 20));
        }
        await g.up();
        await tester.pumpAndSettle();
      }

      testWidgets(
        'a finger drag in small steps turns the month (the control)',
        (tester) async {
          await boot(tester);
          await dragLeft(tester, PointerDeviceKind.touch);
          expect(month(), DateTime.utc(2026, 12));
          await shutdown(tester, db);
        },
      );

      testWidgets('the same drag with a mouse does not move the calendar', (
        tester,
      ) async {
        await boot(tester);
        await dragLeft(tester, PointerDeviceKind.mouse);
        expect(month(), DateTime.utc(2026, 11));
        await shutdown(tester, db);
      });

      testWidgets('a pen swipes like a finger', (tester) async {
        await boot(tester);
        await dragLeft(tester, PointerDeviceKind.stylus);
        expect(month(), DateTime.utc(2026, 12));
        await shutdown(tester, db);
      });

      testWidgets('a tap on a day still chooses it', (tester) async {
        await boot(tester);
        await tester.tap(find.text('18').first);
        await tester.pumpAndSettle();
        expect(sel(), DateTime.utc(2026, 11, 18));
        expect(month(), DateTime.utc(2026, 11));
        await shutdown(tester, db);
      });

      testWidgets('under the grid a swipe moves the day, not the month', (
        tester,
      ) async {
        await boot(tester, size: const Size(400, 900));
        // the day panel (an hour-scale timeline) is the only TimeGrid
        await flingLeft(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 12));
        expect(month(), DateTime.utc(2026, 11));
        await flingRight(tester, find.byType(TimeGrid));
        await flingRight(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 10));
        await shutdown(tester, db);
      });

      testWidgets('the day panel follows the day into the next month', (
        tester,
      ) async {
        await boot(tester, size: const Size(400, 900));
        c.read(selectedDayProvider.notifier).set(DateTime.utc(2026, 11, 30));
        await tester.pumpAndSettle();
        await flingLeft(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 12, 1));
        expect(month(), DateTime.utc(2026, 12));
        await shutdown(tester, db);
      });
    });

    group('week, day and agenda', () {
      testWidgets('the week moves by 7 days', (tester) async {
        await boot(tester, view: CalView.week);
        await flingLeft(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 18));
        await flingRight(tester, find.byType(TimeGrid));
        await flingRight(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 4));
        await shutdown(tester, db);
      });

      testWidgets('the day moves by one day', (tester) async {
        await boot(tester, view: CalView.day);
        await flingLeft(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 12));
        await flingRight(tester, find.byType(TimeGrid));
        await flingRight(tester, find.byType(TimeGrid));
        expect(sel(), DateTime.utc(2026, 11, 10));
        await shutdown(tester, db);
      });

      testWidgets('the agenda moves by 14 days', (tester) async {
        await boot(tester, view: CalView.agenda);
        await flingLeft(tester, find.byType(AgendaView));
        expect(sel(), DateTime.utc(2026, 11, 25));
        await flingRight(tester, find.byType(AgendaView));
        await flingRight(tester, find.byType(AgendaView));
        expect(sel(), DateTime.utc(2026, 10, 28));
        await shutdown(tester, db);
      });

      testWidgets('a vertical scroll does not step', (tester) async {
        await boot(tester, view: CalView.week);
        await tester.drag(
          find.descendant(
            of: find.byType(TimeGrid),
            matching: find.byType(SingleChildScrollView),
          ),
          const Offset(0, -200),
        );
        await tester.pumpAndSettle();
        expect(sel(), DateTime.utc(2026, 11, 11));
        await shutdown(tester, db);
      });

      testWidgets('a tap on an empty hour still opens a new event', (
        tester,
      ) async {
        await boot(tester, view: CalView.day);
        await tester.tapAt(tester.getCenter(find.byType(TimeGrid)));
        await tester.pumpAndSettle();
        expect(find.text('Új esemény'), findsWidgets);
        await shutdown(tester, db);
      });
    });

    group('the title of a week', () {
      Future<void> weekOf(WidgetTester tester, DateTime day) async {
        await boot(tester, view: CalView.week);
        c.read(selectedDayProvider.notifier).set(day);
        await tester.pumpAndSettle();
      }

      testWidgets('inside a month', (tester) async {
        await weekOf(tester, DateTime.utc(2026, 11, 11));
        expect(find.text('2026. nov. 9. – 15.'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('over a month boundary (one dot at the end)', (tester) async {
        await weekOf(tester, DateTime.utc(2026, 11, 30));
        expect(find.text('2026. nov. 30. – dec. 6.'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('over New Year it names the second year', (tester) async {
        await weekOf(tester, DateTime.utc(2026, 12, 29));
        expect(find.text('2026. dec. 28. – 2027. jan. 3.'), findsOneWidget);
        await shutdown(tester, db);
      });
    });

    group('no empty page while it loads', () {
      testWidgets('the next week has its events at once', (tester) async {
        await boot(tester, view: CalView.week);
        await tester.runAsync(
          () => events.saveLocal(
            evt('n', 'Jövő heti edzés', floating(2026, 11, 19, 9)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Jövő heti edzés'), findsNothing);
        await tester.tap(find.byTooltip('Következő'));
        await tester.pump(); // ONE frame
        expect(find.text('Jövő heti edzés'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the previous week, too', (tester) async {
        await boot(tester, view: CalView.week);
        await tester.runAsync(
          () => events.saveLocal(
            evt('p', 'Múlt heti edzés', floating(2026, 11, 3, 9)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Előző'));
        await tester.pump();
        expect(find.text('Múlt heti edzés'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the next day', (tester) async {
        await boot(tester, view: CalView.day);
        await tester.runAsync(
          () => events.saveLocal(
            evt('d', 'Holnapi edzés', floating(2026, 11, 12, 9)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Következő'));
        await tester.pump();
        expect(find.text('Holnapi edzés'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the next month', (tester) async {
        await boot(tester);
        await tester.runAsync(
          () => events.saveLocal(
            evt('m', 'Decemberi edzés', floating(2026, 12, 20, 9)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Következő'));
        await tester.pump();
        expect(find.textContaining('Decemberi edzés'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the next 14 days of the agenda', (tester) async {
        await boot(tester, view: CalView.agenda);
        await tester.runAsync(
          () => events.saveLocal(
            evt('a', 'Későbbi edzés', floating(2026, 11, 30, 9)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Következő'));
        await tester.pump();
        expect(find.text('Későbbi edzés'), findsOneWidget);
        await shutdown(tester, db);
      });
    });

    group('the arrows of the bar', () {
      Future<void> at(WidgetTester tester, double w) =>
          boot(tester, size: Size(w, 800));

      for (final w in [320.0, 360.0, 400.0, 439.0]) {
        testWidgets('are not there at ${w.toInt()} px: the swipe does it', (
          tester,
        ) async {
          await at(tester, w);
          expect(find.byTooltip('Előző'), findsNothing);
          expect(find.byTooltip('Következő'), findsNothing);
          expect(find.byTooltip('Keresés'), findsOneWidget);
          expect(find.byTooltip('Nézet'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shutdown(tester, db);
        });
      }

      for (final w in [440.0, 600.0, 820.0, 1280.0]) {
        testWidgets('are there at ${w.toInt()} px', (tester) async {
          await at(tester, w);
          expect(find.byTooltip('Előző'), findsOneWidget);
          expect(find.byTooltip('Következő'), findsOneWidget);
          expect(find.byTooltip('Keresés'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shutdown(tester, db);
        });
      }

      testWidgets('a screen reader keeps them on a phone', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await at(tester, 360);
        expect(find.byTooltip('Előző'), findsOneWidget);
        expect(find.byTooltip('Következő'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });

      testWidgets('without them the swipe still steps on a phone', (
        tester,
      ) async {
        await at(tester, 360);
        await flingLeft(tester, find.byType(MonthView));
        expect(month(), DateTime.utc(2026, 12));
        await shutdown(tester, db);
      });
    });
  });
}
