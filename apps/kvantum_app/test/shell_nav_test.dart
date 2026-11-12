import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/shell_tab.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';

/// Counts how often the running request was cancelled.
class _CountingAssistant extends AssistantController {
  static int cancels = 0;

  @override
  void cancel() {
    cancels++;
    super.cancel();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;

  Future<ProviderContainer> boot(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    List<Override> extra = const [],
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    await tester.pumpWidget(
      app(
        const RootShell(),
        db,
        extra: [walletBridgeProvider.overrideWithValue(FakeWallet()), ...extra],
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(RootShell)));
  }

  /// A destination of the bar or the rail, by its label.
  Finder dest(String label) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is NavigationBar || w is NavigationRail,
    ),
    matching: find.text(label),
  );

  group('the destinations', () {
    testWidgets('a phone gets a bottom bar: four pages and "Több"', (
      tester,
    ) async {
      await boot(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      for (final l in [
        'Naptár',
        'Feladatok',
        'Asszisztens',
        'Pénzügyek',
        'Több',
      ]) {
        expect(dest(l), findsOneWidget, reason: l);
      }
      await shutdown(tester, db);
    });

    testWidgets('a wide window gets the same destinations in a rail', (
      tester,
    ) async {
      await boot(tester, size: const Size(1280, 800));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      for (final l in [
        'Naptár',
        'Feladatok',
        'Asszisztens',
        'Pénzügyek',
        'Több',
      ]) {
        expect(dest(l), findsOneWidget, reason: l);
      }
      await shutdown(tester, db);
    });

    testWidgets('the rail begins at 760 px, the bar below', (tester) async {
      await boot(tester, size: const Size(759, 800));
      expect(find.byType(NavigationBar), findsOneWidget);
      await shutdown(tester, db);
      await boot(tester, size: const Size(760, 800));
      expect(find.byType(NavigationRail), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the calendar bar no longer holds the page shortcuts', (
      tester,
    ) async {
      await boot(tester);
      final bar = find.descendant(
        of: find.byType(AppBar),
        matching: find.byWidgetPredicate(
          (w) => w is IconButton || w is PopupMenuButton,
        ),
      );
      for (final t in [
        'Menü',
        'Feladatok',
        'Asszisztens',
        'Beosztás',
        'Beállítások',
      ]) {
        expect(
          find.descendant(of: bar, matching: find.byTooltip(t)),
          findsNothing,
          reason: t,
        );
        expect(
          find.descendant(of: find.byType(AppBar), matching: find.byTooltip(t)),
          findsNothing,
          reason: t,
        );
      }
      await shutdown(tester, db);
    });
  });

  group('switching', () {
    testWidgets('each page opens from the bar', (tester) async {
      final c = await boot(tester);
      expect(c.read(shellTabProvider), ShellTab.calendar);
      expect(find.byType(HomePage), findsOneWidget);

      await tester.tap(dest('Feladatok'));
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.tasks);
      expect(find.byType(TasksPage), findsOneWidget);

      await tester.tap(dest('Asszisztens'));
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.assistant);
      expect(find.text('Mit tervezzen az asszisztens?'), findsOneWidget);

      await tester.tap(dest('Pénzügyek'));
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.finance);
      expect(find.byType(FinancePage), findsOneWidget);

      await tester.tap(dest('Naptár'));
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.calendar);
      await shutdown(tester, db);
    });

    testWidgets('a page is built the first time it is shown, then kept', (
      tester,
    ) async {
      await boot(tester);
      expect(find.byType(TasksPage, skipOffstage: false), findsNothing);
      expect(find.byType(FinancePage, skipOffstage: false), findsNothing);
      await tester.tap(dest('Feladatok'));
      await tester.pumpAndSettle();
      await tester.tap(dest('Naptár'));
      await tester.pumpAndSettle();
      expect(find.byType(TasksPage, skipOffstage: false), findsOneWidget);
      expect(find.byType(FinancePage, skipOffstage: false), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a page that is not showing takes no keyboard focus', (
      tester,
    ) async {
      await boot(tester);
      for (final l in ['Feladatok', 'Asszisztens', 'Pénzügyek', 'Naptár']) {
        await tester.tap(dest(l));
        await tester.pumpAndSettle();
      }
      final excluded = tester
          .widgetList<ExcludeFocus>(
            find.byWidgetPredicate(
              // the shell's own wrappers (the framework has others)
              (w) => w is ExcludeFocus && w.child is TickerMode,
              skipOffstage: false,
            ),
          )
          .where((e) => e.excluding)
          .length;
      expect(excluded, 3, reason: 'all but the calendar');
      await shutdown(tester, db);
    });

    testWidgets('a page that is not showing runs no animations', (
      tester,
    ) async {
      await boot(tester);
      for (final l in ['Feladatok', 'Asszisztens', 'Pénzügyek', 'Naptár']) {
        await tester.tap(dest(l));
        await tester.pumpAndSettle();
      }
      final stopped = tester
          .widgetList<TickerMode>(
            find.byWidgetPredicate(
              (w) => w is TickerMode && w.child is! TickerMode,
              skipOffstage: false,
            ),
          )
          .where((t) => !t.enabled)
          .length;
      expect(stopped, greaterThanOrEqualTo(3), reason: 'all but the calendar');
      await shutdown(tester, db);
    });

    testWidgets('the calendar keeps its view while another page shows', (
      tester,
    ) async {
      final c = await boot(tester);
      c.read(viewModeProvider.notifier).set(CalView.day);
      await tester.pumpAndSettle();
      await tester.tap(dest('Pénzügyek'));
      await tester.pumpAndSettle();
      await tester.tap(dest('Naptár'));
      await tester.pumpAndSettle();
      expect(c.read(viewModeProvider), CalView.day);
      await shutdown(tester, db);
    });
  });

  group('"Több"', () {
    testWidgets('opens the shift planner and the settings as pages', (
      tester,
    ) async {
      final c = await boot(tester, size: const Size(700, 900));
      await tester.tap(dest('Több'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-shifts')), findsOneWidget);
      expect(find.byKey(const Key('more-settings')), findsOneWidget);

      await tester.tap(find.byKey(const Key('more-shifts')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Beosztás'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing, reason: 'a full page');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(dest('Több'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('more-settings')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Beállítások'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // "Több" is no page: the one that was showing still is
      expect(c.read(shellTabProvider), ShellTab.calendar);
      await shutdown(tester, db);
    });

    testWidgets('does not change the page that is showing', (tester) async {
      final c = await boot(tester);
      await tester.tap(dest('Pénzügyek'));
      await tester.pumpAndSettle();
      await tester.tap(dest('Több'));
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.finance);
      // dismiss the sheet by tapping outside it
      await tester.tapAt(const Offset(180, 40));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-shifts')), findsNothing);
      expect(c.read(shellTabProvider), ShellTab.finance);
      await shutdown(tester, db);
    });

    testWidgets('works from the rail of a wide window too', (tester) async {
      await boot(tester, size: const Size(1280, 800));
      await tester.tap(dest('Több'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-settings')), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('back', () {
    testWidgets('goes to the calendar first', (tester) async {
      final c = await boot(tester);
      await tester.tap(dest('Pénzügyek'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(c.read(shellTabProvider), ShellTab.calendar);
      await shutdown(tester, db);
    });

    testWidgets('may leave the app only from the calendar', (tester) async {
      final c = await boot(tester);
      PopScope scope() => tester.widget(
        find.descendant(
          of: find.byType(RootShell),
          matching: find.byWidgetPredicate((w) => w is PopScope),
        ),
      ) as PopScope;
      expect(scope().canPop, isTrue, reason: 'on the calendar');
      await tester.tap(dest('Feladatok'));
      await tester.pumpAndSettle();
      expect(scope().canPop, isFalse, reason: 'elsewhere: first the calendar');
      expect(c.read(shellTabProvider), ShellTab.tasks);
      await shutdown(tester, db);
    });
  });

  group('the assistant', () {
    testWidgets('leaving its page ends the running request', (tester) async {
      _CountingAssistant.cancels = 0;
      await boot(
        tester,
        extra: [
          assistantControllerProvider.overrideWith(_CountingAssistant.new),
        ],
      );
      await tester.tap(dest('Asszisztens'));
      await tester.pumpAndSettle();
      expect(_CountingAssistant.cancels, 0);
      await tester.tap(dest('Pénzügyek'));
      await tester.pumpAndSettle();
      expect(_CountingAssistant.cancels, 1);
      await shutdown(tester, db);
    });

    testWidgets('choosing the page that is already showing does not cancel', (
      tester,
    ) async {
      _CountingAssistant.cancels = 0;
      await boot(
        tester,
        extra: [
          assistantControllerProvider.overrideWith(_CountingAssistant.new),
        ],
      );
      await tester.tap(dest('Asszisztens'));
      await tester.pumpAndSettle();
      await tester.tap(dest('Asszisztens'));
      await tester.pumpAndSettle();
      expect(_CountingAssistant.cancels, 0);
      await shutdown(tester, db);
    });

    testWidgets('moving between other pages does not touch it', (tester) async {
      _CountingAssistant.cancels = 0;
      await boot(
        tester,
        extra: [
          assistantControllerProvider.overrideWith(_CountingAssistant.new),
        ],
      );
      for (final l in ['Feladatok', 'Pénzügyek', 'Naptár']) {
        await tester.tap(dest(l));
        await tester.pumpAndSettle();
      }
      expect(_CountingAssistant.cancels, 0);
      await shutdown(tester, db);
    });
  });

  group('the keyboard after a page change', () {
    testWidgets('works again when the calendar is chosen again', (
      tester,
    ) async {
      final c = await boot(tester, size: const Size(1280, 800));
      await tester.tap(dest('Feladatok'));
      await tester.pumpAndSettle();
      await tester.tap(dest('Naptár'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pumpAndSettle();
      expect(c.read(viewModeProvider), CalView.week);
      await shutdown(tester, db);
    });
  });
}
