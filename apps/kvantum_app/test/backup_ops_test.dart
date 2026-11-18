import 'dart:io';

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

      test('a rule stored with its RRULE: prefix is the same series', () async {
        final text = await backupOf([
          evt(
            'p',
            'Edzés',
            floating(2026, 11, 2, 9),
            rrule: 'RRULE:FREQ=DAILY;UNTIL=20261106T235959Z',
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
        'so is one the engine refuses: the prefix is not what differs',
        () async {
          final text = await backupOf([
            evt(
              'q',
              'Rossz szabály',
              floating(2026, 11, 2, 9),
              rrule: 'RRULE:FREQ=SOMETIMES',
            ),
          ]);
          final plan = await previewBackup(
            repo,
            text,
            calendarId: kNaptarCalendar,
          );
          expect(plan.changes, isEmpty);
          expect(plan.unchanged, 1);
        },
      );

      test('a refused rule that nothing shifts (UTC) is the same without the '
          'prefix too', () async {
        // UNTIL together with COUNT is refused by the engine, so the rule is
        // compared as text; in UTC no limit is moved on the way to the file and
        // back, so the two texts can be equal at all
        final text = await backupOf([
          evt(
            'u',
            'UTC-esemény',
            floating(2026, 11, 2, 9),
            rrule: 'RRULE:FREQ=DAILY;UNTIL=20261106T235959Z;COUNT=3',
          ).copyWith(tzid: 'UTC'),
        ]);
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.changes, isEmpty);
        expect(plan.unchanged, 1);
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

    group('a file from Google, for a calendar that is on the device', () {
      // The UID a Google file carries for an event is what the device keeps as
      // the iCalUID of that same event; the device's own id is another one.
      String file(String body) =>
          'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$body'
          'END:VCALENDAR\r\n';
      String vevent({
        required String uid,
        required String title,
        String start = '20261120T090000',
        String end = '20261120T100000',
        String extra = '',
      }) =>
          'BEGIN:VEVENT\r\nUID:$uid\r\n'
          'DTSTART;TZID=Europe/Budapest:$start\r\n'
          'DTEND;TZID=Europe/Budapest:$end\r\n$extra'
          'SUMMARY:$title\r\nEND:VEVENT\r\n';

      CalEvent pulled(String id, String title, String uid, {String? rrule}) =>
          evt(
            id,
            title,
            floating(2026, 11, 20, 9),
            rrule: rrule,
          ).copyWith(iCalUid: uid, googleId: 'g-$id', etag: 'e-$id');

      test('an event the device has under another id is not new', () async {
        await repo.saveLocal(pulled('L1', 'Fogorvos', 'gid1@google.com'));
        final plan = await previewBackup(
          repo,
          file(vevent(uid: 'gid1@google.com', title: 'Fogorvos')),
          calendarId: kNaptarCalendar,
        );
        expect(plan.fresh, isEmpty);
        expect(plan.changes, isEmpty);
        expect(plan.unchanged, 1);
      });

      test('a change to it is a change of THAT event, and a restore does not '
          'make a second one', () async {
        await repo.saveLocal(pulled('L1', 'Fogorvos', 'gid1@google.com'));
        final plan = await previewBackup(
          repo,
          file(vevent(uid: 'gid1@google.com', title: 'Fogorvos (új helyen)')),
          calendarId: kNaptarCalendar,
        );
        expect(plan.fresh, isEmpty);
        expect(plan.changes.map((c) => c.current.id), ['L1']);
        expect(plan.changes.single.incoming.id, 'L1');
        await applyBackup(repo, plan, overwrite: true);
        final all = await repo.all();
        expect(all.map((e) => e.id), ['L1']);
        expect(all.single.title, 'Fogorvos (új helyen)');
        expect(all.single.googleId, 'g-L1', reason: 'the link is kept');
      });

      test('two moved days of one series are two events, not one', () async {
        await repo.saveLocal(
          pulled('L1', 'Edzés', 'gid2@google.com', rrule: 'FREQ=DAILY;COUNT=5'),
        );
        final plan = await previewBackup(
          repo,
          file(
            vevent(
                  uid: 'gid2@google.com',
                  title: 'Edzés',
                  extra: 'RRULE:FREQ=DAILY;COUNT=5\r\n',
                ) +
                vevent(
                  uid: 'gid2@google.com',
                  title: 'Edzés (korán)',
                  start: '20261121T070000',
                  end: '20261121T080000',
                  extra:
                      'RECURRENCE-ID;TZID=Europe/Budapest:20261121T090000\r\n',
                ) +
                vevent(
                  uid: 'gid2@google.com',
                  title: 'Edzés (későn)',
                  start: '20261123T190000',
                  end: '20261123T200000',
                  extra:
                      'RECURRENCE-ID;TZID=Europe/Budapest:20261123T090000\r\n',
                ),
          ),
          calendarId: kNaptarCalendar,
        );
        expect(
          {for (final e in plan.fresh) e.id},
          {'L1#2026-11-21T09:00:00.000Z', 'L1#2026-11-23T09:00:00.000Z'},
        );
      });

      test('a moved day is matched with the row of ITS series, not of another '
          'with the same original day', () async {
        // two series, each with its moved day from the same original day; the
        // device lists the row of the other series first
        await repo.saveAll([
          pulled('L2', 'Másik', 'gid3@google.com', rrule: 'FREQ=DAILY;COUNT=5'),
          CalEvent(
            id: 'X0',
            calendarId: kNaptarCalendar,
            title: 'Másik (áthelyezve)',
            tzid: bp,
            start: floating(2026, 11, 21, 7),
            end: floating(2026, 11, 21, 8),
            recurringEventId: 'L2',
            originalStart: floating(2026, 11, 21, 9),
          ),
          pulled('L1', 'Edzés', 'gid2@google.com', rrule: 'FREQ=DAILY;COUNT=5'),
          CalEvent(
            id: 'X1',
            calendarId: kNaptarCalendar,
            title: 'Edzés (áthelyezve)',
            tzid: bp,
            start: floating(2026, 11, 21, 18),
            end: floating(2026, 11, 21, 19),
            recurringEventId: 'L1',
            originalStart: floating(2026, 11, 21, 9),
          ),
        ]);
        String series(String uid, String title) => vevent(
          uid: uid,
          title: title,
          extra: 'RRULE:FREQ=DAILY;COUNT=5\r\n',
        );
        String moved(String uid, String title, String s, String e) => vevent(
          uid: uid,
          title: title,
          start: s,
          end: e,
          extra: 'RECURRENCE-ID;TZID=Europe/Budapest:20261121T090000\r\n',
        );
        final plan = await previewBackup(
          repo,
          file(
            series('gid2@google.com', 'Edzés') +
                series('gid3@google.com', 'Másik') +
                moved(
                  'gid2@google.com',
                  'Edzés (áthelyezve)',
                  '20261121T180000',
                  '20261121T190000',
                ) +
                moved(
                  'gid3@google.com',
                  'Másik (áthelyezve)',
                  '20261121T070000',
                  '20261121T080000',
                ),
          ),
          calendarId: kNaptarCalendar,
        );
        expect(plan.fresh, isEmpty);
        expect(plan.changes, isEmpty);
        expect(plan.unchanged, 4);
      });

      test('a moved occurrence of its series stays with the series', () async {
        await repo.saveAll([
          pulled('L1', 'Edzés', 'gid2@google.com', rrule: 'FREQ=DAILY;COUNT=5'),
          CalEvent(
            id: 'X1',
            calendarId: kNaptarCalendar,
            title: 'Edzés (áthelyezve)',
            tzid: bp,
            start: floating(2026, 11, 21, 18),
            end: floating(2026, 11, 21, 19),
            recurringEventId: 'L1',
            originalStart: floating(2026, 11, 21, 9),
          ),
        ]);
        final text = file(
          vevent(
                uid: 'gid2@google.com',
                title: 'Edzés',
                extra: 'RRULE:FREQ=DAILY;COUNT=5\r\n',
              ) +
              // the moved one, as the device has it
              vevent(
                uid: 'gid2@google.com',
                title: 'Edzés (áthelyezve)',
                start: '20261121T180000',
                end: '20261121T190000',
                extra: 'RECURRENCE-ID;TZID=Europe/Budapest:20261121T090000\r\n',
              ) +
              // and one more, that the device does not have
              vevent(
                uid: 'gid2@google.com',
                title: 'Edzés (korábban)',
                start: '20261123T070000',
                end: '20261123T080000',
                extra: 'RECURRENCE-ID;TZID=Europe/Budapest:20261123T090000\r\n',
              ),
        );
        final plan = await previewBackup(
          repo,
          text,
          calendarId: kNaptarCalendar,
        );
        expect(plan.unchanged, 2, reason: 'the series and the moved day');
        final fresh = plan.fresh.single;
        expect(fresh.title, 'Edzés (korábban)');
        expect(fresh.recurringEventId, 'L1', reason: 'the device calls it L1');
        expect(
          fresh.id,
          'L1#2026-11-23T09:00:00.000Z',
          reason: 'a moved day the device does not have is named by its day',
        );
        await applyBackup(repo, plan, overwrite: false);
        final all = await repo.all();
        expect(all.length, 3);
        expect(all.where((e) => e.isException).map((e) => e.recurringEventId), [
          'L1',
          'L1',
        ]);
      });
    });

    test('the Google sample: a device that has these events has nothing new '
        'but the moved day of a series that is nowhere', () async {
      final text = File(
        '../../packages/kvantum_core/test/fixtures/ics/google_export.ics',
      ).readAsStringSync();
      final masters = parseIcs(
        text,
        calendarId: kNaptarCalendar,
      ).events.where((e) => !e.isException).toList();
      // the device has them the way a sync from Google gives them: under its
      // own ids, with the UID of the file as their iCalUID
      await repo.saveAll([
        for (var i = 0; i < masters.length; i++)
          masters[i].copyWith(
            id: 'L$i',
            iCalUid: masters[i].id,
            googleId: 'g$i',
          ),
      ]);
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      expect(plan.changes, isEmpty);
      expect(plan.unchanged, masters.length);
      expect(plan.fresh.map((e) => e.title), [
        'Átrakott alkalom (a sorozata nincs a fájlban)',
      ]);
      expect(plan.fresh.single.isException, isFalse);
      // (two more lines about what the app does not take over: RDATE, the UTC series)
      expect(plan.problems.length, 3);
    });

    group('a moved day whose series is nowhere is an event of its own', () {
      CalEvent? only(ImportPlan p) => p.fresh.singleOrNull;
      const orphan =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:nowhere@example.com\r\n'
          'RECURRENCE-ID;TZID=Europe/Budapest:20261125T090000\r\n'
          'DTSTART;TZID=Europe/Budapest:20261125T143000\r\n'
          'DTEND;TZID=Europe/Budapest:20261125T153000\r\n'
          'SUMMARY:Átrakott alkalom\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

      test('it is taken over as a single event, and it says so', () async {
        final plan = await previewBackup(
          repo,
          orphan,
          calendarId: kNaptarCalendar,
        );
        final e = only(plan)!;
        expect(e.title, 'Átrakott alkalom');
        expect(e.isException, isFalse);
        expect(e.originalStart, isNull);
        expect(e.start, floating(2026, 11, 25, 14, 30));
        expect(plan.problems, [
          allOf(contains('Átrakott alkalom'), contains('önálló esemény')),
        ]);
        await applyBackup(repo, plan, overwrite: false);
        // and it is seen: it is on the calendar
        final occ = await repo.occurrences(
          DateTime.utc(2026, 11, 25),
          DateTime.utc(2026, 11, 26),
        );
        expect(occ.map((o) => o.title), ['Átrakott alkalom']);
      });

      test('a series that IS on the device keeps its moved day', () async {
        await repo.saveLocal(
          evt(
            'nowhere@example.com',
            'Edzés',
            floating(2026, 11, 2, 9),
            rrule: 'FREQ=DAILY;COUNT=30',
          ),
        );
        final plan = await previewBackup(
          repo,
          orphan,
          calendarId: kNaptarCalendar,
        );
        final e = only(plan)!;
        expect(e.recurringEventId, 'nowhere@example.com');
        expect(e.originalStart, floating(2026, 11, 25, 9));
        expect(plan.problems, isEmpty);
      });

      test('a cancelled day of a series that is nowhere is left out', () async {
        final plan = await previewBackup(
          repo,
          orphan.replaceFirst(
            'SUMMARY:Átrakott alkalom',
            'STATUS:CANCELLED\r\nSUMMARY:Átrakott alkalom',
          ),
          calendarId: kNaptarCalendar,
        );
        expect(plan.fresh, isEmpty);
        expect(plan.empty, isTrue);
        expect(plan.problems, [
          allOf(contains('Átrakott alkalom'), contains('lemondott')),
        ]);
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
