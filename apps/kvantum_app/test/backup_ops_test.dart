import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/backup_ops.dart';
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

  CalEvent at(String id, String title, int day) =>
      evt(id, title, floating(2026, 11, day, 9));

  Future<String> backupOf(List<CalEvent> events) async {
    await repo.saveAll(events);
    return exportBackup(repo);
  }

  group('preview: nothing is written, the difference is worked out', () {
    test('new, changed and unchanged events are told apart', () async {
      final text = await backupOf([
        at('a', 'Régi', 2),
        at('b', 'Változatlan', 3),
        at('c', 'Töröltem', 4),
      ]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      await repo.deleteLocal('c');

      final before = await repo.all();
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh.map((e) => e.id), ['c']);
      expect(plan.changes.map((c) => c.current.title), ['Átírt']);
      expect(plan.changes.single.incoming.title, 'Régi');
      expect(plan.unchanged, 1);
      expect(plan.empty, isFalse);
      expect(
        (await repo.all()).map((e) => '${e.id}:${e.title}').toSet(),
        before.map((e) => '${e.id}:${e.title}').toSet(),
        reason: 'a preview writes nothing',
      );
    });

    group('the same series in another spelling is not a change', () {
      // The rule editor writes the limit of a series as the end of a day
      // (…T235959Z). The file carries the UTC instant of the LAST occurrence,
      // and that reads back as the wall-clock time of that occurrence
      // (…T090000Z): the same series, spelled differently.
      test('a backup of the device itself shows no change', () async {
        final text = await backupOf([
          evt(
            's',
            'Edzés',
            floating(2026, 11, 2, 9),
            rrule: 'FREQ=DAILY;UNTIL=20261106T235959Z',
          ),
        ]);
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes, isEmpty);
        expect(plan.unchanged, 1);
      });

      test('an all-day series is told the same way', () async {
        final text = await backupOf([
          evt(
            'd',
            'Szabi',
            floating(2026, 11, 2),
            allDay: true,
            len: const Duration(days: 1),
            rrule: 'FREQ=DAILY;UNTIL=20261106T235959Z',
          ),
        ]);
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes, isEmpty);
        expect(plan.unchanged, 1);
      });

      test(
        'a limit that lets the same days through is the same series',
        () async {
          final text = await backupOf([
            evt(
              's',
              'Edzés',
              floating(2026, 11, 2, 9),
              rrule: 'FREQ=DAILY;UNTIL=20261106T235959Z',
            ),
          ]);
          // the same five days (the last one is the 6th at 09:00), the limit
          // written as an hour after it
          await repo.saveLocal(
            evt(
              's',
              'Edzés',
              floating(2026, 11, 2, 9),
              rrule: 'FREQ=DAILY;UNTIL=20261106T100000Z',
            ),
          );
          final plan = await previewBackup(
            repo,
            text,
            calendarId: kNaptarCalendar,
          );
          expect(plan.changes, isEmpty);
        },
      );

      test('a limit that lets other days through IS a change', () async {
        final text = await backupOf([
          evt(
            's',
            'Edzés',
            floating(2026, 11, 2, 9),
            rrule: 'FREQ=DAILY;UNTIL=20261106T235959Z',
          ),
        ]);
        await repo.saveLocal(
          evt(
            's',
            'Edzés',
            floating(2026, 11, 2, 9),
            rrule: 'FREQ=DAILY;UNTIL=20261108T235959Z',
          ),
        );
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes.map((c) => c.current.id), ['s']);
      });

      test('a rule the engine refuses is compared as plain text', () async {
        final bad = evt(
          'x',
          'Rossz szabály',
          floating(2026, 11, 2, 9),
          rrule: 'FREQ=SOMETIMES;UNTIL=20261106T235959Z',
        );
        final text = await backupOf([bad]);
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        // it must not throw; the series cannot be shown to be the same
        expect(plan.fresh, isEmpty);
        expect(plan.changes.length + plan.unchanged, 1);
      });
    });

    test('an occurrence the file says is cancelled is a change', () async {
      final master = evt(
        'm',
        'Edzés',
        floating(2026, 11, 2, 9),
        rrule: 'FREQ=DAILY;COUNT=5',
      );
      final moved = CalEvent(
        id: 'o',
        calendarId: kNaptarCalendar,
        title: 'Edzés',
        tzid: bp,
        start: floating(2026, 11, 3, 18),
        end: floating(2026, 11, 3, 19),
        recurringEventId: 'm',
        originalStart: floating(2026, 11, 3, 9),
      );
      await repo.saveAll([master, moved]);
      // the same file as the device's own, except that the moved occurrence is
      // cancelled in it (an Outlook file keeps such rows)
      final text = await exportBackup(repo);
      final cancelled = text.replaceFirst(
        'X-NAPTAR-ID:o',
        'X-NAPTAR-ID:o\r\nSTATUS:CANCELLED',
      );
      expect(cancelled, isNot(text));
      final plan = await previewBackup(
        repo,
        cancelled,
        calendarId: kNaptarCalendar,
      );
      // the moved occurrence is cancelled in the file, and with it a day of
      // the series is gone there: both differ from the device
      expect(
        plan.changes.map((c) => c.current.id),
        unorderedEquals(['m', 'o']),
      );
      expect(
        plan.changes.singleWhere((c) => c.current.id == 'o').incoming.cancelled,
        isTrue,
      );
      // and the device's own file shows no change at all
      final same = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(same.changes, isEmpty);
    });

    group('a day of a series that is gone is gone in either spelling', () {
      // A cancelled occurrence of a series (what Google sends when one day is
      // deleted there) is a row of its own on the device; a file writes it as an
      // EXDATE of the series. Both say: that day is gone.
      CalEvent master({List<DateTime> gone = const []}) => evt(
        'm',
        'Edzés',
        floating(2026, 11, 2, 9),
        rrule: 'FREQ=DAILY;COUNT=5',
      ).copyWith(exdates: gone);

      CalEvent cancelledDay(int day) => CalEvent(
        id: 'c$day',
        calendarId: kNaptarCalendar,
        title: 'Edzés',
        tzid: bp,
        start: floating(2026, 11, day, 9),
        end: floating(2026, 11, day, 10),
        recurringEventId: 'm',
        originalStart: floating(2026, 11, day, 9),
        cancelled: true,
      );

      test('the device\'s own backup shows no change', () async {
        await repo.saveAll([master(), cancelledDay(4)]);
        final text = await exportBackup(repo);
        expect(text, contains('EXDATE;TZID=Europe/Budapest:20261104T090000'));
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes, isEmpty);
        expect(plan.fresh, isEmpty);
        expect(plan.unchanged, 1);
      });

      test(
        'one day gone as an EXDATE, one as a cancelled row: the same',
        () async {
          await repo.saveAll([
            master(gone: [floating(2026, 11, 3, 9)]),
            cancelledDay(4),
          ]);
          final plan = await previewBackup(
            repo,
            await exportBackup(repo),
            calendarId: kNaptarCalendar,
          );
          expect(plan.changes, isEmpty);
        },
      );

      test('a day gone only in the file IS a change', () async {
        await repo.saveAll([master(), cancelledDay(4)]);
        final text = (await exportBackup(repo)).replaceFirst(
          'EXDATE;TZID=Europe/Budapest:20261104T090000',
          'EXDATE;TZID=Europe/Budapest:20261104T090000\r\n'
              'EXDATE;TZID=Europe/Budapest:20261105T090000',
        );
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes.map((c) => c.current.id), ['m']);
      });

      test('a day gone only on the device IS a change', () async {
        await repo.saveAll([master(), cancelledDay(4)]);
        final text = await exportBackup(repo);
        await repo.saveLocal(cancelledDay(5));
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes.map((c) => c.current.id), ['m']);
      });
    });

    test('junk gives an empty plan and the reasons', () async {
      final plan = await previewBackup(
        repo,
        'ez nem naptár',
        calendarId: kNaptarCalendar,
      );
      expect(plan.empty, isTrue);
    });
  });

  group('apply', () {
    test('without overwrite only the new events are written', () async {
      final text = await backupOf([at('a', 'Régi', 2), at('c', 'Törölt', 4)]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      await repo.deleteLocal('c');
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);

      final r = await applyBackup(repo, plan, overwrite: false);
      expect((r.added, r.updated, r.kept), (1, 0, 1));
      expect((await repo.byId('a'))!.title, 'Átírt');
      expect(await repo.byId('c'), isNotNull);
    });

    test(
      'with overwrite the changed event is restored with its link',
      () async {
        final text = await backupOf([at('a', 'Régi', 2)]);
        final linked = (await repo.byId('a'))!.copyWith(
          title: 'Átírt',
          googleId: 'g-1',
          etag: 'e-1',
          iCalUid: 'u-1',
        );
        await repo.saveLocal(linked);
        final stored = (await repo.byId('a'))!;
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );

        final r = await applyBackup(repo, plan, overwrite: true);
        expect((r.added, r.updated, r.kept), (0, 1, 0));
        final e = (await repo.byId('a'))!;
        expect(e.title, 'Régi');
        expect((e.googleId, e.etag, e.iCalUid), ('g-1', 'e-1', 'u-1'));
        expect(e.version, greaterThan(stored.version));
        expect(
          await repo.pendingOps(),
          containsPair('a', 'upsert'),
          reason: 'the restored event goes up to Google',
        );
      },
    );

    test('a second restore of the same file changes nothing', () async {
      final text = await backupOf([at('a', 'Régi', 2)]);
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh, isEmpty);
      expect(plan.changes, isEmpty);
      expect(plan.unchanged, 1);
    });

    test('importBackup needs an explicit decision', () async {
      final text = await backupOf([at('a', 'Régi', 2)]);
      await repo.saveLocal(at('a', 'Átírt', 2));
      final kept = await importBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        overwrite: false,
      );
      expect(kept.kept, 1);
      expect((await repo.byId('a'))!.title, 'Átírt');
    });
  });

  group('large files are read away from the screen thread', () {
    test('the runner is used above the threshold only', () async {
      final text = exportIcs([at('a', 'Régi', 2)]);
      var runs = 0;
      Future<IcsImport> runner(IcsImport Function() job) {
        runs++;
        return Future.value(job());
      }

      await previewBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        threshold: text.length,
        runner: runner,
      );
      expect(runs, 0, reason: 'at the threshold it is read in place');
      await previewBackup(
        repo,
        text,
        calendarId: kNaptarCalendar,
        threshold: text.length - 1,
        runner: runner,
      );
      expect(runs, 1);
    });

    test('a really large file is read on an isolate, to the end', () async {
      final events = [
        for (var i = 0; i < 1500; i++) at('e$i', 'Esemény $i', 5),
      ];
      final text = exportIcs(events);
      expect(text.length, greaterThan(isolateParseThreshold));
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.fresh, hasLength(1500));
      expect(plan.fresh.last.title, 'Esemény 1499');
    });
  });
}
