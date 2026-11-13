import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/finance_editors.dart';
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

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late FinanceRepository fin;
  late ProviderContainer c;

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db);
    fin = FinanceRepository(db);
    await tester.pumpWidget(
      app(
        const HomePage(),
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
    c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
  }

  Future<void> seedEvent(
    WidgetTester tester,
    String id,
    String title,
    DateTime start, {
    String? rrule,
    String location = '',
  }) => tester.runAsync(
    () => events.saveLocal(
      evt(id, title, start, rrule: rrule).copyWith(location: location),
    ),
  );

  Future<void> seedTask(WidgetTester tester, String id, String title) => tester
      .runAsync(() => records.edit(kindTask, id, taskFields(title: title)));

  Future<void> seedTx(
    WidgetTester tester,
    String id,
    String merchant,
    int amount, {
    String cat = 'cat-food',
  }) => tester.runAsync(() async {
    await fin.ensureDefaults();
    await fin.saveTx(
      FinTx(
        id: id,
        date: floating(2026, 11, 3),
        amount: amount,
        kind: FinKind.expense,
        merchant: merchant,
        categoryId: cat,
      ),
    );
  });

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Keresés'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String q) async {
    await tester.enterText(find.byKey(const Key('search-field')), q);
    await tester.pumpAndSettle();
  }

  group('opening it', () {
    testWidgets('the search icon of the calendar bar opens the page', (
      tester,
    ) async {
      await boot(tester);
      expect(find.byKey(const Key('search-field')), findsNothing);
      await openSearch(tester);
      expect(find.byKey(const Key('search-field')), findsOneWidget);
      expect(find.textContaining('Írj be legalább két betűt'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('Ctrl+F opens it from the calendar, Esc closes it', (
      tester,
    ) async {
      await boot(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-field')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-field')), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a plain F (no Ctrl) does not open it', (tester) async {
      await boot(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-field')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('it works at the width of a phone, too', (tester) async {
      await boot(tester, size: const Size(360, 800));
      await openSearch(tester);
      await seedEvent(tester, 'a', 'Orvos', floating(2026, 11, 20, 9));
      await type(tester, 'orvos');
      expect(find.text('Orvos'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });

  group('what it finds', () {
    testWidgets('events, tasks and money entries, each in its own group', (
      tester,
    ) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Orvos', floating(2026, 11, 20, 9));
      await seedTask(tester, 't', 'Orvosi időpont kérése');
      await seedTx(tester, 'x', 'Orvosi rendelő', 8000);
      await openSearch(tester);
      await type(tester, 'orvos');
      expect(find.text('Események (1)'), findsOneWidget);
      expect(find.text('Feladatok (1)'), findsOneWidget);
      expect(find.text('Pénzügyek (1)'), findsOneWidget);
      expect(find.text('Orvos'), findsOneWidget);
      expect(find.text('Orvosi időpont kérése'), findsOneWidget);
      expect(find.text('Orvosi rendelő'), findsOneWidget);
      // the groups come in this order
      final ev = tester.getTopLeft(find.text('Események (1)')).dy;
      final tk = tester.getTopLeft(find.text('Feladatok (1)')).dy;
      final tx = tester.getTopLeft(find.text('Pénzügyek (1)')).dy;
      expect(ev, lessThan(tk));
      expect(tk, lessThan(tx));
      await shutdown(tester, db);
    });

    testWidgets('case and accents do not matter', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Édes élet', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'EDES');
      expect(find.text('Édes élet'), findsOneWidget);
      await type(tester, 'édes élet');
      expect(find.text('Édes élet'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a place and the notes are searched, too', (tester) async {
      await boot(tester);
      await seedEvent(
        tester,
        'e',
        'Edzés',
        floating(2026, 11, 20, 18),
        location: 'Városliget',
      );
      await openSearch(tester);
      await type(tester, 'varosliget');
      expect(find.text('Edzés'), findsOneWidget);
      expect(find.textContaining('Városliget'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a series is one line, with its next occurrence', (
      tester,
    ) async {
      await boot(tester);
      // Mondays; the clock is Thursday the 12th: the next one is the 16th
      await seedEvent(
        tester,
        's',
        'Heti edzés',
        floating(2026, 5, 4, 9),
        rrule: 'FREQ=WEEKLY',
      );
      await openSearch(tester);
      await type(tester, 'heti');
      expect(find.text('Heti edzés'), findsOneWidget);
      expect(find.textContaining('2026. nov. 16.'), findsOneWidget);
      expect(find.textContaining('ismétlődő'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('upcoming events are above the past ones', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'old', 'Edzés régi', floating(2026, 10, 1, 9));
      await seedEvent(tester, 'new', 'Edzés új', floating(2026, 12, 1, 9));
      await openSearch(tester);
      await type(tester, 'edzes');
      final upcoming = tester.getTopLeft(find.text('Edzés új')).dy;
      final past = tester.getTopLeft(find.text('Edzés régi')).dy;
      expect(upcoming, lessThan(past));
      await shutdown(tester, db);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Edzés', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'xyzw');
      expect(find.text('Nincs találat: „xyzw”.'), findsOneWidget);
      expect(find.text('Edzés'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('one letter is not enough', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Edzés', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'e');
      expect(find.text('Edzés'), findsNothing);
      expect(find.textContaining('Írj be legalább két betűt'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a money entry is found by its amount, too', (tester) async {
      await boot(tester);
      await seedTx(tester, 'x', 'Tesco', 25000);
      await seedTx(tester, 'y', 'Mozi', 1200);
      await openSearch(tester);
      await type(tester, '25000');
      expect(find.text('Tesco'), findsOneWidget);
      expect(find.text('Mozi'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the list is cut at 50 events and says how many more', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(
        () => events.saveAll([
          for (var i = 0; i < 52; i++)
            evt(
              'e$i',
              'Edzés $i',
              floating(2026, 11, 20 + (i % 9), 6 + i % 12),
            ),
        ]),
      );
      await tester.pumpAndSettle();
      await openSearch(tester);
      await type(tester, 'edzes');
      expect(find.text('Események (50)'), findsOneWidget);
      // the note is at the end of the list: scroll to it
      await tester.scrollUntilVisible(
        find.text('és még 2 találat – pontosítsd a keresést'),
        200,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.text('és még 2 találat – pontosítsd a keresést'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });
  });

  group('while it is open', () {
    testWidgets('the list follows the data', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'a', 'Edzés egy', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'edzes');
      expect(find.text('Események (1)'), findsOneWidget);

      await seedEvent(tester, 'b', 'Edzés kettő', floating(2026, 11, 21, 9));
      await tester.pumpAndSettle();
      expect(find.text('Események (2)'), findsOneWidget);
      expect(find.text('Edzés kettő'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the clear button empties the field', (tester) async {
      await boot(tester);
      await openSearch(tester);
      expect(find.byTooltip('Mező törlése'), findsNothing);
      await type(tester, 'edzes');
      await tester.tap(find.byTooltip('Mező törlése'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('search-field')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.textContaining('Írj be legalább két betűt'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a new search starts empty', (tester) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Edzés', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'edzes');
      expect(find.text('Edzés'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-field')), findsNothing);

      await openSearch(tester);
      expect(find.text('Edzés'), findsNothing);
      expect(find.textContaining('Írj be legalább két betűt'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('a tap', () {
    testWidgets('on an event opens its editor; the results stay behind', (
      tester,
    ) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Fogorvos', floating(2026, 11, 20, 9));
      await openSearch(tester);
      await type(tester, 'fogorvos');
      await tester.tap(find.text('Fogorvos'));
      await tester.pumpAndSettle();
      expect(find.text('Esemény szerkesztése'), findsOneWidget);

      await tester.tap(find.byTooltip('Bezár'));
      await tester.pumpAndSettle();
      expect(find.text('Esemény szerkesztése'), findsNothing);
      expect(find.byKey(const Key('search-field')), findsOneWidget);
      expect(find.text('Fogorvos'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('on the calendar button goes to the day and closes', (
      tester,
    ) async {
      await boot(tester);
      await seedEvent(tester, 'e', 'Fogorvos', floating(2026, 12, 3, 9));
      await openSearch(tester);
      await type(tester, 'fogorvos');
      await tester.tap(find.byTooltip('Ugrás a naptárban'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-field')), findsNothing);
      expect(c.read(selectedDayProvider), DateTime.utc(2026, 12, 3));
      expect(c.read(visibleMonthProvider), DateTime.utc(2026, 12, 1));
      await shutdown(tester, db);
    });

    testWidgets('on a task opens the task editor', (tester) async {
      await boot(tester);
      await seedTask(tester, 't', 'Számla befizetése');
      await openSearch(tester);
      await type(tester, 'szamla');
      await tester.tap(find.text('Számla befizetése'));
      await tester.pumpAndSettle();
      expect(find.text('Feladat szerkesztése'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('on a money entry opens its editor', (tester) async {
      await boot(tester);
      await seedTx(tester, 'x', 'Tesco', 25000);
      await openSearch(tester);
      await type(tester, 'tesco');
      await tester.tap(find.text('Tesco'));
      await tester.pumpAndSettle();
      expect(find.byType(TxEditor), findsOneWidget);
      expect(find.text('Tétel szerkesztése'), findsOneWidget);
      await shutdown(tester, db);
    });
  });
}
