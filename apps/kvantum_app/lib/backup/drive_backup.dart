import 'dart:convert';
import 'dart:typed_data';

import '../diag/diag_log.dart';
import '../drive/drive_remote.dart';
import '../sync/error_catalog.dart';
import 'backup_bundle.dart';
import 'backup_key_store.dart';
import 'backup_service.dart';

/// Why a copy cannot be made or fetched, besides the network.
enum DriveBackupProblem { signedOut, noPassword, tooBig }

class DriveBackupException implements Exception {
  const DriveBackupException(this.problem, [this.detail = '']);
  final DriveBackupProblem problem;
  final String detail;

  /// What to tell the user.
  String get message => switch (problem) {
    DriveBackupProblem.signedOut => 'Nem vagy belépve a Google-fiókkal.',
    DriveBackupProblem.noPassword =>
      'Előbb adj meg egy jelszót a Drive-mentéshez.',
    DriveBackupProblem.tooBig =>
      'A mentés túl nagy a Drive-példányhoz ($detail MB); a „Mentés fájlba” '
          'nem korlátos.',
  };

  @override
  String toString() => 'DriveBackupException($problem)';
}

/// What the Drive copy did last, as the Settings page tells it.
class DriveBackupState {
  const DriveBackupState({
    this.enabled = false,
    this.hasPassword = false,
    this.last,
    this.error,
  });

  /// Whether the weekly copy is switched on.
  final bool enabled;

  /// Whether a password is set (the copy is locked with it).
  final bool hasPassword;

  /// When the last one succeeded (UTC).
  final DateTime? last;

  /// Why the last one failed (null when it did not).
  final String? error;
}

/// A weekly copy of the whole backup in the hidden app folder of the user's
/// Drive, locked with the user's password (AES-256 zip, kept as base64 text
/// because the Drive layer of the app stores text). The newest three stay.
/// Nobody - not Google, not this program without the password - can read it:
/// it protects against the loss of the device, which the copies on the device
/// itself cannot.
class DriveBackup {
  DriveBackup({
    required this.service,
    required this.remote,
    required this.keys,
    required this.readMeta,
    required this.writeMeta,
    required this.now,
    this.log,
  });

  final BackupService service;

  /// The Drive folder of the signed-in account (null when signed out).
  final DriveRemote? Function() remote;
  final BackupKeyStore keys;
  final Future<String?> Function(String key) readMeta;
  final Future<void> Function(String key, String? value) writeMeta;

  /// The clock (replaced by tests).
  final DateTime Function() now;
  final DiagLog? log;

  static const enabledKey = 'backup.drive';
  static const lastKey = 'backup.drive.last';
  static const errorKey = 'backup.drive.error';

  /// The start of the name of every copy in Drive.
  static const prefix = 'kvbackup-';

  /// How many copies stay.
  static const keep = 3;

  /// A copy is due when the last one is older than this (a little under a
  /// week, so that opening the app at about the same time every week never
  /// skips one).
  static const due = Duration(days: 6, hours: 20);

  /// The longest text uploaded (about 4 MB: Drive's plain upload takes 5 MB).
  static const maxChars = 4000000;

  static final _name = RegExp(
    r'^kvbackup-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.zip\.b64$',
  );

  /// "kvbackup-20261113-091530.zip.b64".
  static String fileName(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '$prefix${at.year.toString().padLeft(4, '0')}${two(at.month)}'
        '${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}'
        '.zip.b64';
  }

  /// The time in a copy's name, or null for any other name.
  static DateTime? timeOf(String name) {
    final m = _name.firstMatch(name);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    final t = DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
    if (t.year != v[0] || t.month != v[1] || t.day != v[2]) return null;
    return t;
  }

  Future<DriveBackupState> state() async => DriveBackupState(
    enabled: (await readMeta(enabledKey)) == 'on',
    hasPassword: (await keys.read()) != null,
    last: DateTime.tryParse(await readMeta(lastKey) ?? '')?.toUtc(),
    error: await readMeta(errorKey),
  );

  Future<void> setEnabled(bool on) => writeMeta(enabledKey, on ? 'on' : null);

