import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/db_open.dart';
import 'package:kvantum_app/data/startup.dart';
import 'package:kvantum_app/ui/startup_problem.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

/// A small but real database: tables, rows, a version.
void _makeDb(String path, {int version = 4, int rows = 3}) {
  Directory(p.dirname(path)).createSync(recursive: true);
  final db = sql.sqlite3.open(path);
  try {
    db.execute('CREATE TABLE event_rows (id TEXT PRIMARY KEY, title TEXT)');
    db.execute('CREATE TABLE meta_rows (key TEXT PRIMARY KEY, value TEXT)');
    for (var i = 0; i < rows; i++) {
      db.execute('INSERT INTO event_rows VALUES (?, ?)', ['e$i', 'Esemény $i']);
    }
    db.execute("INSERT INTO meta_rows VALUES ('deviceId', 'dev1')");
    db.execute('PRAGMA user_version = $version');
  } finally {
    db.close();
  }
}

int _rows(String path, String table) {
  final db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
  try {
    return db.select('SELECT count(*) AS c FROM $table').first['c'] as int;
  } finally {
    db.close();
  }
}

void main() {
  late Directory root;
  late String docs, local;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    root = Directory.systemTemp.createTempSync('kvantum-start-');
    docs = p.join(root.path, 'Documents');
    local = p.join(root.path, 'AppData', 'Local');
    Directory(docs).createSync(recursive: true);
    Directory(local).createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  String legacy() => p.join(docs, 'kvantum.sqlite');
  String fresh() => p.join(local, 'KvantumNaptar', 'kvantum.sqlite');
  String marker() => p.join(local, 'KvantumNaptar', 'legacy-db-moved.txt');

  group('where the database lives', () {
    test('Windows: outside Documents, which OneDrive may mirror', () {
      final w = locateDatabase(
        windows: true,
        documentsDir: docs,
        localAppData: local,
      );
      expect(w.path, fresh());
      expect(w.legacyPath, legacy());
    });

    test('other systems keep the place they always had', () {
      final a = locateDatabase(
        windows: false,
        documentsDir: docs,
        localAppData: local,
      );
      expect(a.path, legacy());
      expect(a.legacyPath, isNull);
    });

    test('Windows without a LOCALAPPDATA keeps the old place too', () {
      for (final none in [null, '']) {
        final w = locateDatabase(
          windows: true,
          documentsDir: docs,
          localAppData: none,
        );
        expect(w.path, legacy());
        expect(w.legacyPath, isNull);
      }
    });
  });

  group('moving the database out of Documents', () {
    test('nothing there, nothing to move', () {
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect((r.moved, r.cleaned, r.problem), (false, false, null));
      expect(r.path, fresh());
      expect(File(fresh()).existsSync(), isFalse);
    });

    test('first start: copied, checked, noted; the old file stays', () {
      _makeDb(legacy(), rows: 5);
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect(r.moved, isTrue);
      expect(r.problem, isNull);
      expect(r.path, fresh());
      expect(_rows(fresh(), 'event_rows'), 5);
      expect(_rows(fresh(), 'meta_rows'), 1);
      expect(
        File(legacy()).existsSync(),
        isTrue,
        reason: 'kept for one more start',
      );
      expect(File(marker()).readAsStringSync(), legacy());
      expect(
        Directory(p.dirname(fresh())).listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.moving'))),
      );
    });

    test('the next start: the new place has been used, the old copy goes', () {
      _makeDb(legacy());
      moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      File('${legacy()}-journal').writeAsStringSync('leftover');
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect(r.cleaned, isTrue);
      expect(r.path, fresh());
      expect(File(legacy()).existsSync(), isFalse);
      expect(File('${legacy()}-journal').existsSync(), isFalse);
      expect(File(marker()).existsSync(), isFalse);
      expect(
        _rows(fresh(), 'event_rows'),
        3,
        reason: 'the new file is untouched',
      );
    });

    test('every later start leaves everything alone', () {
      _makeDb(legacy());
      moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      final again = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect((again.moved, again.cleaned, again.problem), (false, false, null));
      expect(again.path, fresh());
    });

    test(
      'an old file appearing later (restored by hand) is not touched either',
      () {
        _makeDb(fresh());
        _makeDb(legacy(), rows: 9);
        final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
        expect(r.path, fresh());
        expect(File(legacy()).existsSync(), isTrue);
        expect(_rows(fresh(), 'event_rows'), 3);
      },
    );

    test('a file that cannot be checked: the old place stays in use, nothing is left behind', () {
      File(legacy()).writeAsStringSync('this is not a database ' * 30);
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect(r.moved, isFalse);
      expect(r.problem, isNotNull);
      expect(r.path, legacy());
      expect(File(fresh()).existsSync(), isFalse);
      expect(File('${fresh()}.moving').existsSync(), isFalse);
      expect(File(marker()).existsSync(), isFalse);
      expect(File(legacy()).readAsStringSync(), startsWith('this is not'));
    });

    group('a copy that does not match the original is not used', () {
      // copies the main file, then damages the copy the way [damage] says
      FileCopier damaging(void Function(sql.Database copy) damage) =>
          (from, to) {
            File(from).copySync(to);
            if (!to.endsWith('.moving')) return;
            final db = sql.sqlite3.open(to);
            try {
              damage(db);
            } finally {
              db.close();
            }
          };

      void expectKept(DbMoveResult r, String about) {
        expect(r.moved, isFalse);
        expect(r.problem, contains(about));
        expect(r.path, legacy(), reason: 'the old place stays in use');
        expect(File(fresh()).existsSync(), isFalse);
        expect(File('${fresh()}.moving').existsSync(), isFalse);
        expect(File(marker()).existsSync(), isFalse);
        expect(_rows(legacy(), 'event_rows'), 3, reason: 'untouched');
      }

      test('a row is missing', () {
        _makeDb(legacy());
        final r = moveLegacyDatabase(
          path: fresh(),
          legacyPath: legacy(),
          copy: damaging(
            (d) => d.execute("DELETE FROM event_rows WHERE id = 'e1'"),
          ),
        );
        expectKept(r, 'event_rows');
      });

      test('another schema version', () {
        _makeDb(legacy());
        final r = moveLegacyDatabase(
          path: fresh(),
          legacyPath: legacy(),
          copy: damaging((d) => d.execute('PRAGMA user_version = 3')),
        );
        expectKept(r, 'séma-verzió');
      });

      test('a table is missing', () {
        _makeDb(legacy());
        final r = moveLegacyDatabase(
          path: fresh(),
          legacyPath: legacy(),
          copy: damaging((d) => d.execute('DROP TABLE meta_rows')),
        );
        expectKept(r, 'táblák');
      });

      test('a faithful copy goes through the same road', () {
        _makeDb(legacy());
        final r = moveLegacyDatabase(
          path: fresh(),
          legacyPath: legacy(),
          copy: damaging((d) {}),
        );
        expect(r.moved, isTrue);
        expect(_rows(fresh(), 'event_rows'), 3);
      });
    });

    test('a half-finished copy of an earlier try is replaced', () {
      _makeDb(legacy(), rows: 2);
      Directory(p.dirname(fresh())).createSync(recursive: true);
      File('${fresh()}.moving').writeAsStringSync('half');
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect(r.moved, isTrue);
      expect(_rows(fresh(), 'event_rows'), 2);
    });

    test('the moved database opens like any other', () async {
      // a database as the app itself makes it
      Directory(docs).createSync(recursive: true);
      final seed = AppDatabase(NativeDatabase(File(legacy())));
      await seed.customSelect('SELECT 1').get();
      await seed.close();
      final r = moveLegacyDatabase(path: fresh(), legacyPath: legacy());
      expect(r.moved, isTrue);
      // (openAt needs the platform plugins; the file is what matters here)
      final db = AppDatabase(NativeDatabase(File(r.path)));
      final rows = await db
          .customSelect('SELECT count(*) AS c FROM event_rows')
          .getSingle();
      expect(rows.read<int>('c'), 0);
      await db.close();
    });
  });

  group('the hook that runs on the raw file before drift migrates it', () {
    test('a newer file is refused, and nothing is copied or changed', () {
      final path = p.join(root.path, 'x.sqlite');
      _makeDb(path, version: 9);
      final raw = sql.sqlite3.open(path);
      try {
        expect(
          () => prepareRawDatabase(raw, path: path, schemaVersion: 4),
          throwsA(
            isA<NewerDatabaseError>()
                .having((e) => e.found, 'found', 9)
                .having((e) => e.supported, 'supported', 4),
          ),
        );
        expect(
          raw.select('PRAGMA user_version').first.values.first,
          9,
          reason: 'the label is not written back',
        );
      } finally {
        raw.close();
      }
      expect(
        Directory(root.path).listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.bak-v'))),
      );
    });

    test('the current version passes without a copy', () {
      final path = p.join(root.path, 'x.sqlite');
      _makeDb(path, version: 4);
      final raw = sql.sqlite3.open(path);
      try {
        prepareRawDatabase(raw, path: path, schemaVersion: 4);
      } finally {
        raw.close();
      }
      expect(
        Directory(root.path).listSync().map((e) => p.basename(e.path)),
        isNot(anyElement(contains('.bak-v'))),
      );
    });
  });

  group('the check at start', () {
    test(
      'Windows, first start: moved, then opened from the new place',
      () async {
        _makeDb(legacy());
        final s = await prepareStartup(
          windows: true,
          documentsDir: docs,
          localAppData: local,
        );
        expect(s.problem, isNull);
        expect(s.path, fresh());
        expect(s.move!.moved, isTrue);
      },
    );

    test('other systems: the usual place, no move', () async {
      _makeDb(legacy());
      final s = await prepareStartup(windows: false, documentsDir: docs);
      expect(s.path, legacy());
      expect(s.move, isNull);
      expect(s.problem, isNull);
    });

    test(
      'a database of a newer version is reported, not opened or moved on',
      () async {
        _makeDb(legacy(), version: 9);
        final s = await prepareStartup(windows: false, documentsDir: docs);
        expect(s.problem, isA<NewerDatabaseError>());
        final w = await prepareStartup(
          windows: true,
          documentsDir: docs,
          localAppData: local,
        );
        expect(
          w.problem,
          isA<NewerDatabaseError>(),
          reason: 'a faithful copy is just as new',
        );
      },
    );

    test('nothing yet: a clean start', () async {
      final s = await prepareStartup(windows: false, documentsDir: docs);
      expect(s.problem, isNull);
    });
  });

  group('the screen for a database that must not be opened', () {
    testWidgets('a newer database: says so and that nothing was touched', (
      tester,
    ) async {
      await tester.pumpWidget(
        StartupProblemApp(problem: const NewerDatabaseError(9, 4)),
      );
      expect(find.byKey(const Key('startup-title')), findsOneWidget);
      expect(find.textContaining('újabb alkalmazásverzióhoz'), findsOneWidget);
      expect(find.textContaining('érintetlenek'), findsOneWidget);
      expect(find.byKey(const Key('startup-close')), findsOneWidget);
    });

    testWidgets('a damaged file: names the file and the safety copies', (
      tester,
    ) async {
      await tester.pumpWidget(
        StartupProblemApp(
          problem: UnreadableDatabaseError(
            '/x/kvantum.sqlite',
            'not a database',
          ),
        ),
      );
      expect(find.textContaining('/x/kvantum.sqlite'), findsOneWidget);
      expect(find.textContaining('.bak-v'), findsOneWidget);
    });

    testWidgets('anything else still gets a plain sentence', (tester) async {
      await tester.pumpWidget(StartupProblemApp(problem: StateError('boom')));
      expect(find.textContaining('nem sikerült megnyitni'), findsOneWidget);
    });

    testWidgets('it fits a phone', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        StartupProblemApp(problem: const NewerDatabaseError(9, 4)),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
