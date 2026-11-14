import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/backup_ops.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/google/google_calendar_remote.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_engine.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/google_fake.dart';
import 'support/harness.dart' show newDb;

// The samples in test/fixtures/google are written by hand, after what the
// Google Calendar API's `events.list` answers with (see the README there):
// every field a real answer has, with the exact types and shapes of the API.
// They are NOT recordings of real answers. Each expectation below was worked
// out by hand from the sample text.

const bp = 'Europe/Budapest';

Map<String, dynamic> sample(String name) =>
    jsonDecode(File('test/fixtures/google/$name').readAsStringSync())
        as Map<String, dynamic>;

FakeGoogle serving(String name) => FakeGoogle((r) => jsonResp(sample(name)));

Future<PullResult> pull(FakeGoogle f) =>
    GoogleCalendarRemote(f.client).pull('primary', null);

Map<String, RemoteChange> byGoogleId(PullResult r) => {
  for (final c in r.changes) c.ref.googleId: c,
};

/// A remote that only listens: everything it is given comes from the sample,
/// and nothing may be written back.
class PullOnly implements RemoteCalendar {
  PullOnly(this.inner);
  final RemoteCalendar inner;

  @override
  Future<RemoteIdentity> identity(String calendarId) async =>
      const RemoteIdentity(account: 'me@example.com', calendar: 'naptar-cal');

  @override
  Future<PullResult> pull(String calendarId, String? syncToken) =>
      inner.pull(calendarId, syncToken);

  @override
  Future<PushResult> upsert(CalEvent event, {String? masterGoogleId}) =>
      throw StateError('nothing to upload, but "${event.title}" is');

  @override
  Future<void> delete(CalEvent event) =>
      throw StateError('nothing to delete, but "${event.title}" is');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  group('a listing in two pages', () {
    FakeGoogle twoPages() => FakeGoogle(
      (r) => jsonResp(
        sample(
          r.url.queryParameters['pageToken'] == null
              ? 'events_page1.json'
              : 'events_page2.json',
        ),
      ),
    );

    test('is read as one: every event, the token of the last page', () async {
      final f = twoPages();
      final res = await pull(f);
      expect(res.nextSyncToken, 'SYNC-TOKEN-1');
      expect(res.skipped, isEmpty);
      expect(res.changes.map((c) => c.ref.googleId), [
        'weekly1a2b3c',
        'dentist4d5e6f',
        'leave7a8b9c',
        'removed0d1e2f',
        'winter3a4b5c',
      ]);
      final lists = f.reqs.where((r) => r.url.path.endsWith('/events'));
      expect(lists.length, 2);
      expect(lists.last.url.queryParameters['pageToken'], 'PAGE2-TOKEN');
      expect(
        lists.last.url.queryParameters['timeMin'],
        lists.first.url.queryParameters['timeMin'],
        reason: 'every page of one listing uses the same filter',
      );
    });

    test('a timed event: its zone, times, link and our own id', () async {
      final c = byGoogleId(await pull(twoPages()))['weekly1a2b3c']!;
      expect(c.ref.appEventId, 'L-weekly');
      expect(c.ref.iCalUid, 'weekly1a2b3c@google.com');
      final e = c.event!;
      expect(e.title, 'Heti megbeszélés');
      expect(e.tzid, bp);
      expect(e.start, floating(2026, 5, 4, 9));
      expect(e.end, floating(2026, 5, 4, 10));
      expect(e.allDay, isFalse);
    });

    test(
      'place and a description with a line break come as they are',
      () async {
        final e = byGoogleId(await pull(twoPages()))['dentist4d5e6f']!.event!;
        expect(e.location, 'Budapest, Andrássy út 10.');
        expect(e.notes, 'Hozd a kártyát.\nMásodik sor');
      },
    );

    test('an all-day event has an exclusive end date', () async {
      final e = byGoogleId(await pull(twoPages()))['leave7a8b9c']!.event!;
      expect(e.allDay, isTrue);
      expect(e.tzid, isNull);
      expect(e.start, floating(2026, 8, 3));
      expect(e.end, floating(2026, 8, 4));
    });

    test('a winter time (+01:00) is the same wall clock time', () async {
      final e = byGoogleId(await pull(twoPages()))['winter3a4b5c']!.event!;
      expect(e.start, floating(2026, 12, 7, 18));
      expect(e.end, floating(2026, 12, 7, 19));
    });

    test('a deleted event is only an id and a status', () async {
      final c = byGoogleId(await pull(twoPages()))['removed0d1e2f']!;
      expect(c.ref.cancelled, isTrue);
      expect(c.event, isNull);
    });
  });

