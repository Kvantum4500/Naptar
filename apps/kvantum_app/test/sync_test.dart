import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
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

  test('local create is pushed once and linked; echo never duplicates', () async {
    await repo.saveLocal(ev('a', 'Edzés'));
    final r1 = await engine.sync(cal);
    expect(r1.pushed, 1);
    expect(remote.events.length, 1);
    // Next sync sees our own write coming back: must not create a second copy.
    final r2 = await engine.sync(cal);
    expect(r2.pushed, 0);
    expect((await repo.all()).length, 1);
    expect(remote.events.length, 1);
    final stored = (await repo.all()).single;
    expect(stored.googleId, isNotNull);
    expect(stored.etag, isNotNull);
  });

  test(
    'retry after a failed push does not duplicate (idempotent upsert)',
    () async {
      await repo.saveLocal(ev('a', 'x'));
      remote.offline = true;
      final r1 = await engine.sync(cal);
      expect(r1.stoppedEarly, isTrue);
      expect((await repo.pending()).length, 1);
      remote.offline = false;
      await engine.sync(cal);
      await engine.sync(cal);
      expect(remote.events.length, 1);
      expect(await repo.pending(), isEmpty);
    },
  );

  test('several offline edits collapse into one queued op', () async {
    await repo.saveLocal(ev('a', 'v1'));
    await repo.saveLocal(ev('a', 'v2'));
    await repo.saveLocal(ev('a', 'v3'));
    expect((await repo.pending()).length, 1);
    await engine.sync(cal);
    expect(remote.upsertCalls, 1);
    expect(remote.events.values.single.title, 'v3');
  });

  test('remote create / update / delete reach the local store', () async {
    final g = remote.externalCreate(ev('x', 'Külső'));
    await engine.sync(cal);
    expect((await repo.all()).single.title, 'Külső');
    remote.externalUpdate(g, (e) => e.copyWith(title: 'Átírt'));
    await engine.sync(cal);
    expect((await repo.all()).single.title, 'Átírt');
    remote.externalDelete(g);
    await engine.sync(cal);
    expect(await repo.all(), isEmpty);
  });

  test('local delete is pushed and tombstone removed; unsynced delete is local only', () async {
    await repo.saveLocal(ev('a', 'x'));
    await engine.sync(cal);
    final g = (await repo.byId('a'))!.googleId!;
    await repo.deleteLocal('a');
    expect(await repo.all(), isEmpty); // hidden immediately
    expect(remote.isCancelled(g), isFalse);
    await engine.sync(cal);
    expect(remote.isCancelled(g), isTrue);
    expect(await repo.pending(), isEmpty);
    // never-synced event: deleted without any remote call
    await repo.saveLocal(ev('b', 'y'));
    await repo.deleteLocal('b');
    expect(await repo.pending(), isEmpty);
  });

  test(
    'conflict: pending local edit wins, etag adopted, push succeeds',
    () async {
      await repo.saveLocal(ev('a', 'orig'));
      await engine.sync(cal);
      final g = (await repo.all()).single.googleId!;
      remote.externalUpdate(g, (e) => e.copyWith(title: 'remote edit'));
      await repo.saveLocal(
        (await repo.byId('a'))!.copyWith(title: 'local edit'),
      );
      final r = await engine.sync(cal);
      expect(r.localWonConflicts, ['a']);
      expect(remote.events[g]!.title, 'local edit');
      expect(await repo.pending(), isEmpty);
    },
  );

  test(
    'expired sync token triggers full resync and mirrors remote deletions',
    () async {
      final g1 = remote.externalCreate(ev('x', 'keep'));
      final g2 = remote.externalCreate(ev('y', 'gone', hour: 12));
      await engine.sync(cal);
      expect((await repo.all()).length, 2);
      remote.events.remove(g2); // vanished while we were away (no tombstone)
      remote.expireToken = true;
      final r = await engine.sync(cal);
      expect(r.fullResync, isTrue);
      final left = await repo.all();
      expect(left.length, 1);
      expect(left.single.googleId, g1);
    },
  );

  test('exception instances attach to their series master', () async {
    final master = ev('m', 'Series').copyWith(rrule: 'FREQ=DAILY;COUNT=3');
    final gm = remote.externalCreate(master);
    remote.externalCreate(
      ev(
        'o',
        'Moved',
        hour: 15,
      ).copyWith(originalStart: floating(2026, 5, 5, 9)),
      master: gm,
    );
    await engine.sync(cal);
    final all = await repo.all();
    final m = all.firstWhere((e) => e.googleId == gm);
    final o = all.firstWhere((e) => e.isException);
    expect(o.recurringEventId, m.id);
    final occ = await repo.occurrences(
      DateTime.utc(2026, 5, 1),
      DateTime.utc(2026, 6, 1),
    );
    expect(occ.length, 3);
    expect(occ.any((x) => x.title == 'Moved'), isTrue);
  });

  test(
    'times round-trip through the database unchanged (DST zone + all-day)',
    () async {
      final timed = CalEvent(
        id: 't',
        calendarId: cal,
        title: 't',
        tzid: bp,
        start: floating(2026, 3, 29, 2, 30),
        end: floating(2026, 3, 29, 3, 30),
        exdates: [floating(2026, 4, 1, 2, 30)],
      );
      final allDay = CalEvent(
        id: 'd',
        calendarId: cal,
        title: 'd',
        allDay: true,
        start: floating(2026, 12, 31),
        end: floating(2027, 1, 2),
      );
      await repo.saveLocal(timed);
      await repo.saveLocal(allDay);
      final t = (await repo.byId('t'))!;
      expect(t.start, timed.start);
      expect(t.exdates, timed.exdates);
      final d = (await repo.byId('d'))!;
      expect(d.allDay, isTrue);
      expect(d.end, floating(2027, 1, 2));
    },
  );
}
