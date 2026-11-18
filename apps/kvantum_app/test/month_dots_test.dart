import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/month_view.dart';
import 'package:kvantum_app/ui/palette.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;

  /// A month view of [width] px with [titles] on the 12th of November 2026.
  Future<void> boot(
    WidgetTester tester,
    double width,
    List<String> titles, {
    List<String?> colors = const [],
  }) async {
    useSize(tester, size: Size(width, 900));
    db = await newDb();
    final repo = EventRepository(db);
    await tester.runAsync(() async {
      for (var i = 0; i < titles.length; i++) {
        await repo.saveLocal(
          evt(
            'e$i',
            titles[i],
            floating(2026, 11, 12, 9 + i),
            colorId: i < colors.length ? colors[i] : null,
          ),
        );
      }
    });
    final timers = ManualTimers();
    await tester.pumpWidget(
      app(
        const HomePage(),
        db,
        extra: [
          appClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 11, 12, 9),
          ),
          midnightTimerProvider.overrideWithValue(timers.make),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inGrid(Finder f) =>
      find.descendant(of: find.byType(MonthView), matching: f);

  Finder dots() => find.descendant(
    of: find.byKey(const Key('month-dots')),
    matching: find.byType(Container),
  );

  group('a narrow cell (a phone held upright)', () {
    testWidgets('shows one dot per event and no text bars', (tester) async {
      await boot(tester, 360, ['Edzés', 'Fogorvos']);
      expect(find.byKey(const Key('month-dots')), findsOneWidget);
      expect(dots(), findsNWidgets(2));
      expect(inGrid(find.textContaining('Edzés')), findsNothing);
      expect(inGrid(find.textContaining('•')), findsNothing);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('the first dots, then "+N" when there are more', (
      tester,
    ) async {
      await boot(tester, 360, ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(dots(), findsNWidgets(3));
      expect(inGrid(find.text('+3')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('four events still fit as four dots', (tester) async {
      await boot(tester, 360, ['a', 'b', 'c', 'd']);
      expect(dots(), findsNWidgets(4));
      expect(inGrid(find.textContaining('+')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('each dot has the colour of its event', (tester) async {
      await boot(tester, 360, ['a', 'b'], colors: ['7', '11']);
      final colors = [
        for (final c in tester.widgetList<Container>(dots()))
          (c.decoration! as BoxDecoration).color,
      ];
      expect(colors, [eventColor('7'), eventColor('11')]);
      expect(eventColor('7'), isNot(eventColor('11')));
      await shutdown(tester, db);
    });

    testWidgets('a day without events has no dots', (tester) async {
      await boot(tester, 360, []);
      expect(find.byKey(const Key('month-dots')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the event is named in the day list under the grid', (
      tester,
    ) async {
      await boot(tester, 360, ['Edzés']);
      // the chosen day is today, the 12th: its list names the event
      expect(find.text('Edzés'), findsWidgets);
      expect(inGrid(find.text('Edzés')), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('a wider cell', () {
    testWidgets('shows text bars with the time, no dots', (tester) async {
      await boot(tester, 1280, ['Edzés']);
      expect(find.byKey(const Key('month-dots')), findsNothing);
      expect(inGrid(find.text('09:00 Edzés')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a middle width keeps the title and drops the time', (
      tester,
    ) async {
      // 520 px: a cell is ~71 px inner, text bars, but too narrow for "09:00 "
      await boot(tester, 520, ['Edzés']);
      expect(find.byKey(const Key('month-dots')), findsNothing);
      expect(inGrid(find.text('Edzés')), findsOneWidget);
      expect(inGrid(find.textContaining('09:00')), findsNothing);
      await shutdown(tester, db);
    });
  });

  testWidgets('a very small window clips the cells instead of overflowing', (
    tester,
  ) async {
    useSize(tester, size: const Size(320, 420));
    db = await newDb();
    final repo = EventRepository(db);
    await tester.runAsync(() async {
      // (not a workout: its feedback card would take room of its own)
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 11, 12, 9)));
    });
    final timers = ManualTimers();
    await tester.pumpWidget(
      app(
        const HomePage(),
        db,
        extra: [
          appClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 11, 12, 9),
          ),
          midnightTimerProvider.overrideWithValue(timers.make),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // every cell clips what does not fit instead of painting it over the next
    // cell (the content may be taller than the cell: it is laid out freely)
    final clipped = find.descendant(
      of: find.byType(MonthView),
      matching: find.byWidgetPredicate(
        (w) => w is ClipRect && w.child is OverflowBox,
      ),
    );
    expect(clipped, findsNWidgets(42));
    await shutdown(tester, db);
  });
}
