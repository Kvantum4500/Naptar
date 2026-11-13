import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/backup_io.dart';
import 'package:kvantum_app/ui/charts.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/finance/finance_trend_tab.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// Wednesday 2026-11-18, 10:00 in Budapest.
DateTime clock() => DateTime.utc(2026, 11, 18, 9);

DateTime d(int y, int m, int day) => floating(y, m, day);

class _FakeIo implements BackupIo {
  final saved = <({String name, String text, String mime, String title})>[];
  bool result = true;
  Object? failure;

  @override
  Future<bool> save(
    String fileName,
    String text, {
    String mimeType = 'text/calendar',
    String dialogTitle = 'Naptár mentése',
  }) async {
    if (failure != null) throw failure!;
    saved.add((name: fileName, text: text, mime: mimeType, title: dialogTitle));
    return result;
  }

  @override
  Future<String?> pick() async => null;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the words of the trend page', () {
    MonthTotal m(int y, int mo, {int income = 0, int expense = 0}) =>
        MonthTotal(year: y, month: mo, income: income, expense: expense);

    test('a month by its name, and short', () {
      expect(trendMonthName(m(2026, 3)), '2026. március');
      expect(trendMonthName(m(2025, 12)), '2025. december');
      expect(trendMonthShort(m(2025, 12)), '2025.12.');
      expect(trendMonthShort(m(2026, 3)), '2026.03.');
    });

    test('a row of the table', () {
      expect(
        trendRow(m(2026, 3, income: 300000, expense: 120000)),
        '2026. március: bevétel ${formatHuf(300000)} · '
        'kiadás ${formatHuf(120000)} · egyenleg ${formatHuf(180000)}',
      );
      expect(
        trendRow(m(2026, 3, expense: 5)),
        contains('egyenleg ${formatHuf(-5)}'),
      );
    });

    test('a month with nothing in it says so, not "0 Ft"', () {
      expect(trendRow(m(2026, 6)), '2026. június: nincs rögzített tétel');
      // (one amount is enough for the month to have something in it)
      expect(
        trendRow(m(2026, 6, income: 1)),
        '2026. június: bevétel ${formatHuf(1)} · kiadás ${formatHuf(0)} · '
        'egyenleg ${formatHuf(1)}',
      );
      expect(
        trendRow(m(2026, 6, expense: 1)),
        '2026. június: bevétel ${formatHuf(0)} · kiadás ${formatHuf(1)} · '
        'egyenleg ${formatHuf(-1)}',
      );
    });

    test('what a screen reader says for the bars', () {
      final totals = [
        m(2026, 9, expense: 1000),
        m(2026, 10, expense: 5000),
        m(2026, 11, expense: 300),
      ];
      expect(
        trendBarsLabel('Kiadás', totals, (t) => t.expense),
        'Kiadás az elmúlt 3 hónapban: összesen ${formatHuf(6300)}; '
        'a legtöbb 2026. október: ${formatHuf(5000)}. '
        'Ebben a hónapban eddig ${formatHuf(300)}.',
      );
      expect(
        trendBarsLabel('Bevétel', totals, (t) => t.income),
        'Bevétel az elmúlt 3 hónapban: nincs tétel.',
      );
    });

    test('the first of two equal months is the most', () {
      final totals = [m(2026, 9, expense: 5), m(2026, 10, expense: 5)];
      expect(
        trendBarsLabel('Kiadás', totals, (t) => t.expense),
        contains('2026. szeptember'),
      );
    });

    Subscription sub({
      SubscriptionCadence cadence = SubscriptionCadence.monthly,
      int amount = 4990,
    }) => Subscription(
      key: 'netflix',
      name: 'Netflix',
      amount: amount,
      cadence: cadence,
      lastDate: d(2026, 11, 5),
      nextDate: d(2026, 12, 5),
      count: 3,
      categoryId: 'cat-subs',
    );

