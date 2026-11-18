import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/intake/intake_providers.dart';
import 'package:kvantum_app/journal/journal_providers.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// What the providers of the app hand to the stores (8th round): after every
/// change of the diary, the food log or the synced settings the sync is asked
/// to run, and the daily upkeep sweeps the pictures. (The stores themselves are
/// tested with their own callbacks; this holds that the app connects them.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late _Ctl ctl;
  late MemoryPhotoFiles files;

  setUp(() async {
    db = await newDb();
    ctl = _Ctl();
    files = MemoryPhotoFiles();
  });
  tearDown(() => db.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        ...baseOverrides(db),
        syncControllerProvider.overrideWith(() => ctl),
        photoFilesProvider.overrideWithValue(files),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a saved diary entry asks the sync to run, once', () async {
    final c = container();
    await c
        .read(journalOpsProvider)
        .save(
          JournalEntry.checked(
            id: 'e1',
            at: DateTime.utc(2026, 11, 16, 8),
            title: 'Cím',
            text: 'Szöveg',
          ),
        );
    expect(ctl.calls, ['request']);
  });

  test('a logged food asks the sync to run, once', () async {
    final c = container();
    await c
        .read(intakeOpsProvider)
        .addFood(
          day: DateTime.utc(2026, 11, 16),
          minute: 8 * 60,
          meal: Meal.breakfast,
          kcal: 300,
        );
    expect(ctl.calls, ['request']);
  });

  test('a saved setting asks the sync to run, once', () async {
    final c = container();
    await c
        .read(syncedSettingsProvider)
        .savePay(const PaySettings(hourly: 2500));
    expect(ctl.calls, ['request']);
  });

  test('the daily upkeep sweeps the pictures nobody refers to', () async {
    final c = container();
    files.put(
      'orphan.jpg',
      Uint8List.fromList([1]),
      age: const Duration(days: 30),
    );
    final report = await c.read(housekeepingProvider).runIfDue();
    expect(report, isNotNull);
    expect(report!.photos, 1);
    expect(files.names, isEmpty);
  });
}

/// A sync controller that only counts what it is asked.
class _Ctl extends SyncController {
  final calls = <String>[];

  @override
  SyncState build() => const SyncState();

  @override
  void requestSync() => calls.add('request');
}
