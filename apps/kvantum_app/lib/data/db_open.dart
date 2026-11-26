import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' as sql;

/// File name of the database.
const dbFileName = 'kvantum.sqlite';

/// How many safety copies of older database versions are kept.
const keepBackups = 2;

/// The database belongs to a NEWER version of the app (its schema is higher
/// than this build knows). Opening it with this build would label it as old
/// again and break the next upgrade, so it is left alone.
class NewerDatabaseError implements Exception {
  const NewerDatabaseError(this.found, this.supported);
  final int found, supported;

  String get message =>
      'Ez az adatbázis egy újabb alkalmazásverzióhoz tartozik (séma $found; '
      'ez a verzió a(z) $supported-ig ismeri). Telepítsd az újabb verziót; az '
      'adataid érintetlenek.';

  @override
  String toString() => 'NewerDatabaseError(found $found, supported $supported)';
}

/// The file is not a readable SQLite database (damaged).
class UnreadableDatabaseError implements Exception {
  const UnreadableDatabaseError(this.path, this.detail);
  final String path;
  final String detail;

  String get message =>
      'Az adatbázis-fájl nem olvasható (sérült lehet): $path. A program nem '
      'nyúlt hozzá. Ha mellette van biztonsági másolat (.bak-v… végű fájl), az '
      'átnevezésével visszaállítható.';

  @override
  String toString() => 'UnreadableDatabaseError($path: $detail)';
}

int _userVersion(CommonDatabase db) =>
    (db.select('PRAGMA user_version').first.values.first as num).toInt();

/// Runs on the raw database right before drift migrates it: refuses a
/// database of a newer version, and makes a safety copy of an older one.
void prepareRawDatabase(
  CommonDatabase db, {
  required String path,
  required int schemaVersion,
}) {
  final v = _userVersion(db);
  if (v > schemaVersion) throw NewerDatabaseError(v, schemaVersion);
  if (v > 0 && v < schemaVersion) _backup(db, path, v);
}

