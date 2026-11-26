import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_dialogs.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_app/journal/journal_ops.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'backup_service_test.dart' show Device, device;
import 'support/fake_drive.dart';
import 'support/harness.dart';

/// The diary on two devices and in a backup (8th round): the text of an entry
/// goes through Drive and into a backup, a title changed on one device and a
/// text changed on the other both stay, a deletion travels, and the pictures
/// themselves are no part of the records: only the entry's words that they
/// exist (the files travel on their own way: see photo_sync_test).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  final at = DateTime.utc(2026, 11, 16, 8, 15);

  JournalEntry entry(
    String id, {
    String title = 'Kirándulás',
    String text = 'Szép idő volt.',
    List<PhotoRef> photos = const [],
  }) => JournalEntry.checked(
    id: id,
    at: at,
    title: title,
    text: text,
    photos: photos,
  );

  group('on two devices', () {
    late AppDatabase dbA, dbB;
    late RecordRepository repoA, repoB;
    late JournalOps a, b;
    late FakeDrive drive;
    late DriveSyncEngine engineA, engineB;
    var clock = 1000;

    RecordRepository repoFor(AppDatabase d, String dev) =>
        RecordRepository(d, deviceId: dev, clock: () => ++clock);

    setUp(() async {
      clock = 1000;
      dbA = await newDb();
      dbB = await newDb();
      repoA = repoFor(dbA, 'A');
      repoB = repoFor(dbB, 'B');
      a = JournalOps(repoA);
      b = JournalOps(repoB);
      drive = FakeDrive();
      engineA = DriveSyncEngine(repoA, drive);
      engineB = DriveSyncEngine(repoB, drive);
    });
    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    Future<List<JournalEntry>> entriesOf(RecordRepository r) async =>
        journalEntries(await r.all(kindJournal));

    test('an entry goes up as a file of its own, and arrives', () async {
      await a.save(entry('e1'));
      final r = await engineA.sync();
      expect(r.pushed, 1);
      expect(drive.files.values.single.name, 'journal-e1.json');
      await engineB.sync();
      final e = (await entriesOf(repoB)).single;
      expect((e.title, e.text, e.at), ('Kirándulás', 'Szép idő volt.', at));
      expect(await repoB.dirtyCount(), 0);
    });

    test('says which pictures there are, and carries no picture', () async {
      final photos = [
        for (var i = 0; i < 12; i++)
          PhotoRef(id: 'p$i', width: 1600, height: 1067, bytes: 400000),
      ];
      await a.save(entry('e1', photos: photos));
      await engineA.sync();
      final file = drive.files.values.single.content;
      expect(file.length, lessThan(4000), reason: 'only words and numbers');
      await engineB.sync();
      final e = (await entriesOf(repoB)).single;
      expect([for (final p in e.photos) p.id], [for (final p in photos) p.id]);
      expect(e.photos.first.bytes, 400000);
    });

    test(
      'a title changed on one device and a text on the other both stay',
      () async {
        await a.save(entry('e1'));
        await engineA.sync();
        await engineB.sync();
        await a.save(entry('e1', title: 'Új cím'));
        await b.save(entry('e1', text: 'Új szöveg'));
        await engineA.sync();
        await engineB.sync();
        await engineA.sync();
        for (final r in [repoA, repoB]) {
          final e = (await entriesOf(r)).single;
          expect(e.title, 'Új cím');
          expect(e.text, 'Új szöveg');
        }
      },
    );

    test('the same part on both: the later one wins on both', () async {
      await a.save(entry('e1'));
      await engineA.sync();
      await engineB.sync();
      await a.save(entry('e1', text: 'Korábbi'));
      await b.save(entry('e1', text: 'Későbbi'));
      await engineA.sync();
      await engineB.sync();
      await engineA.sync();
      expect((await entriesOf(repoA)).single.text, 'Későbbi');
      expect((await entriesOf(repoB)).single.text, 'Későbbi');
    });

    test(
      'a deletion reaches the other device, and taking it back does too',
      () async {
        await a.save(entry('e1'));
        await engineA.sync();
        await engineB.sync();
        await b.delete('e1');
        await engineB.sync();
        await engineA.sync();
        expect(await entriesOf(repoA), isEmpty);
        await b.restore('e1');
        await engineB.sync();
        await engineA.sync();
        expect((await entriesOf(repoA)).single.id, 'e1');
      },
    );

    test('a file that is no entry hides itself and nothing else', () async {
      await a.save(entry('e1'));
      drive.externalWrite(
        'journal-broken.json',
        jsonEncode({'v': 1, 'id': 'broken', 'kind': 'journal', 'f': {}}),
      );
      drive.externalWrite('journal-x.json', 'nem json');
      await engineA.sync();
      await engineB.sync();
      expect([for (final e in await entriesOf(repoB)) e.id], ['e1']);
    });
  });

  group('in a backup', () {
    late Device a, b;
    setUp(() async {
      a = await device();
      b = await device();
    });
    tearDown(() async {
      await a.db.close();
      await b.db.close();
    });

    Future<void> seed(Device d) async {
      final ops = JournalOps(d.records);
      await ops.save(entry('e1', photos: const [PhotoRef(id: 'p1', bytes: 5)]));
      await ops.save(entry('e2', title: 'Második', text: 'Másik nap'));
    }

    test('the entries are in it, and it says how many', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindJournal], 2);
      expect(backupCountsText({kindJournal: 2}), '2 napló-bejegyzés');
      expect(backupCountsText({kindJournal: 0}), 'üres');
    });

    test(
      'they come back on an empty device, with the words of the pictures',
      () async {
        await seed(a);
        final file = await b.service().open(await a.service().create());
        final preview = await b.service().preview(file);
        expect(preview.records.added, 2);
        expect(
          await b.records.all(kindJournal),
          isEmpty,
          reason: 'a preview writes nothing',
        );
        await b.service().restore(file, overwrite: false);
        final list = journalEntries(await b.records.all(kindJournal));
        expect({for (final e in list) e.id}, {'e1', 'e2'});
        expect(list.firstWhere((e) => e.id == 'e1').photos.single.id, 'p1');
      },
    );

    test('an entry deleted since is not brought back', () async {
      await seed(a);
      final bytes = await a.service().create();
      a.clock.ms += 60000;
      await JournalOps(a.records).delete('e2');
      final file = await a.service().open(bytes);
      await a.service().restore(file, overwrite: false);
      expect(
        [
          for (final e in journalEntries(await a.records.all(kindJournal)))
            e.id,
        ],
        ['e1'],
      );
    });

    test('a text changed since stays', () async {
      await seed(a);
      final bytes = await a.service().create();
      a.clock.ms += 60000;
      await JournalOps(a.records)
          .save(entry('e2', title: 'Második', text: 'Újabb szöveg'));
      final file = await a.service().open(bytes);
      await a.service().restore(file, overwrite: false);
      final e = journalEntries(await a.records.all(kindJournal))
          .firstWhere((e) => e.id == 'e2');
      expect(e.text, 'Újabb szöveg');
    });

    test('locked, they are in it too', () async {
      await seed(a);
      final locked = await a.service().create(password: 'jelszo');
      final file = await a.service().open(locked, password: 'jelszo');
      expect(file.meta.counts[kindJournal], 2);
    });
  });
}
