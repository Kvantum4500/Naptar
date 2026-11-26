import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/a11y.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the words for a screen reader', () {
    final d = DateTime.utc(2026, 12, 24);

    test('a holiday is named between the count and "today"', () {
      expect(
        spokenCell(
          day: d,
          events: 0,
          today: true,
          inMonth: true,
          special: huDayInfo(d),
        ),
        'csütörtök, 2026. december 24., nincs esemény, '
        'Munkaszüneti nap: Szenteste, ma',
      );
    });

    test('a moved working Saturday is named too', () {
      final sat = DateTime.utc(2026, 1, 10);
      expect(
        spokenCell(
          day: sat,
          events: 1,
          today: false,
          inMonth: false,
          special: huDayInfo(sat),
        ),
        'szombat, 2026. január 10., 1 esemény, '
        'Áthelyezett munkanap (szombat), másik hónap',
      );
    });

    test('an ordinary day says nothing more than before', () {
      expect(
        spokenCell(
          day: DateTime.utc(2026, 11, 12),
          events: 2,
          today: false,
          inMonth: true,
        ),
        'csütörtök, 2026. november 12., 2 esemény',
      );
    });
  });

  group('on the screen', () {
    late AppDatabase db;
    late ProviderContainer c;

    Future<void> boot(
      WidgetTester tester,
      DateTime clock, {
      Size size = const Size(1280, 900),
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          extra: [
            appClockProvider.overrideWithValue(() => clock),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
    }

    Color? colourOf(WidgetTester tester, String number) =>
        tester.widget<Text>(find.text(number)).style?.color;

    ColorScheme scheme(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(HomePage))).colorScheme;

    testWidgets('month: the number of a holiday is red and the cell names it', (
      tester,
    ) async {
      // Sunday 20 December 2026, noon
      await boot(tester, DateTime.utc(2026, 12, 20, 11));
      final s = scheme(tester);
      expect(colourOf(tester, '24'), s.error);
      expect(colourOf(tester, '25'), s.error);
      expect(colourOf(tester, '26'), s.error);
      // an ordinary day is not
      expect(colourOf(tester, '22'), s.onSurface);
      // the wide cell says which holiday it is, in the same red
      expect(find.text('Szenteste'), findsOneWidget);
      expect(find.text('Karácsony'), findsOneWidget);
      expect(find.text('Karácsony másnapja'), findsOneWidget);
      expect(colourOf(tester, 'Szenteste'), s.error);
      await shutdown(tester, db);
    });

    testWidgets('month: a holiday outside the month is red, but dimmed', (
      tester,
    ) async {
      // the December grid reaches Friday 1 January 2027 (a holiday) and
      // Saturday the 2nd (an ordinary day)
      await boot(tester, DateTime.utc(2026, 12, 20, 11));
      final s = scheme(tester);
      Color? last(String number) =>
          tester.widgetList<Text>(find.text(number)).last.style?.color;
      expect(last('1'), s.error.withValues(alpha: .6));
      expect(last('2'), s.onSurfaceVariant);
      // and in the month itself it is not dimmed
      expect(colourOf(tester, '25'), s.error);
      await shutdown(tester, db);
    });

    testWidgets('month: a narrow cell has the red number, not the words', (
      tester,
    ) async {
      await boot(
        tester,
        DateTime.utc(2026, 12, 20, 11),
        size: const Size(360, 800),
      );
      expect(colourOf(tester, '24'), scheme(tester).error);
      expect(find.text('Szenteste'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('month: a screen reader hears the holiday in the cell', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester, DateTime.utc(2026, 12, 20, 11));
      expect(
        find.bySemanticsLabel(
          RegExp(
            'csütörtök, 2026. december 24., nincs esemény, '
            'Munkaszüneti nap: Szenteste',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Munkaszüneti nap')),
        findsNWidgets(4),
        reason: 'the 24th, 25th and 26th, and 1 January (the grid reaches it)',
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('month: the day panel says what the selected day is', (
      tester,
    ) async {
      await boot(tester, DateTime.utc(2026, 12, 20, 11));
      expect(find.byKey(const Key('day-special')), findsNothing);
      c.read(selectedDayProvider.notifier).set(floating(2026, 12, 24));
      await tester.pumpAndSettle();
      final t = tester.widget<Text>(find.byKey(const Key('day-special')));
      expect(t.data, 'Munkaszüneti nap: Szenteste');
      expect(t.style?.color, scheme(tester).error);
      await shutdown(tester, db);
    });

    testWidgets('month: a moved working Saturday is told, but not in red', (
      tester,
    ) async {
      await boot(tester, DateTime.utc(2026, 1, 5, 11));
      c.read(selectedDayProvider.notifier).set(floating(2026, 1, 10));
      await tester.pumpAndSettle();
      final t = tester.widget<Text>(find.byKey(const Key('day-special')));
      expect(t.data, 'Áthelyezett munkanap (szombat)');
      expect(t.style?.color, scheme(tester).onSurfaceVariant);
      expect(colourOf(tester, '10'), scheme(tester).onSurface);
      expect(find.text('Munkanap'), findsOneWidget);
      expect(colourOf(tester, 'Munkanap'), scheme(tester).onSurfaceVariant);
      await shutdown(tester, db);
    });

    testWidgets('month: the bridge day is red like a holiday', (tester) async {
      await boot(tester, DateTime.utc(2026, 1, 5, 11));
      expect(find.text('Pihenőnap'), findsOneWidget);
      expect(colourOf(tester, 'Pihenőnap'), scheme(tester).error);
      // the number in the same header as the words (2 January)
      final header = find.ancestor(
        of: find.text('Pihenőnap'),
        matching: find.byType(Row),
      );
      final number = find.descendant(
        of: header.first,
        matching: find.text('2'),
      );
      expect(tester.widget<Text>(number).style?.color, scheme(tester).error);
      await shutdown(tester, db);
    });

    testWidgets('agenda: holidays are listed even with nothing on them', (
      tester,
    ) async {
      await boot(tester, DateTime.utc(2026, 12, 20, 11));
      await tester.tap(find.text('Napirend'));
      await tester.pumpAndSettle();
      expect(find.text('csütörtök, dec. 24.'), findsOneWidget);
      expect(find.text('péntek, dec. 25.'), findsOneWidget);
      expect(find.text('szombat, dec. 26.'), findsOneWidget);
      expect(find.text('Munkaszüneti nap: Szenteste'), findsOneWidget);
      expect(
        colourOf(tester, 'Munkaszüneti nap: Szenteste'),
        scheme(tester).error,
      );
      expect(find.text('Munkaszüneti nap: Karácsony'), findsOneWidget);
      expect(find.text('Munkaszüneti nap: Karácsony másnapja'), findsOneWidget);
      // the ordinary days with nothing are still left out
      expect(find.textContaining('dec. 22.'), findsNothing);
      expect(find.textContaining('Nincs esemény'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('agenda: a moved working Saturday is told, but not in red', (
      tester,
    ) async {
      await boot(tester, DateTime.utc(2026, 1, 5, 11));
      await tester.tap(find.text('Napirend'));
      await tester.pumpAndSettle();
      expect(find.text('szombat, jan. 10.'), findsOneWidget);
      expect(find.text('Áthelyezett munkanap (szombat)'), findsOneWidget);
      expect(
        colourOf(tester, 'Áthelyezett munkanap (szombat)'),
        scheme(tester).onSurfaceVariant,
      );
      await shutdown(tester, db);
    });

    testWidgets('week: the number of a moved working Saturday is not red', (
      tester,
    ) async {
      // the week of 5-11 January 2026: the 10th is a worked Saturday
      await boot(tester, DateTime.utc(2026, 1, 7, 11));
      await tester.tap(find.text('Hét'));
      await tester.pumpAndSettle();
      final s = scheme(tester);
      expect(
        tester.widgetList<Text>(find.text('10')).first.style?.color,
        isNot(s.error),
      );
      // (and a plain Sunday of the same week is red: the 11th is no holiday,
      // the weekend alone does not colour a number)
      expect(
        tester.widgetList<Text>(find.text('11')).first.style?.color,
        isNot(s.error),
      );
      await shutdown(tester, db);
    });

    testWidgets('week: the header numbers of the days off are red', (
      tester,
    ) async {
      // the week of 21-27 December 2026
      await boot(tester, DateTime.utc(2026, 12, 23, 11));
      await tester.tap(find.text('Hét'));
      await tester.pumpAndSettle();
      final s = scheme(tester);
      for (final n in ['24', '25', '26']) {
        final t = tester.widgetList<Text>(find.text(n)).first;
        expect(t.style?.color, s.error, reason: n);
      }
      expect(
        tester.widgetList<Text>(find.text('23')).first.style?.color,
        isNot(s.error),
      );
      await shutdown(tester, db);
    });

    testWidgets('week: a screen reader hears the holiday in the header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester, DateTime.utc(2026, 12, 23, 11));
      await tester.tap(find.text('Hét'));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(
          'csütörtök, 2026. december 24., Munkaszüneti nap: Szenteste',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('szerda, 2026. december 23., ma'),
        findsOneWidget,
      );
      handle.dispose();
      await shutdown(tester, db);
    });
  });
}
