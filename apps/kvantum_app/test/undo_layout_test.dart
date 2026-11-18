import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/shell_tab.dart';
import 'package:kvantum_app/ui/undo_service.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';

/// The "Visszavonás" bar in the real frame: each page has a round button of
/// its own, and the frame's bar knows nothing about them.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;

  Future<ProviderContainer> boot(WidgetTester tester, Size size) async {
    useSize(tester, size: size);
    db = await newDb();
    await tester.pumpWidget(
      app(
        const RootShell(),
        db,
        extra: [walletBridgeProvider.overrideWithValue(FakeWallet())],
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(RootShell)));
  }

  /// The visible card of the bar.
  Rect card(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first,
  );

  Future<void> showBar(WidgetTester tester, ProviderContainer c) async {
    c
        .read(undoServiceProvider)
        .offer(
          UndoSite.of(tester.element(find.byType(RootShell))),
          message: 'Esemény törölve',
          undo: () async => true,
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final size in [const Size(360, 800), const Size(1280, 900)]) {
    for (final (tab, inner) in <(ShellTab, String?)>[
      (ShellTab.calendar, null),
      (ShellTab.tasks, null),
      // (the diary tab has a round button on both its pages)
      (ShellTab.journal, 'journal-tab-entries'),
      (ShellTab.journal, 'journal-tab-intake'),
      (ShellTab.finance, null),
    ]) {
      testWidgets('the bar does not cover the round button on ${tab.label}'
          '${inner == null ? '' : ' ($inner)'} at '
          '${size.width.toInt()} px', (tester) async {
        final c = await boot(tester, size);
        c.read(shellTabProvider.notifier).select(tab);
        await tester.pumpAndSettle();
        if (inner != null) {
          await tester.tap(find.byKey(Key(inner)));
          await tester.pumpAndSettle();
        }
        if (tab == ShellTab.finance) {
          // (the overview has no round button; the transactions have one)
          await tester.tap(find.text('Tételek'));
          await tester.pumpAndSettle();
        }
        // (measured before the bar is up: a bar over a button makes it
        // un-hittable, and an empty list would pass for the wrong reason)
        final fabs = [
          for (final w in tester.widgetList<FloatingActionButton>(
            find.byType(FloatingActionButton).hitTestable(),
          ))
            tester.getRect(find.byWidget(w)),
        ];
        expect(fabs, isNotEmpty, reason: 'the page has a round button');
        await showBar(tester, c);
        final bar = card(tester);
        for (final r in fabs) {
          expect(bar.overlaps(r), isFalse, reason: 'bar $bar over button $r');
        }
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    }
  }

  testWidgets('the bar stays above the navigation bar', (tester) async {
    final c = await boot(tester, const Size(360, 800));
    await showBar(tester, c);
    final nav = tester.getRect(find.byType(NavigationBar));
    expect(card(tester).bottom, lessThanOrEqualTo(nav.top));
    await shutdown(tester, db);
  });
}
