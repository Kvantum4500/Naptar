import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/finance_editors.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_app/ui/search_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// Wednesday 2026-11-18, 10:00 in Budapest.
DateTime clock() => DateTime.utc(2026, 11, 18, 9);

DateTime d(int y, int m, int day) => floating(y, m, day);

const nb = ' ';

/// A repository whose "last rate" arrives when the test lets it.
class _SlowRates extends FinanceRepository {
  _SlowRates(super.db);
  final waits = <String, Completer<double?>>{};

  @override
  Future<double?> lastRate(String currency) =>
      (waits[currency] = Completer<double?>()).future;
}

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
    Widget home = const FinancePage(),
    Size size = const Size(900, 1400),
    double? textScale,
    FinanceRepository Function(AppDatabase)? makeRepo,
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    repo = makeRepo == null ? FinanceRepository(db) : makeRepo(db);
    await tester.pumpWidget(
      app(
        home,
        db,
        textScale: textScale,
        extra: [
          if (makeRepo != null) financeRepoProvider.overrideWithValue(repo),
          appClockProvider.overrideWithValue(clock),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          walletBridgeProvider.overrideWithValue(FakeWallet()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openNew(WidgetTester tester) async {
    // (on a narrow phone with big text the tab is out of the bar's view)
    await tester.ensureVisible(find.text('Tételek'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tételek'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Új tétel'));
    await tester.pumpAndSettle();
  }

  /// Picks an item of the currency list ("EUR – euró").
  Future<void> choose(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const Key('tx-currency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  Finder amountField(String currency) =>
      find.widgetWithText(TextField, 'Összeg ($currency)');
  final rateField = find.byKey(const Key('tx-rate'));

  String rateText(WidgetTester tester) =>
      tester.widget<TextField>(rateField).controller!.text;
  String amountText(WidgetTester tester, String currency) =>
      tester.widget<TextField>(amountField(currency)).controller!.text;

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
  }

  Future<List<FinTx>> txs(WidgetTester tester) async =>
      (await tester.runAsync(repo.txs))!;

  Future<void> seed(WidgetTester tester, FinTx t) async {
    await tester.runAsync(() => repo.saveTx(t));
    await tester.pumpAndSettle();
  }

  FinTx euro({
    String id = 'e1',
    int cents = 1240,
    double rate = 399.5,
    int amount = 4954,
    String merchant = 'Spar Wien',
  }) => FinTx(
    id: id,
    date: d(2026, 11, 17),
    amount: amount,
    kind: FinKind.expense,
    categoryId: 'cat-food',
    merchant: merchant,
    foreign: FinForeign(currency: 'EUR', cents: cents, rate: rate),
  );

  group('the editor', () {
    testWidgets('it starts in forints: the usual amount, no rate', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      expect(find.text('Pénznem'), findsOneWidget);
      expect(find.text('Ft – forint'), findsOneWidget);
      expect(amountField('Ft'), findsOneWidget);
      expect(rateField, findsNothing);
      expect(find.byKey(const Key('tx-forints')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the list of currencies: forint, the common ones, another', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await tester.tap(find.byKey(const Key('tx-currency')));
      await tester.pumpAndSettle();
      expect(find.text('Ft – forint'), findsWidgets);
      for (final (code, name) in commonCurrencies) {
        expect(find.text('$code – $name'), findsOneWidget, reason: code);
      }
      expect(find.text('Másik pénznem…'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('euros: the labels, a rate, and the forints that follow', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      expect(amountField('EUR'), findsOneWidget);
      expect(amountField('Ft'), findsNothing);
      expect(find.widgetWithText(TextField, 'Árfolyam (Ft / EUR)'), findsOne);
      expect(
        find.text('Add meg az összeget és az árfolyamot.'),
        findsOneWidget,
      );
      await tester.enterText(amountField('EUR'), '12,40');
      await tester.pump();
      expect(
        find.text('Add meg az összeget és az árfolyamot.'),
        findsOneWidget,
      );
      await tester.enterText(rateField, '399,5');
      await tester.pump();
      expect(find.text('= ${formatHuf(4954)}'), findsOneWidget);
      // (an amount of nothing is worth nothing: the hint stays)
      await tester.enterText(amountField('EUR'), '0');
      await tester.pump();
      expect(
        find.text('Add meg az összeget és az árfolyamot.'),
        findsOneWidget,
      );
      expect(find.text('= ${formatHuf(0)}'), findsNothing);
      // (a point is as good as a comma, a thousand has a space)
      await tester.enterText(amountField('EUR'), '1 000.5');
      await tester.enterText(rateField, '400');
      await tester.pump();
      expect(find.text('= ${formatHuf(400200)}'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('only digits, spaces, points and commas are typed', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(amountField('EUR'), 'a1b2,3-c');
      await tester.enterText(rateField, 'x4 0,5y');
      await tester.pump();
      expect(amountText(tester, 'EUR'), '12,3');
      expect(rateText(tester), '4 0,5');
      await shutdown(tester, db);
    });

    testWidgets('saved: the forints, what it was paid in, the rate kept', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(amountField('EUR'), '12,40');
      await tester.enterText(rateField, '399,5');
      await tester.enterText(
        find.widgetWithText(TextField, 'Kereskedő / honnan-hová'),
        'Spar Wien',
      );
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Élelmiszer'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Élelmiszer'));
      await tester.pump();
      await save(tester);
      final t = (await txs(tester)).single;
      expect(t.amount, 4954);
      expect(t.kind, FinKind.expense);
      expect(
        t.foreign,
        const FinForeign(currency: 'EUR', cents: 1240, rate: 399.5),
      );
      expect(t.merchant, 'Spar Wien');
      expect(t.categoryId, 'cat-food');
      expect(t.date, d(2026, 11, 18));
      expect(await tester.runAsync(() => repo.lastRate('EUR')), 399.5);
      expect(await tester.runAsync(() => repo.lastRate('USD')), isNull);
      // the list says it in forints, and what it was paid in
      expect(find.text('-${formatHuf(4954)}'), findsOneWidget);
      expect(
        find.text('12,40${nb}EUR · 399,5${nb}Ft/EUR · Élelmiszer'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('saved in forints: no rate is remembered for anything', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await tester.enterText(amountField('Ft'), '4500');
      await save(tester);
      final t = (await txs(tester)).single;
      expect(t.amount, 4500);
      expect(t.foreign, isNull);
      final rows = (await tester.runAsync(() => db.select(db.metaRows).get()))!;
      expect(rows.where((r) => r.key.startsWith('fin.rate.')), isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('an income in euros is an income of forints', (tester) async {
      await boot(tester);
      await openNew(tester);
      await tester.tap(find.text('Bevétel').last);
      await tester.pump();
      await choose(tester, 'EUR – euró');
      await tester.enterText(amountField('EUR'), '100');
      await tester.enterText(rateField, '400');
      await save(tester);
      final t = (await txs(tester)).single;
      expect(t.kind, FinKind.income);
      expect(t.amount, 40000);
      expect(t.foreign!.cents, 10000);
      expect(find.text('+${formatHuf(40000)}'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the next one in the same currency starts from that rate', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(() => repo.rememberRate('EUR', 401.25));
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      expect(rateText(tester), '401,25');
      // a currency with no rate yet starts empty
      await choose(tester, 'USD – amerikai dollár');
      expect(rateText(tester), '');
      await shutdown(tester, db);
    });

    testWidgets('a rate that was typed is not overwritten by the old one', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(() => repo.rememberRate('EUR', 401.25));
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(rateField, '390');
      await tester.pump();
      // (the same choice again changes nothing)
      await choose(tester, 'EUR – euró');
      expect(rateText(tester), '390');
      await shutdown(tester, db);
    });

    testWidgets(
      'editing: what was paid in is there, a new rate changes forints',
      (tester) async {
        await boot(tester);
        await seed(tester, euro());
        await tester.tap(find.text('Tételek'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Spar Wien'));
        await tester.pumpAndSettle();
        expect(find.text('EUR – euró'), findsOneWidget);
        expect(amountText(tester, 'EUR'), '12,40');
        expect(rateText(tester), '399,5');
        expect(find.text('= ${formatHuf(4954)}'), findsOneWidget);
        await tester.enterText(rateField, '400');
        await tester.pump();
        expect(find.text('= ${formatHuf(4960)}'), findsOneWidget);
        await save(tester);
        final t = (await txs(tester)).single;
        expect(t.id, 'e1');
        expect(t.amount, 4960);
        expect(
          t.foreign,
          const FinForeign(currency: 'EUR', cents: 1240, rate: 400),
        );
        expect(await tester.runAsync(() => repo.lastRate('EUR')), 400);
        await shutdown(tester, db);
      },
    );

    // (a rate such as 2,512 must be read as 2.512 when the entry is saved again
    // as it is; it was read as 2512, or as too much to be a rate)
    for (final (rate, amount) in [(2.512, 311), (399.123, 49491)]) {
      testWidgets('editing and saving as it is: a rate of $rate stays', (
        tester,
      ) async {
        await boot(tester);
        await seed(tester, euro(cents: 12400, rate: rate, amount: amount));
        await tester.tap(find.text('Tételek'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Spar Wien'));
        await tester.pumpAndSettle();
        expect(rateText(tester), formatRate(rate));
        expect(find.text('= ${formatHuf(amount)}'), findsOneWidget);
        await save(tester);
        final t = (await txs(tester)).single;
        expect(t.amount, amount);
        expect(t.foreign!.rate, rate);
        expect(await tester.runAsync(() => repo.lastRate('EUR')), rate);
        await shutdown(tester, db);
      });
    }

    testWidgets('a whole amount in euros has no decimals in its field', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro(cents: 2000, rate: 400, amount: 8000));
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spar Wien'));
      await tester.pumpAndSettle();
      expect(amountText(tester, 'EUR'), '20');
      expect(rateText(tester), '400');
      await shutdown(tester, db);
    });

    testWidgets('back to forints: what it was worth, and nothing foreign', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro());
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spar Wien'));
      await tester.pumpAndSettle();
      await choose(tester, 'Ft – forint');
      expect(amountField('Ft'), findsOneWidget);
      expect(amountText(tester, 'Ft'), '4954');
      expect(rateField, findsNothing);
      expect(find.byKey(const Key('tx-forints')), findsNothing);
      await save(tester);
      final t = (await txs(tester)).single;
      expect(t.amount, 4954);
      expect(t.foreign, isNull);
      expect(t.toJson().containsKey('fx'), isFalse);
      // the list has nothing about euros any more
      expect(find.textContaining('EUR'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('from forints to a currency: the field starts empty', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await tester.enterText(amountField('Ft'), '5000');
      await choose(tester, 'EUR – euró');
      expect(amountText(tester, 'EUR'), '');
      await shutdown(tester, db);
    });

    testWidgets('through forints to another currency: no rate of the first', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(amountField('EUR'), '12,40');
      await tester.enterText(rateField, '399,5');
      await choose(tester, 'Ft – forint');
      expect(amountText(tester, 'Ft'), '4954');
      await choose(tester, 'USD – amerikai dollár');
      expect(rateText(tester), '');
      expect(amountText(tester, 'USD'), '');
      await shutdown(tester, db);
    });

    testWidgets(
      'from one currency to another: the amount stays, the rate does not',
      (tester) async {
        await boot(tester);
        await openNew(tester);
        await choose(tester, 'EUR – euró');
        await tester.enterText(amountField('EUR'), '12,40');
        await tester.enterText(rateField, '399,5');
        await choose(tester, 'USD – amerikai dollár');
        expect(amountText(tester, 'USD'), '12,40');
        expect(rateText(tester), '');
        expect(find.widgetWithText(TextField, 'Árfolyam (Ft / USD)'), findsOne);
        await shutdown(tester, db);
      },
    );

    testWidgets('a currency that is not on the list: its code is asked', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'Másik pénznem…');
      expect(find.text('Másik pénznem'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, ' aud ');
      await tester.tap(find.text('Mentés').last);
      await tester.pumpAndSettle();
      expect(amountField('AUD'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Árfolyam (Ft / AUD)'), findsOne);
      // it is in the list while it is the one chosen
      expect(find.text('AUD'), findsOneWidget);
      await tester.enterText(amountField('AUD'), '10');
      await tester.enterText(rateField, '260');
      await save(tester);
      final t = (await txs(tester)).single;
      expect(t.foreign!.currency, 'AUD');
      expect(t.amount, 2600);
      await shutdown(tester, db);
    });

    testWidgets(
      'a code that is not a currency code, or is the forint: refused',
      (tester) async {
        await boot(tester);
        await openNew(tester);
        for (final bad in ['hu', 'eurx', 'huf', 'HUF', '12', '']) {
          await choose(tester, 'Másik pénznem…');
          await tester.enterText(find.byType(TextField).last, bad);
          await tester.tap(find.text('Mentés').last);
          await tester.pumpAndSettle();
          if (bad.isEmpty) {
            // (an empty code keeps the question open: Mégse closes it)
            await tester.tap(find.text('Mégse').last);
            await tester.pumpAndSettle();
            continue;
          }
          expect(
            find.text('A pénznem kódja három betű (pl. AUD), a forint nem.'),
            findsOneWidget,
            reason: bad,
          );
          expect(amountField('Ft'), findsOneWidget, reason: bad);
          expect(rateField, findsNothing, reason: bad);
          ScaffoldMessenger.of(tester.element(find.byType(Dialog).first))
              .clearSnackBars();
          await tester.pump();
        }
        await shutdown(tester, db);
      },
    );

    testWidgets('asking for a code and giving up changes nothing', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await choose(tester, 'Másik pénznem…');
      await tester.tap(find.text('Mégse').last);
      await tester.pumpAndSettle();
      expect(amountField('EUR'), findsOneWidget);
      await shutdown(tester, db);
    });

    group('what is refused', () {
      Future<void> inEuros(WidgetTester tester) async {
        await boot(tester);
        await openNew(tester);
        await choose(tester, 'EUR – euró');
      }

      testWidgets('no amount', (tester) async {
        await inEuros(tester);
        await tester.enterText(rateField, '400');
        await save(tester);
        expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
        await tester.enterText(amountField('EUR'), '0');
        await save(tester);
        expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
        expect(await txs(tester), isEmpty);
        // typing takes the message away
        await tester.enterText(amountField('EUR'), '1');
        await tester.pump();
        expect(find.text('Adj meg egy pozitív összeget'), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('no rate', (tester) async {
        await inEuros(tester);
        await tester.enterText(amountField('EUR'), '12');
        await save(tester);
        expect(find.text('Adj meg árfolyamot (pl. 400)'), findsOneWidget);
        await tester.enterText(rateField, '0');
        await save(tester);
        expect(find.text('Adj meg árfolyamot (pl. 400)'), findsOneWidget);
        expect(await txs(tester), isEmpty);
        await tester.enterText(rateField, '4');
        await tester.pump();
        expect(find.text('Adj meg árfolyamot (pl. 400)'), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('less than a forint', (tester) async {
        await inEuros(tester);
        await tester.enterText(amountField('EUR'), '0,01');
        await tester.enterText(rateField, '10');
        await save(tester);
        expect(
          find.text('Forintban ez nem érné el az 1 Ft-ot'),
          findsOneWidget,
        );
        expect(await txs(tester), isEmpty);
        // (one forint is enough)
        await tester.enterText(rateField, '50');
        await save(tester);
        expect((await txs(tester)).single.amount, 1);
        await shutdown(tester, db);
      });

      testWidgets('too much', (tester) async {
        await inEuros(tester);
        await tester.enterText(amountField('EUR'), '99999999999');
        await tester.enterText(rateField, '400');
        await save(tester);
        expect(find.text('Túl nagy összeg'), findsOneWidget);
        expect(await txs(tester), isEmpty);
        // (a rate that makes it more than the forints can hold)
        await tester.enterText(amountField('EUR'), '10000000000');
        await tester.enterText(rateField, '100');
        await save(tester);
        expect(find.text('Túl nagy összeg'), findsOneWidget);
        expect(await txs(tester), isEmpty);
        await shutdown(tester, db);
      });
    });

    testWidgets(
      'a rate that arrives late is for the currency it was asked for',
      (tester) async {
        late _SlowRates slow;
        await boot(tester, makeRepo: (db) => slow = _SlowRates(db));
        await openNew(tester);
        await choose(tester, 'EUR – euró');
        await choose(tester, 'USD – amerikai dollár');
        slow.waits['EUR']!.complete(401.0);
        await tester.pumpAndSettle();
        expect(
          rateText(tester),
          '',
          reason: 'the rate of the euro is not for USD',
        );
        slow.waits['USD']!.complete(380.5);
        await tester.pumpAndSettle();
        expect(rateText(tester), '380,5');
        await shutdown(tester, db);
      },
    );

    testWidgets('a rate that arrives late does not take what was typed', (
      tester,
    ) async {
      late _SlowRates slow;
      await boot(tester, makeRepo: (db) => slow = _SlowRates(db));
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(rateField, '390');
      slow.waits['EUR']!.complete(401.0);
      await tester.pumpAndSettle();
      expect(rateText(tester), '390');
      await shutdown(tester, db);
    });

    testWidgets('no rate yet: the field stays empty', (tester) async {
      late _SlowRates slow;
      await boot(tester, makeRepo: (db) => slow = _SlowRates(db));
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      slow.waits['EUR']!.complete(null);
      await tester.pumpAndSettle();
      expect(rateText(tester), '');
      await shutdown(tester, db);
    });

    testWidgets('the keyboards: whole forints, or a decimal point', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      TextInputType? keyboard(Finder f) =>
          tester.widget<TextField>(f).keyboardType;
      expect(keyboard(amountField('Ft')), TextInputType.number);
      // (in forints: digits and spaces only)
      await tester.enterText(amountField('Ft'), 'a1 2,3-4.');
      expect(amountText(tester, 'Ft'), '1 234');
      await choose(tester, 'EUR – euró');
      const decimal = TextInputType.numberWithOptions(decimal: true);
      expect(keyboard(amountField('EUR')), decimal);
      expect(keyboard(rateField), decimal);
      await shutdown(tester, db);
    });

    testWidgets('the edges: the most of an amount, the most of the forints', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      // the most a currency amount can be, at a rate that keeps the forints low
      await tester.enterText(amountField('EUR'), '10000000000,01');
      await tester.enterText(rateField, '0,0001');
      await save(tester);
      expect(find.text('Túl nagy összeg'), findsOneWidget);
      await tester.enterText(amountField('EUR'), '10000000000');
      await save(tester);
      expect(find.text('Túl nagy összeg'), findsNothing);
      var t = (await txs(tester)).single;
      expect(t.foreign!.cents, 1000000000000);
      expect(t.amount, 1000000);
      // the most the forints can be
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await tester.enterText(amountField('EUR'), '100000000,01');
      await tester.enterText(rateField, '1000');
      await save(tester);
      expect(find.text('Túl nagy összeg'), findsOneWidget);
      await tester.enterText(amountField('EUR'), '100000000');
      await save(tester);
      t = (await txs(tester)).firstWhere((x) => x.amount > 1000000);
      expect(t.amount, 100000000000);
      await shutdown(tester, db);
    });

    testWidgets('a message goes when the currency is changed', (tester) async {
      await boot(tester);
      await openNew(tester);
      await choose(tester, 'EUR – euró');
      await save(tester);
      expect(find.text('Adj meg egy pozitív összeget'), findsOneWidget);
      await choose(tester, 'USD – amerikai dollár');
      expect(find.text('Adj meg egy pozitív összeget'), findsNothing);
      await tester.enterText(amountField('USD'), '5');
      await save(tester);
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsOneWidget);
      await choose(tester, 'GBP – angol font');
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('on a wide screen: the buttons in one line, at the right', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro());
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spar Wien'));
      await tester.pumpAndSettle();
      final dialog = tester.getRect(find.byType(TxEditor));
      final del = tester.getRect(find.text('Törlés'));
      final cancel = tester.getRect(find.text('Mégse'));
      final ok = tester.getRect(find.text('Mentés'));
      expect(ok.right, greaterThan(dialog.right - 60));
      expect(del.right, lessThan(cancel.left));
      expect(cancel.right, lessThan(ok.left));
      expect((cancel.center.dy - ok.center.dy).abs(), lessThan(4));
      expect((del.center.dy - ok.center.dy).abs(), lessThan(4));
      // (the delete button keeps its distance from the one beside it)
      final delButton = tester.getRect(
        find.ancestor(
          of: find.text('Törlés'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      final cancelButton = tester.getRect(
        find.widgetWithText(TextButton, 'Mégse'),
      );
      expect(cancelButton.left - delButton.right, greaterThanOrEqualTo(24));
      await shutdown(tester, db);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('the three buttons of an old entry fit a narrow phone '
          '(${scale}x)', (tester) async {
        await boot(tester, size: const Size(360, 800), textScale: scale);
        tester.takeException();
        await seed(tester, euro());
        await tester.ensureVisible(find.text('Tételek'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tételek'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Spar Wien'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final dialog = tester.getRect(find.byType(TxEditor));
        final seen = <Rect>[];
        for (final label in ['Törlés', 'Mégse', 'Mentés']) {
          final box = tester.getRect(find.text(label));
          expect(box.left, greaterThanOrEqualTo(dialog.left), reason: label);
          expect(box.right, lessThanOrEqualTo(dialog.right), reason: label);
          expect(box.bottom, lessThanOrEqualTo(dialog.bottom), reason: label);
          seen.add(box);
        }
        // (one under the other or side by side: they do not lie on each other)
        for (var i = 0; i < seen.length; i++) {
          for (var j = i + 1; j < seen.length; j++) {
            expect(seen[i].overlaps(seen[j]), isFalse, reason: '$i $j');
          }
        }
        await shutdown(tester, db);
      });
    }

    testWidgets('twice the text size on a phone: nothing overflows', (
      tester,
    ) async {
      await boot(tester, size: const Size(360, 800), textScale: 2.0);
      // (the test font draws every character a full em wide: an amount of the
      // overview, which is not what is looked at here, is wider than its card at
      // this size, so what was said until now is let go)
      tester.takeException();
      await openNew(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('tx-currency')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('USD – amerikai dollár').last);
      await tester.pumpAndSettle();
      await tester.enterText(amountField('USD'), '1 234,56');
      await tester.enterText(rateField, '380,5');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('= ${formatHuf(469750)}'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('where it is seen', () {
    testWidgets('the list: forints at the right, what it was paid in beside', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro());
      await seed(
        tester,
        FinTx(
          id: 'h1',
          date: d(2026, 11, 17),
          amount: 3000,
          kind: FinKind.expense,
          merchant: 'Bolt',
          categoryId: 'cat-food',
          note: 'hazafelé',
        ),
      );
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      expect(find.text('-${formatHuf(4954)}'), findsOneWidget);
      expect(
        find.text('12,40${nb}EUR · 399,5${nb}Ft/EUR · Élelmiszer'),
        findsOneWidget,
      );
      // a transaction in forints says nothing about a currency
      expect(find.text('Élelmiszer · hazafelé'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a note comes after what it was paid in', (tester) async {
      await boot(tester);
      await seed(tester, euro().copyWith(note: 'ebéd'));
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      expect(
        find.text('12,40${nb}EUR · 399,5${nb}Ft/EUR · Élelmiszer · ebéd'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a transaction with no merchant is named by its category', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro(merchant: ''));
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      expect(find.text('12,40${nb}EUR · 399,5${nb}Ft/EUR'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the search says it too', (tester) async {
      await boot(tester, home: const SearchPage(), size: const Size(900, 900));
      await tester.runAsync(repo.ensureDefaults);
      await seed(tester, euro());
      await tester.enterText(find.byKey(const Key('search-field')), 'spar');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hit-tx-e1')), findsOneWidget);
      expect(
        find.text(
          '${fmtDate(d(2026, 11, 17))} · '
          '12,40${nb}EUR · 399,5${nb}Ft/EUR · Élelmiszer',
        ),
        findsOneWidget,
      );
      expect(find.text('-${formatHuf(4954)}'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('sums and the rest go on in forints', () {
    testWidgets('the month adds up the forints of every transaction', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester, euro());
      await seed(
        tester,
        FinTx(
          id: 'f1',
          date: d(2026, 11, 3),
          amount: 1000,
          kind: FinKind.expense,
        ),
      );
      await tester.tap(find.text('Áttekintés'));
      await tester.pumpAndSettle();
      expect(find.text(formatHuf(5954)), findsWidgets);
      await shutdown(tester, db);
    });
  });
}
