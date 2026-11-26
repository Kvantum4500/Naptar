import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/notify/budget_alerts.dart';
import 'package:kvantum_app/notify/budget_notify.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_budget_notifier.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the settings page, budget alerts', () {
    late AppDatabase db;
    late ProviderContainer c;

    Future<void> mount(
      WidgetTester tester,
      FakeBudgetNotifier notifier, {
      Size size = const Size(900, 6400),
      double? textScale,
      Future<void> Function()? seed,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      if (seed != null) await tester.runAsync(seed);
      await tester.pumpWidget(
        app(
          const SettingsPage(),
          db,
          textScale: textScale,
          extra: [
            apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null)),
            budgetNotifierProvider.overrideWithValue(notifier),
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));
    }

    Finder switchTile() =>
        find.widgetWithText(SwitchListTile, 'Értesítés a költségkeretről');
    bool isOn(WidgetTester tester) =>
        tester.widget<SwitchListTile>(switchTile()).value;
    Future<String?> meta(WidgetTester tester, String key) async {
      String? value;
      await tester.runAsync(() async {
        value = await c.read(recordRepoProvider).meta(key);
      });
      return value;
    }

    testWidgets('where notifications cannot be shown, the card is not there', (
      tester,
    ) async {
      await mount(tester, FakeBudgetNotifier(isSupported: false));
      expect(find.text('Költségkeret'), findsNothing);
      expect(switchTile(), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the card is there, off at first, among the notifications', (
      tester,
    ) async {
      await mount(tester, FakeBudgetNotifier());
      expect(find.text('Költségkeret'), findsOneWidget);
      expect(switchTile(), findsOneWidget);
      expect(isOn(tester), isFalse);
      expect(
        find.textContaining('Szól, ha egy kategória eléri a keret 80%-át'),
        findsOneWidget,
      );
      expect(
        find.textContaining('nem megy el hozzá adat sehová'),
        findsWidgets,
      );

      // after the reminders, in the group of the notifications
      double top(String text) => tester.getTopLeft(find.text(text).first).dy;
      expect(top('Értesítések'), lessThan(top('Költségkeret')));
      expect(top('Emlékeztetők'), lessThan(top('Költségkeret')));
      expect(top('Költségkeret'), lessThan(top('Adatok')));
      await shutdown(tester, db);
    });

    testWidgets('switching it on asks, and remembers what is over', (
      tester,
    ) async {
      final fake = FakeBudgetNotifier();
      await mount(
        tester,
        fake,
        seed: () async {
          final fin = FinanceRepository(db);
          await fin.saveBudget(
            const FinBudget(categoryId: 'cat-food', limit: 10000),
          );
          await fin.saveTx(
            FinTx(
              id: 'a',
              date: floating(2026, 11, 10),
              amount: 12000,
              kind: FinKind.expense,
              categoryId: 'cat-food',
            ),
          );
        },
      );
      await tester.tap(switchTile());
      await tester.pumpAndSettle();

      expect(fake.permissionAsks, 1);
      expect(isOn(tester), isTrue);
      expect(await meta(tester, budgetAlertsKey), 'on');
      expect(await meta(tester, 'bud.alert.2026-11'), '{"cat-food":2}');
      expect(find.byType(SnackBar), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a refusal leaves it off and says why', (tester) async {
      final fake = FakeBudgetNotifier(grant: false);
      await mount(tester, fake);
      await tester.tap(switchTile());
      await tester.pumpAndSettle();

      expect(fake.permissionAsks, 1);
      expect(isOn(tester), isFalse);
      expect(await meta(tester, budgetAlertsKey), isNull);
      expect(
        find.textContaining('Az értesítések le vannak tiltva'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('switching it off is not asked of anybody', (tester) async {
      final fake = FakeBudgetNotifier();
      await mount(
        tester,
        fake,
        seed: () => RecordRepository(db).setMeta(budgetAlertsKey, 'on'),
      );
      expect(isOn(tester), isTrue);
      await tester.tap(switchTile());
      await tester.pumpAndSettle();

      expect(isOn(tester), isFalse);
      expect(fake.permissionAsks, 0);
      expect(await meta(tester, budgetAlertsKey), isNull);
      await shutdown(tester, db);
    });

    testWidgets('on a narrow screen with the largest text nothing overflows', (
      tester,
    ) async {
      await mount(
        tester,
        FakeBudgetNotifier(),
        size: const Size(360, 800),
        textScale: 2.0,
      );
      await tester.scrollUntilVisible(
        switchTile(),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(switchTile(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });
}
