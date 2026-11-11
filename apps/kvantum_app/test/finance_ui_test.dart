import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/day_utils.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late FinanceRepository repo;

  Future<void> boot(
    WidgetTester tester, {
    Widget? home,
    FakeWallet? wallet,
  }) async {
    useSize(tester, size: const Size(900, 1400));
    db = await newDb();
    repo = FinanceRepository(db);
    await tester.pumpWidget(
      app(
        home ?? const FinancePage(),
        db,
        extra: [
          if (wallet != null) walletBridgeProvider.overrideWithValue(wallet),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goTo(WidgetTester tester, String tab) async {
    await tester.tap(find.text(tab));
    await tester.pumpAndSettle();
  }

  Future<void> addTx(
    WidgetTester tester,
    String amount, {
    String? category,
    String merchant = '',
    bool income = false,
  }) async {
    await tester.tap(find.byTooltip('Új tétel'));
    await tester.pumpAndSettle();
    if (income) {
      await tester.tap(find.text('Bevétel').last);
      await tester.pump();
    }
    await tester.enterText(
      find.widgetWithText(TextField, 'Összeg (Ft)'),
      amount,
    );
    if (category != null) {
      await tester.tap(find.widgetWithText(ChoiceChip, category));
      await tester.pump();
    }
    if (merchant.isNotEmpty) {
      await tester.enterText(
        find.widgetWithText(TextField, 'Kereskedő / honnan-hová'),
        merchant,
      );
    }
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first start: defaults are seeded and the empty state explains itself',
    (tester) async {
      await boot(tester);
      expect(find.text('Pénzügyek'), findsOneWidget);
      expect(find.textContaining('még nincs tétel'), findsOneWidget);
      expect(find.textContaining('csak ezen az eszközön'), findsOneWidget);
      expect(find.textContaining('nincs teljes másolat'), findsOneWidget);
      expect(
        (await tester.runAsync(repo.categories))!.length,
        defaultCategories().length,
      );
      await shutdown(tester, db);
    },
  );

  testWidgets('a new expense shows up in the list and in the overview totals', (
    tester,
  ) async {
    await boot(tester);
    await goTo(tester, 'Tételek');
    await addTx(tester, '3490', category: 'Élelmiszer', merchant: 'SPAR');
    expect(find.text('SPAR'), findsOneWidget);
    expect(find.text('-3 490 Ft'), findsOneWidget);
    await goTo(tester, 'Áttekintés');
    expect(find.text('3 490 Ft'), findsWidgets); // expense card + bar
    expect(find.text('Élelmiszer'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('income raises the balance; an empty or zero amount is refused', (
    tester,
  ) async {
    await boot(tester);
    await goTo(tester, 'Tételek');
    await tester.tap(find.byTooltip('Új tétel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Összeg (Ft)'), '0');
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
    expect((await tester.runAsync(repo.txs))!, isEmpty);
    await tester.tap(find.text('Mégse'));
    await tester.pumpAndSettle();

    await addTx(tester, '400000', category: 'Fizetés', income: true);
    expect(find.text('+400 000 Ft'), findsOneWidget);
    await goTo(tester, 'Áttekintés');
    expect(find.text('400 000 Ft'), findsWidgets);
    await shutdown(tester, db);
  });

  testWidgets('an uncategorized item is pointed out and can be sorted later', (
    tester,
  ) async {
    await boot(tester);
    await goTo(tester, 'Tételek');
    await addTx(tester, '1200', merchant: 'Ismeretlen');
    await goTo(tester, 'Áttekintés');
    expect(find.text('1 besorolatlan tétel'), findsOneWidget);
    await goTo(tester, 'Tételek');
    await tester.tap(find.text('Ismeretlen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Közlekedés'));
    await tester.pump();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    await goTo(tester, 'Áttekintés');
    expect(find.textContaining('besorolatlan'), findsNothing);
    await shutdown(tester, db);
  });

  testWidgets('editing and deleting a transaction', (tester) async {
    await boot(tester);
    await goTo(tester, 'Tételek');
    await addTx(tester, '1000', merchant: 'Kávé');
    await tester.tap(find.text('Kávé'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Összeg (Ft)'),
      '1500',
    );
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('-1 500 Ft'), findsOneWidget);

    await tester.tap(find.text('Kávé'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Törlés'));
    await tester.pumpAndSettle();
    expect(find.text('Törlöd a tételt?'), findsOneWidget);
    await tester.tap(find.text('Mégse').last);
    await tester.pumpAndSettle();
    expect((await tester.runAsync(repo.txs))!.length, 1); // still there
    await tester.tap(find.text('Törlés'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Törlés').last);
    await tester.pumpAndSettle();
    expect((await tester.runAsync(repo.txs))!, isEmpty);
    expect(find.text('Kávé'), findsNothing);
    await shutdown(tester, db);
  });

  testWidgets(
    'a budget turns into a bar that warns and then shows the overspend',
    (tester) async {
      await boot(tester);
      await goTo(tester, 'Keretek');
      // the Élelmiszer row is the first expense category
      await tester.tap(find.byTooltip('Keret beállítása').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '10000');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Havi keret: 10 000 Ft'), findsOneWidget);

      await goTo(tester, 'Tételek');
      await addTx(tester, '12000', category: 'Élelmiszer');
      await goTo(tester, 'Áttekintés');
      expect(find.text('Költségkeretek'), findsOneWidget);
      expect(find.text('Túllépve: 2 000 Ft'), findsOneWidget);
      await shutdown(tester, db);
    },
  );

  testWidgets('a category that is in use cannot be deleted', (tester) async {
    await boot(tester);
    await goTo(tester, 'Tételek');
    await addTx(tester, '500', category: 'Élelmiszer');
    await goTo(tester, 'Keretek');
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Élelmiszer'),
        matching: find.byTooltip('Kategória'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Törlés'));
    await tester.pumpAndSettle();
    expect(find.textContaining('nem törölhető'), findsOneWidget);
    expect(
      (await tester.runAsync(repo.categories))!.any((c) => c.id == 'cat-food'),
      isTrue,
    );
    await shutdown(tester, db);
  });

  testWidgets(
    'a recurring item appears among this month\'s transactions by itself',
    (tester) async {
      await boot(tester);
      await goTo(tester, 'Ismétlődők');
      expect(find.textContaining('havonta ismétlődő'), findsOneWidget);
      await tester.tap(find.byTooltip('Új ismétlődő tétel'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Név (pl. Fizetés, Lakbér)'),
        'Lakbér',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Összeg (Ft)'),
        '120000',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'A hónap hányadik napján'),
        '1',
      );
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Lakbér'), findsOneWidget);
      expect(find.textContaining('Minden hónap 1. napján'), findsOneWidget);

      await goTo(tester, 'Tételek');
      expect(find.text('Lakbér'), findsOneWidget);
      expect(find.text('-120 000 Ft'), findsOneWidget);
      final t = (await tester.runAsync(repo.txs))!.single;
      expect(t.source, FinSource.recurring);
      await shutdown(tester, db);
    },
  );

  testWidgets('a recurring item needs a name, an amount and a valid day', (
    tester,
  ) async {
    await boot(tester);
    await goTo(tester, 'Ismétlődők');
    await tester.tap(find.byTooltip('Új ismétlődő tétel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Adj nevet a tételnek'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Név (pl. Fizetés, Lakbér)'),
      'X',
    );
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Összeg (Ft)'), '5');
    await tester.enterText(
      find.widgetWithText(TextField, 'A hónap hányadik napján'),
      '40',
    );
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('A nap 1 és 31 között legyen'), findsOneWidget);
    expect((await tester.runAsync(repo.recurring))!, isEmpty);
    await shutdown(tester, db);
  });

  testWidgets('a goal shows its progress after a deposit', (tester) async {
    await boot(tester);
    await goTo(tester, 'Célok');
    await tester.tap(find.byTooltip('Új cél'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Név (pl. Nyaralás)'),
      'Nyaralás',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Célösszeg (Ft)'),
      '600000',
    );
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Nyaralás'), findsOneWidget);
    expect(find.textContaining('(0%)'), findsOneWidget);

    await tester.tap(find.text('Befizetés'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '150000');
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.textContaining('(25%)'), findsOneWidget);
    expect(find.text('Hátravan: 450 000 Ft'), findsOneWidget);

    await tester.tap(find.byTooltip('Cél törlése'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Törlés').last);
    await tester.pumpAndSettle();
    expect(find.text('Nyaralás'), findsNothing);
    expect((await tester.runAsync(repo.deposits))!, isEmpty);
    await shutdown(tester, db);
  });

  testWidgets('the month switcher moves between months', (tester) async {
    await boot(tester);
    final label = find.byTooltip('Előző hónap');
    await tester.tap(label);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FinancePage)),
    );
    final now = todayIn(DateTime.now());
    final prev = DateTime.utc(now.year, now.month - 1, 1);
    expect(container.read(finMonthProvider), prev);
    await tester.tap(find.byTooltip('Következő hónap'));
    await tester.pumpAndSettle();
    expect(container.read(finMonthProvider).month, now.month);
    await shutdown(tester, db);
  });

  testWidgets('the two top-level tabs switch between calendar and money', (
    tester,
  ) async {
    await boot(tester, home: const RootShell());
    expect(find.text('Naptár'), findsWidgets);
    await tester.tap(find.text('Pénzügyek').last);
    await tester.pumpAndSettle();
    expect(find.text('Áttekintés'), findsOneWidget);
    await tester.tap(find.text('Naptár').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsWidgets);
    await shutdown(tester, db);
  });

  testWidgets(
    'payments collected while the app was closed are booked at start',
    (tester) async {
      final w = FakeWallet(
        queue: [
          note('SPAR', '3 490 Ft', DateTime.now().millisecondsSinceEpoch),
          note(
            'Google Wallet',
            'Új ajánlat',
            DateTime.now().millisecondsSinceEpoch + 1,
          ),
        ],
      );
      await boot(tester, home: const RootShell(), wallet: w);
      await tester.tap(find.text('Pénzügyek').last);
      await tester.pumpAndSettle();
      await goTo(tester, 'Tételek');
      expect(find.text('SPAR'), findsOneWidget);
      expect(find.text('-3\u00a0490\u00a0Ft'), findsOneWidget);
      expect(w.queue, isEmpty);
      expect(
        (await tester.runAsync(repo.txs))!.single.source,
        FinSource.wallet,
      );
      await shutdown(tester, db);
    },
  );

  testWidgets('filing a payment teaches the app the merchant', (tester) async {
    final w = FakeWallet(
      queue: [
        note('SPAR', '1 000 Ft', DateTime.now().millisecondsSinceEpoch),
        note('SPAR', '2 000 Ft', DateTime.now().millisecondsSinceEpoch + 5),
      ],
    );
    await boot(tester, home: const RootShell(), wallet: w);
    await tester.tap(find.text('Pénzügyek').last);
    await tester.pumpAndSettle();
    await goTo(tester, 'Áttekintés');
    expect(find.text('2 besorolatlan tétel'), findsOneWidget);
    await goTo(tester, 'Tételek');
    await tester.tap(find.text('SPAR').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Élelmiszer'));
    await tester.pump();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    final txs = (await tester.runAsync(repo.txs))!;
    expect(txs.every((t) => t.categoryId == 'cat-food'), isTrue);
    await goTo(tester, 'Áttekintés');
    expect(find.textContaining('besorolatlan'), findsNothing);
    await shutdown(tester, db);
  });
}
