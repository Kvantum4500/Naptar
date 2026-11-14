import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/db_open.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

// The tables exactly as the first four versions of the app created them.
const _outbox =
    'CREATE TABLE "outbox_rows" ("seq" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "event_id" TEXT NOT NULL, "op" TEXT NOT NULL, "attempts" INTEGER NOT NULL DEFAULT 0, "last_error" TEXT NULL)';
const _meta =
    'CREATE TABLE "meta_rows" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, PRIMARY KEY ("key"))';
String _event({required bool v2}) =>
    'CREATE TABLE "event_rows" ("id" TEXT NOT NULL, "calendar_id" TEXT NOT NULL, "title" TEXT NOT NULL, "notes" TEXT NOT NULL DEFAULT \'\', "location" TEXT NOT NULL DEFAULT \'\', "start_wall" TEXT NOT NULL, "end_wall" TEXT NOT NULL, "tzid" TEXT NULL, "all_day" INTEGER NOT NULL DEFAULT 0 CHECK ("all_day" IN (0, 1)), "rrule" TEXT NULL, "exdates" TEXT NOT NULL DEFAULT \'\', "recurring_event_id" TEXT NULL, "original_start" TEXT NULL, "cancelled" INTEGER NOT NULL DEFAULT 0 CHECK ("cancelled" IN (0, 1)), "version" INTEGER NOT NULL DEFAULT 1, "google_id" TEXT NULL, "etag" TEXT NULL, "i_cal_uid" TEXT NULL, ${v2 ? '"color_id" TEXT NULL, "ai_generated" INTEGER NOT NULL DEFAULT 0 CHECK ("ai_generated" IN (0, 1)), ' : ''}"deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), PRIMARY KEY ("id"))';
const _record =
    'CREATE TABLE "record_rows" ("kind" TEXT NOT NULL, "id" TEXT NOT NULL, "json" TEXT NOT NULL, "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "updated_at" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("kind", "id"))';
const _driveFile =
    'CREATE TABLE "drive_file_rows" ("name" TEXT NOT NULL, "file_id" TEXT NOT NULL, PRIMARY KEY ("name"))';
const _fin =
    'CREATE TABLE "fin_rows" ("kind" TEXT NOT NULL, "id" TEXT NOT NULL, "json" TEXT NOT NULL, "updated_at" INTEGER NOT NULL DEFAULT 0, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), PRIMARY KEY ("kind", "id"))';

/// Writes a database as the app of [version] left it, with some data.
void _seed(String path, int version, {bool blockFin = false}) {
  final db = sql.sqlite3.open(path);
  try {
    db.execute(_event(v2: version >= 2));
    db.execute(_outbox);
    db.execute(_meta);
    db.execute(
      'INSERT INTO event_rows (id, calendar_id, title, start_wall, end_wall) VALUES '
      "('a', 'naptar', 'Edzés', '2026-05-04T09:00:00', '2026-05-04T10:00:00'), "
      "('p', 'primary', 'Régi, másik naptár', '2026-05-05T09:00:00', '2026-05-05T10:00:00')",
    );
    db.execute(
      "INSERT INTO outbox_rows (event_id, op) VALUES ('a', 'upsert'), ('p', 'upsert')",
    );
    db.execute(
      "INSERT INTO meta_rows VALUES ('deviceId', 'dev1'), ('syncToken:naptar', 'T1'), ('syncToken:primary', 'T2')",
    );
    if (version >= 3) {
      db.execute(_record);
      db.execute(_driveFile);
      db.execute(
        "INSERT INTO record_rows (kind, id, json) VALUES ('task', 't1', '{}')",
      );
      db.execute("INSERT INTO drive_file_rows VALUES ('task-t1.json', 'f1')");
    }
    if (blockFin) {
      // an index that carries the name of a table the last step has to create:
      // that step fails, after the earlier ones have already done their work
      db.execute('CREATE INDEX "fin_rows" ON "meta_rows" ("key")');
    }
    if (version >= 4) {
      db.execute(_fin);
      db.execute(
        "INSERT INTO fin_rows (kind, id, json) VALUES ('tx', 'x1', '{}')",
      );
    }
    db.execute('PRAGMA user_version = $version');
  } finally {
    db.close();
  }
}

AppDatabase _open(String path, {bool guarded = true}) => AppDatabase(
  NativeDatabase(
    File(path),
    setup: guarded
        ? (raw) => prepareRawDatabase(
            raw,
            path: path,
            schemaVersion: AppDatabase.currentSchemaVersion,
          )
        : null,
  ),
);

