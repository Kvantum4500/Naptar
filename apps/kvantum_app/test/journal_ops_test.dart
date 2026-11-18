import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/housekeeping.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/journal/journal_draft_store.dart';
import 'package:kvantum_app/journal/journal_ops.dart';
import 'package:kvantum_app/journal/journal_providers.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/journal/photo_import.dart';
import 'package:kvantum_app/journal/photo_sweep.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/turns.dart';

/// The diary in the app (8th round): what is written where, that every change
/// has a way back, where the unsaved start of an entry is kept, the folder of
/// pictures, and the daily tidying of it.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  final nov16 = DateTime.utc(2026, 11, 16, 8, 15);
  late AppDatabase db;
  late RecordRepository repo;
  late int nowMs;
  late int changed;
  late JournalOps ops;

  setUp(() async {
    db = await newDb();
    nowMs = DateTime.utc(2026, 11, 16, 12).millisecondsSinceEpoch;
    repo = RecordRepository(db, deviceId: 'dev1', clock: () => nowMs);
    changed = 0;
    ops = JournalOps(repo, onChanged: () => changed++);
  });
  tearDown(() => db.close());

  JournalEntry entry(
    String id, {
    DateTime? at,
    String title = 'Kirándulás',
    String text = 'Szép idő volt.',
    List<PhotoRef> photos = const [],
  }) => JournalEntry.checked(
    id: id,
    at: at ?? nov16,
    title: title,
    text: text,
    photos: photos,
  );

  Future<List<JournalEntry>> entries() async =>
      journalEntries(await repo.all(kindJournal));

  group('the operations', () {
    test(
      'a new entry is a record of its own, and asks the sync to run',
      () async {
        await ops.save(
          entry('e1', photos: [const PhotoRef(id: 'p1', bytes: 5)]),
        );
        final r = await repo.get(kindJournal, 'e1');
        expect(
          JournalEntry.fromRecord(r!),
          entry('e1', photos: [const PhotoRef(id: 'p1', bytes: 5)]),
        );
        expect(changed, 1);
        expect({for (final d in await repo.dirty()) d.id}, contains('e1'));
      },
    );

    test('an entry is changed in the same record', () async {
      await ops.save(entry('e1'));
      nowMs += 1000;
      await ops.save(entry('e1', title: 'Új cím'));
      expect(await repo.all(kindJournal), hasLength(1));
      expect((await entries()).single.title, 'Új cím');
    });

    test('only a part that changed is stamped anew', () async {
      await ops.save(entry('e1'));
      final before = (await repo.get(kindJournal, 'e1'))!;
      nowMs += 60000;
      await ops.save(entry('e1', title: 'Új cím'));
      final after = (await repo.get(kindJournal, 'e1'))!;
      expect(after.fields['text']!.ts, before.fields['text']!.ts);
      expect(after.fields['at']!.ts, before.fields['at']!.ts);
      expect(
        after.fields['title']!.ts,
        greaterThan(before.fields['title']!.ts),
      );
    });

    test(
      'a deletion keeps the record as a marker, and can be taken back',
      () async {
        await ops.save(entry('e1'));
        await ops.delete('e1');
        expect(await entries(), isEmpty);
        expect((await repo.get(kindJournal, 'e1'))!.deleted, isTrue);
        expect(await ops.restore('e1'), isTrue);
        expect((await entries()).single.id, 'e1');
        expect(changed, 3);
      },
    );

    test('taking back what is not deleted does nothing', () async {
      await ops.save(entry('e1'));
      expect(await ops.restore('e1'), isFalse);
      expect(await ops.restore('nincs-ilyen'), isFalse);
      expect(await repo.get(kindJournal, 'nincs-ilyen'), isNull);
    });

    test('deleting what is not there makes no record', () async {
      await ops.delete('nincs-ilyen');
      expect(await repo.all(kindJournal), isEmpty);
    });
  });

  group('the providers', () {
    test(
      'give the entries, the newest first, and follow the changes',
      () async {
        final c = ProviderContainer(overrides: baseOverrides(db));
        addTearDown(c.dispose);
        c.listen(journalEntriesProvider, (_, _) {});
        expect(await c.read(journalEntriesProvider.future), isEmpty);
        await c
            .read(journalOpsProvider)
            .save(entry('a', at: DateTime.utc(2026, 11, 14, 9)));
        await c
            .read(journalOpsProvider)
            .save(entry('b', at: DateTime.utc(2026, 11, 16, 7)));
        await turns();
        expect(
          [for (final e in c.read(journalEntriesProvider).value!) e.id],
          ['b', 'a'],
        );
        await c.read(journalOpsProvider).delete('b');
        await turns();
        expect(
          [for (final e in c.read(journalEntriesProvider).value!) e.id],
          ['a'],
        );
      },
    );

    test('an entry another device wrote shows without a restart', () async {
      final c = ProviderContainer(overrides: baseOverrides(db));
      addTearDown(c.dispose);
      c.listen(journalEntriesProvider, (_, _) {});
      await c.read(journalEntriesProvider.future);
      await repo.applyRemote(
        SyncRecord(
          id: 'x',
          kind: kindJournal,
        ).edit(entry('x').fields, ts: nowMs + 5, dev: 'dev2'),
      );
      await turns();
      expect(c.read(journalEntriesProvider).value!.single.id, 'x');
    });
  });

  group('the draft', () {
    late JournalDraftStore store;
    setUp(() => store = JournalDraftStore(repo));

    JournalDraft draft({String text = 'Félbehagyott'}) => JournalDraft(
      id: 'n1',
      at: nov16,
      text: text,
      photos: const [PhotoRef(id: 'p1')],
    );

    test('is kept and read back', () async {
      expect(await store.load(), isNull);
      await store.save(draft());
      final back = (await store.load())!;
      expect((back.id, back.text), ('n1', 'Félbehagyott'));
      expect(back.photos.single.id, 'p1');
    });

    test(
      'is kept on this device only: not a record, not in the backup',
      () async {
        await store.save(draft());
        expect(await repo.all(kindJournal), isEmpty);
        expect(await repo.meta(journalDraftKey), isNotNull);
        expect(journalDraftKey, 'journal.draft');
      },
    );

    test(
      'one with nothing in it is no draft, and clears the old one',
      () async {
        await store.save(draft());
        await store.save(JournalDraft(id: 'n1', at: nov16));
        expect(await store.load(), isNull);
        expect(await repo.meta(journalDraftKey), isNull);
      },
    );

    test('is cleared', () async {
      await store.save(draft());
      await store.clear();
      expect(await store.load(), isNull);
    });

    test('a damaged one is not offered', () async {
      await repo.setMeta(journalDraftKey, 'nem json');
      expect(await store.load(), isNull);
    });
  });

  group('the folder of pictures', () {
    late Directory dir;
    late DirPhotoFiles files;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('kvantum-photos');
      files = DirPhotoFiles(Directory('${dir.path}/journal/photos'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps a file and gives it back', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      expect(await files.exists('a1.jpg'), isFalse);
      expect(await files.read('a1.jpg'), isNull);
      await files.write('a1.jpg', bytes);
      expect(await files.exists('a1.jpg'), isTrue);
      expect(await files.read('a1.jpg'), bytes);
      await files.delete('a1.jpg');
      expect(await files.exists('a1.jpg'), isFalse);
      await files.delete('a1.jpg'); // (already gone: no error)
    });

    test('creates its folder, and leaves no half-written file', () async {
      await files.write('a1.jpg', Uint8List.fromList([1]));
      final names = [
        for (final e in Directory('${dir.path}/journal/photos').listSync())
          e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
      expect(names, ['a1.jpg']);
    });

    test('a write that fails leaves nothing behind and says so', () async {
      // (a directory is in the way of the file)
      Directory('${dir.path}/journal/photos/b2.jpg')
          .createSync(recursive: true);
      await expectLater(
        files.write('b2.jpg', Uint8List.fromList([1])),
        throwsA(isA<FileSystemException>()),
      );
      final leftovers = [
        for (final e in Directory('${dir.path}/journal/photos').listSync())
          if (e.path.endsWith('.tmp')) e.path,
      ];
      expect(leftovers, isEmpty);
    });

    test(
      'lists the pictures that are named like ours, and nothing else',
      () async {
        await files.write('a1.jpg', Uint8List.fromList([1, 2]));
        await files.write('b2.heic', Uint8List.fromList([1, 2, 3]));
        File('${dir.path}/journal/photos/jegyzet.txt').writeAsStringSync('x');
        File('${dir.path}/journal/photos/../x.jpg').writeAsStringSync('x');
        Directory('${dir.path}/journal/photos/mappa.jpg').createSync();
        final listed = await files.list();
        expect({for (final f in listed) f.name}, {'a1.jpg', 'b2.heic'});
        expect(listed.firstWhere((f) => f.name == 'b2.heic').size, 3);
      },
    );

    test('an empty or missing folder lists nothing', () async {
      expect(await files.list(), isEmpty);
    });

    test('refuses a name that is not an id and a picture ending', () async {
      for (final name in [
        '../x.jpg',
        'a/b.jpg',
        'a.exe',
        'a b.jpg',
        '.jpg',
        'x',
      ]) {
        expect(isPhotoFileName(name), isFalse, reason: name);
        await expectLater(files.write(name, Uint8List(1)), throwsArgumentError);
        await expectLater(files.read(name), throwsArgumentError);
        await expectLater(files.delete(name), throwsArgumentError);
      }
      for (final name in [
        'a1.jpg',
        'abc-123_X.png',
        'x.HEIC'.toLowerCase(),
        'p.webp',
      ]) {
        expect(isPhotoFileName(name), isTrue, reason: name);
      }
    });
  });

  group('the daily tidying of the pictures', () {
    late MemoryPhotoFiles files;
    late JournalDraftStore drafts;
    late PhotoSweep sweep;
    final now = DateTime.utc(2026, 11, 16, 12);

    setUp(() {
      files = MemoryPhotoFiles(clock: () => now);
      drafts = JournalDraftStore(repo);
      sweep = PhotoSweep(files: files, records: repo, drafts: drafts);
    });

    void put(String name, {Duration age = const Duration(days: 5)}) =>
        files.put(name, Uint8List.fromList([1]), age: age);

    test('removes an old picture nobody refers to, and only that', () async {
      await ops.save(entry('e1', photos: [const PhotoRef(id: 'kept')]));
      put('kept.jpg');
      put('orphan.jpg');
      expect(await sweep.run(now), 1);
      expect(files.names.toSet(), {'kept.jpg'});
    });

    test(
      'leaves a young picture alone: its entry may be being written',
      () async {
        put('young.jpg', age: const Duration(days: 1));
        put('older.jpg', age: const Duration(days: 3));
        expect(await sweep.run(now), 1);
        expect(files.names.toSet(), {'young.jpg'});
      },
    );

    test('the grace is two days, to the minute', () async {
      expect(orphanPhotoGrace, const Duration(days: 2));
      put('young.jpg', age: const Duration(days: 1, hours: 23, minutes: 59));
      put('exact.jpg', age: orphanPhotoGrace);
      put('older.jpg', age: const Duration(days: 2, minutes: 1));
      expect(await sweep.run(now), 2);
      expect(files.names.toSet(), {'young.jpg'});
    });

    test('keeps what a draft refers to', () async {
      put('draftpic.jpg');
      await drafts.save(
        JournalDraft(
          id: 'n1',
          at: nov16,
          photos: [const PhotoRef(id: 'draftpic')],
        ),
      );
      expect(await sweep.run(now), 0);
      await drafts.clear();
      expect(await sweep.run(now), 1);
    });

    test('removes the pictures of a deleted entry once they are old', () async {
      await ops.save(entry('e1', photos: [const PhotoRef(id: 'gone')]));
      put('gone.jpg');
      await ops.delete('e1');
      expect(await sweep.run(now), 1);
    });

    test('keeps the pictures of an entry that is taken back', () async {
      await ops.save(entry('e1', photos: [const PhotoRef(id: 'back')]));
      put('back.jpg', age: const Duration(days: 1));
      await ops.delete('e1');
      expect(await sweep.run(now), 0);
      await ops.restore('e1');
      put('back.jpg');
      expect(await sweep.run(now), 0);
    });

    test('keeps the file of another ending of the same id apart', () async {
      await ops.save(
        entry(
          'e1',
          photos: [const PhotoRef(id: 'a', ext: 'heic')],
        ),
      );
      put('a.heic');
      put('a.jpg'); // not what the entry says
      expect(await sweep.run(now), 1);
      expect(files.names.toSet(), {'a.heic'});
    });

    test('has nothing to do in an empty folder', () async {
      expect(await sweep.run(now), 0);
    });

    test('does not touch what is not named like ours', () async {
      // (the memory folder lists only our names; the real one does the same)
      put('orphan.jpg');
      expect(await sweep.run(now), 1);
    });
  });

  group('the daily upkeep', () {
    test('tidies the pictures and counts them in its report', () async {
      final files = MemoryPhotoFiles(
        clock: () => DateTime.utc(2026, 11, 16, 12),
      );
      files.put('orphan.jpg', Uint8List(1), age: const Duration(days: 9));
      final h = Housekeeping(
        events: EventRepository(db),
        finance: FinanceRepository(db, clock: () => nowMs),
        now: () => DateTime.utc(2026, 11, 16, 12),
        sweepPhotos: PhotoSweep(
          files: files,
          records: repo,
          drafts: JournalDraftStore(repo),
        ).run,
      );
      final report = (await h.runIfDue())!;
      expect(report.photos, 1);
      expect(report.any, isTrue);
      expect(report.toJson()['photos'], 1);
      expect(files.names, isEmpty);
    });

    test('goes on when the folder cannot be tidied', () async {
      final h = Housekeeping(
        events: EventRepository(db),
        finance: FinanceRepository(db, clock: () => nowMs),
        now: () => DateTime.utc(2026, 11, 16, 12),
        sweepPhotos: (_) => throw const FileSystemException('nem olvasható'),
      );
      final report = await h.runIfDue();
      expect(report, isNotNull);
      expect(report!.photos, 0);
    });

    test('without a folder to tidy it does what it did', () async {
      final h = Housekeeping(
        events: EventRepository(db),
        finance: FinanceRepository(db, clock: () => nowMs),
        now: () => DateTime.utc(2026, 11, 16, 12),
      );
      expect((await h.runIfDue())!.photos, 0);
    });
  });

  group('what the screens read of a picture', () {
    test(
      'is its bytes, or nothing when the file is not on this device',
      () async {
        final files = MemoryPhotoFiles()
          ..put('a1.jpg', Uint8List.fromList([9, 8]));
        final c = ProviderContainer(
          overrides: [
            ...baseOverrides(db),
            photoFilesProvider.overrideWithValue(files),
          ],
        );
        addTearDown(c.dispose);
        c.listen(photoBytesProvider('a1.jpg'), (_, _) {});
        c.listen(photoBytesProvider('b2.jpg'), (_, _) {});
        expect(await c.read(photoBytesProvider('a1.jpg').future), [9, 8]);
        expect(await c.read(photoBytesProvider('b2.jpg').future), isNull);
      },
    );
  });

  group('the pieces the app puts together', () {
    test(
      'the importer writes into the pictures and the log of the app',
      () async {
        final files = MemoryPhotoFiles();
        final sink = MemoryDiagSink();
        final log = DiagLog()..attach(sink);
        final c = ProviderContainer(
          overrides: [
            ...baseOverrides(db),
            photoFilesProvider.overrideWithValue(files),
            diagLogProvider.overrideWithValue(log),
          ],
        );
        addTearDown(c.dispose);
        // (no engine can read these bytes: an ending the phone may keep as it
        // is stays, anything else is no picture and is told to the log)
        PickedPhoto file(String name) => PickedPhoto(
          name: name,
          size: 4,
          read: () async => Uint8List.fromList([1, 2, 3, 4]),
        );
        final result = await c.read(photoImporterProvider).import([
          file('scan.heic'),
          file('notes.txt'),
        ], room: 5);
        expect(result.added, hasLength(1));
        expect(files.names.single, '${result.added.single.id}.heic');
        await log.flush();
        final text = sink.lines.join('\n');
        expect(text, contains('photo.kept_as_is'));
        expect(text, contains('photo.decode_failed'));
        // (codes only: no name of a chosen file)
        expect(text, isNot(contains('scan')));
        expect(text, isNot(contains('notes')));
      },
    );

    test('the pictures in memory know what they hold and keep to picture '
        'names', () async {
      final files = MemoryPhotoFiles();
      expect(await files.exists('a1.jpg'), isFalse);
      await files.write('a1.jpg', Uint8List.fromList([1]));
      expect(await files.exists('a1.jpg'), isTrue);
      expect(files.write('x.txt', Uint8List(1)), throwsArgumentError);
      expect(files.write('../a1.jpg', Uint8List(1)), throwsArgumentError);
      expect(files.names.toList(), ['a1.jpg']);
    });
  });
}
