import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/approval.dart';
import 'package:kvantum_app/ai/assistant_service.dart'
    show DeletionProposal, MoveProposal;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_change.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/ui/event_editor.dart' show Scope;
import 'package:kvantum_app/ui/move_ops.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// A repository whose Nth write fails: an approval is ONE transaction, so
/// nothing of it may be left behind.
class _Flaky extends EventRepository {
  _Flaky(super.db, {this.failOnSave, this.failOnDelete});
  final int? failOnSave;
  final int? failOnDelete;
  var _saves = 0;
  var _deletes = 0;

  @override
  Future<void> saveLocal(CalEvent e) {
    if (++_saves == failOnSave) throw StateError('boom');
    return super.saveLocal(e);
  }

  @override
  Future<void> deleteLocal(String id) {
    if (++_deletes == failOnDelete) throw StateError('boom');
    return super.deleteLocal(id);
  }
}

void main() {
  late AppDatabase db;
  late EventRepository repo;

  setUpAll(ensureTimeZones);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
  });
  tearDown(() => db.close());

  // Monday 2026-05-04, 10:00 Budapest: the clock of the proposals below
  final now = DateTime.utc(2026, 5, 4, 8);

  Future<List<Occurrence>> live() =>
      repo.occurrences(DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 30));

  Future<Occurrence> occ(String title, {int? day}) async =>
      (await live()).firstWhere(
        (o) => o.title == title && (day == null || o.originalStart.day == day),
      );

  Future<List<int>> days() async => [
    for (final o in await live()) o.originalStart.day,
  ];

  /// Pretends everything has been uploaded: a deletion leaves a tombstone.
  Future<void> synced() =>
      db.customStatement("UPDATE event_rows SET google_id = 'g1'");

  ProposalItem item(String title, DateTime start, {int minutes = 60}) =>
      ProposalItem(
        title: title,
        startWall: start,
        endWall: start.add(Duration(minutes: minutes)),
        tzid: bp,
        kind: 'workout',
        hard: false,
        reason: 'jó',
      );

  CalEvent build(ProposalItem it, String id) => CalEvent(
    id: id,
    calendarId: kNaptarCalendar,
    title: it.title,
    start: it.startWall,
    end: it.endWall,
    tzid: it.tzid,
    aiGenerated: true,
  );

  DeletionProposal del(Occurrence o) => DeletionProposal(o, 'kérted');
  MoveProposal mv(Occurrence o, DateTime s, DateTime e) =>
      MoveProposal(o, s, e, 'kérted');

  CalEvent weekly() => evt(
    'm',
    'Edzés',
    floating(2026, 5, 4, 9),
    rrule: 'FREQ=WEEKLY;BYDAY=MO;COUNT=4', // 4., 11., 18., 25. May
  );

  group('applyNew', () {
    test(
      'creates the accepted proposals in one go, with the given ids',
      () async {
        final r = await applyNew(
          repo,
          [
            item('Futás', floating(2026, 5, 5, 18)),
            item('Gym', floating(2026, 5, 6, 18)),
          ],
          ['a', 'b'],
          now: now,
          build: build,
        );
        expect(r.applied, 2);
        expect(r.skipped, isEmpty);
        expect((await repo.byId('a'))!.title, 'Futás');
        expect((await repo.byId('b'))!.title, 'Gym');
        expect(r.changes!.created, {'a', 'b'});
      },
    );

    test('taking it back removes exactly what it created', () async {
      await repo.saveLocal(evt('x', 'Fogorvos', floating(2026, 5, 7, 9)));
      final r = await applyNew(
        repo,
        [item('Futás', floating(2026, 5, 5, 18))],
        ['a'],
        now: now,
        build: build,
      );
      expect(await repo.undoChange(r.changes!), isTrue);
      expect([for (final e in await repo.all()) e.id], ['x']);
    });

    test('a proposal whose time is over by now is left out', () async {
      final r = await applyNew(
        repo,
        [
          item('Reggeli futás', floating(2026, 5, 4, 7)), // over at 08:00
          item('Esti futás', floating(2026, 5, 4, 18)),
        ],
        ['a', 'b'],
        now: now,
        build: build,
      );
      expect(r.applied, 1);
      expect(r.skipped.single.title, 'Reggeli futás');
      expect(r.skipped.single.reason, SkipReason.over);
      expect(await repo.byId('a'), isNull);
      expect(await repo.byId('b'), isNotNull);
    });

    test('one that is half over is still added (it has not ended)', () async {
      final r = await applyNew(
        repo,
        [item('Futás', floating(2026, 5, 4, 9, 30))], // 09:30–10:30, now 10:00
        ['a'],
        now: now,
        build: build,
      );
      expect(r.applied, 1);
    });

    test('a clash with something added meanwhile leaves it out', () async {
      await repo.saveLocal(evt('x', 'Fogorvos', floating(2026, 5, 5, 18)));
      final r = await applyNew(
        repo,
        [
          item('Futás', floating(2026, 5, 5, 18)),
          item('Gym', floating(2026, 5, 6, 18)),
        ],
        ['a', 'b'],
        now: now,
        build: build,
      );
      expect(r.applied, 1);
      expect(r.skipped.single.reason, SkipReason.clash);
      expect(await repo.byId('a'), isNull);
      expect(await repo.byId('b'), isNotNull);
    });

    test(
      'the buffer counts: ten minutes after another event is a clash',
      () async {
        await repo.saveLocal(evt('x', 'Fogorvos', floating(2026, 5, 5, 17)));
        final r = await applyNew(
          repo,
          [
            item('Futás', floating(2026, 5, 5, 18, 10)),
          ], // 10 min after: inside the 15
          ['a'],
          now: now,
          build: build,
        );
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.clash);
      },
    );

    test(
      'an event the user is also deleting does not count as a clash',
      () async {
        await repo.saveLocal(evt('x', 'Fogorvos', floating(2026, 5, 5, 18)));
        final doomed = {occurrenceRef(await occ('Fogorvos'))};
        final r = await applyNew(
          repo,
          [item('Futás', floating(2026, 5, 5, 18))],
          ['a'],
          now: now,
          build: build,
          doomed: doomed,
        );
        expect(r.applied, 1);
      },
    );

    test(
      'nothing is created, and nothing described, when all are left out',
      () async {
        final r = await applyNew(
          repo,
          [item('Reggeli futás', floating(2026, 5, 4, 7))],
          ['a'],
          now: now,
          build: build,
        );
        expect(r.applied, 0);
        expect(r.changes, isNull);
        expect(await repo.all(), isEmpty);
      },
    );

    test(
      'all or nothing: a failing write leaves none of them behind',
      () async {
        final flaky = _Flaky(db, failOnSave: 2);
        await expectLater(
          applyNew(
            flaky,
            [
              item('Egy', floating(2026, 5, 5, 8)),
              item('Kettő', floating(2026, 5, 6, 8)),
              item('Három', floating(2026, 5, 7, 8)),
            ],
            ['a', 'b', 'c'],
            now: now,
            build: build,
          ),
          throwsStateError,
        );
        expect(await repo.all(), isEmpty);
        expect(await repo.pending(), isEmpty);
      },
    );
  });

  group('applyDeletions', () {
    test(
      'deletes the events and describes it so it can be taken back',
      () async {
        await repo.saveAll([
          evt('a', 'Fogorvos', floating(2026, 5, 5, 9)),
          evt('b', 'Edzés', floating(2026, 5, 6, 9)),
        ]);
        final r = await applyDeletions(repo, [
          del(await occ('Fogorvos')),
          del(await occ('Edzés')),
        ], {});
        expect(r.applied, 2);
        expect(r.skipped, isEmpty);
        expect(await repo.all(), isEmpty);
        // one change set for the whole card: one "Visszavonás"
        expect(await repo.undoChange(r.changes!), isTrue);
        expect([for (final e in await repo.all()) e.id]..sort(), ['a', 'b']);
      },
    );

    test(
      'an event that is gone meanwhile is left out, not "deleted again"',
      () async {
        await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
        final proposal = del(await occ('Fogorvos'));
        await repo.deleteLocal('a');
        final r = await applyDeletions(repo, [proposal], {});
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.gone);
        expect(r.changes, isNull);
      },
    );

    test(
      'a deletion that has not been uploaded yet is not brought back',
      () async {
        await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
        await synced();
        final proposal = del(await occ('Fogorvos'));
        await repo.deleteLocal('a');
        expect(await repo.isTombstone('a'), isTrue);
        final r = await applyDeletions(repo, [proposal], {});
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.gone);
        // still just the tombstone: the queued deletion is untouched
        expect(await repo.isTombstone('a'), isTrue);
        expect(await repo.all(), isEmpty);
        expect((await repo.pending()).single.op, 'delete');
      },
    );

    test('an event renamed meanwhile is left alone', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final proposal = del(await occ('Fogorvos'));
      await repo.saveLocal(
        (await repo.byId('a'))!.copyWith(title: 'Fogorvos (lemondva)'),
      );
      final r = await applyDeletions(repo, [proposal], {});
      expect(r.applied, 0);
      expect(r.skipped.single.reason, SkipReason.changed);
      expect((await repo.byId('a'))!.title, 'Fogorvos (lemondva)');
    });

    test('an event moved meanwhile is left alone', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final proposal = del(await occ('Fogorvos'));
      await repo.saveLocal(
        (await repo.byId('a'))!.copyWith(
          start: floating(2026, 5, 5, 15),
          end: floating(2026, 5, 5, 16),
        ),
      );
      final r = await applyDeletions(repo, [proposal], {});
      expect(r.applied, 0);
      expect(await repo.byId('a'), isNotNull);
    });

    test(
      'a series that became a single event meanwhile is left alone',
      () async {
        await repo.saveLocal(weekly());
        // (the first day is the one that is still there as a single event)
        final proposal = del(await occ('Edzés', day: 4));
        await repo.saveLocal(
          (await repo.byId('m'))!.copyWith(clearRrule: true),
        );
        final r = await applyDeletions(repo, [proposal], {});
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.changed);
        expect(await repo.byId('m'), isNotNull);
      },
    );

    test('a day of a series that is gone meanwhile is left out', () async {
      await repo.saveLocal(weekly());
      final proposal = del(await occ('Edzés', day: 11));
      await repo.saveLocal((await repo.byId('m'))!.copyWith(clearRrule: true));
      final r = await applyDeletions(repo, [proposal], {});
      expect(r.applied, 0);
      expect(r.skipped.single.reason, SkipReason.gone);
      expect(await repo.byId('m'), isNotNull);
    });

    test('a recurring event goes by the scope of its line', () async {
      await repo.saveLocal(weekly());
      final r = await applyDeletions(
        repo,
        [del(await occ('Edzés', day: 11))],
        {0: Scope.following},
      );
      expect(r.applied, 1);
      expect(await days(), [4]);
    });

    test('with no scope chosen only that day goes', () async {
      await repo.saveLocal(weekly());
      await applyDeletions(repo, [del(await occ('Edzés', day: 11))], {});
      expect(await days(), [4, 18, 25]);
    });

    test(
      'the second line of a series the first one took away is not "left out"',
      () async {
        await repo.saveLocal(weekly());
        final r = await applyDeletions(
          repo,
          [del(await occ('Edzés', day: 11)), del(await occ('Edzés', day: 18))],
          {0: Scope.following},
        );
        expect(r.applied, 1);
        expect(r.skipped, isEmpty);
        expect(await days(), [4]);
      },
    );

    test(
      'two lines on one series are one change: one undo brings both back',
      () async {
        await repo.saveLocal(weekly());
        final r = await applyDeletions(repo, [
          del(await occ('Edzés', day: 11)),
          del(await occ('Edzés', day: 18)),
        ], {});
        expect(r.applied, 2);
        expect(await days(), [4, 25]);
        expect(await repo.undoChange(r.changes!), isTrue);
        expect(await days(), [4, 11, 18, 25]);
      },
    );

    test('pressing it twice deletes once: the second finds nothing', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final proposals = [del(await occ('Fogorvos'))];
      final first = await applyDeletions(repo, proposals, {});
      final second = await applyDeletions(repo, proposals, {});
      expect((first.applied, second.applied), (1, 0));
      expect(second.skipped.single.reason, SkipReason.gone);
    });

    test(
      'all or nothing: a failing write leaves the others untouched',
      () async {
        await repo.saveAll([
          evt('a', 'Egy', floating(2026, 5, 5, 9)),
          evt('b', 'Kettő', floating(2026, 5, 6, 9)),
        ]);
        final proposals = [del(await occ('Egy')), del(await occ('Kettő'))];
        final flaky = _Flaky(db, failOnDelete: 2);
        await expectLater(
          applyDeletions(flaky, proposals, {}),
          throwsStateError,
        );
        expect([for (final e in await repo.all()) e.id]..sort(), ['a', 'b']);
      },
    );
  });

  group('applyMoves', () {
    test('moves an event and describes it so it can be taken back', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final r = await applyMoves(repo, [
        mv(
          await occ('Fogorvos'),
          floating(2026, 5, 5, 19),
          floating(2026, 5, 5, 20),
        ),
      ]);
      expect(r.applied, 1);
      expect((await repo.byId('a'))!.start, floating(2026, 5, 5, 19));
      expect(await repo.undoChange(r.changes!), isTrue);
      expect((await repo.byId('a'))!.start, floating(2026, 5, 5, 9));
    });

    test(
      'an event deleted meanwhile is NOT brought back by the move',
      () async {
        await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
        await synced();
        final proposal = mv(
          await occ('Fogorvos'),
          floating(2026, 5, 5, 19),
          floating(2026, 5, 5, 20),
        );
        await repo.deleteLocal(
          'a',
        ); // uploaded earlier: only a tombstone is left
        final r = await applyMoves(repo, [proposal]);
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.gone);
        expect(await repo.isTombstone('a'), isTrue);
        expect(await repo.all(), isEmpty);
      },
    );

    test('an event renamed meanwhile is left alone', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final proposal = mv(
        await occ('Fogorvos'),
        floating(2026, 5, 5, 19),
        floating(2026, 5, 5, 20),
      );
      await repo.saveLocal((await repo.byId('a'))!.copyWith(title: 'Másik'));
      final r = await applyMoves(repo, [proposal]);
      expect(r.applied, 0);
      expect(r.skipped.single.reason, SkipReason.changed);
      expect((await repo.byId('a'))!.start, floating(2026, 5, 5, 9));
    });

    test(
      'a new time that clashes with something in the calendar now is refused',
      () async {
        await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
        final proposal = mv(
          await occ('Fogorvos'),
          floating(2026, 5, 5, 19),
          floating(2026, 5, 5, 20),
        );
        await repo.saveLocal(evt('x', 'Tárgyalás', floating(2026, 5, 5, 19)));
        final r = await applyMoves(repo, [proposal]);
        expect(r.applied, 0);
        expect(r.skipped.single.reason, SkipReason.clash);
        expect((await repo.byId('a'))!.start, floating(2026, 5, 5, 9));
      },
    );

    test('a move that overlaps its own old time is no clash', () async {
      await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
      final r = await applyMoves(repo, [
        mv(
          await occ('Fogorvos'),
          floating(2026, 5, 5, 9, 30),
          floating(2026, 5, 5, 10, 30),
        ),
      ]);
      expect(r.applied, 1);
      expect((await repo.byId('a'))!.start, floating(2026, 5, 5, 9, 30));
    });

    test(
      'an event the user is also deleting does not count as a clash',
      () async {
        await repo.saveAll([
          evt('a', 'Fogorvos', floating(2026, 5, 5, 9)),
          evt('x', 'Tárgyalás', floating(2026, 5, 5, 19)),
        ]);
        final r = await applyMoves(
          repo,
          [
            mv(
              await occ('Fogorvos'),
              floating(2026, 5, 5, 19),
              floating(2026, 5, 5, 20),
            ),
          ],
          doomed: {occurrenceRef(await occ('Tárgyalás'))},
        );
        expect(r.applied, 1);
      },
    );

    test(
      'two moves to the same time: the second finds the first there',
      () async {
        await repo.saveAll([
          evt('a', 'Egy', floating(2026, 5, 5, 9)),
          evt('b', 'Kettő', floating(2026, 5, 6, 9)),
        ]);
        final r = await applyMoves(repo, [
          mv(
            await occ('Egy'),
            floating(2026, 5, 7, 19),
            floating(2026, 5, 7, 20),
          ),
          mv(
            await occ('Kettő'),
            floating(2026, 5, 7, 19),
            floating(2026, 5, 7, 20),
          ),
        ]);
        expect(r.applied, 1);
        expect(r.skipped.single.title, 'Kettő');
        expect(r.skipped.single.reason, SkipReason.clash);
      },
    );

    test(
      'one day of a series gets an exception row of its own, and only one',
      () async {
        await repo.saveLocal(weekly());
        final proposal = mv(
          await occ('Edzés', day: 11),
          floating(2026, 5, 11, 19),
          floating(2026, 5, 11, 20),
        );
        final first = await applyMoves(repo, [proposal]);
        expect(first.applied, 1);
        expect((await repo.overridesOf('m')).length, 1);
        // pressed again: the day is not where the card says any more
        final second = await applyMoves(repo, [proposal]);
        expect(second.applied, 0);
        expect((await repo.overridesOf('m')).length, 1);
        // taken back: the exception row goes, the day is where it was
        expect(await repo.undoChange(first.changes!), isTrue);
        expect((await repo.overridesOf('m')), isEmpty);
        final o = await occ('Edzés', day: 11);
        expect(toWallClock(bp, o.startUtc), floating(2026, 5, 11, 9));
      },
    );
  });

  group('moveOccurrence', () {
    test('returns null for an event that is not there', () async {
      final o = Occurrence(
        eventId: 'nincs',
        title: 'x',
        startUtc: DateTime.utc(2026, 5, 5, 7),
        endUtc: DateTime.utc(2026, 5, 5, 8),
        originalStart: floating(2026, 5, 5, 9),
        allDay: false,
      );
      expect(
        await moveOccurrence(
          repo,
          o,
          floating(2026, 5, 5, 10),
          floating(2026, 5, 5, 11),
        ),
        isNull,
      );
    });

    test(
      'returns null for a deleted event and leaves the tombstone alone',
      () async {
        await repo.saveLocal(evt('a', 'Fogorvos', floating(2026, 5, 5, 9)));
        await synced();
        final o = await occ('Fogorvos');
        await repo.deleteLocal('a');
        expect(
          await moveOccurrence(
            repo,
            o,
            floating(2026, 5, 5, 10),
            floating(2026, 5, 5, 11),
          ),
          isNull,
        );
        expect(await repo.isTombstone('a'), isTrue);
      },
    );

    test('moving an existing exception row changes that row', () async {
      await repo.saveLocal(weekly());
      await repo.saveLocal(
        makeOverride(
          master: weekly(),
          originalStart: floating(2026, 5, 11, 9),
          edited: weekly().copyWith(
            title: 'Máskor',
            start: floating(2026, 5, 11, 12),
            end: floating(2026, 5, 11, 13),
          ),
          newId: 'x',
        ),
      );
      final o = await occ('Máskor');
      final c = await moveOccurrence(
        repo,
        o,
        floating(2026, 5, 11, 15),
        floating(2026, 5, 11, 16),
      );
      expect(c!.before.single.id, 'x');
      expect((await repo.byId('x'))!.start, floating(2026, 5, 11, 15));
      expect((await repo.overridesOf('m')).length, 1);
    });
  });

  group('skippedNotice', () {
    test('says nothing when nothing was left out', () {
      expect(skippedNotice(const []), isNull);
    });

    test('groups the titles by reason', () {
      final text = skippedNotice(const [
        Skipped('Fogorvos', SkipReason.gone),
        Skipped('Edzés', SkipReason.changed),
        Skipped('Gym', SkipReason.gone),
      ])!;
      expect(
        text,
        contains(
          'Kimaradt, mert közben eltűnt vagy elmozdult: „Fogorvos”, „Gym”.',
        ),
      );
      expect(text, contains('Kimaradt, mert közben megváltozott: „Edzés”.'));
    });

    test('keeps it short: four titles at most, long titles cut', () {
      final text = skippedNotice([
        for (var i = 1; i <= 6; i++) Skipped('Edzés $i', SkipReason.clash),
        Skipped('H' * 80, SkipReason.over),
      ])!;
      expect(text, contains('„Edzés 4”'));
      expect(text, isNot(contains('Edzés 5')));
      expect(text, contains('és még 2'));
      expect(text, contains('${'H' * 39}…'));
      expect(text, isNot(contains('H' * 40)));
    });
  });
}
