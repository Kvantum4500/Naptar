import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A backup kept on this device.
class BackupEntry {
  const BackupEntry(this.name, this.size, this.time);
  final String name;
  final int size;

  /// The day and time the name says (null for a file that is not named like
  /// one of ours).
  final DateTime? time;
}

/// Where the backups are kept (a folder next to the database; memory in tests).
abstract class BackupStore {
  /// Every file there, newest first (files not named like ours last).
  Future<List<BackupEntry>> list();
  Future<void> write(String name, Uint8List bytes);
  Future<Uint8List?> read(String name);
  Future<void> delete(String name);
}

/// "kvantum-20261113-091530.zip".
String backupFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'kvantum-${at.year.toString().padLeft(4, '0')}${two(at.month)}'
      '${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}.zip';
}

final _namePattern = RegExp(
  r'^kvantum-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.zip$',
);

/// The time in a backup's name, or null for any other name.
DateTime? backupTimeOf(String name) {
  final m = _namePattern.firstMatch(name);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  final t = DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  // (a name like 20261345 is not a date)
  if (t.year != v[0] || t.month != v[1] || t.day != v[2]) return null;
  return t;
}

/// Which backups to delete so that the folder keeps the newest one of each of
/// the last [days] days and the newest of each of the [weeks] weeks before
/// those (a week is seven days counted back from the oldest kept day). Files
/// that are not named like ours are never named: they are not ours to delete.
List<String> backupsToDelete(
  Iterable<String> names,
  DateTime now, {
  int days = 7,
  int weeks = 4,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final dated = <({String name, DateTime time})>[
    for (final n in names)
      if (backupTimeOf(n) case final t?) (name: n, time: t),
  ]..sort((a, b) => b.time.compareTo(a.time)); // newest first

  final keep = <String>{};
  final seen = <int>{}; // the "slots": a day, or a week, already kept
  for (final f in dated) {
    final day = DateTime(f.time.year, f.time.month, f.time.day);
    // a file from the future (a clock that was ahead) counts as today
    var back = today.difference(day).inDays;
    if (back < 0) back = 0;
    final int slot;
    if (back < days) {
      slot = back; // 0 .. days-1: one per day
    } else {
      final week = (back - days) ~/ 7;
      if (week >= weeks) continue; // too old
      slot = 1000 + week; // one per week
    }
    if (seen.add(slot)) keep.add(f.name);
  }
  return [
    for (final f in dated)
      if (!keep.contains(f.name)) f.name,
  ];
}

/// A folder on disk.
class FileBackupStore implements BackupStore {
  FileBackupStore(this.dir);
  final Directory dir;

  File _file(String name) => File(p.join(dir.path, p.basename(name)));

  @override
  Future<List<BackupEntry>> list() async {
    if (!await dir.exists()) return const [];
    final out = <BackupEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith('.zip')) continue;
      out.add(BackupEntry(name, await e.length(), backupTimeOf(name)));
    }
    return _newestFirst(out);
  }

  /// Removes what a write that was cut short (the app was closed, the power
  /// went) left behind.
  Future<void> _sweep() async {
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && e.path.endsWith('.part')) await e.delete();
      }
    } catch (_) {
      // (a leftover that cannot be removed is no reason to lose the backup)
    }
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    await dir.create(recursive: true);
    await _sweep();
    final target = _file(name);
    // written aside and renamed: a backup that stopped halfway is never left
    // under its real name
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }

  @override
  Future<Uint8List?> read(String name) async {
    final f = _file(name);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }
}

/// Backups kept in memory (tests, and the default until the app gives a folder).
class MemoryBackupStore implements BackupStore {
  final files = <String, Uint8List>{};

  @override
  Future<List<BackupEntry>> list() async => _newestFirst([
    for (final e in files.entries)
      BackupEntry(e.key, e.value.length, backupTimeOf(e.key)),
  ]);

  @override
  Future<void> write(String name, Uint8List bytes) async =>
      files[name] = Uint8List.fromList(bytes);

  @override
  Future<Uint8List?> read(String name) async => files[name];

  @override
  Future<void> delete(String name) async => files.remove(name);
}

List<BackupEntry> _newestFirst(List<BackupEntry> list) => list
  ..sort((a, b) {
    final x = a.time, y = b.time;
    if (x != null && y != null) return y.compareTo(x);
    if (x != null) return -1;
    if (y != null) return 1;
    return a.name.compareTo(b.name);
  });
