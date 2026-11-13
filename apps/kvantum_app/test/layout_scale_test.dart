import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_app/ui/time_grid.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';
import 'support/real_fonts.dart';

// What the large-text layout rules do, one by one (the text_scale_test checks
// that nothing overflows; these check that things are the right size). They
// measure with Roboto, the font Android draws the app in: the test font says
// nothing about heights.

const _phone = Size(360, 800);
const _small = Size(360, 640);
const _wide = Size(1280, 900);

final _skip = robotoAvailable
    ? null
    : 'Roboto not found in the Flutter SDK cache: the check needs real text '
          'metrics';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
    if (robotoAvailable) await loadRoboto();
  });

  late AppDatabase db;
  late EventRepository events;
  late FinanceRepository fin;

  void t(String description, WidgetTesterCallback body) =>
      testWidgets(description, body, skip: _skip != null);

  /// Opens [home] at a text size ([scale]) and a window size. Thursday
  /// 2026-11-12, 10:00 in Budapest.
  Future<void> show(
    WidgetTester tester,
    Widget home, {
    Size size = _phone,
    double scale = 1.0,
    Future<void> Function()? seed,
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    events = EventRepository(db);
    fin = FinanceRepository(db);
    if (seed != null) await tester.runAsync(seed);
    await tester.pumpWidget(
      app(
        home,
        db,
        textScale: scale,
        theme: appTheme(Brightness.light),
        extra: [
          appClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 11, 12, 9),
          ),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          walletBridgeProvider.overrideWithValue(FakeWallet(supported: false)),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> done(WidgetTester tester) => shutdown(tester, db);

  Future<void> viewAs(WidgetTester tester, CalView view) async {
    ProviderScope.containerOf(tester.element(find.byType(HomePage)))
        .read(viewModeProvider.notifier)
        .set(view);
    await tester.pumpAndSettle();
  }

  final meeting = evt(
    'm',
    'Megbeszélés a lakásfelújításról',
    floating(2026, 11, 12, 10),
  );

  group('the hours of the week and day view', () {
    t('an hour is as tall as the text needs, up to 1.6 times', (tester) async {
      Future<double> heightAt(double scale) async {
        late double h;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Builder(
              builder: (c) {
                h = hourHeightOf(c);
                return const SizedBox();
              },
            ),
          ),
        );
        return h;
      }

      expect(await heightAt(1.0), kHourHeight);
      expect(await heightAt(0.8), kHourHeight); // (never smaller than normal)
      expect(await heightAt(1.3), closeTo(kHourHeight * 1.3, 0.01));
      expect(await heightAt(2.0), closeTo(kHourHeight * 1.6, 0.01));
      expect(
        await heightAt(3.0),
        closeTo(kHourHeight * 1.6, 0.01),
      ); // (the cap)
    });

    t('at 200 % an hour-long block holds its title and its time', (
      tester,
    ) async {
      await show(
        tester,
        const HomePage(),
        scale: 2.0,
        seed: () => events.saveAll([meeting]),
      );
      await viewAs(tester, CalView.day);
      final title = find.text('Megbeszélés a lakásfelújításról');
      expect(title, findsOneWidget);
      // two lines of 12-point text, doubled, at a line height of 1.2
      expect(tester.getSize(title).height, closeTo(2 * 12 * 2 * 1.2, 1));
      expect(find.text('10:00–11:00'), findsOneWidget);
      await done(tester);
    });

    t('a half-hour block has a one-line title, an hour-long one two', (
      tester,
    ) async {
      // both long enough to need two lines in a column of 300 pixels
      const half =
          'Fogorvosi kontroll és fogkő eltávolítás a belvárosi rendelőben';
      const hour =
          'Fogorvosi kontroll és fogkő eltávolítás a belvárosi rendelőben II.';
      await show(
        tester,
        const HomePage(),
        seed: () => events.saveAll([
          evt(
            'h',
            half,
            floating(2026, 11, 12, 10),
            len: const Duration(minutes: 30),
          ),
          evt('k', hour, floating(2026, 11, 12, 12)),
        ]),
      );
      await viewAs(tester, CalView.day);
      // 12-point text at a line height of 1.2
      expect(tester.getSize(find.text(half)).height, closeTo(12 * 1.2, 1));
      expect(
        tester.getSize(find.text(hour)).height,
        closeTo(2 * 12 * 1.2, 1.5),
      );
      await done(tester);
    });

    t('a short event is tall enough for one line of its title', (tester) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const HomePage(),
        scale: 2.0,
        seed: () => events.saveAll([
          evt(
            's',
            'Rövid hívás',
            floating(2026, 11, 12, 10),
            len: const Duration(minutes: 15),
          ),
        ]),
      );
      await viewAs(tester, CalView.day);
      final block = find.bySemanticsLabel(
        'Rövid hívás, csütörtök, 2026. november 12., 10:00–10:15',
      );
      expect(block, findsOneWidget);
      // the title's line (28.8) and the margin: more than 15 minutes' worth of
      // an hour (89.6 / 4 = 22.4)
      expect(tester.getSize(block).height, greaterThanOrEqualTo(28.8 + 4));
      handle.dispose();
      await done(tester);
    });

    t('the time is left out of a block too narrow for it', (tester) async {
      Future<void> week(Size size) async {
        await show(
          tester,
          const HomePage(),
          size: size,
          seed: () => events.saveAll([meeting]),
        );
        await viewAs(tester, CalView.week);
      }

      // a week on a phone: seven columns of 44 pixels
      await week(_phone);
      expect(find.text('10:00–11:00'), findsNothing);
      await done(tester);

      // a week on a wide window
      await week(_wide);
      expect(find.text('10:00–11:00'), findsOneWidget);
      await done(tester);
    });

    t('a tall all-day strip scrolls and leaves room for the hours', (
      tester,
    ) async {
      final day = floating(2026, 11, 12);
      await show(
        tester,
        Scaffold(
          body: SizedBox(
            height: 160,
            child: TimeGrid(
              days: [day],
              range: DayRange(day, day.add(const Duration(days: 1))),
              showDayHeader: false,
              onOpen: (_) {},
              onCreateAt: (_) {},
            ),
          ),
        ),
        scale: 2.0,
        seed: () => events.saveAll([
          for (var i = 0; i < 3; i++)
            evt(
              'a$i',
              'Egésznapos $i',
              day,
              allDay: true,
              len: const Duration(days: 1),
            ),
        ]),
      );
      expect(tester.takeException(), isNull);
      // the hours (the last scroll view) keep at least half of the space
      expect(
        tester.getSize(find.byType(SingleChildScrollView).last).height,
        greaterThanOrEqualTo(80 - 0.01),
      );
      await done(tester);
    });
  });

  group('the month', () {
    t('a cell too short for dots shows a mark after the number', (
      tester,
    ) async {
      await show(
        tester,
        const HomePage(),
        size: _small,
        scale: 2.0,
        seed: () => events.saveAll([meeting]),
      );
      expect(find.text('12 •'), findsOneWidget);
      await done(tester);
    });

    t('a colour bar is as tall as its text at 200 %', (tester) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const HomePage(),
        size: _wide,
        scale: 2.0,
        seed: () => events.saveAll([
          evt(
            'k',
            'Konferencia',
            floating(2026, 11, 14),
            allDay: true,
            len: const Duration(days: 1),
          ),
        ]),
      );
      final bar = find.bySemanticsLabel('Konferencia, egész nap');
      expect(bar, findsOneWidget);
      // an 11-point line of 1.1, doubled, and a margin (the bar was 17 pixels)
      expect(
        tester.getSize(bar).height,
        greaterThanOrEqualTo(24.2 + 4.9 - 0.1),
      );
      handle.dispose();
      await done(tester);
    });

    t('on a short phone the title of the day panel scrolls, not overflows', (
      tester,
    ) async {
      // 400 pixels high, text at 200 %: the panel under the grid (two fifths
      // of the page) is shorter than its own title (a date on three lines and
      // the "no events" line)
      await show(
        tester,
        const HomePage(),
        size: const Size(360, 400),
        scale: 2.0,
      );
      expect(tester.takeException(), isNull);
      final noEvents = find.text('Nincs esemény erre a napra.');
      final hours = find.byType(TimeGrid).last;
      // the title keeps to half of the panel: the hours are not squeezed out
      expect(tester.getSize(hours).height, greaterThanOrEqualTo(40));
      // and the rest of the title is one scroll away
      expect(
        tester.getRect(noEvents).bottom,
        greaterThan(tester.getRect(hours).top),
      );
      // (the date is taller than what shows of it: grab its top)
      await tester.dragFrom(
        tester.getTopLeft(find.text(fmtDateLong(DateTime(2026, 11, 12)))) +
            const Offset(20, 10),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(
        tester.getRect(noEvents).bottom,
        lessThanOrEqualTo(tester.getRect(hours).top + 0.5),
      );
      expect(tester.takeException(), isNull);
      await done(tester);
    });

    t('a cell with room shows the dots, as before', (tester) async {
      await show(
        tester,
        const HomePage(),
        seed: () => events.saveAll([meeting]),
      );
      expect(find.byKey(const Key('month-dots')), findsOneWidget);
      expect(find.text('12 •'), findsNothing);
      await done(tester);
    });
  });

  group('the other pages', () {
    t('the agenda keeps a time in one piece at 200 %', (tester) async {
      await show(
        tester,
        const HomePage(),
        scale: 2.0,
        seed: () => events.saveAll([
          evt(
            'w',
            'Reggeli edzés',
            floating(2026, 11, 12, 7),
            len: const Duration(minutes: 90),
          ),
        ]),
      );
      await viewAs(tester, CalView.agenda);
      // two lines (the start, the end), not a time broken in the middle
      expect(
        tester.getSize(find.text('07:00\n08:30')).height,
        lessThanOrEqualTo(70),
      );
      await done(tester);
    });

    t('the editor keeps its labels whole at 200 %', (tester) async {
      await show(tester, const HomePage(), scale: 2.0);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      // one line of 14-point text, doubled (the broken label was two)
      expect(tester.getSize(find.text('Kezdés')).height, lessThan(50));
      expect(tester.getSize(find.text('Befejezés')).height, lessThan(50));
      await done(tester);
    });

    t('the bottom bar writes only the chosen label at 200 %', (tester) async {
      await show(tester, const RootShell(), scale: 2.0);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
        NavigationDestinationLabelBehavior.onlyShowSelected,
      );
      await done(tester);

      await show(tester, const RootShell());
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
        NavigationDestinationLabelBehavior.alwaysShow,
      );
      await done(tester);
    });
  });

  group('the money overview', () {
    Future<void> seedMoney() async {
      await fin.ensureDefaults();
      await fin.saveBudget(
        const FinBudget(categoryId: 'cat-food', limit: 10000),
      );
      await fin.saveTx(
        FinTx(
          id: 'x',
          date: floating(2026, 11, 3),
          amount: 3000,
          kind: FinKind.expense,
          categoryId: 'cat-food',
        ),
      );
      await fin.saveTx(
        FinTx(
          id: 'i',
          date: floating(2026, 11, 5),
          amount: 520000,
          kind: FinKind.income,
          categoryId: 'cat-salary',
        ),
      );
    }

    Element? cardOf(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(Card))
        .evaluate()
        .firstOrNull;

    t('three cards side by side where the amounts fit', (tester) async {
      await show(
        tester,
        const FinancePage(),
        size: const Size(900, 1400),
        seed: seedMoney,
      );
      expect(cardOf('Bevétel'), isNotNull);
      expect(cardOf('Bevétel'), isNot(cardOf('Kiadás')));
      expect(cardOf('Kiadás'), isNot(cardOf('Egyenleg')));
      await done(tester);
    });

    t('one card with three lines where they do not', (tester) async {
      await show(
        tester,
        const FinancePage(),
        size: const Size(360, 2000),
        scale: 2.0,
        seed: seedMoney,
      );
      expect(cardOf('Bevétel'), isNotNull);
      expect(cardOf('Bevétel'), cardOf('Kiadás'));
      expect(cardOf('Kiadás'), cardOf('Egyenleg'));
      await done(tester);
    });

    t('a budget row has its amounts beside the name where both fit', (
      tester,
    ) async {
      await show(
        tester,
        const FinancePage(),
        size: const Size(900, 1400),
        seed: seedMoney,
      );
      final name = find.text('Élelmiszer');
      final amounts = find.text('${formatHuf(3000)} / ${formatHuf(10000)}');
      expect(
        (tester.getCenter(name).dy - tester.getCenter(amounts).dy).abs(),
        lessThan(6),
      );
      await done(tester);
    });

    t('and under the name where they do not', (tester) async {
      await show(
        tester,
        const FinancePage(),
        size: const Size(360, 2000),
        scale: 2.0,
        seed: seedMoney,
      );
      final name = find.text('Élelmiszer');
      final amounts = find.text('${formatHuf(3000)} / ${formatHuf(10000)}');
      expect(
        tester.getTopLeft(amounts).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(name).dy - 1),
      );
      await done(tester);
    });
  });
}
