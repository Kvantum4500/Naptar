import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
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

  CalEvent at(String id, int day) => evt(id, id, floating(2026, 11, day, 9));

  /// An event that is in Google already (it has a link).
  Future<void> linked(String id, int day) async {
    await repo.saveLocal(at(id, day));
    final item = (await repo.pending()).firstWhere((i) => i.event.id == id);
    await repo.markPushed(item, googleId: 'g-$id', etag: 'e-$id');
  }

  group('failedOutbox: what Google refused', () {
    test(
      'lists the items that were refused, not those that only wait',
      () async {
        await repo.saveAll([at('a', 2), at('b', 3), at('c', 4)]);
        final items = await repo.pending();
        await repo.markFailed(items[0], 'rejected:400:invalid');
        await repo.noteError(items[1], 'transient'); // waits: not a refusal

        final failed = await repo.failedOutbox();
        expect(failed.map((i) => i.event.id), ['a']);
        expect(failed.single.attempts, 1);
        expect(failed.single.lastError, 'rejected:400:invalid');
        expect(failed.single.op, 'upsert');
      },
    );

    test('is empty when nothing was refused', () async {
      await repo.saveLocal(at('a', 2));
      expect(await repo.failedOutbox(), isEmpty);
    });

    test(
      'a manual retry (reset of the attempts) takes the item off the list',
      () async {
        await repo.saveLocal(at('a', 2));
        await repo.markFailed((await repo.pending()).single, 'conflict');
        expect(await repo.failedOutbox(), hasLength(1));
        await repo.resetAttempts();
        expect(await repo.failedOutbox(), isEmpty);
      },
    );
  });

  group('discardOutbox: giving up on one upload', () {
    test('the queue entry goes, the event stays on the device', () async {
      await repo.saveLocal(at('a', 2));
      final seq = (await repo.pending()).single.seq;

      expect(await repo.discardOutbox(seq), isTrue);

      expect(await repo.pending(), isEmpty);
      expect((await repo.byId('a'))?.title, 'a');
      expect(await repo.all(), hasLength(1));
    });

    test('editing the event queues it again', () async {
      await repo.saveLocal(at('a', 2));
      await repo.discardOutbox((await repo.pending()).single.seq);
      await repo.saveLocal(at('a', 2).copyWith(title: 'módosítva'));
      final again = (await repo.pending()).single;
      expect(again.attempts, 0);
      expect(again.lastError, isNull);
    });

    test('only the chosen entry is dropped', () async {
      await repo.saveAll([at('a', 2), at('b', 3)]);
      final items = await repo.pending();
      await repo.discardOutbox(items.first.seq);
      expect((await repo.pending()).map((i) => i.event.id), ['b']);
    });

    test('a queued deletion goes together with the tombstone', () async {
      await linked('a', 2);
      await repo.deleteLocal('a');
      final del = (await repo.pending()).single;
      expect(del.op, 'delete');
      expect(await repo.isTombstone('a'), isTrue);

      expect(await repo.discardOutbox(del.seq), isTrue);

      expect(await repo.pending(), isEmpty);
      expect(await repo.isTombstone('a'), isFalse);
      expect(await repo.byId('a'), isNull);
    });

    test(
      'so the daily housekeeping does not queue that deletion again',
      () async {
        await linked('a', 2);
        await repo.deleteLocal('a');
        await repo.discardOutbox((await repo.pending()).single.seq);
        final r = await repo.purgeOrphans();
        expect(r.requeued, 0);
        expect(await repo.pending(), isEmpty);
      },
    );

    test('(why) a tombstone left behind would be queued again', () async {
      await linked('a', 2);
      await repo.deleteLocal('a');
      // what discarding only the queue entry would do
      await db.customStatement('DELETE FROM outbox_rows');
      final r = await repo.purgeOrphans();
      expect(r.requeued, 1);
    });

    test('an entry that does not exist: false, nothing changes', () async {
      await repo.saveLocal(at('a', 2));
      expect(await repo.discardOutbox(9999), isFalse);
      expect(await repo.pending(), hasLength(1));
    });
  });
}