  group('a series, a moved and a cancelled occurrence', () {
    late Map<String, RemoteChange> by;
    setUp(
      () async =>
          by = byGoogleId(await pull(serving('recurring_with_exception.json'))),
    );

    test('the series carries its rule', () {
      final e = by['series9z8y7x']!.event!;
      expect(e.rrule, 'FREQ=WEEKLY;COUNT=6;BYDAY=MO');
      expect(e.recurringEventId, isNull);
      expect(by['series9z8y7x']!.ref.appEventId, 'L-series');
    });

    test('the moved occurrence knows its series and its original time', () {
      final c = by['series9z8y7x_20260511T070000Z']!;
      expect(c.masterGoogleId, 'series9z8y7x');
      expect(c.ref.isInstance, isTrue);
      expect(c.event!.originalStart, floating(2026, 5, 11, 9));
      expect(c.event!.start, floating(2026, 5, 12, 14));
      expect(c.event!.end, floating(2026, 5, 12, 15));
      expect(c.event!.cancelled, isFalse);
    });

    test('the cancelled occurrence is a hidden day, not a deleted series', () {
      final c = by['series9z8y7x_20260518T070000Z']!;
      expect(c.ref.cancelled, isFalse);
      expect(c.event!.cancelled, isTrue);
      expect(c.masterGoogleId, 'series9z8y7x');
      expect(c.event!.originalStart, floating(2026, 5, 18, 9));
    });
  });

  group('all-day events', () {
    late Map<String, RemoteChange> by;
    setUp(
      () async => by = byGoogleId(await pull(serving('all_day_multiday.json'))),
    );

    test('three days: the end date is the day after the last', () {
      final e = by['conf1a2b3c']!.event!;
      expect(e.allDay, isTrue);
      expect(e.start, floating(2026, 6, 12));
      expect(e.end, floating(2026, 6, 15));
    });

    test('over the turn of the year', () {
      final e = by['newyear4d5e6f']!.event!;
      expect(e.start, floating(2026, 12, 30));
      expect(e.end, floating(2027, 1, 3));
    });

    test('a yearly all-day event keeps its rule', () {
      final e = by['yearly7a8b9c']!.event!;
      expect(e.rrule, 'FREQ=YEARLY');
      expect(e.allDay, isTrue);
    });
  });

  group('event types: they are read as ordinary events', () {
    // Today the app does not keep the type of an event (birthday, out of
    // office, focus time, working location, from Gmail): all six come as plain
    // events, with their times, and are written back as plain events.
    test('six events, each with its title and time', () async {
      final by = byGoogleId(await pull(serving('event_types.json')));
      expect(by.length, 6);
      expect(by['birthday1']!.event!.allDay, isTrue);
      expect(by['birthday1']!.event!.rrule, 'FREQ=YEARLY');
      final away = by['ooo1']!.event!;
      expect(away.title, 'Szabadság');
      expect(away.start, floating(2026, 7, 13));
      expect(away.end, floating(2026, 7, 18));
      expect(by['focus1']!.event!.start, floating(2026, 5, 6, 13));
      expect(by['where1']!.event!.allDay, isTrue);
      final mail = by['gmail1']!.event!;
      expect(mail.title, 'Repülőjegy: BUD → LHR');
      expect(mail.location, contains('Liszt Ferenc'));
      expect(by['plain1']!.event!.title, 'Közönséges');
    });
  });

