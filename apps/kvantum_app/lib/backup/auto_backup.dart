import 'dart:typed_data';

import '../diag/diag_log.dart';
import '../sync/error_catalog.dart';
import 'backup_service.dart';
import 'backup_store.dart';

/// What the automatic backup did last, as the Settings page tells it.
class AutoBackupState {
  const AutoBackupState({this.enabled = true, this.last, this.error});

  /// Whether the daily backup is switched on.
  final bool enabled;

  /// When the last one succeeded (UTC).
  final DateTime? last;

  /// Why the last one failed (null when it did not).
  final String? error;
}

/// A backup every day on this device, in a folder of its own, and the oldest
/// ones thrown away (the newest of each of the last 7 days and of the 4 weeks
/// before those stay). It runs when the app has started (not in the
/// background: there is none) and writes down what it did.
class AutoBackup {
  AutoBackup({
    required this.service,
    required this.store,
    required this.readMeta,
    required this.writeMeta,
    required this.now,
    this.log,
  });

  final BackupService service;
  final BackupStore store;
  final Future<String?> Function(String key) readMeta;
  final Future<void> Function(String key, String? value) writeMeta;

  /// The clock (replaced by tests).
  final DateTime Function() now;
  final DiagLog? log;

  static const enabledKey = 'backup.auto';
  static const lastKey = 'backup.last';
  static const errorKey = 'backup.error';

  /// A backup is due when the last one is older than this (a little less than
  /// a day, so that opening the app at about the same time every day never
  /// skips one).
  static const due = Duration(hours: 20);

  Future<AutoBackupState> state() async => AutoBackupState(
    enabled: (await readMeta(enabledKey)) != 'off',
    last: DateTime.tryParse(await readMeta(lastKey) ?? '')?.toUtc(),
    error: await readMeta(errorKey),
  );

  Future<void> setEnabled(bool on) => writeMeta(enabledKey, on ? null : 'off');

  /// The backup that is being made right now (a second request - the app
  /// came back to the front while the first one ran, or the button was
  /// pressed - joins it instead of making another).
  Future<BackupEntry?>? _running;

  Future<BackupEntry?> _once(Future<BackupEntry?> Function() job) =>
      _running ??= job().whenComplete(() => _running = null);

  /// Makes today's backup unless it is switched off or one is recent enough.
  /// Returns what it made (null when there was nothing to do). Never throws:
  /// a failed backup is written down, not raised.
  Future<BackupEntry?> runIfDue() => _once(() async {
    try {
      final s = await state();
      if (!s.enabled) return null;
      final last = s.last;
      if (last != null && now().toUtc().difference(last) < due) return null;
    } catch (e, st) {
      // (the settings are unreadable)
      log?.error('backup', 'due.failed', e, st);
      return null;
    }
    return _make();
  });

  /// Makes a backup now. Returns it, or null when it failed (the reason is in
  /// [AutoBackupState.error]).
  Future<BackupEntry?> backupNow() => _once(_make);

  Future<BackupEntry?> _make() async {
    try {
      final at = now();
      final Uint8List bytes = await service.create();
      final name = backupFileName(at);
      await store.write(name, bytes);
      await writeMeta(lastKey, at.toUtc().toIso8601String());
      await writeMeta(errorKey, null);
      await _tidy(at);
      log?.info('backup', 'auto.done', data: {'bytes': bytes.length});
      return BackupEntry(name, bytes.length, backupTimeOf(name));
    } catch (e, st) {
      log?.error('backup', 'auto.failed', e, st);
      try {
        await writeMeta(errorKey, errorInfoFor(e).text);
      } catch (_) {
        // (not even that could be written: nothing more to do)
      }
      return null;
    }
  }

  /// Throws away the backups the rule does not keep. A failure to delete one
  /// is not a failure of the backup.
  Future<void> _tidy(DateTime at) async {
    final names = [for (final e in await store.list()) e.name];
    for (final n in backupsToDelete(names, at)) {
      try {
        await store.delete(n);
      } catch (e, st) {
        log?.error('backup', 'tidy.failed', e, st);
      }
    }
  }
}