T _peek<T>(String path, T Function(sql.Database db) read) {
  final db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
  try {
    return read(db);
  } finally {
    db.close();
  }
}

int _version(String path) => _peek(
  path,
  (d) => d.select('PRAGMA user_version').first.values.first as int,
);
List<String> _columns(String path, String table) => _peek(
  path,
  (d) => [
    for (final r in d.select('PRAGMA table_info($table)')) r['name'] as String,
  ],
);
Set<String> _names(String path, String type) => _peek(
  path,
  (d) => {
    for (final r in d.select(
      "SELECT name FROM sqlite_master WHERE type = '$type'",
    ))
      r['name'] as String,
  },
);
int _count(String path, String table, [String where = '1']) => _peek(
  path,
  (d) =>
      d.select('SELECT count(*) AS c FROM $table WHERE $where').first['c']
          as int,
);

void main() {
  late Directory dir;
  late String path;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('kvantum-db-');
    path = p.join(dir.path, 'kvantum.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const indexes = {
    'event_rows_series',
    'event_rows_google',
    'outbox_rows_event',
    'record_rows_dirty',
    'fin_rows_kind',
    'fin_rows_dirty',
  };

  Future<void> upgrade() async {
    final db = _open(path);
    await db.customSelect('SELECT 1').get();
    await db.close();
  }

  group('upgrading what earlier versions left', () {
    test('from v1: the data stays, the tables and columns arrive, a safety copy is made', () async {
      _seed(path, 1);
      await upgrade();

      expect(_version(path), 4);
      expect(_count(path, 'event_rows', "id = 'a'"), 1);
      expect(
        _columns(path, 'event_rows'),
        containsAll(['color_id', 'ai_generated']),
      );
      expect(
        _names(path, 'table'),
        containsAll(['record_rows', 'drive_file_rows', 'fin_rows']),
      );
      // the old rule of v2: events of other calendars and their queue are dropped
      expect(_count(path, 'event_rows', "id = 'p'"), 0);
      expect(_count(path, 'outbox_rows', "event_id = 'p'"), 0);
      expect(_count(path, 'outbox_rows', "event_id = 'a'"), 1);
      expect(_count(path, 'meta_rows', "key = 'deviceId'"), 1);
      expect(_count(path, 'meta_rows', "key LIKE 'syncToken:%'"), 0);

      final copy = '$path.bak-v1';
      expect(File(copy).existsSync(), isTrue);
      expect(_version(copy), 1, reason: 'the copy is the old database');
      expect(_count(copy, 'event_rows'), 2, reason: 'with all of its rows');
      expect(_columns(copy, 'event_rows'), isNot(contains('color_id')));
    });

    test('from v2', () async {
      _seed(path, 2);
      await upgrade();
      expect(_version(path), 4);
      expect(
        _count(path, 'event_rows'),
        1 + 1,
        reason:
            'v2 keeps what it had (the other-calendar rule ran in v1->v2 only)',
      );
      expect(_names(path, 'table'), containsAll(['record_rows', 'fin_rows']));
      expect(File('$path.bak-v2').existsSync(), isTrue);
    });

    test('from v3: records stay, finance arrives', () async {
      _seed(path, 3);
      await upgrade();
      expect(_version(path), 4);
      expect(_count(path, 'record_rows'), 1);
      expect(_count(path, 'drive_file_rows'), 1);
      expect(_names(path, 'table'), contains('fin_rows'));
      expect(File('$path.bak-v3').existsSync(), isTrue);
    });

    test('a current database is not copied and loses nothing', () async {
      _seed(path, 4);
      await upgrade();
      expect(_version(path), 4);
      expect(_count(path, 'fin_rows'), 1);
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.bak-'))),
      );
    });

    test('a new database is created with all tables and no copy', () async {
      await upgrade();
      expect(_version(path), 4);
      expect(
        _names(path, 'table'),
        containsAll([
          'event_rows',
          'outbox_rows',
          'meta_rows',
          'record_rows',
          'drive_file_rows',
          'fin_rows',
        ]),
      );
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.bak-'))),
      );
    });

    test('the lookup indexes exist after any start, and starting again is harmless', () async {
      await upgrade();
      expect(_names(path, 'index'), containsAll(indexes));
      await upgrade();
      expect(_names(path, 'index'), containsAll(indexes));
      // an old database gets them too
      final old = p.join(dir.path, 'old.sqlite');
      _seed(old, 4);
      expect(_names(old, 'index').intersection(indexes), isEmpty);
      final db = _open(old);
      await db.customSelect('SELECT 1').get();
      await db.close();
      expect(_names(old, 'index'), containsAll(indexes));
    });
  });

  group('a failure half-way changes nothing', () {
    test('every step is rolled back and the version stays', () async {
      // v1, and the name of the finance table is taken: the LAST step fails
      _seed(path, 1, blockFin: true);
      final db = _open(path);
      await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
      try {
        await db.close();
      } catch (_) {}

      expect(_version(path), 1, reason: 'still the old version');
      expect(
        _columns(path, 'event_rows'),
        isNot(contains('color_id')),
        reason: 'the first step was undone',
      );
      expect(
        _names(path, 'table'),
        isNot(contains('record_rows')),
        reason: 'and the second',
      );
      expect(
        _count(path, 'event_rows'),
        2,
        reason: 'the legacy clean-up was undone as well',
      );
      expect(
        File('$path.bak-v1').existsSync(),
        isTrue,
        reason: 'and there is a safety copy',
      );
    });
  });

  group('a database of a newer version is left alone', () {
    test('the start refuses it and does not touch the file', () async {
      _seed(path, 4);
      sql.sqlite3.open(path)
        ..execute('PRAGMA user_version = 9')
        ..close();
      final before = File(path).readAsBytesSync().length;
      final db = _open(path);
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(
          predicate(
            (e) =>
                e is NewerDatabaseError || '$e'.contains('NewerDatabaseError'),
          ),
        ),
      );
      try {
        await db.close();
      } catch (_) {}
      expect(_version(path), 9, reason: 'the newer label is not written back');
      expect(File(path).readAsBytesSync().length, before);
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.bak-'))),
      );
    });

    test(
      'even without the early check the migration refuses to go backwards',
      () async {
        _seed(path, 4);
        sql.sqlite3.open(path)
          ..execute('PRAGMA user_version = 9')
          ..close();
        final db = _open(path, guarded: false);
        await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
        try {
          await db.close();
        } catch (_) {}
        expect(_version(path), 9);
      },
    );

    test('the file check says so before anything is opened', () {
      _seed(path, 4);
      expect(checkDatabaseFile(path, schemaVersion: 4), isNull);
      sql.sqlite3.open(path)
        ..execute('PRAGMA user_version = 7')
        ..close();
      final problem = checkDatabaseFile(path, schemaVersion: 4);
      expect(problem, isA<NewerDatabaseError>());
      expect((problem! as NewerDatabaseError).message, contains('újabb'));
      expect(checkDatabaseFile(path, schemaVersion: 7), isNull);
    });
  });

  group('the file check', () {
    test('a missing or empty file is fine (it will be created)', () {
      expect(checkDatabaseFile(path, schemaVersion: 4), isNull);
      File(path).writeAsBytesSync([]);
      expect(checkDatabaseFile(path, schemaVersion: 4), isNull);
    });

    test('a file that is not a database is reported, not opened', () {
      File(path).writeAsStringSync('this is not a database ' * 20);
      final problem = checkDatabaseFile(path, schemaVersion: 4);
      expect(problem, isA<UnreadableDatabaseError>());
      expect(
        (problem! as UnreadableDatabaseError).message,
        contains('biztonsági másolat'),
      );
      expect(File(path).readAsStringSync(), startsWith('this is not'));
    });
  });

  group('safety copies', () {
    test('only the newest two are kept', () async {
      final now = DateTime.now();
      for (final (v, ago) in [(1, 30), (2, 20)]) {
        final f = File('$path.bak-v$v')..writeAsStringSync('old copy $v');
        f.setLastModifiedSync(now.subtract(Duration(days: ago)));
      }
      File('$path.bak-v0')
        ..writeAsStringSync('oldest')
        ..setLastModifiedSync(now.subtract(const Duration(days: 40)));
      _seed(path, 3);
      await upgrade();
      final left = dir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.contains('.bak-'))
          .toSet();
      expect(left, {'kvantum.sqlite.bak-v3', 'kvantum.sqlite.bak-v2'});
    });

    test('a copy is always made from the state before this upgrade', () async {
      _seed(path, 3);
      File('$path.bak-v3').writeAsStringSync('stale copy of an earlier try');
      await upgrade();
      expect(_version('$path.bak-v3'), 3);
      expect(_count('$path.bak-v3', 'record_rows'), 1);
    });
  });
}
