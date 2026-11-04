import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/harness.dart';

void main() {
  // several in-memory databases = several devices in these tests
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late RecordRepository repo; // device A
  late FakeDrive drive;
  late DriveSyncEngine engine;
  var clock = 1000;

  RecordRepository repoFor(AppDatabase d, String dev) =>
      RecordRepository(d, deviceId: dev, clock: () => ++clock);

  setUp(() async {
    clock = 1000;
    db = await newDb();
    repo = repoFor(db, 'A');
    drive = FakeDrive();
    engine = DriveSyncEngine(repo, drive);
  });
  tearDown(() => db.close());

  Future<SyncRecord> addTask(String id, String title, {RecordRepository? r}) =>
      (r ?? repo).edit(kindTask, id, taskFields(title: title));

  test('a local task is uploaded once; a second run changes nothing', () async {
    await addTask('t1', 'Bevásárlás');
    final r1 = await engine.sync();
    expect(r1.pushed, 1);
    expect(drive.files.length, 1);
    expect(drive.files.values.single.name, 'task-t1.json');
    expect(await repo.dirtyCount(), 0);
    final r2 = await engine.sync();
    expect(r2.pushed, 0);
    expect(drive.writes, 1);
  });

  test('files from another device arrive and are merged in', () async {
    final other = repoFor(await newDb(), 'B');
    final rec = await addTask('t9', 'Másik gépről', r: other);
    drive.externalWrite('task-t9.json', rec.encode());
    final r = await engine.sync();
    expect(r.pulled, 1);
    expect(TaskView((await repo.get(kindTask, 't9'))!).title, 'Másik gépről');
    expect(await repo.dirtyCount(), 0); // nothing to push back
    expect(drive.writes, 0);
  });

  test(
    'concurrent edits of DIFFERENT fields both survive on both sides',
    () async {
      await addTask('t1', 'Eredeti');
      await engine.sync();
      final fileId = drive.files.keys.single;

      // device B edits "done" and uploads
      final base = SyncRecord.decode(drive.files[fileId]!.content);
      drive.externalWrite(
        'task-t1.json',
        base.edit({'done': true}, ts: 5000, dev: 'B').encode(),
      );
      // meanwhile device A edits the title locally
      await repo.edit(kindTask, 't1', {'title': 'Új cím'});

      await engine.sync();
      final local = TaskView((await repo.get(kindTask, 't1'))!);
      final remote = TaskView(SyncRecord.decode(drive.files[fileId]!.content));
      for (final t in [local, remote]) {
        expect(t.title, 'Új cím');
        expect(t.done, isTrue);
      }
      expect(drive.files.length, 1);
      expect(await repo.dirtyCount(), 0);
    },
  );

  test('same field edited twice: the later write wins on both sides', () async {
    await addTask('t1', 'x');
    await engine.sync();
    final id = drive.files.keys.single;
    final base = SyncRecord.decode(drive.files[id]!.content);
    drive.externalWrite(
      'task-t1.json',
      base.edit({'title': 'B szerint'}, ts: 9000, dev: 'B').encode(),
    );
    await repo.edit(kindTask, 't1', {'title': 'A szerint'}); // ts ~1003 < 9000
    await engine.sync();
    expect(TaskView((await repo.get(kindTask, 't1'))!).title, 'B szerint');
    expect(
      TaskView(SyncRecord.decode(drive.files[id]!.content)).title,
      'B szerint',
    );
  });

  test('offline: nothing is lost, the queue survives, later it uploads exactly once', () async {
    await addTask('t1', 'Offline');
    drive.offline = true;
    final r1 = await engine.sync();
    expect(r1.stoppedEarly, isTrue);
    expect(await repo.dirtyCount(), 1);
    drive.offline = false;
    await engine.sync();
    await engine.sync();
    expect(drive.files.length, 1);
    expect(drive.creates, 1);
    expect(await repo.dirtyCount(), 0);
  });

  test('two devices created the same check-in day: adopted, merged, no duplicate file', () async {
    final id = checkInId(DateTime.utc(2026, 11, 4));
    await repo.edit(kindCheckIn, id, checkInFields(physical: 4, note: 'A'));
    final bDb = await newDb();
    final b = repoFor(bDb, 'B');
    final recB = await b.edit(kindCheckIn, id, checkInFields(mood: 2));
    drive.externalWrite('checkin-$id.json', recB.encode()); // B uploaded first

    await engine.sync();
    expect(drive.files.length, 1);
    final merged = CheckInView(
      SyncRecord.decode(drive.files.values.single.content),
    );
    expect(merged.mood, 2);
    expect(merged.physical, 4);
    await bDb.close();
  });

  test('duplicate files (race) are merged into the oldest and the extra is deleted', () async {
    final a = repoFor(await newDb(), 'B');
    final r1 = await addTask('t1', 'Első', r: a);
    final r2 = r1.edit({'notes': 'a másikból'}, ts: 7000, dev: 'C');
    drive.externalWrite('task-t1.json', r1.encode());
    drive.externalWrite('task-t1.json', r2.encode(), duplicate: true);
    expect(drive.files.length, 2);

    final rep = await engine.sync();
    expect(rep.mergedDuplicates, 1);
    expect(drive.files.length, 1);
    final t = TaskView(SyncRecord.decode(drive.files.values.single.content));
    expect(t.title, 'Első');
    expect(t.notes, 'a másikból');
  });

  test('corrupt and foreign files are skipped, the rest still syncs', () async {
    final good = (await addTask(
      't1',
      'Jó',
      r: repoFor(await newDb(), 'B'),
    )).encode();
    drive.externalWrite('task-bad.json', 'ez nem json');
    drive.externalWrite('task-t1.json', good);
    drive.externalWrite('notes.txt', 'idegen fájl');
    drive.externalWrite(
      'task-liar.json',
      SyncRecord(
        id: 'other',
        kind: kindTask,
      ).edit({'title': 'x'}, ts: 1, dev: 'A').encode(),
    );
    final rep = await engine.sync();
    expect(
      rep.skippedCorrupt,
      2,
    ); // bad json + id/name mismatch; "notes.txt" is just foreign
    expect(await repo.get(kindTask, 't1'), isNotNull);
    expect(await repo.get(kindTask, 'bad'), isNull);
  });

  test(
    'a corrupt remote copy of a local record is repaired by our upload',
    () async {
      await addTask('t1', 'Helyi');
      await engine.sync();
      final id = drive.files.keys.single;
      drive.externalWrite('task-t1.json', '{{{');
      await repo.edit(kindTask, 't1', {'notes': 'változás'});
      await engine.sync();
      expect(
        TaskView(SyncRecord.decode(drive.files[id]!.content)).notes,
        'változás',
      );
    },
  );

  test('expired page token: full resync, nothing duplicated', () async {
    await addTask('t1', 'x');
    await engine.sync();
    drive.expireToken = true;
    final rep = await engine.sync();
    expect(rep.full, isTrue);
    expect(drive.files.length, 1);
    expect(await repo.dirtyCount(), 0);
  });

  test(
    'a file deleted in Drive is uploaded again from the local copy',
    () async {
      await addTask('t1', 'Marad');
      await engine.sync();
      drive.externalDelete(drive.files.keys.single);
      await engine.sync();
      expect(drive.files.length, 1);
      expect(
        TaskView(SyncRecord.decode(drive.files.values.single.content)).title,
        'Marad',
      );
    },
  );

  test('a full listing without a known file re-queues it', () async {
    await addTask('t1', 'Marad');
    await engine.sync();
    drive.files.clear(); // vanished without a change entry
    drive.expireToken = true;
    await engine.sync();
    expect(drive.files.length, 1);
  });

  test(
    'an edit made WHILE uploading stays queued and goes out next time',
    () async {
      await addTask('t1', 'Első');
      drive.duringWrite = () async {
        await repo.edit(kindTask, 't1', {'notes': 'közben írtam'});
      };
      await engine.sync();
      expect(
        await repo.dirtyCount(),
        1,
      ); // not marked clean: it changed during the upload
      await engine.sync();
      expect(await repo.dirtyCount(), 0);
      expect(
        TaskView(SyncRecord.decode(drive.files.values.single.content)).notes,
        'közben írtam',
      );
    },
  );

  test('deleting propagates as a tombstone to another device', () async {
    await addTask('t1', 'Törlendő');
    await engine.sync();
    await repo.delete(kindTask, 't1');
    await engine.sync();
    final bDb = await newDb();
    final b = repoFor(bDb, 'B');
    final engB = DriveSyncEngine(b, drive);
    await engB.sync();
    expect(TaskView((await b.get(kindTask, 't1'))!).deleted, isTrue);
    await bDb.close();
  });

  test(
    'changes by other devices after the first sync arrive incrementally',
    () async {
      await addTask('t1', 'x');
      await engine.sync();
      final rec = await addTask(
        't2',
        'Később jött',
        r: repoFor(await newDb(), 'B'),
      );
      drive.externalWrite('task-t2.json', rec.encode());
      final rep = await engine.sync();
      expect(rep.full, isFalse);
      expect(await repo.get(kindTask, 't2'), isNotNull);
      // only our own first upload; the echo of it and t2 caused no new write
      expect(drive.writes, 1);
    },
  );

  test('serial runs: overlapping sync() calls never upload twice', () async {
    await addTask('t1', 'x');
    await Future.wait([engine.sync(), engine.sync(), engine.sync()]);
    expect(drive.creates, 1);
  });
}