void _backup(CommonDatabase db, String path, int version) {
  try {
    final target = '$path.bak-v$version';
    final old = File(target);
    if (old.existsSync()) old.deleteSync();
    // a consistent copy, even of a database that is in use
    db.execute("VACUUM INTO '${target.replaceAll("'", "''")}'");
    pruneBackups(path);
  } catch (_) {
    // A missing safety copy must not stop the app from opening; the migration
    // itself is all-or-nothing.
  }
}

/// Keeps the newest [keepBackups] safety copies of the database at [path].
void pruneBackups(String path) {
  final dir = Directory(p.dirname(path));
  final prefix = '${p.basename(path)}.bak-v';
  final copies = [
    for (final e in dir.listSync())
      if (e is File && p.basename(e.path).startsWith(prefix)) e,
  ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  for (final f in copies.skip(keepBackups)) {
    try {
      f.deleteSync();
    } catch (_) {}
  }
}

/// Looks at the database file before the app opens it: null when it is fine
/// (or does not exist yet), otherwise why it must not be opened.
Object? checkDatabaseFile(String path, {required int schemaVersion}) {
  final f = File(path);
  if (!f.existsSync() || f.lengthSync() == 0) return null;
  try {
    final db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
    try {
      final v = _userVersion(db);
      return v > schemaVersion ? NewerDatabaseError(v, schemaVersion) : null;
    } finally {
      db.close();
    }
  } on sql.SqliteException catch (e) {
    return UnreadableDatabaseError(path, e.message);
  }
}

// ---------------------------------------------------------------- Windows

const _legacyMarker = 'legacy-db-moved.txt';

/// Where the database lives, and where it used to live.
class DbLocations {
  const DbLocations({required this.path, this.legacyPath});

  /// The file to open.
  final String path;

  /// The old place the file may still be in (Windows: Documents, which
  /// OneDrive may sync), or null when nothing moved.
  final String? legacyPath;
}

/// Windows keeps the database in `%LOCALAPPDATA%\KvantumNaptar` instead of the
/// Documents folder (which OneDrive may mirror to the cloud, and which other
/// programs read). Other platforms keep the default place.
DbLocations locateDatabase({
  required bool windows,
  required String documentsDir,
  String? localAppData,
}) {
  final legacy = p.join(documentsDir, dbFileName);
  if (windows && localAppData != null && localAppData.isNotEmpty) {
    return DbLocations(
      path: p.join(localAppData, 'KvantumNaptar', dbFileName),
      legacyPath: legacy,
    );
  }
  return DbLocations(path: legacy);
}

/// What the move of the database to its new place did.
class DbMoveResult {
  const DbMoveResult(
    this.path, {
    this.moved = false,
    this.cleaned = false,
    this.problem,
  });

  /// The file the app must open: the new place after a successful move (or a
  /// move that was done earlier), the old one when the move did not work.
  final String path;
  final bool moved, cleaned;

  /// Why the move did not happen (the old file stays in use).
  final String? problem;
}

const _sidecars = ['', '-wal', '-shm', '-journal'];

/// Copies one file (replaced by tests that need a damaged copy).
typedef FileCopier = void Function(String from, String to);

void _copyFile(String from, String to) => File(from).copySync(to);

/// Moves the database from [legacyPath] to [path] in two steps.
///
/// First start: the file is copied next to its new place, checked (it opens,
/// passes `integrity_check`, has the same version and the same number of rows
/// in every table), renamed into place, and a note is left. The old file stays.
/// Next start, when the new place has been in use: the old file is removed.
/// Whenever anything is not right, the old file keeps being used.
DbMoveResult moveLegacyDatabase({
  required String path,
  required String legacyPath,
  FileCopier copy = _copyFile,
}) {
  final newFile = File(path);
  final oldFile = File(legacyPath);
  final marker = File(p.join(p.dirname(path), _legacyMarker));
  try {
    if (newFile.existsSync() && marker.existsSync()) {
      // The new place has run for a start already: the old copy can go.
      for (final s in _sidecars) {
        final f = File('$legacyPath$s');
        if (f.existsSync()) f.deleteSync();
      }
      marker.deleteSync();
      return DbMoveResult(path, cleaned: true);
    }
    if (newFile.existsSync()) return DbMoveResult(path);
    if (!oldFile.existsSync()) return DbMoveResult(path);

    Directory(p.dirname(path)).createSync(recursive: true);
    final tmp = File('$path.moving');
    if (tmp.existsSync()) tmp.deleteSync();
    copy(legacyPath, tmp.path);
    for (final s in _sidecars.skip(1)) {
      if (File('$legacyPath$s').existsSync()) {
        copy('$legacyPath$s', '${tmp.path}$s');
      }
    }
    final problem = _sameDatabase(legacyPath, tmp.path);
    if (problem != null) {
      for (final s in _sidecars) {
        final f = File('${tmp.path}$s');
        if (f.existsSync()) f.deleteSync();
      }
      return DbMoveResult(legacyPath, problem: problem);
    }
    for (final s in _sidecars.skip(1)) {
      final f = File('${tmp.path}$s');
      if (f.existsSync()) f.renameSync('$path$s');
    }
    tmp.renameSync(path);
    marker.writeAsStringSync(legacyPath);
    return DbMoveResult(path, moved: true);
  } catch (e) {
    for (final s in _sidecars) {
      try {
        final f = File('$path.moving$s');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    return DbMoveResult(
      newFile.existsSync() && !oldFile.existsSync() ? path : legacyPath,
      problem: '$e',
    );
  }
}

/// null when the copy at [copy] holds exactly what [original] holds.
String? _sameDatabase(String original, String copy) {
  final a = sql.sqlite3.open(original, mode: sql.OpenMode.readOnly);
  final b = sql.sqlite3.open(copy, mode: sql.OpenMode.readOnly);
  try {
    final check = b.select('PRAGMA integrity_check').first.values.first;
    if ('$check' != 'ok') return 'az ellenőrzés hibát jelzett: $check';
    if (_userVersion(a) != _userVersion(b)) return 'a séma-verzió eltér';
    List<String> tables(CommonDatabase d) => [
      for (final r in d.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      ))
        r['name'] as String,
    ];
    final ta = tables(a);
    if ('$ta' != '${tables(b)}') return 'a táblák eltérnek';
    for (final t in ta) {
      final ca = a.select('SELECT count(*) AS c FROM "$t"').first['c'];
      final cb = b.select('SELECT count(*) AS c FROM "$t"').first['c'];
      if (ca != cb) return 'a(z) $t tábla sorainak száma eltér';
    }
    return null;
  } finally {
    a.close();
    b.close();
  }
}
