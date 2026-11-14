import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/auto_backup.dart';
import 'package:kvantum_app/backup/backup_bundle.dart';
import 'package:kvantum_app/backup/backup_service.dart';
import 'package:kvantum_app/backup/backup_store.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// A folder that counts how often it was written to.
class _CountingStore extends MemoryBackupStore {
  int writes = 0;

  @override
  Future<void> write(String name, Uint8List bytes) {
    writes++;
    return super.write(name, bytes);
  }
}

/// One device: a database and the three stores on it.
class Device {
  Device(this.db)
    : events = EventRepository(db),
      records = RecordRepository(db),
      fin = FinanceRepository(db);
  final AppDatabase db;
  final EventRepository events;
  final RecordRepository records;
  final FinanceRepository fin;

  BackupService service({DateTime? at, Future<int?> Function()? build}) =>
      BackupService(
        events: events,
        records: records,
        finance: fin,
        now: () => at ?? DateTime.utc(2026, 11, 13, 9, 15),
        build: build,
        runner: inline,
      );
}

Future<Device> device() async => Device(await newDb());

/// Something of everything the app keeps.
Future<void> seed(Device d) async {
  await d.events.saveAll([
    evt('e1', 'Fogorvos', floating(2026, 11, 12, 14)),
    evt(
      'e2',
      'Kajak edzés',
      floating(2026, 11, 13, 7),
      rrule: 'FREQ=WEEKLY;BYDAY=FR',
    ),
  ]);
  await d.records.edit(
    kindTask,
    't1',
    taskFields(title: 'Számla befizetése', due: floating(2026, 11, 20)),
  );
  await d.records.edit(
    kindCheckIn,
    '2026-11-12',
    checkInFields(physical: 3, mood: 4, note: 'rendben'),
  );
  await d.fin.ensureDefaults();
  await d.fin.saveTx(
    FinTx(
      id: 'x1',
      date: floating(2026, 11, 3),
      amount: 8500,
      kind: FinKind.expense,
      categoryId: 'cat-food',
      merchant: 'Spar',
    ),
  );
  await d.fin.saveBudget(const FinBudget(categoryId: 'cat-food', limit: 40000));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late Device a;
  late Device b;
  setUp(() async {
    a = await device();
    b = await device();
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  group('a backup of everything', () {
    test('says when it was made and how much it holds', () async {
      await seed(a);
      final bytes = await a.service(build: () async => 73).create();
      final file = await a.service().open(bytes);
      expect(file.meta.createdAt, DateTime.utc(2026, 11, 13, 9, 15));
      expect(file.meta.build, 73);
      expect(file.meta.counts['events'], 2);
      expect(file.meta.counts[kindTask], 1);
      expect(file.meta.counts[kindCheckIn], 1);
      expect(file.meta.counts[kindHandbook], 0);
      expect(file.meta.counts['finance'], greaterThanOrEqualTo(3));
    });

    test('is made even if the build number cannot be read', () async {
      final bytes = await a
          .service(build: () async => throw StateError('no plugin'))
          .create();
      expect((await a.service().open(bytes)).meta.build, isNull);
    });

    test('can be locked, and then needs the password to be opened', () async {
      await seed(a);
      final locked = await a.service().create(password: 'jelszo');
      await expectLater(
        a.service().open(locked),
        throwsA(
          isA<BackupException>().having(
            (e) => e.problem,
            'problem',
            BackupProblem.passwordNeeded,
          ),
        ),
      );
      expect(
        (await a.service().open(
          locked,
          password: 'jelszo',
        )).meta.counts['events'],
        2,
      );
    });

    test('an empty device makes an empty backup', () async {
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts['events'], 0);
      expect(file.data.records, isEmpty);
    });
  });

  group('what a restore would do', () {
    test(
      'on an empty device: everything is new, and nothing is written',
      () async {
        await seed(a);
        final file = await b.service().open(await a.service().create());
        final p = await b.service().preview(file);
        expect(p.events.fresh.length, 2);
        expect(p.events.changes, isEmpty);
        expect(p.finance.added, greaterThanOrEqualTo(3));
        expect(p.records.added, 2);
        expect(p.changesNothing, isFalse);
        // (a preview writes nothing)
        expect(await b.events.all(), isEmpty);
        expect(await b.records.all(kindTask), isEmpty);
        expect(await b.fin.txs(), isEmpty);
      },
    );

    test('on the device it came from: nothing would change', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final p = await a.service().preview(file);
      expect(p.changesNothing, isTrue);
      expect(p.events.unchanged, 2);
      expect(p.records.same, 2);
    });

    test('an event changed since is a change, not a new one', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final e = (await a.events.all()).firstWhere((e) => e.id == 'e1');
      await a.events.saveLocal(e.copyWith(title: 'Fogorvos (átvitt)'));
      final p = await a.service().preview(file);
      expect(p.events.changes.length, 1);
      expect(p.events.changes.single.current.title, 'Fogorvos (átvitt)');
      expect(p.events.changes.single.incoming.title, 'Fogorvos');
      expect(p.changesNothing, isFalse);
    });

    test('a record that is newer here is not a change either', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      await a.records.edit(kindTask, 't1', {'title': 'Számla (új cím)'});
      final p = await a.service().preview(file);
      expect(p.records.updated, 0); // (the backup has nothing newer)
    });
  });

  group('a restore', () {
    test('puts back everything, on an empty device', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      final r = await b.service().restore(file, overwrite: false);
      expect(r.events.added, 2);
      expect(
        {for (final e in await b.events.all()) e.title},
        {'Fogorvos', 'Kajak edzés'},
      );
      expect(
        (await b.events.all()).firstWhere((e) => e.id == 'e2').rrule,
        'FREQ=WEEKLY;BYDAY=FR',
      );
      final t = (await b.records.get(kindTask, 't1'))!;
      expect(t['title'], 'Számla befizetése');
      expect(
        (await b.records.get(kindCheckIn, '2026-11-12'))!['note'],
        'rendben',
      );
      expect((await b.fin.txs()).single.merchant, 'Spar');
      expect((await b.fin.budgets()).single.limit, 40000);
      expect(r.problems, isEmpty);
    });

    test(
      'queues what it puts back for upload (Drive may have lost it too)',
      () async {
        await seed(a);
        final file = await b.service().open(await a.service().create());
        await b.service().restore(file, overwrite: false);
        final dirty = {for (final r in await b.records.dirty()) r.id};
        expect(dirty, {'t1', '2026-11-12'});
        expect(await b.events.pending(), isNotEmpty);
      },
    );

    test('twice is the same as once', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      await b.service().restore(file, overwrite: false);
      final again = await b.service().restore(file, overwrite: false);
      expect(again.events.added, 0);
      expect(again.records.added + again.records.updated, 0);
      expect(again.finance.added + again.finance.updated, 0);
      expect((await b.events.all()).length, 2);
    });

    test('never deletes what the backup does not have', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      await b.events.saveAll([
        evt('mine', 'Csak itt van', floating(2026, 12, 1, 9)),
      ]);
      await b.records.edit(
        kindTask,
        'only-here',
        taskFields(title: 'Csak itt'),
      );
      await b.service().restore(file, overwrite: true);
      expect((await b.events.all()).map((e) => e.id), contains('mine'));
      expect(
        (await b.records.get(kindTask, 'only-here'))!['title'],
        'Csak itt',
      );
    });

    test('keeps what is newer here: a record field by field', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      await a.records.edit(kindTask, 't1', {'title': 'Számla (új cím)'});
      await a.service().restore(file, overwrite: true);
      expect(
        (await a.records.get(kindTask, 't1'))!['title'],
        'Számla (új cím)',
      );
    });

    test('a task deleted since stays deleted', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      await a.records.delete(kindTask, 't1');
      await a.service().restore(file, overwrite: true);
      expect((await a.records.get(kindTask, 't1'))!.deleted, isTrue);
    });

    test('a changed event is replaced only when asked', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final e = (await a.events.all()).firstWhere((e) => e.id == 'e1');
      await a.events.saveLocal(e.copyWith(title: 'Fogorvos (átvitt)'));

      final kept = await a.service().restore(file, overwrite: false);
      expect(kept.events.kept, 1);
      expect(
        (await a.events.all()).firstWhere((e) => e.id == 'e1').title,
        'Fogorvos (átvitt)',
      );

      final replaced = await a.service().restore(file, overwrite: true);
      expect(replaced.events.updated, 1);
      expect(
        (await a.events.all()).firstWhere((e) => e.id == 'e1').title,
        'Fogorvos',
      );
    });

    test('a finance record that is newer here stays', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final tx = (await a.fin.txs()).single;
      await a.fin.saveTx(tx.copyWith(amount: 9999));
      await a.service().restore(file, overwrite: true);
      expect((await a.fin.txs()).single.amount, 9999);
    });

    test(
      'a finance part of a newer format is not restored, and said so',
      () async {
        await seed(a);
        final plain = await a.service().open(await a.service().create());
        final newer = BackupFile(
          plain.meta,
          BackupData(
            calendarIcs: plain.data.calendarIcs,
            financeJson: jsonEncode({
              'format': 'kvantum-finance',
              'version': financeBackupVersion + 1,
              'records': <Object>[],
            }),
            records: plain.data.records,
          ),
        );
        final p = await b.service().preview(newer);
        expect(p.problems.single, contains('újabb formátumú'));
        final r = await b.service().restore(newer, overwrite: false);
        expect(r.problems.single, contains('újabb formátumú'));
        expect(await b.fin.txs(), isEmpty);
        expect((await b.events.all()).length, 2); // (the rest was restored)
      },
    );

    test('a record that cannot be read is counted, the rest goes on', () async {
      await seed(a);
      final plain = await a.service().open(await a.service().create());
      final damaged = BackupFile(
        plain.meta,
        BackupData(
          calendarIcs: plain.data.calendarIcs,
          financeJson: plain.data.financeJson,
          records: [
            ...plain.data.records,
            'not json',
            '{"v":99,"id":"z","kind":"task","f":{}}', // a newer record format
            '{"v":1,"id":"y","kind":"unknown","f":{}}', // a kind we do not know
          ],
        ),
      );
      final r = await b.service().restore(damaged, overwrite: false);
      expect(r.records.added, 2);
      expect(r.problems.single, startsWith('3 rekord nem olvasható'));
    });

    test('works through the isolate runner too', () async {
      await seed(a);
      final service = BackupService(
        events: a.events,
        records: a.records,
        finance: a.fin,
        now: () => DateTime.utc(2026, 11, 13),
      ); // (the default runner: another isolate)
      final bytes = await service.create(password: 'x');
      expect(
        (await service.open(bytes, password: 'x')).meta.counts['events'],
        2,
      );
    });
  });

  group('the details of a backup and a restore', () {
    test('a deleted record is not counted, but it is in the backup', () async {
      await seed(a);
      await a.records.delete(kindTask, 't1');
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindTask], 0);
      final tasks = [
        for (final text in file.data.records) SyncRecord.decode(text),
      ].where((r) => r.kind == kindTask).toList();
      expect(tasks.single.deleted, isTrue);
    });

    test(
      'a deletion in the backup reaches a device that still has it',
      () async {
        // b has the task from before; a created it later on and deleted it
        await b.records.edit(kindTask, 't1', taskFields(title: 'Számla'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await a.records.edit(kindTask, 't1', taskFields(title: 'Számla'));
        await a.records.delete(kindTask, 't1');
        final file = await a.service().open(await a.service().create());
        await b.service().restore(file, overwrite: false);
        expect((await b.records.get(kindTask, 't1'))!.deleted, isTrue);
      },
    );

    test('a restore tells what it could not read in the calendar', () async {
      final plain = await a.service().open(await a.service().create());
      final long = BackupFile(
        plain.meta,
        const BackupData(
          calendarIcs:
              'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n'
              'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
              'DTEND;TZID=Europe/Budapest:99990504T090000\r\n'
              'SUMMARY:Valami\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
        ),
      );
      final p = await b.service().preview(long);
      expect(p.problems.single, contains('túl hosszú'));
      final r = await b.service().restore(long, overwrite: false);
      expect(r.problems.single, contains('túl hosszú'));
      expect(r.events.added, 0);
    });

    test(
      'a record that is newer in the backup is a change, and is queued',
      () async {
        await b.records.edit(kindTask, 't1', taskFields(title: 'Régi cím'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await a.records.edit(kindTask, 't1', taskFields(title: 'Régi cím'));
        await a.records.edit(kindTask, 't1', {'title': 'Új cím'});
        final file = await a.service().open(await a.service().create());
        // (nothing else differs, and b has nothing waiting for upload)
        await b.db.customStatement('UPDATE record_rows SET dirty = 0');

        final p = await b.service().preview(file);
        expect(p.records.updated, 1);
        expect(p.records.added, 0);
        expect(p.changesNothing, isFalse);
        expect(await b.records.dirtyCount(), 0); // (the preview wrote nothing)

        final r = await b.service().restore(file, overwrite: false);
        expect(r.records.updated, 1);
        expect((await b.records.get(kindTask, 't1'))!['title'], 'Új cím');
        expect(await b.records.dirtyCount(), 1); // (it goes up to Drive again)
      },
    );

    test('the preview of a newer finance row writes nothing', () async {
      await seed(a);
      await b.service().restore(
        await a.service().open(await a.service().create()),
        overwrite: false,
      );
      final tx = (await a.fin.txs()).single;
      await a.fin.saveTx(tx.copyWith(amount: 12000));
      final file = await a.service().open(await a.service().create());

      final p = await b.service().preview(file);
      expect(p.finance.updated, 1);
      expect((await b.fin.txs()).single.amount, 8500);
      await b.service().restore(file, overwrite: false);
      expect((await b.fin.txs()).single.amount, 12000);
    });
  });

  group('the daily backup', () {
    late MemoryBackupStore store;
    late Map<String, String> meta;
    late DateTime clock;
    late AutoBackup auto;

    AutoBackup make({BackupStore? withStore}) => AutoBackup(
      service: a.service(at: clock),
      store: withStore ?? store,
      readMeta: (k) async => meta[k],
      writeMeta: (k, v) async => v == null ? meta.remove(k) : meta[k] = v,
      now: () => clock,
    );

    setUp(() {
      store = MemoryBackupStore();
      meta = {};
      clock = DateTime(2026, 11, 13, 8);
      auto = make();
    });

    test('is made the first time, and written down', () async {
      await seed(a);
      final made = await auto.runIfDue();
      expect(made, isNotNull);
      expect(made!.name, 'kvantum-20261113-080000.zip');
      expect((await store.list()).length, 1);
      final s = await auto.state();
      expect(s.enabled, isTrue);
      expect(s.last, clock.toUtc());
      expect(s.error, isNull);
      // and it is a backup that opens
      final file = await a.service().open((await store.read(made.name))!);
      expect(file.meta.counts['events'], 2);
    });

    test('two requests at once make one backup', () async {
      await seed(a);
      final counting = _CountingStore();
      final one = make(withStore: counting);
      final both = await Future.wait([one.runIfDue(), one.backupNow()]);
      expect(both[0]?.name, both[1]?.name);
      expect(counting.writes, 1); // (the second joined the first)
      expect((await counting.list()).length, 1);
    });

    test('unreadable settings are no reason to raise', () async {
      final broken = AutoBackup(
        service: a.service(at: clock),
        store: store,
        readMeta: (_) async => throw StateError('adatbázis'),
        writeMeta: (_, _) async {},
        now: () => clock,
      );
      expect(await broken.runIfDue(), isNull);
      expect(await store.list(), isEmpty);
    });

    test('is not made again within the day', () async {
      await auto.runIfDue();
      clock = clock.add(const Duration(hours: 19, minutes: 59));
      expect(await auto.runIfDue(), isNull);
      expect((await store.list()).length, 1);
    });

    test('is made again after the day', () async {
      await auto.runIfDue();
      clock = clock.add(const Duration(hours: 20));
      expect(await auto.runIfDue(), isNotNull);
      expect((await store.list()).length, 2);
    });

    test('is not made when it is switched off', () async {
      await auto.setEnabled(false);
      expect((await auto.state()).enabled, isFalse);
      expect(await auto.runIfDue(), isNull);
      expect(await store.list(), isEmpty);
      await auto.setEnabled(true);
      expect(await auto.runIfDue(), isNotNull);
    });

    test('can be made at any time (of a day, the newest stays)', () async {
      await auto.runIfDue();
      clock = clock.add(const Duration(hours: 1));
      final made = await auto.backupNow();
      expect(made!.name, 'kvantum-20261113-090000.zip');
      expect([for (final e in await store.list()) e.name], [made.name]);
    });

    test('the oldest are thrown away', () async {
      for (var d = 1; d <= 12; d++) {
        await store.write(
          backupFileName(DateTime(2026, 11, 13 - d, 8)),
          Uint8List(1),
        );
      }
      await auto.runIfDue();
      final names = [for (final e in await store.list()) e.name];
      // today, the six days before it, and the newest of the first week after
      // them; the other days of that week and everything older than four
      // weeks are gone (12 days back is inside the first week: 11 and 12 go)
      expect(names.first, 'kvantum-20261113-080000.zip');
      expect(names.length, 8);
      expect(names, contains('kvantum-20261106-080000.zip')); // 7 days back
      expect(names, isNot(contains('kvantum-20261101-080000.zip')));
    });

    test('files of others in the folder are left alone', () async {
      await store.write('mine.zip', Uint8List(1));
      await auto.runIfDue();
      expect(await store.read('mine.zip'), isNotNull);
    });

    test('a failure is written down, not raised, and the next try goes on', () async {
      final broken = _BrokenStore();
      final failing = make(withStore: broken);
      expect(await failing.runIfDue(), isNull);
      var s = await failing.state();
      expect(s.error, isNotNull);
      expect(s.last, isNull);

      // it is tried again at the next start (nothing was written down as done)
      broken.works = true;
      expect(await failing.runIfDue(), isNotNull);
      s = await failing.state();
      expect(s.error, isNull);
      expect(s.last, isNotNull);
    });

    test('a failure to delete an old one does not fail the backup', () async {
      for (var d = 1; d <= 12; d++) {
        await store.write(
          backupFileName(DateTime(2026, 11, 13 - d, 8)),
          Uint8List(1),
        );
      }
      final stubborn = _BrokenStore(
        inner: store,
        works: true,
        failDelete: true,
      );
      final made = await make(withStore: stubborn).runIfDue();
      expect(made, isNotNull);
      expect((await auto.state()).error, isNull);
    });
  });
}

/// A folder that cannot be written to (or deleted from) until it "works".
class _BrokenStore implements BackupStore {
  _BrokenStore({
    MemoryBackupStore? inner,
    this.works = false,
    this.failDelete = false,
  }) : inner = inner ?? MemoryBackupStore();
  final MemoryBackupStore inner;
  bool works;
  final bool failDelete;

  @override
  Future<List<BackupEntry>> list() => inner.list();
  @override
  Future<void> write(String name, Uint8List bytes) async {
    if (!works) throw const FileSystemExceptionLike('A lemez megtelt.');
    await inner.write(name, bytes);
  }

  @override
  Future<Uint8List?> read(String name) => inner.read(name);
  @override
  Future<void> delete(String name) async {
    if (failDelete) throw const FileSystemExceptionLike('Nem törölhető.');
    await inner.delete(name);
  }
}

class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike(this.message);
  final String message;
  @override
  String toString() => message;
}
