import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_change.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/ui/delete_ops.dart';
import 'package:kvantum_app/ui/event_editor.dart' show Scope;
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// Weekly on Mondays, 4 occurrences: 4., 11., 18., 25. May 2026, 09:00.
CalEvent series() => evt(
  'm',
  'Edzés',
  floating(2026, 5, 4, 9),
  rrule: 'FREQ=WEEKLY;BYDAY=MO;COUNT=4',
);

void main() {
  late AppDatabase db;
  late EventRepository repo;

  setUpAll(ensureTimeZones);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
  });
  tearDown(() => db.close());

  Future<List<int>> days() async => [
    for (final o in await repo.occurrences(
      DateTime.utc(2026, 5, 1),
      DateTime.utc(2026, 6, 30),
    ))
      o.originalStart.day,
  ];

  Future<EventChangeSet?> delete(
    String id,
    DateTime orig,
    Scope scope, {
    bool recurring = true,
  }) => deleteEvent(
    repo,
    eventId: id,
    originalStart: orig,
    recurring: recurring,
    scope: scope,
  );

  CalEvent exception18() => makeOverride(
    master: series(),
    originalStart: floating(2026, 5, 18, 9),
    edited: series().copyWith(
      title: 'Máskor',
      start: floating(2026, 5, 18, 12),
      end: floating(2026, 5, 18, 13),
    ),
    newId: 'x',
  );

  test(
    'a single event goes, and the change set says how to bring it back',
    () async {
      await repo.saveLocal(evt('p', 'Egyszeri', floating(2026, 5, 4, 9)));
      final set = await delete(
        'p',
        floating(2026, 5, 4, 9),
        Scope.only,
        recurring: false,
      );
      expect(set, isNotNull);
      expect(await repo.all(), isEmpty);
      expect(set!.before.single.id, 'p');
      expect(await repo.undoChange(set), isTrue);
      expect((await repo.all()).single.title, 'Egyszeri');
    },
  );

  test(
    'an event that does not exist, or is deleted already, gives null',
    () async {
      expect(
        await delete(
          'nincs',
          floating(2026, 5, 4, 9),
          Scope.only,
          recurring: false,
        ),
        isNull,
      );
      await repo.saveLocal(evt('p', 'Egyszeri', floating(2026, 5, 4, 9)));
      // (a synced event leaves a tombstone, which is still "deleted")
      await repo.db.customStatement("UPDATE event_rows SET google_id = 'g1'");
      await delete('p', floating(2026, 5, 4, 9), Scope.only, recurring: false);
      expect(await repo.isTombstone('p'), isTrue);
      final queued = (await repo.pending()).single.seq;
      expect(
        await delete(
          'p',
          floating(2026, 5, 4, 9),
          Scope.only,
          recurring: false,
        ),
        isNull,
      );
      expect(
        (await repo.pending()).single.seq,
        queued,
        reason: 'the deletion is not queued a second time',
      );
    },
  );

  group('one occurrence of a series', () {
    test('adds an EXDATE to the master', () async {
      await repo.saveLocal(series());
      final set = await delete('m', floating(2026, 5, 11, 9), Scope.only);
      expect(await days(), [4, 18, 25]);
      expect(set!.before.single.exdates, isEmpty, reason: 'the image is old');
      expect(await repo.undoChange(set), isTrue);
      expect(await days(), [4, 11, 18, 25]);
    });

    test('an exception: its row goes and the master gets the EXDATE', () async {
      await repo.saveAll([series(), exception18()]);
      expect(await days(), [4, 11, 18, 25]);
      final set = await delete('x', floating(2026, 5, 18, 9), Scope.only);
      expect(await repo.byId('x'), isNull);
      expect(await days(), [4, 11, 25]);
      expect({for (final e in set!.before) e.id}, {'m', 'x'});
      expect(await repo.undoChange(set), isTrue);
      expect((await repo.byId('x'))!.title, 'Máskor');
      expect(await days(), [4, 11, 18, 25]);
    });
  });

  group('this and the following', () {
    test(
      'ends the series before this one and drops the later exceptions',
      () async {
        await repo.saveAll([series(), exception18()]);
        final set = await delete(
          'm',
          floating(2026, 5, 11, 9),
          Scope.following,
        );
        expect(await days(), [4]);
        expect(await repo.byId('x'), isNull, reason: 'it is after the split');
        expect(await repo.undoChange(set!), isTrue);
        expect(await days(), [4, 11, 18, 25]);
        expect((await repo.byId('x'))!.title, 'Máskor');
      },
    );

    test('keeps the exceptions BEFORE the split', () async {
      await repo.saveAll([series(), exception18()]);
      await delete('m', floating(2026, 5, 25, 9), Scope.following);
      expect(await days(), [4, 11, 18], reason: 'the 18th exception stays');
      expect((await repo.byId('x'))!.title, 'Máskor');
    });

    test('from the first occurrence it is the whole series', () async {
      await repo.saveAll([series(), exception18()]);
      final set = await delete('m', floating(2026, 5, 4, 9), Scope.following);
      expect(await repo.all(), isEmpty);
      expect(await repo.undoChange(set!), isTrue);
      expect(await days(), [4, 11, 18, 25]);
    });
  });

  test('the whole series goes with its exceptions, and comes back', () async {
    await repo.saveAll([series(), exception18()]);
    final set = await delete('m', floating(2026, 5, 11, 9), Scope.all);
    expect(await repo.all(), isEmpty);
    expect(
      [for (final e in set!.before) e.id],
      ['m', 'x'],
      reason: 'master first',
    );
    expect(await repo.undoChange(set), isTrue);
    expect({for (final e in await repo.all()) e.id}, {'m', 'x'});
  });

  test('an exception whose series is gone is simply deleted', () async {
    await repo.saveLocal(exception18());
    final set = await delete('x', floating(2026, 5, 18, 9), Scope.all);
    expect(await repo.all(), isEmpty);
    expect(set!.before.single.id, 'x');
  });

  test(
    'deleteOccurrence still says whether there was anything to delete',
    () async {
      await repo.saveLocal(series());
      final o = (await repo.occurrences(
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 5, 31),
      )).first;
      expect(await deleteOccurrence(repo, o, Scope.only), isTrue);
      await repo.deleteLocal('m');
      expect(await deleteOccurrence(repo, o, Scope.only), isFalse);
    },
  );
}
