import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_bundle.dart';
import 'package:kvantum_app/backup/backup_key_store.dart';
import 'package:kvantum_app/backup/backup_service.dart';
import 'package:kvantum_app/backup/drive_backup.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/harness.dart';

/// A backup service whose backups are as big as the test says.
class _BigService extends BackupService {
  _BigService(BackupService inner, this.size)
    : super(
        events: inner.events,
        records: inner.records,
        finance: inner.finance,
        now: inner.now,
        runner: inline,
      );
  final int size;

  @override
  Future<Uint8List> create({String? password}) async {
    final r = Random(1);
    return Uint8List.fromList([for (var i = 0; i < size; i++) r.nextInt(256)]);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  // 2026-11-13 09:15:00 on the device's clock; a test may move it on
  final start = DateTime(2026, 11, 13, 9, 15);
  var now = start;

  late AppDatabase db;
  late BackupService service;
  late FakeDrive drive;
  late MemoryBackupKeyStore keys;
  late MemoryDiagSink sink;
  late DiagLog log;
  late DriveBackup backup;
  late Map<String, String?> meta;
  DriveRemote? signedIn;

  DriveBackup make({BackupService? svc}) => DriveBackup(
    service: svc ?? service,
    remote: () => signedIn,
    keys: keys,
    readMeta: (k) async => meta[k],
    writeMeta: (k, v) async => meta[k] = v,
    now: () => now,
    log: log,
  );

  setUp(() async {
    now = start;
    db = await newDb();
    service = BackupService(
      events: EventRepository(db),
      records: RecordRepository(db),
      finance: FinanceRepository(db),
      now: () => now,
      build: () async => 73,
      runner: inline,
    );
    await EventRepository(db)
        .saveAll([evt('a', 'Fogorvos', floating(2026, 11, 14, 10))]);
    drive = FakeDrive();
    signedIn = drive;
    keys = MemoryBackupKeyStore('Titok-2026');
    sink = MemoryDiagSink();
    log = DiagLog(now: () => now.toUtc(), maxPerMinute: 1000)..attach(sink);
    meta = {};
    backup = make();
  });
  tearDown(() => db.close());

  List<String> driveNames() =>
      [for (final f in drive.files.values) f.name]..sort();

  group('the names', () {
    test('a name is made from the clock and read back', () {
      final name = DriveBackup.fileName(DateTime(2026, 11, 13, 9, 5, 7));
      expect(name, 'kvbackup-20261113-090507.zip.b64');
      expect(DriveBackup.timeOf(name), DateTime(2026, 11, 13, 9, 5, 7));
    });

    test('any other name is not one of ours', () {
      for (final n in [
        'task-1.json',
        'fin-abc.json',
        'kvbackup-20261113-090507.zip', // (the local format)
        'kvbackup-20261113-090507.zip.b64.part',
        'kvbackup-2026111-090507.zip.b64',
        'kvbackup-v2-20261113.zip.b64',
        'kvantum-20261113-090507.zip',
      ]) {
        expect(DriveBackup.timeOf(n), isNull, reason: n);
      }
    });

    test('a date that does not exist is no date', () {
      expect(DriveBackup.timeOf('kvbackup-20261345-090507.zip.b64'), isNull);
      expect(DriveBackup.timeOf('kvbackup-20260230-090507.zip.b64'), isNull);
    });
  });

  group('making a copy', () {
    test('uploads a locked zip as base64 text', () async {
      final made = await backup.backupNow();
      expect(made?.name, 'kvbackup-20261113-091500.zip.b64');
      expect(driveNames(), [made!.name]);
      final text = drive.files[made.id]!.content;
      // the text is base64 of a zip that needs the password
      final bytes = base64.decode(text);
      expect(
        () => unpackBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.problem,
            'problem',
            BackupProblem.passwordNeeded,
          ),
        ),
      );
      final file = unpackBackup(bytes, password: 'Titok-2026');
      expect(file.data.calendarIcs, contains('Fogorvos'));
      expect(file.meta.build, 73);
      // and nothing readable is in what Drive holds
      expect(text, isNot(contains('Fogorvos')));
      expect(
        latin1.decode(bytes, allowInvalid: true),
        isNot(contains('Fogorvos')),
      );
    });

    test('writes down when it was done and clears an old complaint', () async {
      meta[DriveBackup.errorKey] = 'régi hiba';
      await backup.backupNow();
      final s = await backup.state();
      expect(s.last, now.toUtc());
      expect(s.error, isNull);
      expect(meta[DriveBackup.errorKey], isNull);
    });

    test('without a login it says so and uploads nothing', () async {
      signedIn = null;
      expect(await backup.backupNow(), isNull);
      expect(
        (await backup.state()).error,
        'Nem vagy belépve a Google-fiókkal.',
      );
      expect(drive.files, isEmpty);
    });

    test('without a password it says so and uploads nothing', () async {
      keys.value = null;
      expect(await backup.backupNow(), isNull);
      expect(
        (await backup.state()).error,
        'Előbb adj meg egy jelszót a Drive-mentéshez.',
      );
      expect(drive.files, isEmpty);
    });

    test('a refused upload is a failed copy, not an exception', () async {
      drive.failWrite = StateError('tele');
      expect(await backup.backupNow(), isNull);
      final s = await backup.state();
      expect(s.error, isNotNull);
      expect(s.last, isNull);
      // the next one that works clears it
      drive.failWrite = null;
      expect(await backup.backupNow(), isNotNull);
      expect((await backup.state()).error, isNull);
    });

    test('no network is told in words, with no raw exception', () async {
      drive.offline = true;
      expect(await backup.backupNow(), isNull);
      final text = (await backup.state()).error!;
      expect(text, isNot(contains('Exception')));
      expect(text, isNot(contains('Instance of')));
      expect(text, isNotEmpty);
    });

    test('a copy too big for the upload is not tried', () async {
      final big = make(svc: _BigService(service, 3300000));
      expect(await big.backupNow(), isNull);
      expect(drive.creates, 0);
      expect(
        (await big.state()).error,
        startsWith('A mentés túl nagy a Drive-példányhoz (4,'),
      );
    });

    test('a second copy within the same second replaces the first', () async {
      await backup.backupNow();
      await backup.backupNow();
      expect(driveNames(), ['kvbackup-20261113-091500.zip.b64']);
      expect(drive.creates, 1);
      expect(drive.writes, 2);
    });

    test('two requests at once make one copy', () async {
      final both = await Future.wait([backup.backupNow(), backup.backupNow()]);
      expect(both[0]?.id, both[1]?.id);
      expect(drive.writes, 1);
    });

    test('the log has sizes and codes, no password and no title', () async {
      drive.failWrite = StateError('tele');
      await backup.backupNow();
      drive.failWrite = null;
      await backup.backupNow();
      await log.flush();
      final text = sink.lines.join('\n');
      expect(text, contains('drive'));
      expect(text, isNot(contains('Titok-2026')));
      expect(text, isNot(contains('Fogorvos')));
    });
  });

  group('keeping three', () {
    test('the oldest go, the newest three stay', () async {
      for (var i = 0; i < 5; i++) {
        await backup.backupNow();
        now = now.add(const Duration(days: 7));
      }
      expect(driveNames(), [
        'kvbackup-20261127-091500.zip.b64',
        'kvbackup-20261204-091500.zip.b64',
        'kvbackup-20261211-091500.zip.b64',
      ]);
      expect(drive.deletes, 2);
    });

    test('what is not ours is never deleted', () async {
      drive.externalWrite('task-1.json', '{}');
      drive.externalWrite('fin-peer-1.json', '{}');
      drive.externalWrite('kvbackup-v2-20261001.zip.b64', 'future');
      for (var i = 0; i < 5; i++) {
        await backup.backupNow();
        now = now.add(const Duration(days: 7));
      }
      final names = driveNames();
      expect(names, contains('task-1.json'));
      expect(names, contains('fin-peer-1.json'));
      expect(names, contains('kvbackup-v2-20261001.zip.b64'));
      expect(names.where((n) => DriveBackup.timeOf(n) != null), hasLength(3));
    });

    test('a refused delete does not fail the copy', () async {
      for (var i = 0; i < 3; i++) {
        await backup.backupNow();
        now = now.add(const Duration(days: 7));
      }
      drive.failDelete = StateError('nem törölhető');
      final made = await backup.backupNow();
      expect(made, isNotNull);
      expect((await backup.state()).error, isNull);
      expect(driveNames(), hasLength(4)); // (the next one tidies)
      drive.failDelete = null;
      now = now.add(const Duration(days: 7));
      await backup.backupNow();
      expect(driveNames(), hasLength(3));
    });
  });

  group('when it is due', () {
    Future<void> on() => backup.setEnabled(true);

    test('it is off until switched on', () async {
      expect((await backup.state()).enabled, isFalse);
      expect(await backup.runIfDue(), isNull);
      expect(drive.files, isEmpty);
    });

    test('switched on, the first copy is due at once', () async {
      await on();
      expect((await backup.runIfDue())?.name, isNotNull);
      expect(drive.files, hasLength(1));
    });

    test('a copy is not due again within 6 days and 20 hours', () async {
      await on();
      await backup.runIfDue();
      now = start.add(const Duration(days: 6, hours: 19, minutes: 59));
      expect(await backup.runIfDue(), isNull);
      expect(drive.files, hasLength(1));
      now = start.add(const Duration(days: 6, hours: 20));
      expect(await backup.runIfDue(), isNotNull);
      expect(drive.files, hasLength(2));
    });

    test('with no login it waits, and does not call it a failure', () async {
      await on();
      signedIn = null;
      expect(await backup.runIfDue(), isNull);
      expect((await backup.state()).error, isNull);
      signedIn = drive;
      expect(await backup.runIfDue(), isNotNull);
    });

    test('with no password it does nothing', () async {
      await on();
      keys.value = null;
      expect(await backup.runIfDue(), isNull);
      expect(drive.files, isEmpty);
      expect((await backup.state()).error, isNull);
    });

    test(
      'a failed copy is tried again next time (the clock is not set)',
      () async {
        await on();
        drive.offline = true;
        expect(await backup.runIfDue(), isNull);
        drive.offline = false;
        expect(await backup.runIfDue(), isNotNull);
      },
    );

    test('unreadable settings never raise', () async {
      final broken = DriveBackup(
        service: service,
        remote: () => drive,
        keys: keys,
        readMeta: (_) async => throw StateError('adatbázis'),
        writeMeta: (_, _) async {},
        now: () => now,
      );
      expect(await broken.runIfDue(), isNull);
    });
  });

  group('restoring', () {
    test('the copies come newest first, ours only', () async {
      drive.externalWrite('task-1.json', '{}');
      // (a name that starts like ours but is not one - a later format, say)
      drive.externalWrite('kvbackup-v2-20261001.zip.b64', 'future');
      for (var i = 0; i < 3; i++) {
        await backup.backupNow();
        now = now.add(const Duration(days: 1));
      }
      final names = [for (final n in await backup.list()) n.name];
      expect(names, [
        'kvbackup-20261115-091500.zip.b64',
        'kvbackup-20261114-091500.zip.b64',
        'kvbackup-20261113-091500.zip.b64',
      ]);
    });

    test('a copy is fetched as the zip it was made from', () async {
      final made = (await backup.backupNow())!;
      final bytes = (await backup.download(made))!;
      expect(
        unpackBackup(bytes, password: 'Titok-2026').data.calendarIcs,
        contains('Fogorvos'),
      );
    });

    test('a copy that has gone is null, not an error', () async {
      final made = (await backup.backupNow())!;
      drive.externalDelete(made.id);
      expect(await backup.download(made), isNull);
    });

    test('a damaged text is a damaged backup', () async {
      final id = drive.externalWrite(
        'kvbackup-20261113-091500.zip.b64',
        '%%% nem base64 %%%',
      );
      await expectLater(
        backup.download(
          DriveName(id: id, name: 'kvbackup-20261113-091500.zip.b64'),
        ),
        throwsA(
          isA<BackupException>().having(
            (e) => e.problem,
            'problem',
            BackupProblem.damaged,
          ),
        ),
      );
    });

    test('without a login there is nothing to list or fetch', () async {
      signedIn = null;
      await expectLater(
        backup.list(),
        throwsA(
          isA<DriveBackupException>().having(
            (e) => e.problem,
            'problem',
            DriveBackupProblem.signedOut,
          ),
        ),
      );
      await expectLater(
        backup.download(const DriveName(id: 'x', name: 'x')),
        throwsA(isA<DriveBackupException>()),
      );
    });
  });
}
