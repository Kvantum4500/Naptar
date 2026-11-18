import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/sync/sync_engine.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_remote.dart';

const cal = 'naptar';
const bp = 'Europe/Budapest';

CalEvent ev(String id, String title, {int day = 4, int hour = 9}) => CalEvent(
  id: id,
  calendarId: cal,
  title: title,
  tzid: bp,
  start: floating(2026, 5, day, hour),
  end: floating(2026, 5, day, hour + 1),
);

void main() {
  late AppDatabase db;
  late EventRepository repo;
  late FakeRemote remote;
  late SyncHold hold;
  late SyncEngine engine;

  setUpAll(ensureTimeZones);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
    remote = FakeRemote();
    hold = SyncHold();
    engine = SyncEngine(repo, remote, isHeld: hold.holdsEvent);
  });
  tearDown(() => db.close());

  group('the hold', () {
    test('a held event stays in the queue; released, it goes up', () async {
      await repo.saveLocal(ev('a', 'Edzés'));
      final t = hold.acquire(['a']);
      final r1 = await engine.sync(cal);
      expect(r1.held, 1);
      expect(r1.pushed, 0);
      expect(r1.deferred, 0, reason: 'held is not "waiting for the master"');
      expect(remote.pushLog, isEmpty);
      expect((await repo.pending()).length, 1);
      t.release();
      final r2 = await engine.sync(cal);
      expect(r2.pushed, 1);
      expect(r2.held, 0);
      expect(remote.pushLog, [('upsert', 'a')]);
    });

    test('other events are not held back', () async {
      await repo.saveLocal(ev('a', 'Held'));
      await repo.saveLocal(ev('b', 'Free', hour: 11));
      hold.acquire(['a']);
      final r = await engine.sync(cal);
      expect(r.held, 1);
      expect(r.pushed, 1);
      expect(remote.pushLog, [('upsert', 'b')]);
    });

    test('a held series master holds its exceptions too', () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      final exception = makeOverride(
        master: master,
        originalStart: floating(2026, 5, 5, 9),
        edited: master.copyWith(
          start: floating(2026, 5, 5, 10),
          end: floating(2026, 5, 5, 11),
        ),
        newId: 'x',
      );
      await repo.saveAll([master, exception]);
      final t = hold.acquire(['m']);
      final r = await engine.sync(cal);
      expect(r.held, 2);
      expect(r.pushed, 0);
      expect(remote.pushLog, isEmpty);
      t.release();
      final r2 = await engine.sync(cal);
      expect(r2.pushed, 2);
    });

    test(
      'a held DELETION is not sent; taking it back sends no delete',
      () async {
        final original = ev('a', 'Edzés');
        await repo.saveLocal(original);
        await engine.sync(cal); // now linked to Google
        final linked = (await repo.byId('a'))!;
        expect(linked.googleId, isNotNull);

        final t = hold.acquire(['a']);
        await repo.deleteLocal('a');
        final r1 = await engine.sync(cal);
        expect(r1.held, 1);
        expect(remote.pushLog.where((p) => p.$1 == 'delete'), isEmpty);
        expect(await repo.isTombstone('a'), isTrue);

        // "Visszavonás": the event is saved again (the link is kept)
        await repo.saveLocal(linked.copyWith(title: 'Edzés'));
        t.release();
        await engine.sync(cal);
        expect(remote.pushLog.where((p) => p.$1 == 'delete'), isEmpty);
        expect(remote.isCancelled(linked.googleId!), isFalse);
        expect(remote.events[linked.googleId], isNotNull);
        expect((await repo.all()).single.googleId, linked.googleId);
      },
    );

    test('released without undo, the deletion goes up', () async {
      await repo.saveLocal(ev('a', 'Edzés'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;
      final t = hold.acquire(['a']);
      await repo.deleteLocal('a');
      await engine.sync(cal);
      expect(remote.isCancelled(g), isFalse);
      t.release();
      await engine.sync(cal);
      expect(remote.isCancelled(g), isTrue);
      expect(await repo.byId('a'), isNull, reason: 'the tombstone is purged');
    });
  });

  group('a deletion on the wire when it is taken back', () {
    Future<void> waitForDelete() async {
      for (var i = 0; i < 200; i++) {
        if (remote.pushLog.any((p) => p.$1 == 'delete')) return;
        await Future<void>.delayed(Duration.zero);
      }
      fail('the delete never reached the remote');
    }

    test(
      'the restored event survives the end of the upload and is re-created',
      () async {
        await repo.saveLocal(ev('a', 'Edzés'));
        await engine.sync(cal);
        final linked = (await repo.byId('a'))!;
        final oldGoogleId = linked.googleId!;

        await repo.deleteLocal('a');
        remote.deleteGate = Completer<void>();
        final running = engine.sync(cal); // the delete is now "on the wire"
        await waitForDelete();

        // the user takes it back while Google is still working on the deletion
        await repo.saveLocal(linked);
        remote.deleteGate!.complete();
        await running;

        // the upload ended, but the event is still there and alive
        final back = await repo.byId('a');
        expect(
          back,
          isNotNull,
          reason: 'markPushed must not remove a live row',
        );
        expect(await repo.isTombstone('a'), isFalse);
        expect(remote.isCancelled(oldGoogleId), isTrue);

        // the next run notices the cancellation and uploads the event again
        remote.deleteGate = null;
        await engine.sync(cal);
        final after = (await repo.all()).single;
        expect(after.id, 'a');
        expect(after.googleId, isNotNull);
        expect(after.googleId, isNot(oldGoogleId));
        expect(remote.isCancelled(after.googleId!), isFalse);
      },
    );
  });
}
