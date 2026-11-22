import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_app/drive/photo_sync.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/journal/journal_ops.dart';
import 'package:kvantum_app/journal/photo_arrivals.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/channel_status.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_pacer.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_remote.dart';

const _secret = 'titkos-szöveg-456';

class _Auth implements AuthGateway {
  @override
  Future<http.Client?> restore() async => null;
  @override
  Future<http.Client> signIn() async => http.Client();
  @override
  Future<void> signOut() async {}
}

class _Timer implements Timer {
  _Timer(this.delay, this.action);
  final Duration delay;
  final void Function() action;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

/// A picture folder that cannot even be listed.
class _BrokenFiles extends MemoryPhotoFiles {
  _BrokenFiles(this.error);
  final Object error;
  @override
  Future<List<StoredPhoto>> list() async => throw error;
}

/// The pictures of the diary in the sync of the whole program (9th round): the
/// channel of their own, what a run tells of them, that their trouble is no
/// error of the sync, the switch, the background, and what the screens are told
/// when a picture arrives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db, otherDb;
  late FakeRemote remote;
  late FakeDrive drive;
  late MemoryPhotoFiles files;
  late MemoryDiagSink sink;
  late DiagLog log;
  late DateTime now;
  late List<_Timer> timers;
  ProviderContainer? c;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    otherDb = AppDatabase(NativeDatabase.memory());
    remote = FakeRemote();
    drive = FakeDrive();
    now = DateTime.utc(2026, 11, 16, 12);
    files = MemoryPhotoFiles(clock: () => now);
    sink = MemoryDiagSink();
    log = DiagLog(now: () => now)..attach(sink);
    timers = [];
    c = null;
  });
  tearDown(() async {
    if (c != null) {
      await c!.read(syncControllerProvider.notifier).signOut();
      c!.dispose();
    }
    await db.close();
    await otherDb.close();
  });

  SyncController make({List<Override> extra = const []}) {
    c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        googleConfiguredProvider.overrideWithValue(true),
        authGatewayProvider.overrideWithValue(_Auth()),
        remoteFactoryProvider.overrideWithValue((_) => remote),
        driveFactoryProvider.overrideWithValue((_) => drive),
        photoFilesProvider.overrideWithValue(files),
        syncPaceProvider.overrideWithValue(Duration.zero),
        syncClockProvider.overrideWithValue(() => now),
        syncSchedulerProvider.overrideWithValue((d, f) {
          final t = _Timer(d, f);
          timers.add(t);
          return t;
        }),
        diagLogProvider.overrideWithValue(log),
        ...extra,
      ],
    );
    return c!.read(syncControllerProvider.notifier);
  }

  SyncState st() => c!.read(syncControllerProvider);
  RecordRepository records() => c!.read(recordRepoProvider);

  Uint8List jpeg([int fill = 7]) =>
      Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(17, fill)]);

  JournalEntry entry(String id, List<String> photoIds, {int day = 10}) =>
      JournalEntry.checked(
        id: id,
        at: DateTime.utc(2026, 11, day, 8, 15),
        title: 'Nap $id',
        text: 'Szöveg.',
        photos: [
          for (final p in photoIds)
            PhotoRef(id: p, width: 40, height: 30, bytes: 20),
        ],
      );

  /// This device has an entry with pictures that are here.
  Future<void> haveEntry(String id, List<String> photoIds, {int day = 10}) =>
      JournalOps(records()).save(entry(id, photoIds, day: day)).then((_) {
        for (final p in photoIds) {
          files.put('$p.jpg', jpeg());
        }
      });

  Future<List<DiagEntry>> logged() async {
    await log.flush();
    return [for (final l in sink.lines) DiagEntry.tryParse(l)!];
  }

  group('the channel of the pictures', () {
    test('is one of the channels, the last, and reports well when there '
        'is nothing to do', () async {
      expect(syncChannels.last, channelPhotos);
      final ctl = make();
      await ctl.signIn();
      final photos = st().channels[channelPhotos]!;
      expect(photos.ok, isTrue);
      expect(photos.lastOk, now);
      expect((photos.pulled, photos.pushed, photos.failed), (0, 0, 0));
      expect(st().photoNote, isNull);
    });

    test('sends the pictures of an entry in the run that sends the entry, and '
        'says so', () async {
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      expect(
        drive.files.values.map((f) => f.name),
        containsAll(['journal-e1.json', 'photo-p1.jpg']),
      );
      expect(st().photoNote, 'Képek: 1 feltöltve.');
      expect(st().channels[channelPhotos]!.pushed, 1);
      expect(st().error, isNull);
      // (the next run has no news: the line goes)
      await ctl.syncNow(manual: true);
      expect(st().photoNote, isNull);
    });

    test('brings the pictures of an entry of another device, tells the '
        'screens, and says so', () async {
      // the other device: an entry and its picture, in Drive
      final other = RecordRepository(otherDb, deviceId: 'other');
      await JournalOps(other).save(entry('e1', ['p1']));
      await DriveSyncEngine(other, drive).sync();
      drive.externalWriteBytes('photo-p1.jpg', jpeg(9));
      final ctl = make();
      expect(c!.read(photoArrivalsProvider), isEmpty);
      await ctl.signIn();
      expect(await files.read('p1.jpg'), jpeg(9));
      expect(c!.read(photoArrivalsProvider), {'p1.jpg': 1});
      expect(st().photoNote, 'Képek: 1 letöltve.');
      expect(st().channels[channelPhotos]!.pulled, 1);
    });

    test('says what is still to come, too', () async {
      final other = RecordRepository(otherDb, deviceId: 'other');
      await JournalOps(other).save(entry('e1', ['p1', 'p2']));
      await DriveSyncEngine(other, drive).sync();
      drive.externalWriteBytes('photo-p1.jpg', jpeg());
      final ctl = make();
      await ctl.signIn();
      expect(st().photoNote, 'Képek: 1 letöltve, még 1 vár.');
    });
  });

  group('what goes wrong with the pictures is theirs', () {
    test('a full Drive: told on their line, no error of the sync', () async {
      drive.failWriteOf = (n) => n.startsWith('photo-')
          ? ItemRejectedError(403, 'storageQuotaExceeded', 'full')
          : null;
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      final ch = st().channels[channelPhotos]!;
      expect(ch.code, 'quota');
      expect(ch.text, photoQuotaText);
      expect(st().photoNote, photoQuotaText);
      expect(st().error, isNull);
      expect(st().lastSync, now, reason: 'the sync itself went well');
      expect(st().channels[channelDrive]!.ok, isTrue);
      expect((await logged()).map((e) => e.code), contains('photos.quota'));
    });

    test('a full device: the same', () async {
      final other = RecordRepository(otherDb, deviceId: 'other');
      await JournalOps(other).save(entry('e1', ['p1']));
      await DriveSyncEngine(other, drive).sync();
      drive.externalWriteBytes('photo-p1.jpg', jpeg());
      files.failWrite = FileSystemException(
        'x',
        '/p',
        const OSError('No space left on device', 28),
      );
      final ctl = make();
      await ctl.signIn();
      expect(st().channels[channelPhotos]!.code, 'disk_full');
      expect(st().photoNote, photoDiskText);
      expect(st().error, isNull);
      expect(c!.read(photoArrivalsProvider), isEmpty);
    });

    test('pictures given up on, or that went wrong, are told, and are no '
        'error either', () async {
      final ctl = make();
      await haveEntry('e1', ['p1']);
      files.put('p1.jpg', Uint8List.fromList([1, 2, 3])); // (no JPEG)
      await ctl.signIn();
      expect(st().channels[channelPhotos]!.code, 'skipped');
      expect(st().photoNote, photoSkippedText(1));
      expect(st().error, isNull);

      drive.failWriteOf = (n) =>
          n.startsWith('photo-') ? StateError(_secret) : null;
      files.put('p1.jpg', jpeg());
      // (the one that was given up on is not tried again in this run of the
      // program: a second picture shows what an error of a single one does)
      await JournalOps(records()).save(entry('e2', ['p2'], day: 11));
      files.put('p2.jpg', jpeg());
      await ctl.syncNow(manual: true);
      expect(st().channels[channelPhotos]!.code, 'partial');
      expect(st().photoNote, photoPartialText(1));
      expect(st().error, isNull);
      expect(st().photoNote, isNot(contains(_secret)));
    });

    test('a run of the pictures cut short by the network is no error of the '
        'sync', () async {
      drive.failWriteOf = (n) =>
          n.startsWith('photo-') ? DriveTransientError('network') : null;
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      final ch = st().channels[channelPhotos]!;
      expect(ch.code, 'transient');
      expect(ch.text, contains('Képek'));
      expect(st().error, isNull);
      expect(st().lastSync, now);
      // (the usual beat goes on: a minute, not a backoff)
      expect(timers.last.delay, SyncPacer.base);
    });

    test('a limit stops everything for as long as the server asked', () async {
      drive.failWriteOf = (n) => n.startsWith('photo-')
          ? DriveTransientError.throttled(
              'slow',
              retryAfter: const Duration(minutes: 10),
            )
          : null;
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      expect(st().channels[channelPhotos]!.code, 'transient');
      expect(st().error, isNull, reason: 'a wait, not an error');
      expect(
        timers.last.delay,
        greaterThanOrEqualTo(const Duration(minutes: 10)),
      );
    });

    test(
      'a failure nobody planned for is told in Hungarian, and logged',
      () async {
        files = _BrokenFiles(StateError(_secret));
        final ctl = make();
        await ctl.signIn();
        final ch = st().channels[channelPhotos]!;
        expect(ch.code, 'unexpected');
        expect(ch.text, contains('Képek'));
        expect(ch.text, contains('váratlan hiba'));
        expect(ch.text, isNot(contains(_secret)));
        expect(st().error, isNull);
        expect(st().channels[channelDrive]!.ok, isTrue);
        final e = (await logged()).singleWhere(
          (e) => e.code == 'photos.unexpected',
        );
        expect(e.area, 'sync');
        expect(e.error, startsWith('StateError'));
      },
    );

    test('an expired login is the end of it, as everywhere else', () async {
      files = _BrokenFiles(Exception('invalid_grant'));
      final ctl = make();
      await ctl.signIn();
      expect(st().signedIn, isFalse);
      expect(st().error, contains('lejárt'));
    });
  });

  group('when the pictures go', () {
    test('not before the records of Drive went through', () async {
      drive.offline = true;
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      expect(st().channels[channelDrive]!.code, 'transient');
      expect(st().channels.containsKey(channelPhotos), isFalse);
      expect(drive.blobWrites, 0);
    });

    test('not with the switch off', () async {
      final ctl = make();
      await records().setMeta(photoSyncKey, 'off');
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      expect(drive.blobWrites, 0);
      expect(st().channels.containsKey(channelPhotos), isFalse);
      expect(st().photoNote, isNull);
      expect(st().channels[channelDrive]!.ok, isTrue);
      // turned on again: the next run sends them
      await records().setMeta(photoSyncKey, null);
      await ctl.syncNow(manual: true);
      expect(drive.blobWrites, 1);
      expect(st().photoNote, 'Képek: 1 feltöltve.');
    });

    test(
      'a few at a time, and the next run is soon when there are more',
      () async {
        final ctl = make();
        for (var i = 1; i <= 8; i++) {
          await haveEntry('e$i', ['p$i'], day: 10 + i);
        }
        await ctl.signIn();
        expect(drive.blobWrites, photoSyncPerRun);
        expect(st().photoNote, 'Képek: 6 feltöltve, még 2 vár.');
        expect(timers.last.delay, SyncPacer.followUp);
        await ctl.syncNow();
        expect(drive.blobWrites, 8);
        expect(timers.last.delay, SyncPacer.base);
      },
    );

    test(
      'not in the background: the run is cut at the first picture',
      () async {
        final ctl = make();
        await haveEntry('e1', ['p1']);
        ctl.didChangeAppLifecycleState(AppLifecycleState.paused);
        await ctl.signIn();
        expect(drive.blobWrites, 0);
        expect(st().error, isNull);
        ctl.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await ctl.syncNow(manual: true);
        expect(drive.blobWrites, 1);
      },
    );

    test('not after the sign-out: nothing of the old engine goes on', () async {
      final ctl = make();
      await haveEntry('e1', ['p1']);
      await ctl.signIn();
      await ctl.signOut();
      final writes = drive.blobWrites;
      await ctl.syncNow(manual: true);
      expect(drive.blobWrites, writes);
    });
  });
}
