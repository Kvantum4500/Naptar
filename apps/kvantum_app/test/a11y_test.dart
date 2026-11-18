import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/a11y.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

Occurrence occ(
  DateTime startWall,
  DateTime endWall, {
  bool allDay = false,
  String title = 'Edzés',
}) => Occurrence(
  eventId: 'e',
  title: title,
  startUtc: allDay ? startWall : resolveWallClock(bp, startWall),
  endUtc: allDay ? endWall : resolveWallClock(bp, endWall),
  originalStart: startWall,
  allDay: allDay,
  tzid: allDay ? null : bp,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the words', () {
    test('a day is the weekday and the whole date', () {
      expect(
        spokenDay(DateTime.utc(2026, 11, 13)),
        'péntek, 2026. november 13.',
      );
      expect(spokenDay(DateTime.utc(2027, 1, 1)), 'péntek, 2027. január 1.');
    });

    test('a count is said in words', () {
      expect(spokenCount(0), 'nincs esemény');
      expect(spokenCount(1), '1 esemény');
      expect(spokenCount(3), '3 esemény');
    });

    test('a cell: day, count, and only the marks that apply', () {
      final d = DateTime.utc(2026, 11, 12);
      expect(
        spokenCell(day: d, events: 2, today: false, inMonth: true),
        'csütörtök, 2026. november 12., 2 esemény',
      );
      expect(
        spokenCell(day: d, events: 0, today: true, inMonth: true),
        'csütörtök, 2026. november 12., nincs esemény, ma',
      );
      expect(
        spokenCell(day: d, events: 1, today: false, inMonth: false),
        'csütörtök, 2026. november 12., 1 esemény, másik hónap',
      );
      expect(
        spokenCell(day: d, events: 1, today: true, inMonth: false),
        'csütörtök, 2026. november 12., 1 esemény, ma, másik hónap',
      );
    });

    test('a budget row and a row without a budget are one sentence each', () {
      String f(int n) => formatHuf(n);
      expect(
        spokenBudget(
          const BudgetStatus(categoryId: 'c', limit: 10000, spent: 8500),
          'Szórakozás',
          'Közel a kerethez – maradt: ${f(1500)}',
        ),
        'Szórakozás: ${f(8500)} a ${f(10000)} keretből (85%), '
        'Közel a kerethez – maradt: ${f(1500)}',
      );
      expect(
        spokenShare('Közlekedés', 4500, 0.2),
        'Közlekedés: ${f(4500)}, a kiadások 20%-a',
      );
    });

    test('an event: title and time; "egész nap"; a night that goes on', () {
      final d = DateTime.utc(2026, 11, 12);
      final ordinary = occ(
        floating(2026, 11, 12, 9),
        floating(2026, 11, 12, 10, 30),
      );
      expect(spokenEvent(ordinary, d), 'Edzés, 09:00–10:30');
      expect(
        spokenEvent(ordinary, d, withDay: true),
        'Edzés, csütörtök, 2026. november 12., 09:00–10:30',
      );
      final allDay = occ(
        DateTime.utc(2026, 11, 12),
        DateTime.utc(2026, 11, 13),
        allDay: true,
        title: 'Szabadnap',
      );
      expect(spokenEvent(allDay, d), 'Szabadnap, egész nap');
      final night = occ(floating(2026, 11, 12, 22), floating(2026, 11, 13, 2));
      expect(spokenEvent(night, d), 'Edzés, 22:00–02:00');
      expect(
        spokenEvent(night, DateTime.utc(2026, 11, 13)),
        'Edzés, tart tovább, 02:00-ig',
      );
      expect(
        spokenEvent(
          occ(floating(2026, 11, 12, 9), floating(2026, 11, 12, 10), title: ''),
          d,
        ),
        '(nincs cím), 09:00–10:00',
      );
    });
  });

  group('what a screen reader finds', () {
    late AppDatabase db;
    late EventRepository events;
    late RecordRepository records;
    late FinanceRepository fin;
    late ProviderContainer c;
    late SemanticsHandle handle;

    Future<void> boot(
      WidgetTester tester, {
      Size size = const Size(1280, 900),
      Widget home = const HomePage(),
      Future<void> Function()? seed,
    }) async {
      handle = tester.ensureSemantics();
      useSize(tester, size: size);
      db = await newDb();
      events = EventRepository(db);
      records = RecordRepository(db);
      fin = FinanceRepository(db);
      // (before any screen listens: a write that waits for a stream the test
      // is not pumping would never finish)
      if (seed != null) await tester.runAsync(seed);
      await tester.pumpWidget(
        app(
          home,
          db,
          extra: [
            // Thursday 2026-11-12, 10:00 in Budapest
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    }

    Future<void> done(WidgetTester tester) async {
      handle.dispose();
      await shutdown(tester, db);
    }

    Future<void> seedEvents(WidgetTester tester) async {
      await tester.runAsync(
        () => events.saveAll([
          evt('a', 'Fogorvos', floating(2026, 11, 12, 14)),
          evt('b', 'Reggeli edzés', floating(2026, 11, 12, 9)),
          evt(
            'c',
            'Szabadnap',
            floating(2026, 11, 12),
            allDay: true,
            len: const Duration(days: 1),
          ),
        ]),
      );
      await tester.pumpAndSettle();
    }

    SemanticsNode node(WidgetTester tester, String label) =>
        tester.getSemantics(find.bySemanticsLabel(label));

    group('the month', () {
      testWidgets('a day cell has the date, the count and "ma"', (
        tester,
      ) async {
        await boot(tester);
        await seedEvents(tester);
        final cell = node(
          tester,
          'csütörtök, 2026. november 12., 3 esemény, ma',
        );
        expect(
          cell,
          containsSemantics(
            label: 'csütörtök, 2026. november 12., 3 esemény, ma',
            isButton: true,
            hasTapAction: true,
            hasSelectedState: true,
            isSelected: true,
          ),
        );
        await done(tester);
      });

      testWidgets('another day is not selected; an empty day says so', (
        tester,
      ) async {
        await boot(tester);
        final cell = node(tester, 'péntek, 2026. november 13., nincs esemény');
        expect(
          cell,
          containsSemantics(
            isButton: true,
            hasTapAction: true,
            hasSelectedState: true,
            isSelected: false,
          ),
        );
        await done(tester);
      });

      testWidgets('a day of another month says so', (tester) async {
        await boot(tester);
        // the grid of November 2026 starts on Monday 26 October
        expect(
          find.bySemanticsLabel(
            'hétfő, 2026. október 26., nincs esemény, másik hónap',
          ),
          findsOneWidget,
        );
        await done(tester);
      });

      testWidgets('every event is a stop of its own, with its words', (
        tester,
      ) async {
        await boot(tester);
        await seedEvents(tester);
        for (final label in [
          'Fogorvos, 14:00–15:00',
          'Reggeli edzés, 09:00–10:00',
          'Szabadnap, egész nap',
        ]) {
          expect(
            node(tester, label),
            containsSemantics(label: label, isButton: true, hasTapAction: true),
            reason: label,
          );
        }
        await done(tester);
      });

      testWidgets('the words of the cell do not repeat the event titles', (
        tester,
      ) async {
        await boot(tester);
        await seedEvents(tester);
        final cell = node(
          tester,
          'csütörtök, 2026. november 12., 3 esemény, ma',
        );
        expect(cell.label, isNot(contains('Fogorvos')));
        expect(cell.label, isNot(contains('13')));
        await done(tester);
      });

      testWidgets('what does not fit in a cell is one link, with its count', (
        tester,
      ) async {
        await boot(tester);
        await tester.runAsync(
          () => events.saveAll([
            for (var i = 0; i < 7; i++)
              evt('m$i', 'Esemény $i', floating(2026, 11, 12, 8 + i)),
          ]),
        );
        await tester.pumpAndSettle();
        final link = find.bySemanticsLabel(
          RegExp(r'^\d+ további esemény, a nap megnyitása$'),
        );
        expect(link, findsOneWidget);
        expect(
          tester.getSemantics(link),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        await done(tester);
      });

      testWidgets('the number of the day is no stop of its own', (
        tester,
      ) async {
        await boot(tester);
        expect(find.bySemanticsLabel('12'), findsNothing);
        await done(tester);
      });

      testWidgets('the dots of a narrow cell add no stops', (tester) async {
        await boot(tester, size: const Size(360, 800));
        await seedEvents(tester);
        expect(
          find.bySemanticsLabel('csütörtök, 2026. november 12., 3 esemény, ma'),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Fogorvos, 14:00–15:00'), findsNothing);
        await done(tester);
      });
    });

    group('the week and the day', () {
      testWidgets('a day header is read as a date, today as well', (
        tester,
      ) async {
        await boot(tester);
        c.read(viewModeProvider.notifier).set(CalView.week);
        await tester.pumpAndSettle();
        expect(
          node(tester, 'csütörtök, 2026. november 12., ma'),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        expect(
          node(tester, 'péntek, 2026. november 13.'),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        await done(tester);
      });

      testWidgets('an event block has title, day and time', (tester) async {
        await boot(tester);
        await seedEvents(tester);
        c.read(viewModeProvider.notifier).set(CalView.week);
        await tester.pumpAndSettle();
        const label = 'Fogorvos, csütörtök, 2026. november 12., 14:00–15:00';
        expect(
          node(tester, label),
          containsSemantics(label: label, isButton: true, hasTapAction: true),
        );
        await done(tester);
      });

      testWidgets('an all-day bar says "egész nap"', (tester) async {
        await boot(tester);
        await seedEvents(tester);
        c.read(viewModeProvider.notifier).set(CalView.week);
        await tester.pumpAndSettle();
        expect(
          node(tester, 'Szabadnap, csütörtök, 2026. november 12., egész nap'),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        await done(tester);
      });

      testWidgets('the hours down the side are no stops', (tester) async {
        await boot(tester);
        c.read(viewModeProvider.notifier).set(CalView.day);
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('10:00'), findsNothing);
        expect(find.bySemanticsLabel('15:00'), findsNothing);
        await done(tester);
      });
    });

    group('the agenda', () {
      testWidgets('events, tasks and the headings are read as such', (
        tester,
      ) async {
        await boot(tester);
        await seedEvents(tester);
        await tester.runAsync(
          () => records.edit(
            kindTask,
            't',
            taskFields(title: 'Számla befizetése', due: floating(2026, 11, 12)),
          ),
        );
        await tester.runAsync(
          () => records.edit(
            kindTask,
            'l',
            taskFields(title: 'Késő dolog', due: floating(2026, 11, 9)),
          ),
        );
        c.read(viewModeProvider.notifier).set(CalView.agenda);
        await tester.pumpAndSettle();
        expect(
          node(tester, 'Fogorvos, 14:00–15:00'),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        expect(
          node(
            tester,
            'Feladat: Számla befizetése, határidő: 2026. november 12.',
          ),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        expect(
          node(
            tester,
            'Késésben lévő feladat: Késő dolog, határidő: 2026. november 9.',
          ),
          containsSemantics(isButton: true, hasTapAction: true),
        );
        expect(
          node(tester, 'Ma · csütörtök, nov. 12.'),
          containsSemantics(isHeader: true),
        );
        expect(node(tester, 'Késésben'), containsSemantics(isHeader: true));
        await done(tester);
      });
    });

    group('the money', () {
      const tall = Size(900, 1800);

      Future<void> seedBudgets() async {
        await fin.ensureDefaults();
        await fin.saveBudget(
          const FinBudget(categoryId: 'cat-food', limit: 10000),
        );
        await fin.saveBudget(
          const FinBudget(categoryId: 'cat-fun', limit: 10000),
        );
        await fin.saveBudget(
          const FinBudget(categoryId: 'cat-sport', limit: 10000),
        );
        Future<void> tx(String id, int amount, String cat) => fin.saveTx(
          FinTx(
            id: id,
            date: floating(2026, 11, 3),
            amount: amount,
            kind: FinKind.expense,
            categoryId: cat,
            merchant: 'Bolt $id',
          ),
        );
        await tx('1', 3000, 'cat-food'); // 30 %: fine
        await tx('2', 8500, 'cat-fun'); // 85 %: watch out
        await tx('3', 12000, 'cat-sport'); // 120 %: over
      }

      testWidgets('a budget says its level in words, not by colour alone', (
        tester,
      ) async {
        await boot(
          tester,
          home: const FinancePage(),
          size: tall,
          seed: seedBudgets,
        );
        await tester.pumpAndSettle();
        expect(find.text('Maradt: ${formatHuf(7000)}'), findsOneWidget);
        expect(
          find.text('Közel a kerethez – maradt: ${formatHuf(1500)}'),
          findsOneWidget,
        );
        expect(find.text('Túllépve: ${formatHuf(2000)}'), findsOneWidget);
        // and the mark beside it
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
        expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        await done(tester);
      });

      testWidgets('a budget row is one stop, read as one sentence', (
        tester,
      ) async {
        await boot(
          tester,
          home: const FinancePage(),
          size: tall,
          seed: seedBudgets,
        );
        await tester.pumpAndSettle();
        final f = formatHuf;
        for (final label in [
          'Élelmiszer: ${f(3000)} a ${f(10000)} keretből (30%), '
              'Maradt: ${f(7000)}',
          'Szórakozás: ${f(8500)} a ${f(10000)} keretből (85%), '
              'Közel a kerethez – maradt: ${f(1500)}',
          'Sport: ${f(12000)} a ${f(10000)} keretből (120%), '
              'Túllépve: ${f(2000)}',
        ]) {
          expect(node(tester, label), containsSemantics(label: label));
        }
        // the pieces of the row are not stops of their own
        expect(find.bySemanticsLabel('Élelmiszer'), findsNothing);
        expect(
          find.bySemanticsLabel('Maradt: ${formatHuf(7000)}'),
          findsNothing,
        );
        expect(find.bySemanticsLabel('Élelmiszer: 30%'), findsNothing);
        await done(tester);
      });

      testWidgets('the arrow of an entry says income or expense', (
        tester,
      ) async {
        await boot(
          tester,
          home: const FinancePage(),
          size: tall,
          seed: () async {
            await fin.ensureDefaults();
            await fin.saveTx(
              FinTx(
                id: 'i',
                date: floating(2026, 11, 3),
                amount: 500000,
                kind: FinKind.income,
                categoryId: 'cat-salary',
                merchant: 'Munkahely',
              ),
            );
            await fin.saveTx(
              FinTx(
                id: 'x',
                date: floating(2026, 11, 4),
                amount: 2500,
                kind: FinKind.expense,
                merchant: 'Pékség',
              ),
            );
          },
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tételek'));
        await tester.pumpAndSettle();
        Finder icon(String word) =>
            find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == word);
        expect(icon('Bevétel'), findsOneWidget);
        expect(icon('Kiadás'), findsOneWidget);
        await done(tester);
      });
    });
  });
}
