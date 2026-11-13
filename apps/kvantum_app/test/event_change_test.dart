import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_change.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/sync/sync_engine.dart';
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
  late SyncEngine engine;

  setUpAll(ensureTimeZones);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
    remote = FakeRemote();
    engine = SyncEngine(repo, remote);
  });
  tearDown(() => db.close());

  Future<EventChangeSet> deleting(String id) =>
      repo.tracked(existing: [id], change: () => repo.deleteLocal(id));

  group('a deletion', () {
    test('of an event that was never uploaded comes back as it was', () async {
      final a = ev('a', 'Edzés');
      await repo.saveLocal(a);
      final set = await deleting('a');
      expect(await repo.byId('a'), isNull);
      expect(set.after['a'], const RowSig(RowState.gone, 0));
      expect(set.before.single.title, 'Edzés');

      expect(await repo.undoChange(set), isTrue);
      final back = (await repo.all()).single;
      expect(back.title, 'Edzés');
      expect(back.version, greaterThan(a.version), reason: 'screens refresh');
      expect(back.googleId, isNull);
      expect((await repo.pendingOps())['a'], 'upsert');
    });

    test('of an uploaded event keeps its link and drops the delete', () async {
      await repo.saveLocal(ev('a', 'Edzés'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;

      final set = await deleting('a');
      expect(set.after['a']!.state, RowState.tombstone);
      expect((await repo.pendingOps())['a'], 'delete');

      expect(await repo.undoChange(set), isTrue);
      final back = (await repo.all()).single;
      expect(back.googleId, g, reason: 'Google never saw the deletion');
      expect(await repo.isTombstone('a'), isFalse);
      expect((await repo.pendingOps())['a'], 'upsert');

      await engine.sync(cal);
      expect(remote.pushLog.where((p) => p.$1 == 'delete'), isEmpty);
      expect(remote.isCancelled(g), isFalse);
    });

    test(
      'whose upload finished meanwhile comes back as a NEW Google event',
      () async {
        await repo.saveLocal(ev('a', 'Edzés'));
        await engine.sync(cal);
        final old = (await repo.byId('a'))!.googleId!;

        final set = await deleting('a');
        await engine.sync(cal); // the deletion goes up and the tombstone goes
        expect(await repo.byId('a'), isNull);
        expect(remote.isCancelled(old), isTrue);

        expect(await repo.undoChange(set), isTrue);
        final back = (await repo.byId('a'))!;
        expect(back.googleId, isNull, reason: 'the old link is dead');
        expect(back.etag, isNull);
        expect(back.iCalUid, isNull);

        await engine.sync(cal);
        final again = (await repo.all()).single;
        expect(again.googleId, isNotNull);
        expect(again.googleId, isNot(old));
        expect(remote.isCancelled(again.googleId!), isFalse);
      },
    );

    test('cannot be taken back once somebody changed the rows', () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      await repo.saveLocal(master);
      final d = floating(2026, 5, 5, 9);
      final set = await repo.tracked(
        existing: ['m'],
        change: () => repo.saveLocal(deleteInstance(master, d)),
      );
      // the user edits the series in the meantime
      final now = (await repo.byId('m'))!;
      await repo.saveLocal(now.copyWith(title: 'Renamed'));

      expect(await repo.undoChange(set), isFalse);
      final kept = (await repo.byId('m'))!;
      expect(kept.title, 'Renamed', reason: 'nothing was overwritten');
      expect(kept.exdates, [d]);
    });

    test('is all or nothing across rows', () async {
      await repo.saveLocal(ev('a', 'A'));
      await repo.saveLocal(ev('b', 'B', hour: 11));
      final set = await repo.tracked(
        existing: ['a', 'b'],
        change: () => repo.deleteAll(['a', 'b']),
      );
      // b is created again by somebody else
      await repo.saveLocal(ev('b', 'B again', hour: 11));
      expect(await repo.undoChange(set), isFalse);
      expect(await repo.byId('a'), isNull, reason: 'a was NOT restored alone');
      expect((await repo.byId('b'))!.title, 'B again');
    });

    test('of a series comes back master first, with its exceptions', () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      final x = makeOverride(
        master: master,
        originalStart: floating(2026, 5, 5, 9),
        edited: master.copyWith(
          start: floating(2026, 5, 5, 10),
          end: floating(2026, 5, 5, 11),
        ),
        newId: 'x',
      );
      await repo.saveAll([master, x]);
      await engine.sync(cal);

      final set = await repo.tracked(
        existing: ['x', 'm'], // deliberately the wrong order
        change: () => repo.deleteAll(['x', 'm']),
      );
      expect([for (final e in set.before) e.id], ['m', 'x']);
      expect(await repo.all(), isEmpty);

      expect(await repo.undoChange(set), isTrue);
      expect([for (final e in await repo.all()) e.id]..sort(), ['m', 'x']);
      expect((await repo.byId('x'))!.recurringEventId, 'm');
      // and the whole series is in Google, once
      await engine.sync(cal);
      expect(remote.pushLog.where((p) => p.$1 == 'delete'), isEmpty);
    });
  });

  group('creating and moving', () {
    test('new events go away again', () async {
      final set = await repo.tracked(
        existing: const [],
        created: ['n1', 'n2'],
        change: () async {
          await repo.saveAll([ev('n1', 'One'), ev('n2', 'Two', hour: 11)]);
        },
      );
      expect((await repo.all()).length, 2);
      expect(await repo.undoChange(set), isTrue);
      expect(await repo.all(), isEmpty);
      expect(await repo.pending(), isEmpty, reason: 'nothing left to upload');
    });

    test(
      'an uploaded new event is deleted in Google when taken back',
      () async {
        await repo.saveLocal(ev('n', 'One'));
        await engine.sync(cal);
        final g = (await repo.byId('n'))!.googleId!;
        // (as if it had been created inside the window and uploaded)
        final set = EventChangeSet(
          created: {'n'},
          after: {'n': await repo.signatureOf('n')},
        );
        expect(await repo.undoChange(set), isTrue);
        expect(await repo.all(), isEmpty);
        await engine.sync(cal);
        expect(remote.isCancelled(g), isTrue);
      },
    );

    test('a moved event goes back to its time', () async {
      final a = ev('a', 'Edzés');
      await repo.saveLocal(a);
      final set = await repo.tracked(
        existing: ['a'],
        change: () => repo.saveLocal(
          a.copyWith(
            start: floating(2026, 5, 4, 15),
            end: floating(2026, 5, 4, 16),
          ),
        ),
      );
      expect((await repo.byId('a'))!.start, floating(2026, 5, 4, 15));
      expect(await repo.undoChange(set), isTrue);
      final back = (await repo.byId('a'))!;
      expect(back.start, floating(2026, 5, 4, 9));
      expect(back.end, floating(2026, 5, 4, 10));
    });
  });

  group('merge', () {
    test('two deletions of one series are taken back together', () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      await repo.saveLocal(master);
      final d1 = floating(2026, 5, 5, 9), d2 = floating(2026, 5, 6, 9);
      final first = await repo.tracked(
        existing: ['m'],
        change: () => repo.saveLocal(deleteInstance(master, d1)),
      );
      final second = await repo.tracked(
        existing: ['m'],
        change: () async =>
            repo.saveLocal(deleteInstance((await repo.byId('m'))!, d2)),
      );
      expect((await repo.byId('m'))!.exdates.length, 2);

      final both = first.merge(second);
      expect(both.before.single.exdates, isEmpty, reason: 'earliest image');
      expect(both.after['m'], second.after['m'], reason: 'latest signature');
      expect(await repo.undoChange(both), isTrue);
      expect((await repo.byId('m'))!.exdates, isEmpty);
    });

    test('undoing only the first of two would fail the guard', () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      await repo.saveLocal(master);
      final first = await repo.tracked(
        existing: ['m'],
        change: () =>
            repo.saveLocal(deleteInstance(master, floating(2026, 5, 5, 9))),
      );
      await repo.tracked(
        existing: ['m'],
        change: () async => repo.saveLocal(
          deleteInstance((await repo.byId('m'))!, floating(2026, 5, 6, 9)),
        ),
      );
      expect(await repo.undoChange(first), isFalse);
    });
  });

  test('a row that is already deleted is not "brought back"', () async {
    await repo.saveLocal(ev('a', 'A'));
    await engine.sync(cal); // linked, so a deletion leaves a tombstone
    await repo.deleteLocal('a');
    expect(await repo.isTombstone('a'), isTrue);
    final set = await repo.tracked(
      existing: ['a'],
      change: () => repo.deleteLocal('a'),
    );
    expect(set.before, isEmpty, reason: 'nothing to restore: it was deleted');
  });

  test(
    'seriesKeysOf names the master for an exception, else the event',
    () async {
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      final x = makeOverride(
        master: master,
        originalStart: floating(2026, 5, 5, 9),
        edited: master.copyWith(
          start: floating(2026, 5, 5, 10),
          end: floating(2026, 5, 5, 11),
        ),
        newId: 'x',
      );
      await repo.saveAll([master, x, ev('p', 'Plain', hour: 14)]);
      expect(await repo.seriesKeysOf(['x', 'm', 'p']), {'m', 'p'});
      expect(await repo.seriesKeysOf(['nincs']), {'nincs'});
    },
  );

  test('clearLinks cuts the link of the given events only', () async {
    await repo.saveLocal(ev('a', 'A'));
    await repo.saveLocal(ev('b', 'B', hour: 11));
    await engine.sync(cal);
    await repo.clearLinks(['a']);
    expect((await repo.byId('a'))!.googleId, isNull);
    expect((await repo.byId('a'))!.etag, isNull);
    expect((await repo.byId('b'))!.googleId, isNotNull);
  });
}
