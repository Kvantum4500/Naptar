import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diag/diag_log.dart';
import '../drive/drive_remote.dart' show DriveName;
import '../providers.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import '../ui/format.dart';
import 'backup_bundle.dart';
import 'backup_dialogs.dart';
import 'backup_file_io.dart';
import 'backup_providers.dart';
import 'backup_store.dart';
import 'drive_backup.dart' show DriveBackupState;

enum _Job { now, toFile, restore, drive }

enum _EntryAction { restore, save, delete }

/// The body of the "Automatikus mentés" card in Settings: the daily backup on
/// this device, a full backup into a file (optionally locked with a password)
/// and the restore of either.
class BackupBody extends ConsumerStatefulWidget {
  const BackupBody({super.key});

  @override
  ConsumerState<BackupBody> createState() => _BackupBodyState();
}

class _BackupBodyState extends ConsumerState<BackupBody> {
  _Job? _job;

  /// The backups shown at most (the rule keeps about eleven).
  static const _shown = 12;

  void _work(_Job? job) {
    if (mounted) setState(() => _job = job);
  }

  // (the page may have been left while a backup was being made)
  void _refresh() {
    if (!mounted) return;
    ref.invalidate(autoBackupStateProvider);
    ref.invalidate(backupEntriesProvider);
  }

  void _refreshDrive() {
    if (mounted) ref.invalidate(driveBackupStateProvider);
  }

  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(m),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  void _fail(String what, String code, Object e, StackTrace st) {
    ref.read(diagLogProvider).error('backup', code, e, st);
    _toast('$what: ${errorInfoFor(e).text}', error: true);
  }

  // ------------------------------------------------------------ actions

  Future<void> _backupNow() async {
    _work(_Job.now);
    try {
      final auto = ref.read(autoBackupProvider);
      final made = await auto.backupNow();
      _refresh();
      if (made != null) {
        _toast('A mentés elkészült (${backupSizeText(made.size)}).');
      } else {
        final why = (await auto.state()).error;
        _toast(
          'A mentés nem sikerült: ${why ?? 'ismeretlen hiba'}',
          error: true,
        );
      }
    } finally {
      _work(null);
    }
  }

  Future<void> _toFile() async {
    final answer = await askSavePassword(context);
    if (answer == null || !mounted) return;
    final service = ref.read(backupServiceProvider);
    final io = ref.read(backupFileIoProvider);
    final clock = ref.read(appClockProvider);
    _work(_Job.toFile);
    try {
      final bytes = await service.create(password: answer.password);
      _work(null); // (the save dialog is the system's)
      final ok = await io.save(backupFileName(clock()), bytes);
      if (ok) {
        _toast(
          answer.password == null
              ? 'A mentés elmentve.'
              : 'A mentés elmentve, jelszóval védve.',
        );
      }
    } catch (e, st) {
      _fail('A mentés nem sikerült', 'file.save_failed', e, st);
    } finally {
      _work(null);
    }
  }

  Future<void> _fromFile() async {
    final Uint8List? bytes;
    try {
      bytes = await ref.read(backupFileIoProvider).pick();
    } catch (e, st) {
      _fail('A fájl megnyitása nem sikerült', 'file.pick_failed', e, st);
      return;
    }
    if (bytes == null || !mounted) return;
    await _restore(bytes);
  }

