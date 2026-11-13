import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import '../update/update_dialog.dart' show currentBuildProvider;
import 'auto_backup.dart';
import 'backup_key_store.dart';
import 'backup_service.dart';
import 'backup_store.dart';
import 'drive_backup.dart';

/// Where the backups of this device are kept. `main.dart` gives the folder
/// next to the database; until then (and in tests) they are kept in memory.
final backupStoreProvider = Provider<BackupStore>((_) => MemoryBackupStore());

/// Where packing and unpacking a backup run: on another isolate, so the
/// screen does not freeze (tests run them in place).
final backupRunnerProvider = Provider<BackupRunner>((_) => onIsolate);

/// Whether the app makes its daily backup by itself (`main.dart` switches it
/// on; the widget tests have no need of it).
final autoBackupRunsProvider = Provider<bool>((_) => false);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    events: ref.watch(repoProvider),
    records: ref.watch(recordRepoProvider),
    finance: ref.watch(financeRepoProvider),
    now: ref.watch(appClockProvider),
    build: () => ref.read(currentBuildProvider.future),
    runner: ref.watch(backupRunnerProvider),
  ),
);

final autoBackupProvider = Provider<AutoBackup>((ref) {
  final repo = ref.watch(repoProvider);
  return AutoBackup(
    service: ref.watch(backupServiceProvider),
    store: ref.watch(backupStoreProvider),
    readMeta: repo.meta,
    writeMeta: repo.setMeta,
    now: ref.watch(appClockProvider),
    log: ref.watch(diagLogProvider),
  );
});

/// What the daily backup did last (the Settings page shows it).
final autoBackupStateProvider = FutureProvider.autoDispose<AutoBackupState>(
  (ref) => ref.watch(autoBackupProvider).state(),
);

/// The backups on this device, newest first.
final backupEntriesProvider = FutureProvider.autoDispose<List<BackupEntry>>(
  (ref) => ref.watch(backupStoreProvider).list(),
);

/// Where the password of the Drive copy lives. `main.dart` gives the OS secure
/// store; until then (and in tests) it is kept in memory.
final backupKeyStoreProvider = Provider<BackupKeyStore>(
  (_) => MemoryBackupKeyStore(),
);

final driveBackupProvider = Provider<DriveBackup>((ref) {
  final repo = ref.watch(repoProvider);
  return DriveBackup(
    service: ref.watch(backupServiceProvider),
    // (asked when needed: the login comes and goes)
    remote: () => ref.read(syncControllerProvider.notifier).driveRemote(),
    keys: ref.watch(backupKeyStoreProvider),
    readMeta: repo.meta,
    writeMeta: repo.setMeta,
    now: ref.watch(appClockProvider),
    log: ref.watch(diagLogProvider),
  );
});

/// What the Drive copy did last (the Settings page shows it).
final driveBackupStateProvider = FutureProvider.autoDispose<DriveBackupState>(
  (ref) => ref.watch(driveBackupProvider).state(),
);
