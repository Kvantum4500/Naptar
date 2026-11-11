import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/backup_ops.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late EventRepository repo;
  setUp(() async {
    db = await newDb();
    repo = EventRepository(db);
  });
  tearDown(() => db.close());

  CalEvent at(String id, String title, int day) =>
      evt(id, title, floating(2026, 11, day, 9));

  Future<String> backupOf(List<CalEvent> events) async {
    await repo.saveAll(events);
    return exportBackup(repo);
  }

  group('preview: nothing is written, the difference is worked out', () {
    test('new, changed and unchanged events are told apart', () async {
      final text = await backupOf([
        at('a', 'Régi', 2),
        at('b', 'Változatlan', 3),
        at('c', 'Töröltem', 4),
      ]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      await repo.deleteLocal('c');

      final before = await repo.all();
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh.map((e) => e.id), ['c']);
      expect(plan.changes.map((c) => c.current.title), ['Átírt']);
      expect(plan.changes.single.incoming.title, 'Régi');
      expect(plan.unchanged, 1);
      expect(plan.empty, isFalse);
      expect(
        (await repo.all()).map((e) => '${e.id}:${e.title}').toSet(),
        before.map((e) => '${e.id}:${e.title}').toSet(),
        reason: 'a preview writes nothing',
      );
    });

    test('junk gives an empty plan and the reasons', () async {
      final plan = await previewBackup(
        repo,
        'ez nem naptár',
        calendarId: kNaptarCalendar,
      );
      expect(plan.empty, isTrue);
    });
  });

  group('apply', () {
    test('without overwrite only the new events are written', () async {
      final text = await backupOf([at('a', 'Régi', 2), at('c', 'Törölt', 4)]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      await repo.deleteLocal('c');
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);

      final r = await applyBackup(repo, plan, overwrite: false);
      expect((r.added, r.updated, r.kept), (1, 0, 1));
      expect((await repo.byId('a'))!.title, 'Átírt');
      expect(await repo.byId('c'), isNotNull);
    });

    test(
      'with overwrite the changed event is restored with its link',
      () async {
        final text = await backupOf([at('a', 'Régi', 2)]);
        final linked = (await repo.byId('a'))!.copyWith(
          title: 'Átírt',
          googleId: 'g-1',
          etag: 'e-1',
          iCalUid: 'u-1',
        );
        await repo.saveLocal(linked);
        final stored = (await repo.byId('a'))!;
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );

        final r = await applyBackup(repo, plan, overwrite: true);
        expect((r.added, r.updated, r.kept), (0, 1, 0));
        final e = (await repo.byId('a'))!;
        expect(e.title, 'Régi');
        expect((e.googleId, e.etag, e.iCalUid), ('g-1', 'e-1', 'u-1'));
        expect(e.version, greaterThan(stored.version));
        expect(
          await repo.pendingOps(),
          containsPair('a', 'upsert'),
          reason: 'the restored event goes up to Google',
        );
      },
    );

    test('a second restore of the same file changes nothing', () async {
      final text = await backupOf([at('a', 'Régi', 2)]);
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh, isEmpty);
      expect(plan.changes, isEmpty);
      expect(plan.unchanged, 1);
    });

    test('importBackup needs an explicit decision', () async {
      final text = await backupOf([at('a', 'Régi', 2)]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      final kept = await importBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        overwrite: false,
      );
      expect(kept.kept, 1);
      expect((await repo.byId('a'))!.title, 'Átírt');
    });
  });

  group('large files are read away from the screen thread', () {
    test('the runner is used above the threshold only', () async {
      final text = exportIcs([at('a', 'Régi', 2)]);
      var runs = 0;
      Future<IcsImport> runner(IcsImport Function() job) {
        runs++;
        return Future.value(job());
      }

      await previewBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        threshold: text.length,
        runner: runner,
      );
      expect(runs, 0, reason: 'at the threshold it is read in place');
      await previewBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        threshold: text.length - 1,
        runner: runner,
      );
      expect(runs, 1);
    });

    test('a really large file is read on an isolate, to the end', () async {
      final events = [
        for (var i = 0; i < 1500; i++) at('e$i', 'Esemény $i', 5),
      ];
      final text = exportIcs(events);
      expect(text.length, greaterThan(isolateParseThreshold));
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh, hasLength(1500));
      expect(plan.fresh.last.title, 'Esemény 1499');
    });
  });
}
