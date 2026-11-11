import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/housekeeping.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_wallet.dart';
import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  const day = Duration(days: 1);
  final today = DateTime.utc(2026, 11, 11, 12);
  late AppDatabase db;
  late EventRepository events;
  late FinanceRepository fin;
  late RecordRepository recs;
  late int clock;

  setUp(() async {
    db = await newDb();
    clock = today.millisecondsSinceEpoch;
    events = EventRepository(db);
    fin = FinanceRepository(db, clock: () => clock);
    recs = RecordRepository(db, deviceId: 'dev-a', clock: () => clock);
  });
  tearDown(() => db.close());

  void at(Duration ago) =>
      clock = today.millisecondsSinceEpoch - ago.inMilliseconds;

  group('old markers of deleted finance records', () {
    FinTx tx(String id) => FinTx(
      id: id,
      date: floating(2025, 1, 5),
      amount: 1000,
      kind: FinKind.expense,
      merchant: id,
    );

    test(
      'a year old goes, younger stays, a live record of any age stays',
      () async {
        at(const Duration(days: 400));
        await fin.saveTx(tx('old'));
        await fin.deleteTx('old');
        await fin.saveTx(tx('live-old'));
        at(const Duration(days: 100));
        await fin.saveTx(tx('young'));
        await fin.deleteTx('young');
        at(Duration.zero);

        final n = await fin.purgeTombstones(
          clock - tombstoneRetention.inMilliseconds,
        );
        expect(n, 1);
        final left = await db.select(db.finRows).get();
        expect(left.map((r) => r.id).toSet(), {'young', 'live-old'});
        expect((await fin.txs()).map((t) => t.id), ['live-old']);
      },
    );

    test('the limit is a whole year, to the millisecond', () async {
      at(tombstoneRetention);
      await fin.saveTx(tx('edge'));
      await fin.deleteTx('edge');
      at(Duration.zero);
      final cutoff = clock - tombstoneRetention.inMilliseconds;
      expect(
        await fin.purgeTombstones(cutoff),
        0,
        reason: 'exactly a year: kept',
      );
      expect(await fin.purgeTombstones(cutoff + 2), 1);
    });
  });

  group('events a run left half done', () {
    Future<void> event(String id, {bool deleted = false, String? googleId}) =>
        db
            .into(db.eventRows)
            .insert(
              EventRowsCompanion.insert(
                id: id,
                calendarId: kNaptarCalendar,
                title: id,
                startWall: '2026-05-04T09:00:00',
                endWall: '2026-05-04T10:00:00',
                tzid: const Value('Europe/Budapest'),
                deleted: Value(deleted),
                googleId: Value(googleId),
              ),
            );
    Future<void> queue(String eventId, String op, {int attempts = 0}) => db
        .into(db.outboxRows)
        .insert(
          OutboxRowsCompanion.insert(
            eventId: eventId,
            op: op,
            attempts: Value(attempts),
          ),
        );

    test('a linked deletion is queued again, an unlinked one goes', () async {
      await event('linked', deleted: true, googleId: 'g1');
      await event('unlinked', deleted: true);
      await event('waiting', deleted: true, googleId: 'g2');
      await queue('waiting', 'delete', attempts: 3);
      await event('live');
      await queue('ghost', 'upsert');

      final r = await events.purgeOrphans();
      expect((r.requeued, r.removed, r.stale), (1, 1, 1));
      expect(await events.pendingOps(), {
        'linked': 'delete',
        'waiting': 'delete',
      });
      expect((await events.byId('unlinked')), isNull);
      expect(
        await events.isTombstone('linked'),
        isTrue,
        reason: 'kept until pushed',
      );
      expect(await events.byId('live'), isNotNull);
      // the waiting deletion keeps its history of attempts
      final waiting = (await events.pending()).firstWhere(
        (i) => i.event.id == 'waiting',
      );
      expect(waiting.attempts, 3);
    });

    test('a clean database is left exactly as it is', () async {
      await event('a');
      await event('b', deleted: true, googleId: 'g');
      await queue('b', 'delete');
      final r = await events.purgeOrphans();
      expect((r.requeued, r.removed, r.stale), (0, 0, 0));
      expect(await events.pendingOps(), {'b': 'delete'});
    });
  });

  group('Housekeeping runs once a day', () {
    test(
      'first call works, the same day it does not, the next day it does',
      () async {
        var now = today;
        final h = Housekeeping(events: events, finance: fin, now: () => now);
        final first = await h.runIfDue();
        expect(first, isNotNull);
        expect(await h.runIfDue(), isNull);
        now = today.add(const Duration(hours: 11)); // still the same UTC day
        expect(await h.runIfDue(), isNull);
        now = today.add(day);
        expect(await h.runIfDue(), isNotNull);
      },
    );

    test('what it did is kept for the diagnostics', () async {
      final h = Housekeeping(events: events, finance: fin, now: () => today);
      at(const Duration(days: 500));
      await fin.saveTx(
        FinTx(
          id: 'x',
          date: floating(2025, 1, 5),
          amount: 1,
          kind: FinKind.expense,
        ),
      );
      await fin.deleteTx('x');
      at(Duration.zero);
      final r = await h.runIfDue();
      expect(r!.finance, 1);
      expect(r.any, isTrue);
      final saved =
          jsonDecode((await events.meta(Housekeeping.lastKey))!) as Map;
      expect(saved['day'], '2026-11-11');
      expect(saved['finance'], 1);
    });
  });

  group('Drive: old markers of tasks and check-ins', () {
    late FakeDrive drive;
    late DriveSyncEngine engine;
    setUp(() {
      drive = FakeDrive();
      engine = DriveSyncEngine(recs, drive);
    });

    Future<void> taskDeletedAgo(String id, Duration ago) async {
      at(ago);
      await recs.edit(kindTask, id, taskFields(title: id));
      await recs.delete(kindTask, id);
    }

    test('the local row and the Drive file both go, once uploaded', () async {
      await taskDeletedAgo('old', const Duration(days: 400));
      at(const Duration(days: 399));
      await engine.sync(); // uploaded then, when it was new
      expect(drive.files, hasLength(1));
      expect(await recs.get(kindTask, 'old'), isNotNull);

      at(Duration.zero);
      final r = await engine.sync();
      expect(r.purged, 1);
      expect(drive.files, isEmpty);
      expect(await recs.get(kindTask, 'old'), isNull);
      expect(await recs.fileId(recordFileName(kindTask, 'old')), isNull);
    });

    test('a marker younger than a year stays, here and in Drive', () async {
      await taskDeletedAgo('young', const Duration(days: 100));
      await engine.sync();
      at(Duration.zero);
      final r = await engine.sync();
      expect(r.purged, 0);
      expect(drive.files, hasLength(1));
      expect(await recs.get(kindTask, 'young'), isNotNull);
    });

    test('a live record is never touched, however old', () async {
      at(const Duration(days: 900));
      await recs.edit(kindTask, 'live', taskFields(title: 'Régi, de él'));
      at(const Duration(days: 899));
      await engine.sync();
      at(Duration.zero);
      final r = await engine.sync();
      expect(r.purged, 0);
      expect(await recs.get(kindTask, 'live'), isNotNull);
      expect(drive.files, hasLength(1));
    });

    test('it looks once a day', () async {
      at(const Duration(days: 400));
      await recs.edit(kindTask, 'a', taskFields(title: 'a'));
      await recs.delete(kindTask, 'a');
      // 'c' turns a year old an hour after the first look of the day
      clock =
          today.millisecondsSinceEpoch -
          (tombstoneRetention - const Duration(hours: 1)).inMilliseconds;
      await recs.edit(kindTask, 'c', taskFields(title: 'c'));
      await recs.delete(kindTask, 'c');
      clock += const Duration(hours: 1).inMilliseconds;
      await engine.sync(); // both are uploaded while new

      at(Duration.zero);
      expect((await engine.sync()).purged, 1, reason: "'a' is old, 'c' is not");
      expect(await recs.get(kindTask, 'a'), isNull);
      expect(await recs.get(kindTask, 'c'), isNotNull);

      clock += const Duration(hours: 2).inMilliseconds; // still the same day
      expect(
        (await engine.sync()).purged,
        0,
        reason: "'c' is old enough now, but today has been looked at",
      );
      expect(await recs.get(kindTask, 'c'), isNotNull);

      clock += day.inMilliseconds;
      expect((await engine.sync()).purged, 1);
      expect(await recs.get(kindTask, 'c'), isNull);
      expect(drive.files, isEmpty);
    });

    test('a marker that never reached Drive is not forgotten', () async {
      await taskDeletedAgo('stuck', const Duration(days: 400));
      at(Duration.zero);
      drive.failWrite = StateError('refused'); // the upload keeps failing
      final r = await engine.sync();
      expect(r.failed, 1);
      expect(r.purged, 0);
      expect(await recs.get(kindTask, 'stuck'), isNotNull);
      expect(await recs.dirty(), hasLength(1), reason: 'still queued');
    });

    test('a file we lost track of is found by its name', () async {
      await taskDeletedAgo('lost', const Duration(days: 400));
      at(const Duration(days: 399));
      await engine.sync();
      final name = recordFileName(kindTask, 'lost');
      await recs.forgetFile((await recs.fileId(name))!);
      at(Duration.zero);
      final r = await engine.sync();
      expect(r.purged, 1);
      expect(drive.files, isEmpty);
    });

    test('a dropped connection stops the run and the marker stays', () async {
      await taskDeletedAgo('old', const Duration(days: 400));
      at(const Duration(days: 399));
      await engine.sync();
      at(Duration.zero);
      drive.failDelete = DriveTransientError('offline');
      final r = await engine.sync();
      expect(r.stoppedEarly, isTrue);
      expect(await recs.get(kindTask, 'old'), isNotNull);
      expect(
        await recs.meta(DriveSyncEngine.purgeDayKey),
        isNot('2026-11-11'),
        reason: 'a stopped run does not count as having looked',
      );
      drive.failDelete = null;
      expect((await engine.sync()).purged, 1);
    });

    test('a refused delete leaves the marker for tomorrow', () async {
      await taskDeletedAgo('old', const Duration(days: 400));
      at(const Duration(days: 399));
      await engine.sync();
      at(Duration.zero);
      drive.failDelete = StateError('refused');
      final r = await engine.sync();
      expect(r.stoppedEarly, isFalse);
      expect(r.purged, 0);
      expect(await recs.get(kindTask, 'old'), isNotNull);
      drive.failDelete = null;
      expect((await engine.sync()).purged, 0, reason: 'today is done');
      clock += day.inMilliseconds;
      expect((await engine.sync()).purged, 1);
    });
  });
  testWidgets('the root shell does the upkeep once the first screen is up', (
    tester,
  ) async {
    useSize(tester, size: const Size(900, 1400));
    final spy = _Recording(events, fin);
    await tester.pumpWidget(
      app(
        const RootShell(),
        db,
        extra: [
          housekeepingProvider.overrideWithValue(spy),
          walletBridgeProvider.overrideWithValue(FakeWallet()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(spy.rounds, 1);
    await shutdown(tester, db);
  });
}

/// Counts the rounds; "finds" one queued deletion.
class _Recording extends Housekeeping {
  _Recording(EventRepository events, FinanceRepository finance)
    : super(events: events, finance: finance, now: DateTime.now);
  int rounds = 0;
  @override
  Future<HousekeepingReport?> runIfDue() async {
    rounds++;
    return const HousekeepingReport(requeued: 1);
  }
}
