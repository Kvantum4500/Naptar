import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/google/google_calendar_remote.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/retry_after_client.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/google_fake.dart';

const cal = 'primary';
const bp = 'Europe/Budapest';

CalEvent ev({
  String id = 'L1',
  String? googleId,
  String? etag,
  String? rrule,
  bool allDay = false,
}) => CalEvent(
  id: id,
  calendarId: cal,
  title: 'Edzés',
  tzid: allDay ? null : bp,
  allDay: allDay,
  start: allDay ? floating(2026, 5, 4) : floating(2026, 5, 4, 9),
  end: allDay ? floating(2026, 5, 5) : floating(2026, 5, 4, 10),
  rrule: rrule,
  exdates: rrule == null ? const [] : [floating(2026, 5, 6, 9)],
  googleId: googleId,
  etag: etag,
);

void main() {
  setUpAll(ensureTimeZones);

  group('pull mapping', () {
    test('timed, all-day, recurring (+EXDATE forms), cancelled', () async {
      final f = FakeGoogle(
        (r) => jsonResp({
          'nextSyncToken': 'T1',
          'items': [
            {
              'id': 'a',
              'etag': 'e1',
              'summary': 'Timed',
              'start': {
                'dateTime': '2026-05-04T09:00:00+02:00',
                'timeZone': bp,
              },
              'end': {'dateTime': '2026-05-04T10:00:00+02:00', 'timeZone': bp},
              'extendedProperties': {
                'private': {'appEventId': 'L9'},
              },
              'iCalUID': 'uid-a',
            },
            {
              'id': 'b',
              'etag': 'e2',
              'summary': 'AllDay',
              'start': {'date': '2026-12-31'},
              'end': {'date': '2027-01-02'},
            },
            {
              'id': 'c',
              'etag': 'e3',
              'summary': 'Series',
              'start': {
                'dateTime': '2026-05-04T09:00:00+02:00',
                'timeZone': bp,
              },
              'end': {'dateTime': '2026-05-04T10:00:00+02:00', 'timeZone': bp},
              'recurrence': [
                'RRULE:FREQ=DAILY;COUNT=5',
                'EXDATE;TZID=Europe/Budapest:20260506T090000',
                'EXDATE:20260507T070000Z',
              ],
            },
            {'id': 'd', 'status': 'cancelled', 'etag': 'e4'},
            {
              'id': 'c_20260508T070000Z',
              'status': 'cancelled',
              'etag': 'e5',
              'recurringEventId': 'c',
              'originalStartTime': {
                'dateTime': '2026-05-08T09:00:00+02:00',
                'timeZone': bp,
              },
            },
            {
              'id': 'c_20260505T070000Z',
              'etag': 'e6',
              'summary': 'Moved',
              'recurringEventId': 'c',
              'originalStartTime': {
                'dateTime': '2026-05-05T09:00:00+02:00',
                'timeZone': bp,
              },
              'start': {
                'dateTime': '2026-05-05T15:00:00+02:00',
                'timeZone': bp,
              },
              'end': {'dateTime': '2026-05-05T16:00:00+02:00', 'timeZone': bp},
            },
          ],
        }),
      );
      final res = await GoogleCalendarRemote(f.client).pull(cal, null);
      expect(res.nextSyncToken, 'T1');
      final by = {for (final c in res.changes) c.ref.googleId: c};

      final a = by['a']!;
      expect(a.event!.start, floating(2026, 5, 4, 9));
      expect(a.event!.tzid, bp);
      expect(a.ref.appEventId, 'L9');
      expect(a.ref.iCalUid, 'uid-a');

      final b = by['b']!.event!;
      expect(b.allDay, isTrue);
      expect(b.tzid, isNull);
      expect(b.end, floating(2027, 1, 2));

      final c = by['c']!.event!;
      expect(c.rrule, 'FREQ=DAILY;COUNT=5');
      expect(c.exdates, [floating(2026, 5, 6, 9), floating(2026, 5, 7, 9)]);

      expect(by['d']!.ref.cancelled, isTrue);
      expect(by['d']!.event, isNull);

      final hidden = by['c_20260508T070000Z']!;
      expect(
        hidden.ref.cancelled,
        isFalse,
      ); // an exception, NOT a series delete
      expect(hidden.event!.cancelled, isTrue);
      expect(hidden.masterGoogleId, 'c');
      expect(hidden.event!.originalStart, floating(2026, 5, 8, 9));

      final moved = by['c_20260505T070000Z']!;
      expect(moved.event!.start, floating(2026, 5, 5, 15));
      expect(moved.event!.originalStart, floating(2026, 5, 5, 9));
    });

    test('full sync sends timeMin; incremental sends only the token', () async {
      final f = FakeGoogle(
        (r) => jsonResp({'items': [], 'nextSyncToken': 'N'}),
      );
      final remote = GoogleCalendarRemote(f.client);
      await remote.pull(cal, null);
      final full = f.reqs.last.url.queryParameters;
      expect(full['timeMin'], isNotNull);
      expect(full['showDeleted'], 'true');
      expect(full['singleEvents'], 'false');
      await remote.pull(cal, 'TOK');
      final inc = f.reqs.last.url.queryParameters;
      expect(inc['syncToken'], 'TOK');
      expect(inc.containsKey('timeMin'), isFalse);
    });

    test('pagination collects all pages, token comes from the last', () async {
      final f = FakeGoogle((r) {
        final page = r.url.queryParameters['pageToken'];
        return page == null
            ? jsonResp({
                'nextPageToken': 'P2',
                'items': [
                  {
                    'id': 'x1',
                    'etag': 'e',
                    'start': {'date': '2026-05-01'},
                    'end': {'date': '2026-05-02'},
                  },
                ],
              })
            : jsonResp({
                'nextSyncToken': 'FINAL',
                'items': [
                  {
                    'id': 'x2',
                    'etag': 'e',
                    'start': {'date': '2026-05-03'},
                    'end': {'date': '2026-05-04'},
                  },
                ],
              });
      });
      final res = await GoogleCalendarRemote(f.client).pull(cal, null);
      expect(res.changes.length, 2);
      expect(res.nextSyncToken, 'FINAL');
    });

    test(
      '410 -> SyncTokenExpired; 429/5xx/network -> TransientSyncError',
      () async {
        expect(
          GoogleCalendarRemote(FakeGoogle((_) => errResp(410)).client)
              .pull(cal, 'old'),
          throwsA(isA<SyncTokenExpired>()),
        );
        expect(
          GoogleCalendarRemote(
            FakeGoogle((_) => errResp(429, 'rateLimitExceeded')).client,
          ).pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
        expect(
          GoogleCalendarRemote(FakeGoogle((_) => errResp(503)).client)
              .pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
        expect(
          GoogleCalendarRemote(
            FakeGoogle((_) => errResp(403, 'userRateLimitExceeded')).client,
          ).pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
        final down = MockClient(
          (_) async => throw const SocketException('no net'),
        );
        expect(
          GoogleCalendarRemote(down).pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
      },
    );
  });

  group('push', () {
    test(
      'new event: inserts with appEventId, zone and recurrence lines',
      () async {
        final f = FakeGoogle((r) {
          if (r.method == 'GET') {
            return jsonResp({'items': []}); // lookup by appEventId: none
          }
          return jsonResp({'id': 'g1', 'etag': 'E1'});
        });
        final res = await GoogleCalendarRemote(f.client)
            .upsert(ev(rrule: 'FREQ=DAILY;COUNT=5'));
        expect(res.googleId, 'g1');
        expect(res.etag, 'E1');
        final lookup = f.reqs.firstWhere(
          (r) => r.method == 'GET' && r.url.path.endsWith('/events'),
        );
        expect(lookup.url.queryParametersAll['privateExtendedProperty'], [
          'appEventId=L1',
        ]);
        final post = f.reqs.last;
        expect(post.method, 'POST');
        final body = jsonDecode(post.body) as Map<String, dynamic>;
        expect(body['extendedProperties']['private']['appEventId'], 'L1');
        expect(body['start']['timeZone'], bp);
        expect(body['start']['dateTime'], '2026-05-04T07:00:00.000Z');
        expect(body['recurrence'], [
          'RRULE:FREQ=DAILY;COUNT=5',
          'EXDATE;TZID=$bp:20260506T090000',
        ]);
      },
    );

    test(
      'retry after a lost response does NOT insert twice (found by appEventId)',
      () async {
        final f = FakeGoogle((r) {
          if (r.method == 'GET') {
            return jsonResp({
              'items': [
                {'id': 'gExisting'},
              ],
            });
          }
          return jsonResp({'id': 'gExisting', 'etag': 'E2'});
        });
        final res = await GoogleCalendarRemote(f.client).upsert(ev());
        expect(res.googleId, 'gExisting');
        expect(f.reqs.where((r) => r.method == 'POST'), isEmpty);
        expect(f.reqs.where((r) => r.method == 'PUT').length, 1);
      },
    );

    test('all-day body uses date, exclusive end', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp({'items': []})
            : jsonResp({'id': 'g', 'etag': 'e'}),
      );
      await GoogleCalendarRemote(f.client).upsert(ev(allDay: true));
      final body = jsonDecode(f.reqs.last.body) as Map<String, dynamic>;
      expect(body['start'], {'date': '2026-05-04'});
      expect(body['end'], {'date': '2026-05-05'});
    });

    test(
      'update sends the etag it just read as If-Match (not the old one)',
      () async {
        final ok = FakeGoogle(
          (r) => r.method == 'GET'
              ? jsonResp({'id': 'g1', 'etag': 'E7'})
              : jsonResp({'id': 'g1', 'etag': 'E9'}),
        );
        final res = await GoogleCalendarRemote(ok.client)
            .upsert(ev(googleId: 'g1', etag: 'stale-local'));
        expect(res.etag, 'E9');
        final put = ok.reqs.last;
        expect(put.method, 'PUT');
        expect(put.headers['If-Match'], 'E7');
      },
    );

    test(
      'update of an event deleted remotely recreates it (local wins)',
      () async {
        final f = FakeGoogle(
          (r) => r.method == 'PUT'
              ? errResp(404)
              : jsonResp({'id': 'gNew', 'etag': 'E'}),
        );
        final res = await GoogleCalendarRemote(f.client)
            .upsert(ev(googleId: 'gOld', etag: 'E1'));
        expect(res.googleId, 'gNew');
      },
    );

    test('delete: 404 is fine; unknown event makes no delete call', () async {
      final gone = FakeGoogle((r) => errResp(404));
      await GoogleCalendarRemote(gone.client).delete(ev(googleId: 'g1'));
      final none = FakeGoogle((r) => jsonResp({'items': []}));
      await GoogleCalendarRemote(none.client).delete(ev());
      expect(none.reqs.where((r) => r.method == 'DELETE'), isEmpty);
    });
  });

  group('Naptar calendar (find or create once)', () {
    http.Response calList(List<Map<String, Object?>> items) =>
        jsonResp({'items': items});

    test('creates the calendar when none carries the marker', () async {
      final f = FakeGoogle((r) {
        if (r.url.path.endsWith('/users/me/calendarList')) return calList([]);
        if (r.method == 'POST' && r.url.path.endsWith('/calendars')) {
          return jsonResp({'id': 'newCal', 'timeZone': bp});
        }
        if (r.url.path.endsWith('/calendars/newCal')) {
          return jsonResp({'timeZone': bp});
        }
        return jsonResp({'items': [], 'nextSyncToken': 'T'});
      });
      await GoogleCalendarRemote(f.client).pull('naptar', null);
      final post = f.reqs.firstWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['summary'], 'Naptar');
      expect(body['description'], contains(calendarMarker));
      expect(f.reqs.last.url.path, contains('/calendars/newCal/events'));
    });

    test('reuses an existing marked calendar; several -> the same (smallest id) one', () async {
      final f = FakeGoogle((r) {
        if (r.url.path.endsWith('/users/me/calendarList')) {
          return calList([
            {
              'id': 'zzz',
              'accessRole': 'owner',
              'description': 'x $calendarMarker',
            },
            {
              'id': 'aaa',
              'accessRole': 'owner',
              'description': 'x $calendarMarker',
            },
            {'id': 'other', 'accessRole': 'owner', 'description': 'Munka'},
            {'id': 'ro', 'accessRole': 'reader', 'description': calendarMarker},
          ]);
        }
        if (r.url.path.endsWith('/calendars/aaa')) {
          return jsonResp({'timeZone': bp});
        }
        return jsonResp({'items': [], 'nextSyncToken': 'T'});
      });
      final remote = GoogleCalendarRemote(f.client);
      await remote.pull('naptar', null);
      await remote.pull('naptar', 'T'); // second use does not list again
      expect(f.reqs.where((r) => r.method == 'POST'), isEmpty);
      expect(
        f.reqs
            .where((r) => r.url.path.endsWith('/users/me/calendarList'))
            .length,
        1,
      );
      expect(f.reqs.last.url.path, contains('/calendars/aaa/events'));
    });

    test(
      'events are pushed into the Naptar calendar, never into primary',
      () async {
        final f = FakeGoogle((r) {
          if (r.url.path.endsWith('/users/me/calendarList')) {
            return calList([
              {
                'id': 'nap',
                'accessRole': 'owner',
                'description': calendarMarker,
              },
            ]);
          }
          if (r.method == 'GET') return jsonResp({'items': []});
          return jsonResp({'id': 'g', 'etag': 'e'});
        });
        final logical = CalEvent(
          id: 'L',
          calendarId: 'naptar',
          title: 't',
          tzid: bp,
          start: floating(2026, 5, 4, 9),
          end: floating(2026, 5, 4, 10),
        );
        await GoogleCalendarRemote(f.client).upsert(logical);
        expect(f.reqs.last.url.path, contains('/calendars/nap/events'));
        expect(
          f.reqs.any((r) => r.url.path.contains('/calendars/primary/')),
          isFalse,
        );
      },
    );
  });

  group('colours and AI flag', () {
    test('pull maps colorId and the ai marker; push sends them back', () async {
      final f = FakeGoogle(
        (r) => jsonResp({
          'nextSyncToken': 'T',
          'items': [
            {
              'id': 'a',
              'etag': 'e',
              'summary': 'Edzés',
              'colorId': '11',
              'start': {
                'dateTime': '2026-05-04T09:00:00+02:00',
                'timeZone': bp,
              },
              'end': {'dateTime': '2026-05-04T10:00:00+02:00', 'timeZone': bp},
              'extendedProperties': {
                'private': {'appEventId': 'L1', 'ai': '1'},
              },
            },
          ],
        }),
      );
      final res = await GoogleCalendarRemote(f.client).pull(cal, null);
      final e = res.changes.single.event!;
      expect(e.colorId, '11');
      expect(e.aiGenerated, isTrue);

      final out = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp({'items': []})
            : jsonResp({'id': 'g', 'etag': 'e'}),
      );
      await GoogleCalendarRemote(out.client)
          .upsert(ev().copyWith(colorId: '5', aiGenerated: true));
      final body = jsonDecode(out.reqs.last.body) as Map<String, dynamic>;
      expect(body['colorId'], '5');
      expect(body['extendedProperties']['private']['ai'], '1');
    });
  });

  group('single instances of a series', () {
    CalEvent override({String? googleId, bool cancelled = false}) => CalEvent(
      id: 'o1',
      calendarId: cal,
      title: 'Áthelyezve',
      tzid: bp,
      start: floating(2026, 5, 5, 15),
      end: floating(2026, 5, 5, 16),
      recurringEventId: 'm',
      originalStart: floating(2026, 5, 5, 9),
      googleId: googleId,
      cancelled: cancelled,
    );

    test(
      'finds the instance by its original start and patches only it',
      () async {
        final f = FakeGoogle((r) {
          if (r.url.path.contains('/events/gMaster/instances')) {
            return jsonResp({
              'items': [
                {
                  'id': 'gMaster_20260505T070000Z',
                  'originalStartTime': {
                    'dateTime': '2026-05-05T09:00:00+02:00',
                    'timeZone': bp,
                  },
                },
              ],
            });
          }
          return jsonResp({'id': 'gMaster_20260505T070000Z', 'etag': 'E7'});
        });
        final res = await GoogleCalendarRemote(f.client)
            .upsert(override(), masterGoogleId: 'gMaster');
        expect(res.googleId, 'gMaster_20260505T070000Z');
        final patch = f.reqs.last;
        expect(patch.method, 'PATCH');
        expect(patch.url.path, endsWith('/events/gMaster_20260505T070000Z'));
        final body = jsonDecode(patch.body) as Map<String, dynamic>;
        expect(body['summary'], 'Áthelyezve');
        expect(body.containsKey('recurrence'), isFalse);
        expect(body['start']['dateTime'], '2026-05-05T13:00:00.000Z');
      },
    );

    test('known instance id is patched directly (no lookup)', () async {
      final f = FakeGoogle((r) => jsonResp({'id': 'inst', 'etag': 'E'}));
      await GoogleCalendarRemote(f.client)
          .upsert(override(googleId: 'inst'), masterGoogleId: 'gMaster');
      expect(f.reqs.where((r) => r.url.path.contains('/instances')), isEmpty);
      expect(f.reqs.last.method, 'PATCH');
    });

    test('a cancelled override cancels exactly that occurrence', () async {
      final f = FakeGoogle((r) => jsonResp({'id': 'inst', 'etag': 'E'}));
      await GoogleCalendarRemote(f.client).upsert(
        override(googleId: 'inst', cancelled: true),
        masterGoogleId: 'gMaster',
      );
      expect((jsonDecode(f.reqs.last.body) as Map)['status'], 'cancelled');
    });

    test(
      'missing instance or missing series id fail loudly, never silently',
      () async {
        final none = FakeGoogle((r) => jsonResp({'items': []}));
        expect(
          GoogleCalendarRemote(none.client)
              .upsert(override(), masterGoogleId: 'gMaster'),
          throwsStateError,
        );
        expect(
          GoogleCalendarRemote(none.client).upsert(override()),
          throwsStateError,
        );
      },
    );

    test('series push carries EXDATE lines and the converted UNTIL', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp({'items': []})
            : jsonResp({'id': 'g', 'etag': 'e'}),
      );
      final m = ev(rrule: 'FREQ=DAILY;UNTIL=20260510T235959Z');
      await GoogleCalendarRemote(f.client).upsert(m);
      final rec = ((jsonDecode(f.reqs.last.body) as Map)['recurrence'] as List)
          .cast<String>();
      // last occurrence 10.05 09:00 Budapest (CEST) = 07:00Z
      expect(rec.first, 'RRULE:FREQ=DAILY;UNTIL=20260510T070000Z');
      expect(rec[1], startsWith('EXDATE;TZID=$bp:'));
    });
  });

  group('edits keep what only Google knows (read, merge, write)', () {
    Map<String, dynamic> googleSide({String status = 'confirmed'}) => {
      'id': 'g1',
      'etag': 'E7',
      'status': status,
      'summary': 'Régi cím',
      'description': 'Régi leírás',
      'location': 'Régi hely',
      'colorId': '5',
      'start': {'dateTime': '2026-05-04T08:00:00+02:00', 'timeZone': bp},
      'end': {'dateTime': '2026-05-04T09:00:00+02:00', 'timeZone': bp},
      'recurrence': ['RRULE:FREQ=DAILY;COUNT=5', 'RDATE:20260601T070000Z'],
      'reminders': {
        'useDefault': false,
        'overrides': [
          {'method': 'popup', 'minutes': 30},
        ],
      },
      'attendees': [
        {'email': 'bela@example.com'},
      ],
      'conferenceData': {'conferenceId': 'abc-defg-hij'},
      'transparency': 'transparent',
      'visibility': 'private',
      'extendedProperties': {
        'private': {'appEventId': 'L1', 'ai': '1', 'other': 'keep'},
        'shared': {'s': '1'},
      },
    };

    test('reminders, guests, Meet, availability, extra keys survive; ours replace theirs', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp(googleSide())
            : jsonResp({'id': 'g1', 'etag': 'E8'}),
      );
      await GoogleCalendarRemote(f.client)
          .upsert(ev(googleId: 'g1', etag: 'old', rrule: 'FREQ=DAILY;COUNT=5'));
      expect(
        f.reqs.where((r) => r.method == 'GET').last.url.path,
        endsWith('/events/g1'),
      );
      final put = f.reqs.last;
      expect(put.method, 'PUT');
      final b = jsonDecode(put.body) as Map<String, dynamic>;
      // what only Google has
      expect(b['reminders']['overrides'][0]['minutes'], 30);
      expect(b['attendees'][0]['email'], 'bela@example.com');
      expect(b['conferenceData']['conferenceId'], 'abc-defg-hij');
      expect(b['transparency'], 'transparent');
      expect(b['visibility'], 'private');
      expect(b['extendedProperties']['shared'], {'s': '1'});
      expect(b['extendedProperties']['private']['other'], 'keep');
      // what the app owns
      expect(b['summary'], 'Edzés');
      expect(b['start']['dateTime'], '2026-05-04T07:00:00.000Z');
      expect(b['extendedProperties']['private']['appEventId'], 'L1');
      expect(
        (b['extendedProperties']['private'] as Map).containsKey('ai'),
        isFalse,
        reason: 'no longer AI generated here',
      );
      expect(b.containsKey('description'), isFalse, reason: 'cleared here');
      expect(b.containsKey('location'), isFalse);
      expect(b.containsKey('colorId'), isFalse);
      // the series: our rule and EXDATE, and the RDATE we cannot edit stays
      expect(b['recurrence'], [
        'RRULE:FREQ=DAILY;COUNT=5',
        'EXDATE;TZID=$bp:20260506T090000',
        'RDATE:20260601T070000Z',
      ]);
    });

    test(
      'an event that is not a series here is not one afterwards either',
      () async {
        final f = FakeGoogle(
          (r) => r.method == 'GET'
              ? jsonResp(googleSide())
              : jsonResp({'id': 'g1', 'etag': 'E8'}),
        );
        await GoogleCalendarRemote(f.client).upsert(ev(googleId: 'g1'));
        final b = jsonDecode(f.reqs.last.body) as Map<String, dynamic>;
        expect(b.containsKey('recurrence'), isFalse);
      },
    );

    test('the AI marker is set when the event is AI generated', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp({'id': 'g1', 'etag': 'E7'})
            : jsonResp({'id': 'g1', 'etag': 'E8'}),
      );
      await GoogleCalendarRemote(f.client)
          .upsert(ev(googleId: 'g1').copyWith(aiGenerated: true));
      final b = jsonDecode(f.reqs.last.body) as Map<String, dynamic>;
      expect(b['extendedProperties']['private']['ai'], '1');
    });

    test(
      'somebody changed it meanwhile (412): read again, write again',
      () async {
        var gets = 0, puts = 0;
        final f = FakeGoogle((r) {
          if (r.method == 'GET') {
            gets++;
            return jsonResp({'id': 'g1', 'etag': 'E$gets'});
          }
          puts++;
          return puts == 1
              ? errResp(412)
              : jsonResp({'id': 'g1', 'etag': 'done'});
        });
        final res = await GoogleCalendarRemote(f.client)
            .upsert(ev(googleId: 'g1'));
        expect(res.etag, 'done');
        expect((gets, puts), (2, 2));
        expect(f.reqs.last.headers['If-Match'], 'E2', reason: 'the NEW etag');
      },
    );

    test('a write that keeps conflicting gives up after three tries', () async {
      var puts = 0;
      final f = FakeGoogle((r) {
        if (r.method == 'GET') return jsonResp({'id': 'g1', 'etag': 'E'});
        puts++;
        return errResp(412);
      });
      await expectLater(
        GoogleCalendarRemote(f.client).upsert(ev(googleId: 'g1')),
        throwsA(isA<ConflictException>()),
      );
      expect(puts, 3);
    });

    test(
      'deleted in Google (cancelled or 404 on read): created again, local wins',
      () async {
        for (final kind in ['cancelled', '404']) {
          final f = FakeGoogle((r) {
            if (r.method == 'GET') {
              return kind == '404'
                  ? errResp(404)
                  : jsonResp(googleSide(status: 'cancelled'));
            }
            if (r.method == 'POST') {
              return jsonResp({'id': 'gNew', 'etag': 'N'});
            }
            return errResp(500); // a PUT must not happen
          });
          final res = await GoogleCalendarRemote(f.client)
              .upsert(ev(googleId: 'g1'));
          expect(res.googleId, 'gNew', reason: kind);
          expect(f.reqs.where((r) => r.method == 'PUT'), isEmpty, reason: kind);
        }
      },
    );
  });

  group('failures keep their meaning (limits are not rejections)', () {
    for (final (reason, wantDaily) in [
      ('rateLimitExceeded', false),
      ('userRateLimitExceeded', false),
      ('calendarUsageLimitsExceeded', false),
      ('quotaExceeded', false),
      ('dailyLimitExceeded', true),
    ]) {
      test(
        '403 $reason -> transient, throttled${wantDaily ? ', daily' : ''}',
        () async {
          final f = FakeGoogle(
            (r) => r.method == 'GET'
                ? jsonResp({'items': []})
                : errResp(403, reason),
          );
          try {
            await GoogleCalendarRemote(f.client).upsert(ev());
            fail('should have thrown');
          } on TransientSyncError catch (e) {
            expect(e.throttled, isTrue);
            expect(e.dailyLimit, wantDaily);
          }
        },
      );
    }

    test('403 forbiddenForNonOrganizer is a rejection of THIS item', () async {
      final f = FakeGoogle(
        (r) => r.method == 'GET'
            ? jsonResp({'items': []})
            : errResp(403, 'forbiddenForNonOrganizer'),
      );
      await expectLater(
        GoogleCalendarRemote(f.client).upsert(ev()),
        throwsA(isA<ItemRejectedError>()),
      );
    });

    test(
      '429 and 503 are transient; the server\'s Retry-After is passed on',
      () async {
        final inner = MockClient((r) async {
          if (r.url.path.endsWith('/calendars/primary')) {
            return jsonResp({'timeZone': bp});
          }
          if (r.method == 'GET') return jsonResp({'items': []});
          return http.Response(
            jsonEncode({
              'error': {
                'code': 429,
                'message': 'x',
                'errors': [
                  {'reason': 'rateLimitExceeded'},
                ],
              },
            }),
            429,
            headers: {'content-type': 'application/json', 'retry-after': '45'},
          );
        });
        try {
          await GoogleCalendarRemote(RetryAfterClient(inner)).upsert(ev());
          fail('should have thrown');
        } on TransientSyncError catch (e) {
          expect(e.throttled, isTrue);
          expect(e.retryAfter, const Duration(seconds: 45));
        }
        final f = FakeGoogle(
          (r) => r.method == 'GET' ? jsonResp({'items': []}) : errResp(503),
        );
        try {
          await GoogleCalendarRemote(f.client).upsert(ev());
          fail('should have thrown');
        } on TransientSyncError catch (e) {
          expect(e.throttled, isFalse);
          expect(e.retryAfter, isNull);
        }
      },
    );
  });

  group('pull: one unreadable event does not stop the others', () {
    Map<String, dynamic> item(String id, {String? zone}) => {
      'id': id,
      'etag': 'e-$id',
      'summary': 'Esemény $id',
      'start': {
        'dateTime': '2026-05-04T09:00:00+02:00',
        'timeZone': zone ?? bp,
      },
      'end': {'dateTime': '2026-05-04T10:00:00+02:00', 'timeZone': zone ?? bp},
    };

    test(
      'an unknown time zone is skipped and reported, the rest arrive',
      () async {
        final f = FakeGoogle(
          (r) => jsonResp({
            'nextSyncToken': 'T',
            'items': [item('a'), item('bad', zone: 'Mars/Phobos'), item('c')],
          }),
        );
        final res = await GoogleCalendarRemote(f.client).pull(cal, null);
        expect(res.changes.map((c) => c.ref.googleId), ['a', 'c']);
        expect(res.skipped.single.googleId, 'bad');
        expect(res.skipped.single.reason, isNotEmpty);
        expect(res.skipped.single.reason, isNot(contains('Esemény')));
        expect(res.nextSyncToken, 'T', reason: 'the listing still completes');
      },
    );

    test('instances say so: kind and the occurrence they replace', () async {
      final f = FakeGoogle(
        (r) => jsonResp({
          'nextSyncToken': 'T',
          'items': [
            item('series'),
            {
              ...item('series_20260506T070000Z'),
              'recurringEventId': 'series',
              'originalStartTime': {
                'dateTime': '2026-05-06T09:00:00+02:00',
                'timeZone': bp,
              },
              'extendedProperties': {
                'private': {'appEventId': 'L-series'},
              },
            },
          ],
        }),
      );
      final res = await GoogleCalendarRemote(f.client).pull(cal, null);
      final series = res.changes[0].ref, inst = res.changes[1].ref;
      expect(series.isInstance, isFalse);
      expect(inst.isInstance, isTrue);
      expect(inst.originalStart, floating(2026, 5, 6, 9));
      expect(inst.appEventId, 'L-series', reason: 'copied from the series');
    });
  });

  group('the calendar vanishing and the identity of the account', () {
    http.Response calList(List<Map<String, Object?>> items) =>
        jsonResp({'items': items});

    test('404 on the listing: CalendarGoneError, and the calendar is looked up again', () async {
      var listing = 0;
      var eventsGone = false;
      final f = FakeGoogle((r) {
        if (r.url.path.endsWith('/users/me/calendarList')) {
          listing++;
          return calList([
            {'id': 'nap', 'accessRole': 'owner', 'description': calendarMarker},
          ]);
        }
        if (r.url.path.endsWith('/calendars/nap')) {
          return jsonResp({'timeZone': bp});
        }
        if (eventsGone) return errResp(404);
        return jsonResp({'items': [], 'nextSyncToken': 'T'});
      });
      final remote = GoogleCalendarRemote(f.client);
      await remote.pull('naptar', null);
      expect(listing, 1);
      eventsGone = true;
      await expectLater(
        remote.pull('naptar', 'T'),
        throwsA(isA<CalendarGoneError>()),
      );
      eventsGone = false;
      await remote.pull('naptar', null);
      expect(listing, 2, reason: 'the cached calendar id was dropped');
    });

    test('410 with a token is an expired token, 404 with a token is a missing calendar', () async {
      final expired = FakeGoogle((r) => errResp(410));
      await expectLater(
        GoogleCalendarRemote(expired.client).pull(cal, 'T'),
        throwsA(isA<SyncTokenExpired>()),
      );
      final missing = FakeGoogle((r) => errResp(404));
      await expectLater(
        GoogleCalendarRemote(missing.client).pull(cal, 'T'),
        throwsA(isA<CalendarGoneError>()),
      );
    });

    test('identity: the primary calendar id is the account, the Naptar id the calendar; asked once', () async {
      var primary = 0;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/calendars/primary')) {
          primary++;
          return jsonResp({'id': 'anna@gmail.com', 'timeZone': bp});
        }
        if (r.url.path.endsWith('/users/me/calendarList')) {
          return calList([
            {'id': 'nap', 'accessRole': 'owner', 'description': calendarMarker},
          ]);
        }
        return jsonResp({'items': []});
      });
      final remote = GoogleCalendarRemote(client);
      final id = await remote.identity('naptar');
      expect(id.account, 'anna@gmail.com');
      expect(id.calendar, 'nap');
      await remote.identity('naptar');
      expect(primary, 1);
    });
  });

  test('EXDATE parsing: date-only, UTC across the DST switch', () {
    final r = parseRecurrenceLines([
      'RRULE:FREQ=WEEKLY',
      'EXDATE;VALUE=DATE:20260504',
      'EXDATE:20260330T070000Z,20260323T080000Z', // 09:00 local on both sides of 2026-03-29
    ], bp);
    expect(r.rrule, 'FREQ=WEEKLY');
    expect(r.exdates, [
      floating(2026, 5, 4),
      floating(2026, 3, 30, 9),
      floating(2026, 3, 23, 9),
    ]);
  });
}
