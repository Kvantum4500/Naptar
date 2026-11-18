import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/housekeeping.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';

/// What the app does when it starts, before anybody asks (8th round): the
/// settings an older version kept on this device only become synced settings,
/// and the daily upkeep runs. Whatever goes wrong there is written to the log
/// and nothing more: the app comes up.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  testWidgets('an upkeep that fails is logged, and the app comes up all the '
      'same', (tester) async {
    useSize(tester, size: const Size(400, 900));
    final db = await newDb();
    final sink = MemoryDiagSink();
    final log = DiagLog()..attach(sink);
    await tester.pumpWidget(
      app(
        const RootShell(),
        db,
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          diagLogProvider.overrideWithValue(log),
          syncedSettingsProvider.overrideWith(
            (ref) => _BrokenTakeOver(ref.watch(recordRepoProvider)),
          ),
          housekeepingProvider.overrideWith((ref) => _BrokenUpkeep(ref)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RootShell), findsOneWidget);
    await tester.runAsync(log.flush);
    final text = sink.lines.join('\n');
    expect(text, contains('settings.takeover_failed'));
    expect(text, contains('housekeeping.failed'));
    await shutdown(tester, db);
  });
}

/// A take-over that cannot be done (the database is locked).
class _BrokenTakeOver extends SyncedSettings {
  _BrokenTakeOver(super.repo);

  @override
  Future<bool> takeOverOldSettings() => throw StateError('zárolt');
}

/// An upkeep that cannot run.
class _BrokenUpkeep extends Housekeeping {
  _BrokenUpkeep(Ref ref)
    : super(
        events: ref.watch(repoProvider),
        finance: ref.watch(financeRepoProvider),
        now: ref.watch(appClockProvider),
      );

  @override
  Future<HousekeepingReport?> runIfDue() => throw StateError('zárolt');
}