  Future<void> _entryAction(BackupEntry entry, _EntryAction action) async {
    final store = ref.read(backupStoreProvider);
    final io = ref.read(backupFileIoProvider);
    try {
      switch (action) {
        case _EntryAction.restore:
          final bytes = await store.read(entry.name);
          if (bytes == null) {
            _refresh();
            _toast('Ez a mentés már nincs meg.', error: true);
            return;
          }
          await _restore(bytes);
        case _EntryAction.save:
          final bytes = await store.read(entry.name);
          if (bytes == null) {
            _refresh();
            _toast('Ez a mentés már nincs meg.', error: true);
            return;
          }
          final ok = await io.save(entry.name, bytes);
          if (ok) _toast('A mentés elmentve.');
        case _EntryAction.delete:
          final sure = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              key: const Key('backup-delete'),
              title: const Text('Törlöd ezt a mentést?'),
              content: const Text(
                'A fájl végleg törlődik erről az eszközről. Az adataidhoz '
                'nem nyúl.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Mégse'),
                ),
                FilledButton(
                  key: const Key('backup-delete-yes'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Törlés'),
                ),
              ],
            ),
          );
          if (sure != true) return;
          await store.delete(entry.name);
          _refresh();
      }
    } catch (e, st) {
      _fail('A művelet nem sikerült', 'entry.failed', e, st);
    }
  }

  /// Opens [bytes] (asking for the password if it is locked), shows what a
  /// restore would do, and does it when the user agrees.
  ///
  /// [password] is tried first (the one stored for the Drive copies); when it
  /// does not open the file, the user is asked.
  Future<void> _restore(Uint8List bytes, {String? password}) async {
    final service = ref.read(backupServiceProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    _work(_Job.restore);
    try {
      BackupFile? file;
      var guessed = password != null; // (a wrong guess is not the user's typo)
      while (file == null) {
        try {
          file = await service.open(bytes, password: password);
        } on BackupException catch (e) {
          final locked =
              e.problem == BackupProblem.passwordNeeded ||
              e.problem == BackupProblem.wrongPassword;
          if (!locked) {
            _toast(e.message, error: true);
            return;
          }
          final typo = e.problem == BackupProblem.wrongPassword && !guessed;
          guessed = false;
          _work(null); // (the question is the user's turn, not work)
          if (!mounted) return;
          password = await askOpenPassword(context, wrong: typo);
          if (password == null || !mounted) return;
          _work(_Job.restore);
        }
      }
      final preview = await service.preview(file);
      _work(null);
      if (!mounted) return;
      final overwrite = await askRestore(context, preview);
      if (overwrite == null || preview.changesNothing || !mounted) return;
      _work(_Job.restore);
      final result = await service.restore(file, overwrite: overwrite);
      // what came back goes up to Google / Drive again
      sync.requestSync();
      _toast(restoreSummary(result));
    } catch (e, st) {
      _fail('A visszaállítás nem sikerült', 'restore.failed', e, st);
    } finally {
      _work(null);
    }
  }

  // -------------------------------------------------------- the Drive copy

  Future<void> _setDrivePassword() async {
    final answer = await askNewPassword(
      context,
      title: 'Jelszó a Drive-mentéshez',
      intro:
          'Ezzel a jelszóval zárja le a program a Drive-ba kerülő mentéseket '
          '(AES-256). A jelszót csak ezen az eszközön, az operációs rendszer '
          'biztonságos tárolójában őrzi. Ha elveszted, a Drive-beli mentés '
          'nem nyitható meg; új eszközön ugyanezt a jelszót kell megadnod a '
          'visszaállításhoz.',
      required: true,
      dialogKey: 'drive-password-dialog',
    );
    final password = answer?.password;
    if (password == null || !mounted) return;
    try {
      await ref.read(backupKeyStoreProvider).write(password);
      _refreshDrive();
      _toast('A jelszó el van mentve.');
    } catch (e, st) {
      _fail('A jelszót nem sikerült elmenteni', 'drive.password_failed', e, st);
    }
  }

  Future<void> _clearDrivePassword() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('drive-password-clear-dialog'),
        title: const Text('Törlöd a jelszót?'),
        content: const Text(
          'Innentől nem készül új mentés a Drive-ba. A már ott lévők '
          'megmaradnak, de csak a jelszó beírásával nyithatók meg.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            key: const Key('drive-password-clear-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Törlés'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await ref.read(backupKeyStoreProvider).write(null);
      await ref.read(driveBackupProvider).setEnabled(false);
      _refreshDrive();
    } catch (e, st) {
      _fail('A jelszót nem sikerült törölni', 'drive.password_failed', e, st);
    }
  }

  Future<void> _driveSwitch(bool on) async {
    final drive = ref.read(driveBackupProvider);
    await drive.setEnabled(on);
    _refreshDrive();
    // the first copy is made right away, not a week later
    if (on && mounted) await _driveNow();
  }

  Future<void> _driveNow() async {
    _work(_Job.drive);
    try {
      final drive = ref.read(driveBackupProvider);
      final made = await drive.backupNow();
      _refreshDrive();
      if (made != null) {
        _toast('A Drive-mentés elkészült.');
      } else {
        final why = (await drive.state()).error;
        _toast(
          'A Drive-mentés nem sikerült: ${why ?? 'ismeretlen hiba'}',
          error: true,
        );
      }
    } finally {
      _work(null);
    }
  }

  Future<void> _driveRestore() async {
    final drive = ref.read(driveBackupProvider);
    final keys = ref.read(backupKeyStoreProvider);
    _work(_Job.drive);
    final List<DriveName> copies;
    try {
      copies = await drive.list();
    } catch (e, st) {
      _work(null);
      _fail('A Drive-mentések nem érhetők el', 'drive.list_failed', e, st);
      return;
    }
    _work(null);
    if (!mounted) return;
    if (copies.isEmpty) {
      _toast('Még nincs mentés a Drive-ban.');
      return;
    }
    final picked = await askDriveCopy(context, copies);
    if (picked == null || !mounted) return;
    _work(_Job.drive);
    final Uint8List? bytes;
    try {
      bytes = await drive.download(picked);
    } on BackupException catch (e) {
      _work(null);
      _toast(e.message, error: true);
      return;
    } catch (e, st) {
      _work(null);
      _fail('A mentést nem sikerült letölteni', 'drive.download_failed', e, st);
      return;
    }
    _work(null);
    if (bytes == null) {
      _toast('Ez a mentés már nincs meg a Drive-on.', error: true);
      return;
    }
    if (!mounted) return;
    String? stored;
    try {
      stored = await keys.read();
    } catch (_) {
      stored = null; // (the question will be asked)
    }
    await _restore(bytes, password: stored);
  }

  // ------------------------------------------------------------- screen

  Widget _icon(_Job job, IconData icon) => _job == job
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon);

  String _entryTitle(BackupEntry e) {
    final t = e.time;
    // (the digits of the name are the time on the clock when it was made)
    return t == null ? e.name : '${fmtDate(t)} ${fmtTime(t)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final state = ref.watch(autoBackupStateProvider).value;
    final entries = ref.watch(backupEntriesProvider).value ?? const [];
    final drive = ref.watch(driveBackupStateProvider).value;
    final signedIn = ref.watch(
      syncControllerProvider.select((s) => s.signedIn),
    );
    final busy = _job != null;

    final String status;
    if (state == null) {
      status = '';
    } else if (state.error != null) {
      status = 'Az utolsó mentés nem sikerült: ${state.error}';
    } else if (state.last != null) {
      status = 'Utolsó mentés: ${backupWhen(state.last!)}';
    } else if (!state.enabled) {
      status = 'Az automatikus mentés ki van kapcsolva.';
    } else {
      status = 'Még nem készült mentés.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Teljes mentés a naptárról, a pénzügyekről, a feladatokról, a '
          'check-inekről, a kézikönyvről, az edzésnaplóról, az étkezési '
          'naplóról, a napló bejegyzéseinek szövegéről és a beállításokról '
          '(a napló képei nincsenek benne). A program '
          'indulásakor, legfeljebb naponta egyszer készül; az utolsó 7 nap '
          'mentéséből a napi legfrissebb, előtte 4 hétre hetente egy marad meg.',
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          key: const Key('backup-auto'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Naponta egy mentés ezen az eszközön'),
          value: state?.enabled ?? true,
          onChanged: state == null
              ? null
              : (on) async {
                  await ref.read(autoBackupProvider).setEnabled(on);
                  _refresh();
                },
        ),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              status,
              key: const Key('backup-status'),
              style: state?.error != null
                  ? small?.copyWith(color: theme.colorScheme.error)
                  : small,
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('backup-now'),
              onPressed: busy ? null : _backupNow,
              icon: _icon(_Job.now, Icons.save_outlined),
              label: const Text('Mentés most'),
            ),
            OutlinedButton.icon(
              key: const Key('backup-tofile'),
              onPressed: busy ? null : _toFile,
              icon: _icon(_Job.toFile, Icons.download),
              label: const Text('Mentés fájlba…'),
            ),
            OutlinedButton.icon(
              key: const Key('backup-fromfile'),
              onPressed: busy ? null : _fromFile,
              icon: _icon(_Job.restore, Icons.restore),
              label: const Text('Visszaállítás fájlból…'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Az automatikus mentések ezen az eszközön maradnak: az adatbázis '
          'hibája, egy rossz szinkron vagy egy véletlen törlés ellen védenek. '
          'Az eszköz elvesztése ellen a „Mentés fájlba” véd: a fájlt tedd el '
          'máshová (felhő, pendrive).',
          style: small,
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Mentések ezen az eszközön', style: theme.textTheme.titleSmall),
          for (final e in entries.take(_shown))
            ListTile(
              key: Key('backup-entry-${e.name}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(_entryTitle(e)),
              subtitle: Text(backupSizeText(e.size)),
              trailing: PopupMenuButton<_EntryAction>(
                key: Key('backup-entry-menu-${e.name}'),
                tooltip: 'Műveletek: ${_entryTitle(e)}',
                enabled: !busy,
                onSelected: (a) => _entryAction(e, a),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _EntryAction.restore,
                    child: Text('Visszaállítás…'),
                  ),
                  PopupMenuItem(
                    value: _EntryAction.save,
                    child: Text('Mentés fájlba…'),
                  ),
                  PopupMenuItem(
                    value: _EntryAction.delete,
                    child: Text('Törlés…'),
                  ),
                ],
              ),
            ),
          if (entries.length > _shown)
            Text('és még ${entries.length - _shown}…', style: small),
        ],
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),
        _driveSection(context, drive, signedIn, busy),
      ],
    );
  }

  /// The encrypted copy in the user's Drive: a password, a switch, a button
  /// for a copy now, and the restore from Drive.
  Widget _driveSection(
    BuildContext context,
    DriveBackupState? drive,
    bool signedIn,
    bool busy,
  ) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hasPassword = drive?.hasPassword ?? false;
    final enabled = drive?.enabled ?? false;
    final String? hint = !hasPassword
        ? 'Előbb adj meg egy jelszót.'
        : !signedIn
        ? 'Előbb lépj be a Google-fiókkal (a „Google-fiók” kártyán).'
        : null;
    final String status;
    if (drive == null) {
      status = '';
    } else if (drive.error != null) {
      status = 'Az utolsó Drive-mentés nem sikerült: ${drive.error}';
    } else if (drive.last != null) {
      status = 'Utolsó Drive-mentés: ${backupWhen(drive.last!)}';
    } else if (enabled) {
      status = 'Még nem készült Drive-mentés.';
    } else {
      status = '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Titkosított másolat a Google Drive-ban',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          'Hetente egy teljes mentés kerül a Drive rejtett app-mappájába (csak '
          'ez a program látja), a megadott jelszóval titkosítva; az utolsó 3 '
          'marad meg. Ez az eszköz elvesztése ellen is véd. A jelszót nem '
          'lehet visszafejteni: ha elveszted, a Drive-beli mentés nem '
          'nyitható meg.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const Key('drive-password'),
              onPressed: busy ? null : _setDrivePassword,
              icon: const Icon(Icons.key_outlined),
              label: Text(
                hasPassword ? 'Jelszó módosítása' : 'Jelszó megadása',
              ),
            ),
            if (hasPassword)
              TextButton(
                key: const Key('drive-password-clear'),
                onPressed: busy ? null : _clearDrivePassword,
                child: const Text('Jelszó törlése'),
              ),
          ],
        ),
        SwitchListTile(
          key: const Key('drive-auto'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Heti mentés a Drive-ba'),
          subtitle: hint == null ? null : Text(hint),
          value: enabled,
          onChanged: (busy || hint != null) ? null : _driveSwitch,
        ),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              status,
              key: const Key('drive-status'),
              style: drive?.error != null
                  ? small?.copyWith(color: theme.colorScheme.error)
                  : small,
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('drive-now'),
              onPressed: (busy || hint != null) ? null : _driveNow,
              icon: _icon(_Job.drive, Icons.cloud_upload_outlined),
              label: const Text('Mentés a Drive-ra most'),
            ),
            OutlinedButton.icon(
              key: const Key('drive-restore'),
              onPressed: (busy || !signedIn) ? null : _driveRestore,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Visszaállítás a Drive-ról…'),
            ),
          ],
        ),
      ],
    );
  }
}