  /// The copy that is being made right now (a second request joins it).
  Future<DriveName?>? _running;

  Future<DriveName?> _once(Future<DriveName?> Function() job) =>
      _running ??= job().whenComplete(() => _running = null);

  /// Makes this week's copy unless it is switched off, nobody is signed in,
  /// there is no password, or one is recent enough. Returns what it made (null
  /// when there was nothing to do). Never throws: a failed copy is written
  /// down, not raised.
  Future<DriveName?> runIfDue() => _once(() async {
    try {
      final s = await state();
      if (!s.enabled || !s.hasPassword) return null;
      if (remote() == null) return null; // (it will be tried when signed in)
      final last = s.last;
      if (last != null && now().toUtc().difference(last) < due) return null;
    } catch (e, st) {
      log?.error('backup', 'drive.due_failed', e, st);
      return null;
    }
    return _make();
  });

  /// Makes a copy now. Returns it, or null when it failed (the reason is in
  /// [DriveBackupState.error]).
  Future<DriveName?> backupNow() => _once(_make);

  String _text(Object e) =>
      e is DriveBackupException ? e.message : errorInfoFor(e).text;

  Future<DriveName?> _make() async {
    try {
      final r = remote();
      if (r == null) {
        throw const DriveBackupException(DriveBackupProblem.signedOut);
      }
      final password = await keys.read();
      if (password == null) {
        throw const DriveBackupException(DriveBackupProblem.noPassword);
      }
      final at = now();
      final bytes = await service.create(password: password);
      final text = base64.encode(bytes);
      if (text.length > maxChars) {
        throw DriveBackupException(
          DriveBackupProblem.tooBig,
          (text.length / 1000000).toStringAsFixed(1).replaceAll('.', ','),
        );
      }
      final name = fileName(at);
      // a second copy within the same second replaces the first
      final same = await r.findByName(name);
      final id = await r.write(
        fileId: same.isEmpty ? null : same.first,
        name: name,
        content: text,
      );
      await writeMeta(lastKey, at.toUtc().toIso8601String());
      await writeMeta(errorKey, null);
      await _tidy(r);
      log?.info('backup', 'drive.done', data: {'chars': text.length});
      return DriveName(id: id, name: name);
    } catch (e, st) {
      log?.error('backup', 'drive.failed', e, st);
      try {
        await writeMeta(errorKey, _text(e));
      } catch (_) {
        // (not even that could be written: nothing more to do)
      }
      return null;
    }
  }

  /// Deletes all but the newest [keep] copies. A failure to delete one is not
  /// a failure of the copy.
  Future<void> _tidy(DriveRemote r) async {
    try {
      final ours = [
        for (final n in await r.listNames(prefix))
          if (timeOf(n.name) != null) n,
      ]..sort((a, b) => a.name.compareTo(b.name));
      for (final n in ours.take(ours.length - keep)) {
        try {
          await r.delete(n.id);
        } catch (e, st) {
          log?.error('backup', 'drive.tidy_failed', e, st);
        }
      }
    } catch (e, st) {
      log?.error('backup', 'drive.tidy_failed', e, st);
    }
  }

  // ------------------------------------------------------------ restoring

  /// The copies in Drive, newest first. Throws when nobody is signed in or
  /// Drive cannot be reached.
  Future<List<DriveName>> list() async {
    final r = remote();
    if (r == null) {
      throw const DriveBackupException(DriveBackupProblem.signedOut);
    }
    return [
      for (final n in await r.listNames(prefix))
        if (timeOf(n.name) != null) n,
    ]..sort((a, b) => b.name.compareTo(a.name));
  }

  /// The zip bytes of a copy, or null when it has gone from Drive meanwhile.
  Future<Uint8List?> download(DriveName n) async {
    final r = remote();
    if (r == null) {
      throw const DriveBackupException(DriveBackupProblem.signedOut);
    }
    final text = await r.read(n.id);
    if (text == null) return null;
    try {
      return base64.decode(text.trim());
    } on FormatException {
      throw const BackupException(BackupProblem.damaged);
    }
  }
}
