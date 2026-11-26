import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_app/drive/photo_sync.dart';
import 'package:kvantum_app/journal/journal_draft_store.dart';
import 'package:kvantum_app/journal/journal_ops.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/journal/photo_sweep.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/harness.dart';

/// The pictures of the diary between two devices through Drive (9th round):
/// what goes up and what comes down, how much of it in one run, what is waited
/// for, what is given up on, what a full Drive or a full device does, and the
/// daily tidying of Drive.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase dbA, dbB;
  late RecordRepository repoA, repoB;
  late JournalOps opsA, opsB;
  late MemoryPhotoFiles filesA, filesB;
  late FakeDrive drive;
  late DriveSyncEngine recordsA, recordsB;
  late PhotoSyncEngine photosA, photosB;
  late DateTime now;
  late MemoryDiagSink sink;
  late DiagLog log;
  var clock = 1000;
  var stopAfter = -1; // (a test says: stop after this many questions)
  var asked = 0;

  /// A JPEG as far as the sync can tell: it begins as one.
  Uint8List jpeg(int length, [int fill = 7]) =>
      Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(length - 3, fill)]);

  PhotoRef ref(String id, {int bytes = 20}) =>
      PhotoRef(id: id, width: 40, height: 30, bytes: bytes);

  JournalEntry entry(String id, List<PhotoRef> photos, {int day = 10}) =>
      JournalEntry.checked(
        id: id,
        at: DateTime.utc(2026, 11, day, 8, 15),
        title: 'Nap $id',
        text: 'Szöveg.',
        photos: photos,
      );

  PhotoSyncEngine engine(
    RecordRepository repo,
    PhotoFiles files, {
    int perRun = photoSyncPerRun,
    int maxBytes = photoSyncMaxBytes,
    Duration remoteGrace = photoRemoteGrace,
  }) => PhotoSyncEngine(
    records: repo,
    remote: drive,
    files: files,
    now: () => now,
    log: log,
    perRun: perRun,
    maxBytes: maxBytes,
    remoteGrace: remoteGrace,
    shouldStop: () => stopAfter >= 0 && asked++ >= stopAfter,
  );

  void build({int perRun = photoSyncPerRun, int maxBytes = photoSyncMaxBytes}) {
    photosA = engine(repoA, filesA, perRun: perRun, maxBytes: maxBytes);
    photosB = engine(repoB, filesB, perRun: perRun, maxBytes: maxBytes);
  }

  setUp(() async {
    clock = 1000;
    stopAfter = -1;
    asked = 0;
    now = DateTime.utc(2026, 11, 16, 12);
    dbA = await newDb();
    dbB = await newDb();
    repoA = RecordRepository(dbA, deviceId: 'A', clock: () => ++clock);
    repoB = RecordRepository(dbB, deviceId: 'B', clock: () => ++clock);
    opsA = JournalOps(repoA);
    opsB = JournalOps(repoB);
    filesA = MemoryPhotoFiles(clock: () => now);
    filesB = MemoryPhotoFiles(clock: () => now);
    drive = FakeDrive(clock: () => now);
    recordsA = DriveSyncEngine(repoA, drive);
    recordsB = DriveSyncEngine(repoB, drive);
    sink = MemoryDiagSink();
    log = DiagLog()..attach(sink);
    build();
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  /// The records of both devices go through Drive, A first, and back.
  Future<void> syncRecords() async {
    await recordsA.sync();
    await recordsB.sync();
    await recordsA.sync();
  }

  Future<void> put(
    JournalOps ops,
    MemoryPhotoFiles files,
    String id,
    List<String> photoIds, {
    int day = 10,
    int length = 20,
  }) async {
    for (final p in photoIds) {
      files.put('$p.jpg', jpeg(length));
    }
    await ops.save(entry(id, [for (final p in photoIds) ref(p)], day: day));
  }

  Future<String> logged() async {
    await log.flush();
    return sink.lines.join('\n');
  }

  group('a picture', () {
    test('goes up from the device that has it and down to the one that '
        'lacks it', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      final up = await photosA.sync();
      expect((up.uploaded, up.downloaded, up.waiting), (1, 0, 0));
      expect(drive.files.values.map((f) => f.name), contains('photo-p1.jpg'));
      expect(drive.contentTypes['photo-p1.jpg'], 'image/jpeg');
      final down = await photosB.sync();
      expect((down.uploaded, down.downloaded, down.waiting), (0, 1, 0));
      expect(down.arrived, ['p1.jpg']);
      expect(await filesB.read('p1.jpg'), jpeg(20));
      // each device knows where the file is in Drive
      final id = drive.files.entries
          .firstWhere((e) => e.value.name == 'photo-p1.jpg')
          .key;
      expect(await repoA.fileId('photo-p1.jpg'), id);
      expect(await repoB.fileId('photo-p1.jpg'), id);
    });

    test('is sent and fetched once, and a run with nothing to do asks '
        'Drive for nothing', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      await photosA.sync();
      await photosB.sync();
      final writes = drive.blobWrites, reads = drive.blobReads;
      final finds = drive.findCalls, lists = drive.listCalls;
      final again = await photosA.sync();
      final againB = await photosB.sync();
      expect(again.busy, isFalse);
      expect(againB.busy, isFalse);
      expect((again.waiting, againB.waiting), (0, 0));
      expect(drive.blobWrites, writes);
      expect(drive.blobReads, reads);
      expect(drive.findCalls, finds, reason: 'not even a question');
      expect(drive.listCalls, lists, reason: 'no listing for what is done');
    });

    test('that is in Drive already (an answer was lost) is not sent '
        'again', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      final id = drive.externalWriteBytes('photo-p1.jpg', jpeg(20));
      final r = await photosA.sync();
      expect(r.uploaded, 0);
      expect(drive.blobWrites, 0);
      expect(r.waiting, 0);
      expect(await repoA.fileId('photo-p1.jpg'), id);
    });

    test('of an entry that was deleted does not travel, nor does a file '
        'that no entry has', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await put(opsA, filesA, 'e2', ['p2']);
      filesA.put('stray.jpg', jpeg(20));
      await opsA.delete('e2');
      final r = await photosA.sync();
      expect(r.uploaded, 1);
      expect(
        drive.files.values
            .map((f) => f.name)
            .where((n) => n.startsWith('photo')),
        ['photo-p1.jpg'],
      );
    });

    test('of a kind that is not a JPEG (an older version kept it as it was) '
        'stays where it is', () async {
      filesA.put('h1.heic', Uint8List.fromList([1, 2, 3, 4]));
      await opsA.save(entry('e1', [const PhotoRef(id: 'h1', ext: 'heic')]));
      await syncRecords();
      final finds = drive.findCalls; // (the records ask, too)
      final up = await photosA.sync();
      final down = await photosB.sync();
      expect((up.uploaded, up.waiting), (0, 0));
      expect((down.downloaded, down.waiting), (0, 0));
      expect(drive.blobWrites + drive.blobReads, 0);
      expect(drive.findCalls, finds, reason: 'not a question for the picture');
    });

    test('arrives exactly as it went, whatever the bytes are', () async {
      final odd = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0x00, 0x80, 0xFE, 0x7F, 0x0A, 0x0D, //
        for (var i = 0; i < 256; i++) i,
      ]);
      filesA.put('p1.jpg', odd);
      await opsA.save(entry('e1', [ref('p1', bytes: odd.length)]));
      await syncRecords();
      await photosA.sync();
      await photosB.sync();
      expect(await filesB.read('p1.jpg'), odd);
    });

    test(
      'goes both ways at once, each device getting what the other has',
      () async {
        await put(opsA, filesA, 'a1', ['pa'], day: 11);
        await put(opsB, filesB, 'b1', ['pb'], day: 12);
        await syncRecords();
        await recordsB.sync();
        final a = await photosA.sync();
        final b = await photosB.sync();
        expect((a.uploaded, a.downloaded), (1, 0));
        expect((b.uploaded, b.downloaded), (1, 1));
        // (A looked for B's picture before B had sent it: it looks again soon)
        now = now.add(const Duration(minutes: 1));
        final a2 = await photosA.sync();
        expect(a2.downloaded, 1, reason: 'B sent its own after A looked');
        expect(await filesA.read('pb.jpg'), jpeg(20));
        expect(await filesB.read('pa.jpg'), jpeg(20));
      },
    );
  });

  group('how much one run does', () {
    test('sends the newest entries first, a few at a time, and says there '
        'is more', () async {
      build(perRun: 3);
      for (var i = 1; i <= 8; i++) {
        await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
      }
      final first = await photosA.sync();
      expect((first.uploaded, first.more, first.waiting), (3, true, 5));
      expect(
        {
          for (final f in drive.files.values)
            if (f.name.startsWith('photo-')) f.name,
        },
        {'photo-p8.jpg', 'photo-p7.jpg', 'photo-p6.jpg'},
      );
      final second = await photosA.sync();
      expect((second.uploaded, second.more, second.waiting), (3, true, 2));
      final third = await photosA.sync();
      expect((third.uploaded, third.more, third.waiting), (2, false, 0));
      expect(drive.blobWrites, 8);
    });

    test('fetches a few at a time, too', () async {
      for (var i = 1; i <= 5; i++) {
        await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
      }
      await syncRecords();
      for (var i = 0; i < 2; i++) {
        await photosA.sync();
      }
      expect(drive.blobWrites, 5);
      build(perRun: 2);
      final first = await photosB.sync();
      expect((first.downloaded, first.more, first.waiting), (2, true, 3));
      expect(first.arrived, ['p5.jpg', 'p4.jpg'], reason: 'the newest first');
      final second = await photosB.sync();
      final third = await photosB.sync();
      expect((second.downloaded, second.more), (2, true));
      expect((third.downloaded, third.more, third.waiting), (1, false, 0));
    });

    test('does the two kinds in one run, each up to its own number', () async {
      build(perRun: 2);
      for (var i = 1; i <= 3; i++) {
        await put(opsA, filesA, 'a$i', ['pa$i'], day: 10 + i);
        await put(opsB, filesB, 'b$i', ['pb$i'], day: 20 + i);
      }
      await syncRecords();
      await recordsB.sync();
      // (what B has goes up first, so that A has something to fetch)
      for (var i = 0; i < 3; i++) {
        await photosB.sync();
      }
      final r = await photosA.sync();
      expect((r.uploaded, r.downloaded), (2, 2));
      expect(r.more, isTrue);
    });
  });

  group('a picture that is not in Drive yet', () {
    test('is waited for, looked for again after a while, and longer each '
        'time', () async {
      await opsA.save(entry('e1', [ref('p1')]));
      await syncRecords();
      final start = now;
      Future<int> askedAt(Duration after) async {
        now = start.add(after);
        final before = drive.findCalls;
        final r = await photosB.sync();
        expect(r.downloaded, 0);
        expect(r.waiting, 1, reason: 'still missing');
        expect(r.more, isFalse, reason: 'nothing to hurry for');
        return drive.findCalls - before;
      }

      Duration minutes(int m, {int less = 0}) =>
          Duration(seconds: m * 60 - less);

      expect(PhotoSyncEngine.firstMissingWait, const Duration(minutes: 1));
      expect(PhotoSyncEngine.longestMissingWait, const Duration(hours: 6));
      expect(await askedAt(Duration.zero), 1, reason: 'the first look');
      // (it waits 1, 2, 4 ... 256 minutes: each look doubles the wait)
      var t = 0, wait = 1;
      for (var i = 0; i < 9; i++) {
        expect(
          await askedAt(minutes(t + wait, less: 1)),
          0,
          reason: 'a second short of $wait minutes',
        );
        t += wait;
        expect(await askedAt(minutes(t)), 1, reason: 'after $wait minutes');
        wait *= 2;
      }
      // (and never longer than six hours)
      for (var i = 0; i < 3; i++) {
        expect(await askedAt(minutes(t + 360, less: 1)), 0);
        t += 360;
        expect(await askedAt(minutes(t)), 1, reason: 'after six hours');
      }
    });

    test('is fetched once the other device has sent it', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      expect((await photosB.sync()).waiting, 1);
      await photosA.sync();
      now = now.add(const Duration(minutes: 1));
      final r = await photosB.sync();
      expect((r.downloaded, r.waiting), (1, 0));
      expect(await filesB.read('p1.jpg'), isNotNull);
    });
  });

  group('what is given up on', () {
    test('a picture that is too big is neither sent nor tried again', () async {
      build(maxBytes: 50);
      await put(opsA, filesA, 'e1', ['big'], length: 51);
      await put(opsA, filesA, 'e2', ['fits'], length: 50, day: 11);
      final first = await photosA.sync();
      expect((first.uploaded, first.skipped, first.waiting), (1, 1, 0));
      expect(
        drive.files.values
            .map((f) => f.name)
            .where((n) => n.startsWith('photo')),
        ['photo-fits.jpg'],
      );
      final writes = drive.blobWrites;
      final again = await photosA.sync();
      expect((again.skipped, again.failed, again.waiting), (0, 0, 0));
      expect(drive.blobWrites, writes);
      expect(await logged(), contains('photo.too_big_to_sync'));
    });

    test('a picture in Drive that is too big is not fetched either', () async {
      await opsA.save(entry('e1', [ref('big')]));
      await syncRecords();
      drive.externalWriteBytes('photo-big.jpg', jpeg(51));
      build(maxBytes: 50);
      final r = await photosB.sync();
      expect((r.downloaded, r.skipped, r.waiting), (0, 1, 0));
      expect(await filesB.read('big.jpg'), isNull);
      final reads = drive.blobReads;
      await photosB.sync();
      expect(drive.blobReads, reads, reason: 'not asked for again');
    });

    test('what Drive holds under the name of a picture, and is none, is left '
        'alone', () async {
      await opsA.save(entry('e1', [ref('p1')]));
      await syncRecords();
      drive.externalWriteBytes(
        'photo-p1.jpg',
        Uint8List.fromList([0x50, 0x4B, 3, 4, 9, 9]),
      );
      final r = await photosB.sync();
      expect((r.downloaded, r.skipped), (0, 1));
      expect(await filesB.read('p1.jpg'), isNull);
      expect(await logged(), contains('photo.bad_download'));
    });

    test('a file here that is not a JPEG is not sent', () async {
      filesA.put('p1.jpg', Uint8List.fromList([1, 2, 3, 4]));
      await opsA.save(entry('e1', [ref('p1')]));
      final r = await photosA.sync();
      expect((r.uploaded, r.skipped, r.waiting), (0, 1, 0));
      expect(drive.blobWrites, 0);
      expect(await logged(), contains('photo.not_a_jpeg'));
    });

    test('a picture that Drive refuses is given up on, and the others '
        'go on', () async {
      await put(opsA, filesA, 'e1', ['p1'], day: 11);
      await put(opsA, filesA, 'e2', ['p2'], day: 10);
      drive.failWriteOf = (n) =>
          n == 'photo-p1.jpg' ? ItemRejectedError(400, 'invalid', 'x') : null;
      final r = await photosA.sync();
      expect((r.uploaded, r.failed, r.skipped), (1, 1, 0));
      expect(r.quotaFull, isFalse);
      final again = await photosA.sync();
      expect((again.failed, again.uploaded), (0, 0), reason: 'given up on');
      expect(await logged(), contains('photo.upload_rejected'));
    });

    test('one that goes wrong for no reason we know of is tried again (after '
        'a minute), and does not stop the others', () async {
      await put(opsA, filesA, 'e1', ['p1'], day: 11);
      await put(opsA, filesA, 'e2', ['p2'], day: 10);
      drive.failWriteOf = (n) =>
          n == 'photo-p1.jpg' ? StateError('belső részlet') : null;
      final r = await photosA.sync();
      expect((r.uploaded, r.failed), (1, 1));
      expect(r.waiting, 1);
      drive.failWriteOf = null;
      now = now.add(PhotoSyncEngine.firstMissingWait);
      final again = await photosA.sync();
      expect((again.uploaded, again.failed, again.waiting), (1, 0, 0));
      final text = await logged();
      expect(text, contains('photo.upload_failed'));
      expect(text, isNot(contains('belső részlet')));
    });
  });

  group('a picture whose transfer went wrong', () {
    Duration minutes(int m, {int less = 0}) => Duration(seconds: m * 60 - less);

    test('is put off, a minute first and longer each time, so it is not '
        'tried in every run', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      drive.failWriteOf = (n) => StateError('belső részlet');
      final start = now;
      // (a try is Drive being asked for the name, and then the sending)
      Future<int> triedAt(Duration after) async {
        now = start.add(after);
        final before = drive.findCalls;
        final r = await photosA.sync();
        final tried = drive.findCalls - before;
        expect(r.uploaded, 0);
        expect(r.failed, tried, reason: 'it went wrong whenever it was tried');
        expect(r.waiting, 1, reason: 'still to be sent');
        expect(r.more, isFalse, reason: 'nothing to hurry for');
        return tried;
      }

      expect(await triedAt(Duration.zero), 1, reason: 'the first try');
      // (it waits 1, 2, 4 ... 256 minutes: each failure doubles the wait)
      var t = 0, wait = 1;
      for (var i = 0; i < 9; i++) {
        expect(
          await triedAt(minutes(t + wait, less: 1)),
          0,
          reason: 'a second short of $wait minutes',
        );
        t += wait;
        expect(await triedAt(minutes(t)), 1, reason: 'after $wait minutes');
        wait *= 2;
      }
      // (and never longer than six hours)
      for (var i = 0; i < 3; i++) {
        expect(await triedAt(minutes(t + 360, less: 1)), 0);
        t += 360;
        expect(await triedAt(minutes(t)), 1, reason: 'after six hours');
      }
    });

    test('is never put off for more than six hours, however often it '
        'fails', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      drive.failWriteOf = (n) => StateError('belső részlet');
      for (var i = 0; i < 80; i++) {
        now = now.add(const Duration(hours: 7));
        expect((await photosA.sync()).failed, 1, reason: 'try ${i + 1}');
      }
      // (the doubling has not run over: it is six hours, and not none or ever)
      now = now.add(const Duration(hours: 5, minutes: 59));
      expect((await photosA.sync()).failed, 0, reason: 'put off still');
      now = now.add(const Duration(minutes: 1));
      expect((await photosA.sync()).failed, 1, reason: 'after six hours');
    });

    test('a fetch that went wrong is put off the same way', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      await photosA.sync();
      filesB.failWrite = const FileSystemException('belső részlet');
      final start = now;
      Future<(int, int)> tryAt(Duration after) async {
        now = start.add(after);
        final before = drive.blobReads;
        final r = await photosB.sync();
        expect(r.downloaded, 0);
        expect(r.waiting, 1, reason: 'still to be fetched');
        return (r.failed, drive.blobReads - before);
      }

      expect(await tryAt(Duration.zero), (1, 1));
      expect(await tryAt(const Duration(seconds: 59)), (0, 0));
      expect(await tryAt(const Duration(seconds: 60)), (1, 1));
      // (the second wait is two minutes)
      expect(await tryAt(const Duration(seconds: 179)), (0, 0));
      filesB.failWrite = null;
      now = start.add(const Duration(seconds: 180));
      final r = await photosB.sync();
      expect((r.downloaded, r.failed, r.waiting), (1, 0, 0));
      expect(filesB.names, contains('p1.jpg'));
    });

    test('does not make the run ask for another while it is put off', () async {
      build(perRun: 1);
      await put(opsA, filesA, 'e1', ['old'], day: 10);
      drive.failWriteOf = (n) => StateError('belső részlet');
      expect((await photosA.sync()).failed, 1);
      drive.failWriteOf = null;
      // (a newer one comes: it is sent first, and the one put off, which is
      // next in the line, is no reason for a run more)
      await put(opsA, filesA, 'e2', ['new'], day: 12);
      final r = await photosA.sync();
      expect((r.uploaded, r.more, r.waiting), (1, false, 1));
      now = now.add(PhotoSyncEngine.firstMissingWait);
      final later = await photosA.sync();
      expect((later.uploaded, later.waiting), (1, 0));
    });

    test('a picture that went through starts the count again', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      final start = now;
      drive.failWriteOf = (n) => StateError('belső részlet');
      expect((await photosA.sync()).failed, 1);
      now = start.add(minutes(1));
      drive.failWriteOf = null;
      expect((await photosA.sync()).uploaded, 1);
      // (Drive loses the file; the tidying of the next day notices, and the
      // device forgets what it believed)
      final id = drive.files.entries
          .firstWhere((e) => e.value.name == 'photo-p1.jpg')
          .key;
      drive.externalDelete(id);
      now = start.add(const Duration(days: 1, minutes: 1));
      await photosA.sync();
      expect(await repoA.fileId('photo-p1.jpg'), isNull);
      // (it goes wrong again: this is the first failure of a new count)
      drive.failWriteOf = (n) => StateError('belső részlet');
      expect((await photosA.sync()).failed, 1);
      now = now.add(minutes(1));
      expect((await photosA.sync()).failed, 1, reason: 'a minute, not two');
    });
  });

  group('when there is no room', () {
    test('in Drive: nothing more is sent, but what is waiting is still '
        'fetched', () async {
      await put(opsB, filesB, 'b1', ['pb']);
      await syncRecords();
      await photosB.sync(); // (B sends its own)
      await put(opsA, filesA, 'a1', ['pa1'], day: 12);
      await put(opsA, filesA, 'a2', ['pa2'], day: 13);
      await put(opsA, filesA, 'a3', ['pa3'], day: 14);
      await recordsA.sync();
      await recordsB.sync();
      var tries = 0;
      drive.failWriteOf = (n) {
        tries++;
        return ItemRejectedError(403, 'storageQuotaExceeded', 'full');
      };
      final r = await photosA.sync();
      expect(r.quotaFull, isTrue);
      expect(tries, 1, reason: 'the first refusal ends the sending');
      expect((r.uploaded, r.failed), (0, 0));
      expect(r.downloaded, 1, reason: 'B\'s picture came in');
      expect(await filesA.read('pb.jpg'), isNotNull);
      expect(r.waiting, 3);
      // (the next run tries again: Drive may have room by then)
      drive.failWriteOf = null;
      final next = await photosA.sync();
      expect((next.uploaded, next.quotaFull, next.waiting), (3, false, 0));
    });

    test('in Drive, as Google files it (a wait of the usage limits): the '
        'same, and no wait', () async {
      await put(opsA, filesA, 'a1', ['pa1'], day: 12);
      await put(opsA, filesA, 'a2', ['pa2'], day: 13);
      var tries = 0;
      drive.failWriteOf = (n) {
        tries++;
        return DriveTransientError.throttled('http 403 storageQuotaExceeded');
      };
      final r = await photosA.sync();
      expect(r.quotaFull, isTrue);
      expect(r.stoppedEarly, isFalse, reason: 'a full Drive is no wait');
      expect(tries, 1);
      expect(r.waiting, 2);
      // (any other wait is a wait, as before)
      drive.failWriteOf = (n) =>
          DriveTransientError.throttled('http 429 rateLimitExceeded');
      final other = await photosA.sync();
      expect((other.quotaFull, other.stoppedEarly), (false, true));
    });

    test('on the device: nothing more is fetched, and it is said', () async {
      for (var i = 1; i <= 3; i++) {
        await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
      }
      await syncRecords();
      await photosA.sync();
      filesB.failWrite = FileSystemException(
        'x',
        '/p',
        const OSError('No space left on device', 28),
      );
      final r = await photosB.sync();
      expect(r.diskFull, isTrue);
      expect(r.downloaded, 0);
      expect(r.waiting, 3);
      expect(filesB.names, isEmpty);
      // room again: all three come
      filesB.failWrite = null;
      final next = await photosB.sync();
      expect((next.downloaded, next.diskFull, next.waiting), (3, false, 0));
      expect(await logged(), contains('photo.disk_full'));
    });

    test(
      'a write error that is not "full" is one picture\'s trouble only',
      () async {
        for (var i = 1; i <= 2; i++) {
          await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
        }
        await syncRecords();
        await photosA.sync();
        filesB.failWrite = FileSystemException(
          'x',
          '/p',
          const OSError('io', 5),
        );
        final r = await photosB.sync();
        expect((r.diskFull, r.failed, r.downloaded), (false, 2, 0));
        expect(await logged(), contains('photo.download_failed'));
      },
    );
  });

  group('a failure of the moment', () {
    test('stops the run and says why; nothing is lost, and the next run '
        'finishes', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await put(opsA, filesA, 'e2', ['p2'], day: 11);
      drive.offline = true;
      final r = await photosA.sync();
      expect(r.stoppedEarly, isTrue);
      expect(r.hint, isA<DriveTransientError>());
      expect((r.uploaded, r.failed), (0, 0));
      drive.offline = false;
      final next = await photosA.sync();
      expect((next.uploaded, next.stoppedEarly, next.waiting), (2, false, 0));
    });

    test('a limit stops it too, with the wait the server asked for', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      drive.failWith = DriveTransientError.throttled(
        'slow',
        retryAfter: const Duration(minutes: 3),
      );
      final r = await photosA.sync();
      expect(r.stoppedEarly, isTrue);
      expect(r.hint!.throttled, isTrue);
      expect(r.hint!.retryAfter, const Duration(minutes: 3));
    });

    test('during a fetch it keeps what had arrived', () async {
      for (var i = 1; i <= 3; i++) {
        await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
      }
      await syncRecords();
      await photosA.sync();
      var reads = 0;
      drive.failReadOf = (n) =>
          ++reads == 2 ? DriveTransientError('network') : null;
      final r = await photosB.sync();
      expect(r.stoppedEarly, isTrue);
      expect(r.downloaded, 1);
      expect(r.arrived, ['p3.jpg']);
      expect(filesB.names, ['p3.jpg']);
    });
  });

  group('the run', () {
    test('stops between two pictures when it is told to', () async {
      for (var i = 1; i <= 4; i++) {
        await put(opsA, filesA, 'e$i', ['p$i'], day: 10 + i);
      }
      stopAfter = 2;
      final r = await photosA.sync();
      expect(r.uploaded, 2);
      expect(r.more, isFalse, reason: 'it was told to stop, not out of time');
      stopAfter = -1;
      final next = await photosA.sync();
      expect(next.uploaded, 2);
    });

    test('calls that come together are served one after the other', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      final results = await Future.wait([photosA.sync(), photosA.sync()]);
      expect(results.map((r) => r.uploaded).toList()..sort(), [0, 1]);
      expect(drive.blobWrites, 1);
    });

    test('puts nothing of a file, a folder or a name into the log', () async {
      build(maxBytes: 50);
      await put(opsA, filesA, 'e1', ['secretpicture'], length: 51);
      filesA.put('p2.jpg', Uint8List.fromList([1, 2, 3]));
      await opsA.save(entry('e2', [ref('p2')], day: 11));
      await put(opsA, filesA, 'e3', ['p3'], day: 12);
      drive.failWriteOf = (n) => StateError('/home/titkos/photo-p3.jpg');
      await photosA.sync();
      final text = await logged();
      expect(text, contains('photo.'));
      expect(text, isNot(contains('secretpicture')));
      expect(text, isNot(contains('titkos')));
      expect(text, isNot(contains('photo-')));
    });
  });

  group('the daily tidying of Drive', () {
    /// A uploads a picture of an entry, and both devices have the records.
    Future<String> sentAndLater() async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      await photosA.sync();
      await photosB.sync();
      return drive.files.entries
          .firstWhere((e) => e.value.name == 'photo-p1.jpg')
          .key;
    }

    test('removes a picture that no entry refers to, once it is a week '
        'old', () async {
      final id = await sentAndLater();
      await opsA.delete('e1');
      await recordsA.sync();
      now = now.add(const Duration(days: 8));
      drive.setCreated(id, now.subtract(const Duration(days: 8)));
      final r = await photosA.sync();
      expect(r.cleaned, 1);
      expect(drive.files.containsKey(id), isFalse);
      expect(await repoA.fileId('photo-p1.jpg'), isNull);
    });

    test('leaves it a week, to the minute', () async {
      final id = await sentAndLater();
      await opsA.delete('e1');
      await recordsA.sync();
      expect(photoRemoteGrace, const Duration(days: 7));
      now = now.add(const Duration(days: 1));
      drive.setCreated(
        id,
        now.subtract(const Duration(days: 6, hours: 23, minutes: 59)),
      );
      expect((await photosA.sync()).cleaned, 0);
      expect(drive.files.containsKey(id), isTrue);
      now = now.add(const Duration(days: 1));
      drive.setCreated(id, now.subtract(photoRemoteGrace));
      expect((await photosA.sync()).cleaned, 1, reason: 'exactly a week');
    });

    test('keeps a picture that a live entry refers to, however old', () async {
      final id = await sentAndLater();
      now = now.add(const Duration(days: 40));
      drive.setCreated(id, now.subtract(const Duration(days: 40)));
      expect((await photosA.sync()).cleaned, 0);
      expect((await photosB.sync()).cleaned, 0);
      expect(drive.files.containsKey(id), isTrue);
    });

    test('keeps a picture it cannot tell the age of', () async {
      final id = await sentAndLater();
      await opsA.delete('e1');
      await recordsA.sync();
      final f = drive.files[id]!;
      drive.files[id] = (
        name: f.name,
        content: f.content,
        rev: f.rev,
        bytes: f.bytes,
        created: null,
      );
      now = now.add(const Duration(days: 30));
      expect((await photosA.sync()).cleaned, 0);
      expect(drive.files.containsKey(id), isTrue);
    });

    test('keeps a picture that a record names which cannot be shown as an '
        'entry, and removes it once that record is deleted', () async {
      final id = await sentAndLater();
      // (the time of the entry is damaged: it is not shown, but it is not
      // deleted, and it still names the picture)
      await repoA.edit(kindJournal, 'e1', {'at': 'nem idő'});
      await recordsA.sync();
      expect(journalEntries(await repoA.all(kindJournal)), isEmpty);
      now = now.add(const Duration(days: 8));
      drive.setCreated(id, now.subtract(const Duration(days: 8)));
      final kept = await photosA.sync();
      expect(kept.cleaned, 0);
      expect(drive.files.containsKey(id), isTrue);
      await opsA.delete('e1');
      await recordsA.sync();
      now = now.add(const Duration(days: 1));
      expect((await photosA.sync()).cleaned, 1);
      expect(drive.files.containsKey(id), isFalse);
    });

    test('is done once a day, and asks Drive for the list only then', () async {
      await sentAndLater();
      final listed = drive.listCalls;
      await photosA.sync();
      await photosA.sync();
      expect(drive.listCalls, listed, reason: 'it was done today already');
      now = now.add(const Duration(days: 1));
      await photosA.sync();
      expect(drive.listCalls, listed + 1);
      await photosA.sync();
      expect(drive.listCalls, listed + 1, reason: 'once that day');
    });

    test('is for a device that took part in the pictures only', () async {
      await opsA.save(entry('e1', const []));
      await syncRecords();
      final r = await photosA.sync();
      expect(r.cleaned, 0);
      expect(drive.listCalls, 0, reason: 'no picture ever went through');
    });

    test('waits for the records of Drive to have been read', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await photosA.sync(); // (the pictures first, the records never read)
      await repoA.setMeta(PhotoSyncEngine.usedKey, '1');
      now = now.add(const Duration(days: 1));
      final listed = drive.listCalls;
      await photosA.sync();
      expect(
        drive.listCalls,
        listed,
        reason:
            'no token: the records are not '
            'those of Drive',
      );
    });

    test('forgets what it believes is in Drive when it is not, and sends it '
        'again', () async {
      final id = await sentAndLater();
      drive.externalDelete(id);
      now = now.add(const Duration(days: 1));
      final tidy = await photosA.sync();
      expect(tidy.cleaned, 0);
      expect(await repoA.fileId('photo-p1.jpg'), isNull);
      final again = await photosA.sync();
      expect(again.uploaded, 1);
      expect(
        drive.files.values.where((f) => f.name == 'photo-p1.jpg'),
        hasLength(1),
      );
    });

    test('takes the file that is there under another id for the one it '
        'knows', () async {
      final id = await sentAndLater();
      // (somebody made the file again: the old id is gone, the name is there)
      drive.externalDelete(id);
      final other = drive.externalWriteBytes('photo-p1.jpg', jpeg(20));
      now = now.add(const Duration(days: 1));
      await photosA.sync();
      await photosA.sync();
      expect(await repoA.fileId('photo-p1.jpg'), other);
      expect(drive.blobWrites, 1, reason: 'nothing was sent again');
    });

    group('the brake', () {
      Future<List<String>> oldStrays(int n) async {
        final ids = <String>[];
        for (var i = 0; i < n; i++) {
          final id = drive.externalWriteBytes(
            'photo-stray$i.jpg',
            jpeg(20),
            created: now.subtract(const Duration(days: 30)),
          );
          ids.add(id);
        }
        return ids;
      }

      test(
        'does not take more than half of what is in Drive at once',
        () async {
          await sentAndLater();
          final strays = await oldStrays(11); // 11 of 12 pictures
          now = now.add(const Duration(days: 1));
          final r = await photosA.sync();
          expect(r.cleaned, 0);
          expect(strays.every(drive.files.containsKey), isTrue);
          expect(await logged(), contains('photo.tidy_skipped'));
          // (it does not ask again that day)
          final listed = drive.listCalls;
          await photosA.sync();
          expect(drive.listCalls, listed);
        },
      );

      test('takes ten, however much of Drive that is', () async {
        await sentAndLater();
        final strays = await oldStrays(10); // 10 of 11 pictures
        now = now.add(const Duration(days: 1));
        final r = await photosA.sync();
        expect(r.cleaned, 10);
        expect(strays.any(drive.files.containsKey), isFalse);
      });

      test('takes more than ten when it is not more than half', () async {
        await sentAndLater();
        for (var i = 0; i < 12; i++) {
          drive.externalWriteBytes('photo-live$i.jpg', jpeg(20));
        }
        // (the live ones are not referenced by an entry either, but young)
        final strays = await oldStrays(11); // 11 old of 24 pictures
        now = now.add(const Duration(days: 1));
        final r = await photosA.sync();
        expect(r.cleaned, 11);
        expect(strays.any(drive.files.containsKey), isFalse);
      });

      test('exactly half is not more than half', () async {
        await sentAndLater();
        for (var i = 0; i < 11; i++) {
          drive.externalWriteBytes('photo-young$i.jpg', jpeg(20));
        }
        final strays = await oldStrays(12); // 12 old of 24 pictures
        now = now.add(const Duration(days: 1));
        final r = await photosA.sync();
        expect(r.cleaned, 12);
        expect(strays.any(drive.files.containsKey), isFalse);
      });
    });

    test('a refusal to delete one is that picture\'s trouble: the others go '
        'and the day is done', () async {
      await sentAndLater();
      final strays = <String>[];
      for (var i = 0; i < 3; i++) {
        strays.add(
          drive.externalWriteBytes(
            'photo-stray$i.jpg',
            jpeg(20),
            created: now.subtract(const Duration(days: 30)),
          ),
        );
      }
      drive.failDeleteOf = (n) =>
          n == 'photo-stray1.jpg' ? StateError('x') : null;
      now = now.add(const Duration(days: 1));
      final r = await photosA.sync();
      expect(r.cleaned, 2);
      expect(drive.files.containsKey(strays[1]), isTrue);
      expect(await logged(), contains('photo.tidy_failed'));
    });

    test('a failure of the moment in it stops the run, and it is tried '
        'again', () async {
      await sentAndLater();
      final id = drive.externalWriteBytes(
        'photo-stray.jpg',
        jpeg(20),
        created: now.subtract(const Duration(days: 30)),
      );
      drive.failDelete = DriveTransientError('network');
      now = now.add(const Duration(days: 1));
      final r = await photosA.sync();
      expect(r.stoppedEarly, isTrue);
      expect(drive.files.containsKey(id), isTrue);
      drive.failDelete = null;
      final next = await photosA.sync();
      expect((next.stoppedEarly, next.cleaned), (false, 1));
      expect(drive.files.containsKey(id), isFalse);
    });

    test('goes no further when told to stop', () async {
      await sentAndLater();
      for (var i = 0; i < 3; i++) {
        drive.externalWriteBytes(
          'photo-stray$i.jpg',
          jpeg(20),
          created: now.subtract(const Duration(days: 30)),
        );
      }
      now = now.add(const Duration(days: 1));
      stopAfter = 0; // (nothing is asked, so nothing is done at all)
      final r = await photosA.sync();
      expect((r.cleaned, r.uploaded, r.downloaded), (0, 0, 0));
      expect(
        drive.files.values.where((f) => f.name.startsWith('photo-stray')),
        hasLength(3),
      );
    });

    test('only touches what is named like a picture of the diary', () async {
      await sentAndLater();
      final other = drive.externalWriteBytes(
        'photo-x.png',
        jpeg(20),
        created: now.subtract(const Duration(days: 90)),
      );
      final record = drive.externalWrite('journal-zz.json', '{}');
      drive.setCreated(record, now.subtract(const Duration(days: 90)));
      now = now.add(const Duration(days: 1));
      await photosA.sync();
      expect(drive.files.containsKey(other), isTrue);
      expect(drive.files.containsKey(record), isTrue);
    });
  });

  group('next to the tidying of the folder here', () {
    test('a picture that came in is not swept as an orphan while an entry '
        'refers to it', () async {
      await put(opsA, filesA, 'e1', ['p1']);
      await syncRecords();
      await photosA.sync();
      await photosB.sync();
      now = now.add(const Duration(days: 30));
      final sweep = PhotoSweep(
        files: filesB,
        records: repoB,
        drafts: JournalDraftStore(repoB),
      );
      expect(await sweep.run(now), 0);
      expect(filesB.names, ['p1.jpg']);
      // and when the entry is deleted the picture goes, as before
      await opsB.delete('e1');
      expect(await sweep.run(now), 1);
    });
  });
}