    test('a subscription in words', () {
      expect(subscriptionAmount(sub()), '${formatHuf(4990)} / hó');
      expect(
        subscriptionAmount(sub(cadence: SubscriptionCadence.yearly)),
        '${formatHuf(4990)} / év',
      );
      expect(
        subscriptionLine(sub()),
        'havonta · utoljára 2026.11.05. · következő várhatóan 2026.12.05.',
      );
      expect(
        subscriptionLine(sub(cadence: SubscriptionCadence.yearly)),
        startsWith('évente · utoljára'),
      );
    });

    test('the total of the subscriptions, a month and a year', () {
      expect(
        subscriptionTotal([sub(), sub(amount: 1000)]),
        'Összesen kb. ${formatHuf(5990)} havonta (évente ${formatHuf(71880)}).',
      );
      expect(
        subscriptionTotal([
          sub(cadence: SubscriptionCadence.yearly, amount: 12000),
        ]),
        'Összesen kb. ${formatHuf(1000)} havonta (évente ${formatHuf(12000)}).',
      );
    });

    test('a yearly one costs a year, not twelve rounded months', () {
      expect(
        subscriptionTotal([
          sub(cadence: SubscriptionCadence.yearly, amount: 10000),
        ]),
        'Összesen kb. ${formatHuf(833)} havonta (évente ${formatHuf(10000)}).',
      );
    });

    test(
      'the rule that books a subscription: its day, from its next month',
      () {
        final rule = subscriptionRule(sub(), 'rule-1');
        expect(rule.id, 'rule-1');
        expect(rule.title, 'Netflix');
        expect(rule.amount, 4990);
        expect(rule.kind, FinKind.expense);
        expect(rule.categoryId, 'cat-subs');
        expect(rule.dayOfMonth, 5);
        expect(rule.fromMonth, d(2026, 12, 1));
        expect(rule.active, isTrue);
      },
    );

    test(
      'the day of the rule is the day of the last charge, not of the next',
      () {
        // (the 31st, and the next month has 28 days: the next date is the 28th)
        final late = Subscription(
          key: 'x',
          name: 'Gym',
          amount: 9000,
          cadence: SubscriptionCadence.monthly,
          lastDate: d(2026, 1, 31),
          nextDate: d(2026, 2, 28),
          count: 3,
          categoryId: 'cat-sport',
        );
        final rule = subscriptionRule(late, 'r');
        expect(rule.dayOfMonth, 31);
        expect(rule.fromMonth, d(2026, 2, 1));
        expect(rule.categoryId, 'cat-sport');
      },
    );

    test('a long name is cut to what a rule can hold', () {
      Subscription named(int length) => Subscription(
        key: 'x',
        name: 'N' * length,
        amount: 1,
        cadence: SubscriptionCadence.monthly,
        lastDate: d(2026, 11, 5),
        nextDate: d(2026, 12, 5),
        count: 3,
        categoryId: 'c',
      );
      expect(subscriptionRule(named(75), 'r').title, 'N' * 60);
      expect(subscriptionRule(named(61), 'r').title, 'N' * 60);
      expect(subscriptionRule(named(60), 'r').title, 'N' * 60);
      expect(subscriptionRule(named(59), 'r').title, 'N' * 59);
    });