  group('an event with everything Google can put on one', () {
    test('what the app shows: title, place, colour, our markers', () async {
      final c = byGoogleId(
        await pull(serving('rich_event.json')),
      )['rich1a2b3c']!;
      final e = c.event!;
      expect(e.title, 'Negyedéves áttekintés');
      expect(e.location, 'Budapest, Váci út 1., Nagyterem');
      expect(e.colorId, '9');
      expect(e.aiGenerated, isTrue);
      expect(c.ref.appEventId, 'L-rich');
      expect(e.start, floating(2026, 6, 2, 10));
      expect(e.end, floating(2026, 6, 2, 11, 30));
    });

    test('the HTML of the description is kept as text (known)', () async {
      final e = byGoogleId(
        await pull(serving('rich_event.json')),
      )['rich1a2b3c']!.event!;
      expect(e.notes, startsWith('<b>Napirend</b><br>'));
    });

    test('an edit writes back everything the app does not know', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp((sample('rich_event.json')['items'] as List).single)
            : jsonResp({'id': 'rich1a2b3c', 'etag': '"new"'}),
      );
      final pulled = byGoogleId(
        await pull(serving('rich_event.json')),
      )['rich1a2b3c']!.event!;
      await GoogleCalendarRemote(f.client).upsert(
        pulled.copyWith(
          id: 'L-rich',
          title: 'Negyedéves áttekintés (átírva)',
          googleId: 'rich1a2b3c',
          etag: 'old',
        ),
      );
      final put = f.reqs.last;
      expect(put.method, 'PUT');
      final b = jsonDecode(put.body) as Map<String, dynamic>;
      // ours
      expect(b['summary'], 'Negyedéves áttekintés (átírva)');
      // theirs: the guests, the Meet room, the reminders, the attachment, ...
      expect((b['attendees'] as List).length, 2);
      expect(b['attendees'][1]['optional'], isTrue);
      expect(b['hangoutLink'], 'https://meet.google.com/abc-defg-hij');
      expect(b['conferenceData']['conferenceId'], 'abc-defg-hij');
      expect(b['reminders']['useDefault'], isFalse);
      expect((b['reminders']['overrides'] as List).length, 2);
      expect((b['attachments'] as List).single['title'], 'Prezi');
      expect(b['guestsCanModify'], isFalse);
      expect(b['extendedProperties']['shared'], {'team': 'x'});
      expect(b['extendedProperties']['private']['otherApp'], 'keep-me');
    });
  });

  group('the forms in which Google writes a recurrence', () {
    late Map<String, RemoteChange> by;
    setUp(
      () async => by = byGoogleId(await pull(serving('recurrence_forms.json'))),
    );

    test('a fortnightly rule is kept with its week start; one EXDATE', () {
      final e = by['fort1']!.event!;
      expect(e.rrule, 'FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO');
      expect(e.exdates, [floating(2026, 5, 18, 9)]);
    });

    test('two EXDATE lines, one with a zone, one in UTC', () {
      final e = by['mixed1']!.event!;
      expect(e.rrule, 'FREQ=DAILY;COUNT=5');
      expect(e.exdates, [floating(2026, 5, 6, 9), floating(2026, 5, 7, 9)]);
    });

    test('a date-only EXDATE of an all-day series', () {
      final e = by['dateonly1']!.event!;
      expect(e.allDay, isTrue);
      expect(e.exdates, [floating(2026, 6, 12)]);
    });

    test('RDATE (an extra date of a series) is not taken over (known)', () {
      final e = by['rdate1']!.event!;
      expect(e.rrule, 'FREQ=WEEKLY;COUNT=3;BYDAY=MO');
      final occ = expand(e, DateTime.utc(2026, 6), DateTime.utc(2026, 7));
      expect(occ.map((o) => o.originalStart.day), [1, 8, 15]);
    });

    test('a second RRULE line is not taken over (known)', () {
      expect(by['tworules1']!.event!.rrule, 'FREQ=DAILY;COUNT=2');
    });
  });

  group('what Google sent, through the app, into a backup and back', () {
    // The events of a sample are applied the way the app applies them, written
    // as a backup, and the backup is compared with the device it came from:
    // nothing may look changed, and nothing may be new.
    for (final name in [
      'all_day_multiday.json',
      'event_types.json',
      'rich_event.json',
      'recurrence_forms.json',
    ]) {
      test(name, () async {
        final db = await newDb();
        addTearDown(db.close);
        final repo = EventRepository(db);
        final engine = SyncEngine(
          repo,
          PullOnly(GoogleCalendarRemote(serving(name).client)),
        );
        await engine.sync('primary');
        final stored = await repo.all();
        expect(stored, isNotEmpty, reason: name);
        final plan = await previewBackup(
          repo,
          exportIcs(stored),
          calendarId: 'primary',
        );
        expect(plan.problems, isEmpty, reason: name);
        expect(plan.fresh, isEmpty, reason: name);
        expect(plan.changes, isEmpty, reason: name);
        expect(plan.unchanged, stored.where((e) => !e.cancelled).length);
      });
    }
  });
}
