import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/remote.dart';
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

/// What a bad moment looks like: a usage limit, or a network drop.
TransientSyncError limit([Duration? wait]) => TransientSyncError.throttled(
  'http 403 calendarUsageLimitsExceeded',
  retryAfter: wait,
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

  group('which account / calendar this device syncs with', () {
    test('the first run notes it and syncs normally', () async {
      await repo.saveLocal(ev('a', 'x'));
      final r = await engine.sync(cal);
      expect(r.mismatch, isNull);
      expect(r.pushed, 1);
      expect(await repo.meta(syncBindingKey), 'me@example.com|cal-1');
    });

    test('the same account again: no question', () async {
      await engine.sync(cal);
      final r = await engine.sync(cal);
      expect(r.mismatch, isNull);
    });

    test(
      'ANOTHER ACCOUNT: nothing is pulled, pushed, deleted or noted',
      () async {
        await repo.saveLocal(ev('a', 'x'));
        await engine.sync(cal);
        await repo.saveLocal(ev('b', 'edited offline'));
        final pulls = remote.pullCalls, ups = remote.upsertCalls;
        remote.who = const RemoteIdentity(
          account: 'other@example.com',
          calendar: 'cal-9',
        );

        final r = await engine.sync(cal);
        expect(r.mismatch, isNotNull);
        expect(r.mismatch!.accountChanged, isTrue);
        expect(r.mismatch!.stored.account, 'me@example.com');
        expect(r.mismatch!.current.account, 'other@example.com');
        expect(remote.pullCalls, pulls);
        expect(remote.upsertCalls, ups);
        expect(
          (await repo.all()).map((e) => e.id),
          unorderedEquals(['a', 'b']),
        );
        expect((await repo.pending()).length, 1, reason: 'b still waits');
        expect(await repo.meta(syncBindingKey), 'me@example.com|cal-1');
      },
    );

    test(
      'the same account but another calendar (deleted and created again)',
      () async {
        await engine.sync(cal);
        remote.who = const RemoteIdentity(
          account: 'me@example.com',
          calendar: 'cal-NEW',
        );
        final r = await engine.sync(cal);
        expect(r.mismatch, isNotNull);
        expect(r.mismatch!.accountChanged, isFalse);
      },
    );

    test('an installation from before the link was recorded adopts the current one', () async {
      // events and a sync token exist, but no binding yet (an older build)
      await repo.saveFromRemote(
        ev('a', 'x').copyWith(googleId: 'g1', etag: 'e'),
      );
      await repo.setMeta('syncToken:$cal', '5');
      final r = await engine.sync(cal);
      expect(r.mismatch, isNull);
      expect(await repo.meta(syncBindingKey), isNotNull);
    });

    test(
      'an account that was unknown is learned, not treated as a change',
      () async {
        remote.who = const RemoteIdentity(account: '', calendar: 'cal-1');
        await engine.sync(cal);
        remote.who = const RemoteIdentity(
          account: 'me@example.com',
          calendar: 'cal-1',
        );
        final r = await engine.sync(cal);
        expect(r.mismatch, isNull);
        expect(await repo.meta(syncBindingKey), 'me@example.com|cal-1');
      },
    );

    test('a calendar that vanished: the run stops quietly, nothing changes locally', () async {
      await repo.saveLocal(ev('a', 'x'));
      await engine.sync(cal);
      remote.calendarGone = true;
      final r = await engine.sync(cal);
      expect(r.calendarGone, isTrue);
      expect(r.stoppedEarly, isTrue);
      expect((await repo.all()).length, 1);
    });
  });

  group('a failed upload is judged by WHY it failed', () {
    test(
      'a usage limit stops the run and costs the item nothing, however often',
      () async {
        await repo.saveLocal(ev('a', 'x'));
        remote.failUpsertAt.addAll({1: limit(), 2: limit(), 3: limit()});
        for (var i = 0; i < 3; i++) {
          final r = await engine.sync(cal);
          expect(r.stoppedEarly, isTrue);
          expect(r.hint, isA<TransientSyncError>());
          expect((r.hint! as TransientSyncError).throttled, isTrue);
        }
        final item = (await repo.pending()).single;
        expect(
          item.attempts,
          0,
          reason: 'the item is fine, the moment was not',
        );
        expect(
          item.lastError,
          'transient:limit',
          reason: 'a code, not the text of the Google error',
        );
        // and it goes through as soon as the limit is over
        final r = await engine.sync(cal);
        expect(r.pushed, 1);
        expect(await repo.pending(), isEmpty);
      },
    );

    test('the server\'s Retry-After travels with the report', () async {
      await repo.saveLocal(ev('a', 'x'));
      remote.failUpsertAt[1] = limit(const Duration(seconds: 90));
      final r = await engine.sync(cal);
      expect(r.hint!.retryAfter, const Duration(seconds: 90));
    });

    test(
      'a refusal of the item counts; after five it is parked and left alone',
      () async {
        await repo.saveLocal(ev('a', 'x'));
        for (var i = 1; i <= 8; i++) {
          remote.failUpsertAt[i] = ItemRejectedError(
            400,
            'invalid',
            'bad time',
          );
        }
        for (var i = 1; i <= 5; i++) {
          final r = await engine.sync(cal);
          expect(r.failed, 1);
          expect((await repo.pending()).single.attempts, i);
        }
        final calls = remote.upsertCalls;
        final r = await engine.sync(cal);
        expect(r.parked, 1);
        expect(r.failed, 1);
        expect(
          remote.upsertCalls,
          calls,
          reason: 'a parked item is not hammered',
        );
        expect((await repo.pending()).single.lastError, 'rejected:400:invalid');
      },
    );

    test('a manual sync gives parked items a fresh start', () async {
      await repo.saveLocal(ev('a', 'x'));
      for (var i = 1; i <= 5; i++) {
        remote.failUpsertAt[i] = ItemRejectedError(400, 'invalid', 'x');
      }
      for (var i = 0; i < 5; i++) {
        await engine.sync(cal);
      }
      expect((await engine.sync(cal)).parked, 1);

      final r = await engine.sync(cal, manual: true);
      expect(r.pushed, 1, reason: 'the cause has gone, the retry works');
      expect(await repo.pending(), isEmpty);
    });

    test('editing a parked event queues it afresh', () async {
      await repo.saveLocal(ev('a', 'x'));
      for (var i = 1; i <= 5; i++) {
        remote.failUpsertAt[i] = ItemRejectedError(400, 'invalid', 'x');
      }
      for (var i = 0; i < 5; i++) {
        await engine.sync(cal);
      }
      await repo.saveLocal(ev('a', 'fixed'));
      expect((await repo.pending()).single.attempts, 0);
      expect((await engine.sync(cal)).pushed, 1);
    });

    test(
      'a stale etag still counts as a failed try, with its reason',
      () async {
        await repo.saveLocal(ev('a', 'x'));
        remote.failUpsertAt[1] = ConflictException();
        final r = await engine.sync(cal);
        expect(r.failed, 1);
        final item = (await repo.pending()).single;
        expect(item.attempts, 1);
        expect(item.lastError, 'conflict');
      },
    );
  });

  group('uploads are paced and capped per run', () {
    test(
      'at most maxPushPerRun per run; "more" says there is a rest',
      () async {
        engine = SyncEngine(repo, remote, maxPushPerRun: 3);
        for (var i = 0; i < 7; i++) {
          await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
        }
        final r1 = await engine.sync(cal);
        expect((r1.pushed, r1.more), (3, true));
        final r2 = await engine.sync(cal);
        expect((r2.pushed, r2.more), (3, true));
        final r3 = await engine.sync(cal);
        expect((r3.pushed, r3.more), (1, false));
        expect(remote.events.length, 7);
      },
    );

    test(
      'the uploads say how far they are: (0, n) first, then after each',
      () async {
        final seen = <(int, int)>[];
        engine = SyncEngine(
          repo,
          remote,
          onProgress: (d, t) => seen.add((d, t)),
        );
        for (var i = 0; i < 3; i++) {
          await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
        }
        await engine.sync(cal);
        expect(seen, [(0, 3), (1, 3), (2, 3), (3, 3)]);
      },
    );

    test('nothing to upload: no progress at all', () async {
      final seen = <(int, int)>[];
      engine = SyncEngine(repo, remote, onProgress: (d, t) => seen.add((d, t)));
      await engine.sync(cal);
      expect(seen, isEmpty);
    });

    test(
      'the total is what this run will try: the cap, not the whole queue',
      () async {
        final seen = <(int, int)>[];
        engine = SyncEngine(
          repo,
          remote,
          maxPushPerRun: 3,
          onProgress: (d, t) => seen.add((d, t)),
        );
        for (var i = 0; i < 7; i++) {
          await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
        }
        await engine.sync(cal);
        expect(seen.first, (0, 3));
        expect(seen.last, (3, 3));
        expect(seen.every((p) => p.$2 == 3), isTrue);
      },
    );

    test('what is held back or given up on is not counted', () async {
      final seen = <(int, int)>[];
      engine = SyncEngine(
        repo,
        remote,
        maxAttempts: 1,
        isHeld: (e) => e.id == 'h',
        onProgress: (d, t) => seen.add((d, t)),
      );
      for (final id in ['h', 'p', 'o']) {
        await repo.saveLocal(ev(id, id, day: 4 + id.codeUnitAt(0) % 7));
      }
      final parked = (await repo.pending()).firstWhere(
        (i) => i.event.id == 'p',
      );
      await repo.markFailed(parked, 'x'); // one try is all it gets
      await engine.sync(cal);
      expect(seen, [(0, 1), (1, 1)]);
    });

    test(
      'an upload Google refuses has been tried: the count moves on',
      () async {
        final seen = <(int, int)>[];
        engine = SyncEngine(
          repo,
          remote,
          onProgress: (d, t) => seen.add((d, t)),
        );
        for (var i = 0; i < 3; i++) {
          await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
        }
        remote.failUpsertAt[2] = ItemRejectedError(400, 'invalid', 'bad item');
        final r = await engine.sync(cal);
        expect(r.pushed, 2);
        expect(seen.last, (3, 3));
      },
    );

    test('a run that stops on a limit stops reporting there', () async {
      final seen = <(int, int)>[];
      engine = SyncEngine(repo, remote, onProgress: (d, t) => seen.add((d, t)));
      for (var i = 0; i < 4; i++) {
        await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
      }
      remote.failUpsertAt[3] = limit();
      final r = await engine.sync(cal);
      expect(r.stoppedEarly, isNotNull); // the run ended early
      expect(seen, [(0, 4), (1, 4), (2, 4)]);
    });

    test(
      'a pause between two uploads, none before the first or after the last',
      () async {
        engine = SyncEngine(
          repo,
          remote,
          pace: const Duration(milliseconds: 40),
        );
        for (var i = 0; i < 4; i++) {
          await repo.saveLocal(ev('e$i', 'x$i', day: 4 + i));
        }
        final t = Stopwatch()..start();
        final r = await engine.sync(cal);
        t.stop();
        expect(r.pushed, 4);
        expect(t.elapsedMilliseconds, greaterThanOrEqualTo(3 * 40 - 5));
      },
    );

    test(
      'items that wait for their series do not use up the cap or the pause',
      () async {
        engine = SyncEngine(repo, remote, maxPushPerRun: 1);
        final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
        final exc = ev('x', 'Moved', hour: 15).copyWith(
          recurringEventId: 'm',
          originalStart: floating(2026, 5, 5, 9),
        );
        await repo.saveLocal(
          exc,
        ); // queued FIRST, but its series is not in Google
        await repo.saveLocal(master);
        final r = await engine.sync(cal);
        expect(r.pushed, 1, reason: 'the series went first');
        expect(r.deferred, 1);
        expect(remote.pushLog.single, ('upsert', 'm'));
      },
    );
  });

  group('deleted there, edited here', () {
    test('the edit wins: the event is created again with the edit', () async {
      await repo.saveLocal(ev('a', 'original'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;

      await repo.saveLocal(
        (await repo.byId('a'))!.copyWith(title: 'edited offline'),
      );
      remote.externalDelete(g);

      final r = await engine.sync(cal);
      expect(r.localWonConflicts, ['a']);
      final local = (await repo.byId('a'))!;
      expect(local.title, 'edited offline');
      final live = remote.events.entries
          .where((e) => !remote.isCancelled(e.key))
          .toList();
      expect(live.single.value.title, 'edited offline');
      expect(local.googleId, live.single.key, reason: 'linked to the new one');
      expect(await repo.pending(), isEmpty);
    });

    test('an unedited event is removed here as before', () async {
      await repo.saveLocal(ev('a', 'x'));
      await engine.sync(cal);
      remote.externalDelete((await repo.byId('a'))!.googleId!);
      await engine.sync(cal);
      expect(await repo.all(), isEmpty);
    });

    test('deleted on both sides: simply gone', () async {
      await repo.saveLocal(ev('a', 'x'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;
      await repo.deleteLocal('a');
      remote.externalDelete(g);
      final r = await engine.sync(cal);
      expect(r.failed, 0);
      expect(await repo.all(), isEmpty);
      expect(await repo.pending(), isEmpty);
    });

    test(
      'the exceptions of a series that is recreated are cut loose too',
      () async {
        final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
        final exc = ev('x', 'Moved', hour: 15).copyWith(
          recurringEventId: 'm',
          originalStart: floating(2026, 5, 5, 9),
        );
        await repo.saveLocal(master);
        await engine.sync(cal);
        await repo.saveLocal(exc);
        await engine.sync(cal);
        expect((await repo.byId('x'))!.googleId, isNotNull);

        await repo.saveLocal(
          (await repo.byId('m'))!.copyWith(title: 'Series 2'),
        );
        remote.externalDelete((await repo.byId('m'))!.googleId!);
        await engine.sync(cal);
        await engine.sync(cal);
        expect((await repo.byId('m'))!.title, 'Series 2');
        expect((await repo.byId('m'))!.googleId, isNotNull);
        expect((await repo.byId('x'))!.recurringEventId, 'm');
      },
    );
  });

  group('rows are never confused with each other', () {
    test('an instance that carries its series\' appEventId leaves the series alone', () async {
      final master = ev('m', 'Edzés').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      await repo.saveLocal(master);
      await engine.sync(cal);
      final gm = (await repo.byId('m'))!.googleId!;

      // somebody moves one occurrence in Google; Google copies appEventId 'm'
      final gi = remote.externalCreate(
        ev(
          'z',
          'Átrakva',
          hour: 15,
        ).copyWith(originalStart: floating(2026, 5, 6, 9)),
        master: gm,
      );
      remote.inheritedAppId[gi] = 'm';

      await engine.sync(cal);
      final m = (await repo.byId('m'))!;
      expect(m.title, 'Edzés');
      expect(m.rrule, 'FREQ=DAILY;COUNT=5');
      expect(m.isException, isFalse);
      final exc = (await repo.all()).where((e) => e.isException).single;
      expect(exc.id, isNot('m'));
      expect(exc.recurringEventId, 'm');
      expect(exc.title, 'Átrakva');
      expect(exc.originalStart, floating(2026, 5, 6, 9));
      // and the calendar shows the series with the moved occurrence
      final occ = await repo.occurrences(
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 6, 1),
      );
      expect(occ.length, 5);
      expect(occ.where((o) => o.title == 'Átrakva').length, 1);
    });

    test('not even when the deletion cannot go out right now', () async {
      await repo.saveLocal(ev('a', 'x'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;
      await repo.deleteLocal('a');
      remote.externalUpdate(g, (e) => e.copyWith(title: 'changed in Google'));
      remote.failDelete = TransientSyncError('offline');
      final r = await engine.sync(cal);
      expect(r.stoppedEarly, isTrue);
      expect(
        await repo.all(),
        isEmpty,
        reason: 'it must not come back to life',
      );
      expect(await repo.isTombstone('a'), isTrue);
      expect((await repo.pending()).single.op, 'delete');
    });

    test('a change for an event whose deletion is still waiting does not bring it back', () async {
      await repo.saveLocal(ev('a', 'x'));
      await engine.sync(cal);
      final g = (await repo.byId('a'))!.googleId!;
      await repo.deleteLocal('a'); // tombstone + queued deletion
      remote.externalUpdate(g, (e) => e.copyWith(title: 'changed in Google'));
      // the pull shows the Google event, whose appEventId names our tombstone
      final r = await engine.sync(cal);
      expect(r.failed, 0);
      expect(await repo.all(), isEmpty);
      expect(remote.isCancelled(g), isTrue, reason: 'the deletion went out');
      expect(await repo.pending(), isEmpty);
    });
  });

  group('what cannot be read does not stop the rest', () {
    test('skipped remote events are counted; the others arrive; the token advances', () async {
      remote.externalCreate(ev('x', 'good'));
      remote.skipped = const [SkippedRemote('bad', 'FormatException: x')];
      final r = await engine.sync(cal);
      expect(r.skippedRemote, 1);
      expect((await repo.all()).single.title, 'good');
      expect(await repo.meta('syncToken:$cal'), isNotNull);
    });
  });

  group('the stored link wins over an editor\'s old snapshot', () {
    test('saving an old copy does not put the old etag back', () async {
      await repo.saveLocal(ev('a', 'v1'));
      await engine.sync(cal);
      final snapshot = (await repo.byId('a'))!; // the editor opens here
      final g = snapshot.googleId!;
      remote.externalUpdate(g, (e) => e.copyWith(notes: 'from Google'));
      await engine.sync(cal); // the sync adopts the new etag
      final fresh = (await repo.byId('a'))!;
      expect(fresh.etag, isNot(snapshot.etag));

      await repo.saveLocal(snapshot.copyWith(title: 'v2'));
      final saved = (await repo.byId('a'))!;
      expect(saved.title, 'v2');
      expect(saved.etag, fresh.etag);
      expect(saved.googleId, g);
      expect((await engine.sync(cal)).failed, 0);
    });

    test('an event without a stored link takes the one it brings', () async {
      await repo.saveLocal(ev('a', 'x').copyWith(googleId: 'gX', etag: 'eX'));
      final saved = (await repo.byId('a'))!;
      expect((saved.googleId, saved.etag), ('gX', 'eX'));
    });
  });

  group('repository helpers of the reset', () {
    Future<void> seed() async {
      await repo.saveLocal(ev('s', 'single'));
      final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
      final exc = ev(
        'x',
        'Moved',
        hour: 15,
      ).copyWith(recurringEventId: 'm', originalStart: floating(2026, 5, 5, 9));
      await repo.saveLocal(exc);
      await repo.saveLocal(master);
      await repo.saveLocal(ev('d', 'to delete'));
      await engine.sync(cal);
      await engine.sync(cal);
      await repo.deleteLocal('d');
    }

    test(
      'unlinkLive cuts every live link and leaves the waiting deletion alone',
      () async {
        await seed();
        await repo.unlinkLive(cal);
        for (final e in await repo.all()) {
          expect(
            (e.googleId, e.etag, e.iCalUid),
            (null, null, null),
            reason: e.id,
          );
        }
        final tomb = (await repo.pending()).single;
        expect(tomb.op, 'delete');
        expect(
          tomb.event.googleId,
          isNotNull,
          reason: 'still knows what to delete',
        );
      },
    );

    test(
      'requeueLive queues every live event once, series before exceptions',
      () async {
        await seed();
        final n = await repo.requeueLive(cal);
        expect(n, 3);
        final ops = await repo.pendingOps();
        expect(
          ops.keys,
          unorderedEquals(['s', 'm', 'x', 'd']),
          reason: 'd: its deletion',
        );
        expect(ops['d'], 'delete');
        final order = [for (final p in await repo.pending()) p.event.id];
        expect(order.indexOf('m'), lessThan(order.indexOf('x')));
      },
    );

    test(
      'dropTombstones forgets waiting deletions, clearCalendar everything',
      () async {
        await seed();
        await repo.dropTombstones(cal);
        expect(await repo.pending(), isEmpty);
        expect(await repo.byId('d'), isNull);
        expect((await repo.all()).length, 3);
        await repo.clearCalendar(cal);
        expect(await repo.all(), isEmpty);
        expect(await repo.pending(), isEmpty);
      },
    );

    test('unlink of a series also frees its exceptions', () async {
      await seed();
      await repo.unlink('m');
      expect((await repo.byId('m'))!.googleId, isNull);
      expect((await repo.byId('x'))!.googleId, isNull);
      expect((await repo.byId('s'))!.googleId, isNotNull);
    });

    test('resetAttempts and noteError', () async {
      await repo.saveLocal(ev('a', 'x'));
      final item = (await repo.pending()).single;
      await repo.markFailed(item, 'boom');
      await repo.noteError((await repo.pending()).single, 'later');
      var now = (await repo.pending()).single;
      expect((now.attempts, now.lastError), (1, 'later'));
      expect(await repo.resetAttempts(), 1);
      now = (await repo.pending()).single;
      expect(now.attempts, 0);
      expect(await repo.resetAttempts(), 0);
    });

    test('countLive counts live events of the calendar only', () async {
      await seed();
      expect(await repo.countLive(cal), 3);
      expect(await repo.countLive('elsewhere'), 0);
    });

    test('saveAll is one change for the screen, not one per event', () async {
      final emissions = <int>[];
      final sub = repo.watchAll().listen((l) => emissions.add(l.length));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      emissions.clear();
      await repo.saveAll([
        for (var i = 0; i < 6; i++) ev('e$i', 'x', day: 4 + i),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
      expect(emissions, [6]);
    });
  });
}