    test('the periods', () {
      expect(trendRanges, [(6, '6 hónap'), (12, '12 hónap'), (24, '24 hónap')]);
    });
  });

  group('the page', () {
    late AppDatabase db;
    late FinanceRepository repo;
    late _FakeIo io;

    Future<void> boot(
      WidgetTester tester, {
      Size size = const Size(900, 3000),
      double? textScale,
      ThemeData? theme,
      DateTime Function()? now,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      repo = FinanceRepository(db);
      io = _FakeIo();
      await tester.pumpWidget(
        app(
          const FinancePage(),
          db,
          textScale: textScale,
          theme: theme,
          extra: [
            appClockProvider.overrideWithValue(now ?? clock),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
            backupIoProvider.overrideWithValue(io),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tx(
      WidgetTester tester,
      String id,
      DateTime day,
      int amount, {
      FinKind kind = FinKind.expense,
      String cat = 'cat-food',
      String merchant = '',
      FinSource source = FinSource.manual,
      bool deleted = false,
    }) async {
      await tester.runAsync(
        () => repo.saveTx(
          FinTx(
            id: id,
            date: day,
            amount: amount,
            kind: kind,
            categoryId: cat,
            merchant: merchant,
            source: source,
            deleted: deleted,
          ),
        ),
      );
      // (a frame between two writes: the page watches the log)
      await tester.pumpAndSettle();
    }

    /// August to November: a salary each month but the last, some food, and a
    /// subscription that has been charged three times.
    Future<void> seed(WidgetTester tester) async {
      for (final (mo, food) in [
        (8, 80000),
        (9, 120000),
        (10, 100000),
        (11, 50000),
      ]) {
        await tx(tester, 'f$mo', d(2026, mo, 3), food, merchant: 'Spar');
        if (mo < 11) {
          await tx(
            tester,
            's$mo',
            d(2026, mo, 1),
            300000,
            kind: FinKind.income,
            cat: 'cat-salary',
            merchant: 'Munkahely',
          );
        }
      }
      for (final mo in [9, 10, 11]) {
        await tx(
          tester,
          'n$mo',
          d(2026, mo, 5),
          4990,
          cat: 'cat-subs',
          merchant: 'Netflix',
          source: FinSource.wallet,
        );
      }
      await tester.pumpAndSettle();
    }

    Future<void> openTrend(WidgetTester tester) async {
      // (on a narrow phone with big text the tab is out of the bar's view)
      await tester.ensureVisible(find.text('Trend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trend'));
      await tester.pumpAndSettle();
    }

    BarChart bars(WidgetTester tester, String key) =>
        tester.widget<BarChart>(find.byKey(Key(key)));

    String semanticsOf(WidgetTester tester, String key) =>
        tester.getSemantics(find.byKey(Key(key))).label;

    testWidgets('it is the second tab of the money', (tester) async {
      await boot(tester);
      final tabs = tester
          .widgetList<Tab>(find.byType(Tab))
          .map((t) => t.text)
          .toList();
      expect(tabs, [
        'Áttekintés',
        'Trend',
        'Tételek',
        'Keretek',
        'Ismétlődők',
        'Célok',
      ]);
      await shutdown(tester, db);
    });

    testWidgets('with nothing in the log it says so, and still exports', (
      tester,
    ) async {
      await boot(tester);
      await openTrend(tester);
      expect(find.byKey(const Key('trend-empty')), findsOneWidget);
      expect(
        find.text(
          'Még nincs elég adat. A Tételek fülön felvett kiadásokból és '
          'bevételekből itt látod hónapról hónapra, hogyan alakul a pénzed.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('trend-expense')), findsNothing);
      expect(find.byKey(const Key('trend-income')), findsNothing);
      expect(find.byKey(const Key('trend-summary')), findsNothing);
      expect(find.byKey(const Key('trend-export')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the lines in words, for twelve months', (tester) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      for (final line in [
        'Az elmúlt 12 hónap: kiadás ${formatHuf(364970)}, bevétel ${formatHuf(900000)}, '
            'egyenleg ${formatHuf(535030)}.',
        'Egy átlagos hónap (az elmúlt 3 teljes hónapból): '
            'kiadás ${formatHuf(103327)}, bevétel ${formatHuf(300000)}.',
        'Ebben a hónapban eddig: kiadás ${formatHuf(54990)}, bevétel ${formatHuf(0)}.',
        'A legtöbbet erre költötted: Élelmiszer (${formatHuf(350000)}), '
            'Előfizetések (${formatHuf(14970)}).',
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      await shutdown(tester, db);
    });

    testWidgets('the first line of the summary is the heavier one', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      final theme = Theme.of(tester.element(find.byType(TrendTab)));
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('trend-summary')),
              matching: find.byType(Text),
            ),
          )
          .toList();
      expect(texts, hasLength(4));
      expect(texts.first.style, theme.textTheme.titleSmall);
      for (final t in texts.skip(1)) {
        expect(t.style, theme.textTheme.bodyMedium);
      }
      await shutdown(tester, db);
    });

    testWidgets('the name of a subscription is the heading of its row', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      final theme = Theme.of(tester.element(find.byType(TrendTab)));
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('trend-subs')),
          matching: find.text('Netflix'),
        ),
      );
      expect(name.style, theme.textTheme.titleSmall);
      expect(
        tester.widget<Text>(find.text('${formatHuf(4990)} / hó')).style,
        isNull,
      );
      await shutdown(tester, db);
    });

    testWidgets('each chart says what its bars are, in what unit', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      expect(
        find.text(
          'Forintban, hónaponként; a jobb szélső oszlop a mostani hónap, '
          'még nem kész.',
        ),
        findsNWidgets(2),
      );
      await shutdown(tester, db);
    });

    testWidgets('the bars: a month each, oldest first, on a round scale', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      final out = bars(tester, 'trend-expense');
      expect(out.values, [
        ...List.filled(8, 0.0),
        80000,
        124990,
        104990,
        54990,
      ]);
      expect(out.maxValue, 150000);
      expect(out.maxLabel, '150 e Ft');
      expect(out.firstLabel, '2025.12.');
      expect(out.lastLabel, 'ez a hónap');
      final income = bars(tester, 'trend-income');
      expect(income.values, [
        ...List.filled(8, 0.0),
        300000,
        300000,
        300000,
        0,
      ]);
      expect(income.maxValue, 300000);
      expect(income.maxLabel, '300 e Ft');
      expect(income.firstLabel, '2025.12.');
      await shutdown(tester, db);
    });

    testWidgets('the label of the top of the scale is not cut at the edge', (
      tester,
    ) async {
      // (a phone, and the text at twice the size: the label of the scale
      // follows the system text, but only up to 1.3 times)
      await boot(tester, size: const Size(360, 3000), textScale: 2.0);
      await seed(tester);
      tester.takeException();
      await openTrend(tester);
      for (final key in ['trend-expense', 'trend-income']) {
        final picture = find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(CustomPaint),
        );
        final painter =
            tester.widget<CustomPaint>(picture).painter! as BarChartPainter;
        final canvas = TestRecordingCanvas();
        painter.paint(canvas, tester.getSize(picture));
        final words = [
          for (final call in canvas.invocations)
            if (call.invocation.memberName == #drawParagraph)
              (
                paragraph:
                    call.invocation.positionalArguments[0] as ui.Paragraph,
                at: call.invocation.positionalArguments[1] as Offset,
              ),
        ];
        expect(words, hasLength(4), reason: key);
        for (final w in words) {
          expect(
            w.at.dx,
            greaterThanOrEqualTo(0),
            reason: '$key: cut at the left',
          );
        }
        // the label of the top is the first, and ends where the margin does
        expect(
          words.first.at.dx + words.first.paragraph.longestLine,
          closeTo(painter.plotLeft - barLabelGap, 0.01),
          reason: key,
        );
      }
      await shutdown(tester, db);
    });

    testWidgets('the income is not in the colour of the expense', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      final context = tester.element(find.byType(TrendTab));
      expect(bars(tester, 'trend-expense').color, isNull);
      expect(bars(tester, 'trend-income').color, statusColorsOf(context).ok);
      await shutdown(tester, db);
    });

    testWidgets('the periods: six, twelve and twenty-four months', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      bool on(int months) => tester
          .widget<ChoiceChip>(find.byKey(Key('trend-range-$months')))
          .selected;
      expect([on(6), on(12), on(24)], [false, true, false]);
      await tester.tap(find.byKey(const Key('trend-range-6')));
      await tester.pumpAndSettle();
      expect([on(6), on(12), on(24)], [true, false, false]);
      expect(bars(tester, 'trend-expense').values, [
        0,
        0,
        80000,
        124990,
        104990,
        54990,
      ]);
      expect(bars(tester, 'trend-expense').firstLabel, '2026.06.');
      await tester.tap(find.byKey(const Key('trend-range-24')));
      await tester.pumpAndSettle();
      expect(bars(tester, 'trend-expense').values, hasLength(24));
      expect(bars(tester, 'trend-expense').firstLabel, '2024.12.');
      expect(find.textContaining('Az elmúlt 24 hónap:'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the chips say how long', (tester) async {
      await boot(tester);
      await openTrend(tester);
      for (final (months, label) in [
        (6, '6 hónap'),
        (12, '12 hónap'),
        (24, '24 hónap'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('trend-range-$months')),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
      await shutdown(tester, db);
    });

    testWidgets('the sections, in order, with their titles as headings', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      final tops = <double>[];
      for (final title in [
        'Havi kiadás',
        'Havi bevétel',
        'Előfizetések',
        'Adatok szövegesen',
      ]) {
        expect(
          tester.getSemantics(find.text(title)),
          matchesSemantics(label: title, isHeader: true),
          reason: title,
        );
        tops.add(tester.getTopLeft(find.text(title)).dy);
      }
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(4));
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the pictures are described to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      expect(
        semanticsOf(tester, 'trend-expense'),
        'Kiadás az elmúlt 12 hónapban: összesen ${formatHuf(364970)}; '
        'a legtöbb 2026. szeptember: ${formatHuf(124990)}. '
        'Ebben a hónapban eddig ${formatHuf(54990)}.',
      );
      expect(
        semanticsOf(tester, 'trend-income'),
        'Bevétel az elmúlt 12 hónapban: összesen ${formatHuf(900000)}; '
        'a legtöbb 2026. augusztus: ${formatHuf(300000)}. '
        'Ebben a hónapban eddig ${formatHuf(0)}.',
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the button of a subscription says which one it is for', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      await tester.ensureVisible(find.byKey(const Key('sub-add-netflix')));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(const Key('sub-add-netflix'))).label,
        'Felvétel ismétlődőként: Netflix',
      );
      // (what is seen is the short words)
      expect(
        find.descendant(
          of: find.byKey(const Key('sub-add-netflix')),
          matching: find.text('Felvétel ismétlődőként'),
        ),
        findsOneWidget,
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the table: every month with its numbers, the newest first', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await openTrend(tester);
      await tester.ensureVisible(find.text('Hónapok számokkal'));
      await tester.tap(find.text('Hónapok számokkal'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '2026. november: bevétel ${formatHuf(0)} · kiadás ${formatHuf(54990)} · '
          'egyenleg ${formatHuf(-54990)}',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '2026. szeptember: bevétel ${formatHuf(300000)} · kiadás ${formatHuf(124990)} · '
          'egyenleg ${formatHuf(175010)}',
        ),
        findsOneWidget,
      );
      final tops = [
        for (final name in [
          'november',
          'október',
          'szeptember',
          'augusztus',
          'július',
        ])
          tester.getTopLeft(find.textContaining('2026. $name:')).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(5));
      await shutdown(tester, db);
    });

    group('the subscriptions', () {
      testWidgets('what was found, with its price and its next day', (
        tester,
      ) async {
        await boot(tester);
        await seed(tester);
        await openTrend(tester);
        expect(find.byKey(const Key('trend-subs')), findsOneWidget);
        expect(
          find.text(
            'Összesen kb. ${formatHuf(4990)} havonta (évente ${formatHuf(59880)}).',
          ),
          findsOneWidget,
        );
        expect(find.text('Netflix'), findsOneWidget);
        expect(find.text('${formatHuf(4990)} / hó'), findsOneWidget);
        expect(
          find.text(
            'havonta · utoljára 2026.11.05. · következő várhatóan 2026.12.05.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('sub-add-netflix')), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('nothing regular, no card', (tester) async {
        await boot(tester);
        await tx(tester, 'a', d(2026, 10, 3), 5000, merchant: 'Spar');
        await tx(tester, 'b', d(2026, 11, 3), 5000, merchant: 'Spar');
        await tester.pumpAndSettle();
        await openTrend(tester);
        expect(find.byKey(const Key('trend-subs')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets(
        '"Felvétel ismétlődőként" makes a rule, and the card lets go of it',
        (tester) async {
          await boot(tester);
          await seed(tester);
          await openTrend(tester);
          await tester.ensureVisible(find.byKey(const Key('sub-add-netflix')));
          await tester.tap(find.byKey(const Key('sub-add-netflix')));
          await tester.pumpAndSettle();
          final rules = (await tester.runAsync(repo.recurring))!;
          expect(rules, hasLength(1));
          final r = rules.single;
          expect(r.title, 'Netflix');
          expect(r.amount, 4990);
          expect(r.kind, FinKind.expense);
          expect(r.categoryId, 'cat-subs');
          expect(r.dayOfMonth, 5);
          expect(r.fromMonth, d(2026, 12, 1));
          expect(
            find.text(
              'Ismétlődő tétel felvéve: Netflix – minden hónap 5. napján. '
              'Az Ismétlődők fülön szerkesztheted.',
            ),
            findsOneWidget,
          );
          // known now: it is not offered a second time
          expect(find.byKey(const Key('trend-subs')), findsNothing);
          // and the month that is paid already did not get a second charge
          final txs = (await tester.runAsync(repo.txs))!;
          expect(
            txs.where((t) => t.merchant == 'Netflix' && t.date.month == 11),
            hasLength(1),
          );
          await shutdown(tester, db);
        },
      );

      testWidgets(
        'a rule that starts this month has its charge booked at once',
        (tester) async {
          await boot(tester);
          for (final mo in [8, 9, 10]) {
            await tx(
              tester,
              'n$mo',
              d(2026, mo, 20),
              4990,
              cat: 'cat-subs',
              merchant: 'Netflix',
              source: FinSource.wallet,
            );
          }
          await openTrend(tester);
          await tester.ensureVisible(find.byKey(const Key('sub-add-netflix')));
          await tester.tap(find.byKey(const Key('sub-add-netflix')));
          await tester.pumpAndSettle();
          final rule = (await tester.runAsync(repo.recurring))!.single;
          expect(rule.dayOfMonth, 20);
          expect(rule.fromMonth, d(2026, 11, 1));
          final booked = (await tester.runAsync(repo.txs))!
              .where((t) => t.source == FinSource.recurring);
          expect(booked, hasLength(1));
          expect(booked.single.date, d(2026, 11, 20));
          expect(booked.single.amount, 4990);
          expect(booked.single.merchant, 'Netflix');
          await shutdown(tester, db);
        },
      );

      testWidgets(
        'a rule that was deleted does not keep it from being offered',
        (tester) async {
          await boot(tester);
          await seed(tester);
          await tester.runAsync(
            () => repo.saveRecurring(
              FinRecurring(
                id: 'r1',
                title: 'NETFLIX',
                amount: 4990,
                kind: FinKind.expense,
                categoryId: 'cat-subs',
                dayOfMonth: 5,
                fromMonth: d(2026, 1, 1),
                deleted: true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await openTrend(tester);
          expect(find.byKey(const Key('trend-subs')), findsOneWidget);
          expect(find.byKey(const Key('sub-add-netflix')), findsOneWidget);
          await shutdown(tester, db);
        },
      );

      testWidgets('a rule that was there before keeps it from being offered', (
        tester,
      ) async {
        await boot(tester);
        await seed(tester);
        await tester.runAsync(
          () => repo.saveRecurring(
            FinRecurring(
              id: 'r1',
              title: 'NETFLIX',
              amount: 4990,
              kind: FinKind.expense,
              categoryId: 'cat-subs',
              dayOfMonth: 5,
              fromMonth: d(2026, 1, 1),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openTrend(tester);
        expect(find.byKey(const Key('trend-subs')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets(
        'a yearly one is shown, but a month-by-month rule does not fit it',
        (tester) async {
          await boot(tester);
          await tx(
            tester,
            'y1',
            d(2025, 6, 10),
            24000,
            cat: 'cat-subs',
            merchant: 'Domain',
            source: FinSource.wallet,
          );
          await tx(
            tester,
            'y2',
            d(2026, 6, 10),
            24000,
            cat: 'cat-subs',
            merchant: 'Domain',
            source: FinSource.wallet,
          );
          await tester.pumpAndSettle();
          await openTrend(tester);
          expect(find.byKey(const Key('trend-subs')), findsOneWidget);
          expect(find.text('${formatHuf(24000)} / év'), findsOneWidget);
          expect(find.byKey(const Key('sub-add-domain')), findsNothing);
          expect(
            find.text(
              'Összesen kb. ${formatHuf(2000)} havonta (évente ${formatHuf(24000)}).',
            ),
            findsOneWidget,
          );
          await shutdown(tester, db);
        },
      );
    });

    group('the export', () {
      Future<void> pick(WidgetTester tester, String key) async {
        await tester.ensureVisible(find.byKey(const Key('trend-export')));
        await tester.tap(find.byKey(const Key('trend-export')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      List<String> rows(String csv) => [
        for (final l in csv.split('\r\n').skip(1))
          if (l.isNotEmpty) l,
      ];

      testWidgets('the three choices are asked', (tester) async {
        await boot(tester);
        await openTrend(tester);
        await tester.ensureVisible(find.byKey(const Key('trend-export')));
        await tester.tap(find.byKey(const Key('trend-export')));
        await tester.pumpAndSettle();
        expect(find.text('Mit exportálsz?'), findsOneWidget);
        expect(find.text('A mostani hónap tételeit'), findsOneWidget);
        expect(find.text('A kijelzett időszakot (12 hónap)'), findsOneWidget);
        expect(find.text('Minden tételt'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('this month: the rows of November, in a CSV file', (
        tester,
      ) async {
        await boot(tester);
        await seed(tester);
        await openTrend(tester);
        await pick(tester, 'export-month');
        expect(io.saved, hasLength(1));
        final f = io.saved.single;
        expect(f.name, 'kvantum-penzugyek-2026-11.csv');
        expect(f.mime, 'text/csv');
        expect(f.title, 'Tételek exportálása');
        expect(f.text, startsWith('﻿Dátum;Típus;Összeg (Ft);'));
        expect(rows(f.text), [
          '2026-11-03;Kiadás;-50000;;;;Élelmiszer;Spar;;kézi',
          '2026-11-05;Kiadás;-4990;;;;Előfizetések;Netflix;;Wallet',
        ]);
        expect(find.text('A tételek elmentve (CSV).'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('in March the month of the file name has its zero', (
        tester,
      ) async {
        await boot(tester, now: () => DateTime.utc(2026, 3, 18, 9));
        await tx(tester, 'm1', d(2026, 3, 3), 100);
        await tx(tester, 'm0', d(2026, 2, 28), 7);
        await openTrend(tester);
        await pick(tester, 'export-month');
        final f = io.saved.single;
        expect(f.name, 'kvantum-penzugyek-2026-03.csv');
        expect(rows(f.text), ['2026-03-03;Kiadás;-100;;;;Élelmiszer;;;kézi']);
        await shutdown(tester, db);
      });

      testWidgets(
        'the period on the screen: from its first day to the end of this month',
        (tester) async {
          await boot(tester);
          await seed(tester);
          await tx(tester, 'old', d(2025, 11, 30), 1);
          await tx(tester, 'first', d(2025, 12, 1), 2);
          await tx(tester, 'late', d(2026, 11, 30), 3);
          await tx(tester, 'next', d(2026, 12, 1), 4);
          await tester.pumpAndSettle();
          await openTrend(tester);
          await pick(tester, 'export-range');
          final f = io.saved.single;
          expect(f.name, 'kvantum-penzugyek-12-honap.csv');
          final amounts = rows(f.text).map((l) => l.split(';')[2]).toList();
          expect(amounts.first, '-2'); // 2025-12-01
          expect(amounts.last, '-3'); // 2026-11-30
          expect(amounts, isNot(contains('-1')));
          expect(amounts, isNot(contains('-4')));
          await shutdown(tester, db);
        },
      );

      testWidgets('the period follows the chip that is chosen', (tester) async {
        await boot(tester);
        await seed(tester);
        await openTrend(tester);
        await tester.tap(find.byKey(const Key('trend-range-6')));
        await tester.pumpAndSettle();
        await pick(tester, 'export-range');
        final f = io.saved.single;
        expect(f.name, 'kvantum-penzugyek-6-honap.csv');
        // from June: August is the first month with anything
        expect(rows(f.text).first, startsWith('2026-08-'));
        await shutdown(tester, db);
      });

      testWidgets('everything', (tester) async {
        await boot(tester);
        await seed(tester);
        await tx(tester, 'old', d(2019, 1, 2), 7);
        await tx(tester, 'future', d(2027, 5, 6), 8);
        await tester.pumpAndSettle();
        await openTrend(tester);
        await pick(tester, 'export-all');
        final f = io.saved.single;
        expect(f.name, 'kvantum-penzugyek-osszes.csv');
        expect(rows(f.text).first, startsWith('2019-01-02;'));
        expect(rows(f.text).last, startsWith('2027-05-06;'));
        await shutdown(tester, db);
      });

      testWidgets('a deleted row is not in it', (tester) async {
        await boot(tester);
        await tx(tester, 'a', d(2026, 11, 3), 100);
        await tx(tester, 'b', d(2026, 11, 4), 200, deleted: true);
        await openTrend(tester);
        await pick(tester, 'export-month');
        expect(rows(io.saved.single.text), hasLength(1));
        await shutdown(tester, db);
      });

      testWidgets('no choice, no file', (tester) async {
        await boot(tester);
        await openTrend(tester);
        await tester.ensureVisible(find.byKey(const Key('trend-export')));
        await tester.tap(find.byKey(const Key('trend-export')));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(io.saved, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('the save dialog was cancelled: no message', (tester) async {
        await boot(tester);
        io.result = false;
        await openTrend(tester);
        await pick(tester, 'export-all');
        expect(io.saved, hasLength(1));
        expect(find.byType(SnackBar), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('it did not work: a message, not a crash', (tester) async {
        await boot(tester);
        io.failure = StateError('disk full');
        await openTrend(tester);
        await pick(tester, 'export-all');
        expect(find.text('Nem sikerült elmenteni a fájlt.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    });

    for (final dark in [false, true]) {
      testWidgets('at twice the text size on a phone nothing overflows '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        await boot(
          tester,
          size: const Size(360, 640),
          textScale: 2.0,
          theme: appTheme(dark ? Brightness.dark : Brightness.light),
        );
        await seed(tester);
        // (the test font draws every character a full em wide: an amount of
        // the overview, which is not what is looked at here, is wider than the
        // card at this size, so what was said until now is let go)
        tester.takeException();
        await openTrend(tester);
        expect(tester.takeException(), isNull);
        final list = find.descendant(
          of: find.byType(TrendTab),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.text('Hónapok számokkal'),
          300,
          scrollable: list,
        );
        // (built is not yet in view: bring it into view, then open it)
        await tester.ensureVisible(find.text('Hónapok számokkal'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hónapok számokkal'));
        await tester.pumpAndSettle();
        expect(find.textContaining('nincs rögzített tétel'), findsWidgets);
        await tester.scrollUntilVisible(
          find.byKey(const Key('trend-export')),
          300,
          scrollable: list,
        );
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    }
  });
}
