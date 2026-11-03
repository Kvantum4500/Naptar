import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/google/google_calendar_remote.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_core/kvantum_core.dart';

const cal = 'primary';
const bp = 'Europe/Budapest';

/// Records every request and answers from [handler].
class Fake {
  final List<http.Request> reqs = [];
  late final http.Client client;
  Fake(http.Response Function(http.Request r) handler) {
    client = MockClient((r) async {
      reqs.add(r);
      if (r.url.path.endsWith('/calendars/primary') && r.method == 'GET') {
        return _json({'timeZone': bp});
      }
      return handler(r);
    });
  }
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _err(int status, [String reason = '']) => _json({
  'error': {
    'code': status,
    'message': 'x',
    'errors': [
      {'reason': reason},
    ],
  },
}, status);

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
      final f = Fake(
        (r) => _json({
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
      final f = Fake((r) => _json({'items': [], 'nextSyncToken': 'N'}));
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
      final f = Fake((r) {
        final page = r.url.queryParameters['pageToken'];
        return page == null
            ? _json({
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
            : _json({
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
          GoogleCalendarRemote(Fake((_) => _err(410)).client).pull(cal, 'old'),
          throwsA(isA<SyncTokenExpired>()),
        );
        expect(
          GoogleCalendarRemote(
            Fake((_) => _err(429, 'rateLimitExceeded')).client,
          ).pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
        expect(
          GoogleCalendarRemote(Fake((_) => _err(503)).client).pull(cal, null),
          throwsA(isA<TransientSyncError>()),
        );
        expect(
          GoogleCalendarRemote(
            Fake((_) => _err(403, 'userRateLimitExceeded')).client,
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
        final f = Fake((r) {
          if (r.method == 'GET') {
            return _json({'items': []}); // lookup by appEventId: none
          }
          return _json({'id': 'g1', 'etag': 'E1'});
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
        final f = Fake((r) {
          if (r.method == 'GET') {
            return _json({
              'items': [
                {'id': 'gExisting'},
              ],
            });
          }
          return _json({'id': 'gExisting', 'etag': 'E2'});
        });
        final res = await GoogleCalendarRemote(f.client).upsert(ev());
        expect(res.googleId, 'gExisting');
        expect(f.reqs.where((r) => r.method == 'POST'), isEmpty);
        expect(f.reqs.where((r) => r.method == 'PUT').length, 1);
      },
    );

    test('all-day body uses date, exclusive end', () async {
      final f = Fake(
        (r) => r.method == 'GET'
            ? _json({'items': []})
            : _json({'id': 'g', 'etag': 'e'}),
      );
      await GoogleCalendarRemote(f.client).upsert(ev(allDay: true));
      final body = jsonDecode(f.reqs.last.body) as Map<String, dynamic>;
      expect(body['start'], {'date': '2026-05-04'});
      expect(body['end'], {'date': '2026-05-05'});
    });

    test('update sends If-Match; 412 -> ConflictException', () async {
      final ok = Fake((r) => _json({'id': 'g1', 'etag': 'E9'}));
      await GoogleCalendarRemote(ok.client)
          .upsert(ev(googleId: 'g1', etag: 'E1'));
      expect(ok.reqs.last.method, 'PUT');
      expect(ok.reqs.last.headers['If-Match'], 'E1');

      final stale = Fake((r) => _err(412));
      expect(
        GoogleCalendarRemote(stale.client)
            .upsert(ev(googleId: 'g1', etag: 'old')),
        throwsA(isA<ConflictException>()),
      );
    });

    test(
      'update of an event deleted remotely recreates it (local wins)',
      () async {
        final f = Fake(
          (r) => r.method == 'PUT'
              ? _err(404)
              : _json({'id': 'gNew', 'etag': 'E'}),
        );
        final res = await GoogleCalendarRemote(f.client)
            .upsert(ev(googleId: 'gOld', etag: 'E1'));
        expect(res.googleId, 'gNew');
      },
    );

    test('delete: 404 is fine; unknown event makes no delete call', () async {
      final gone = Fake((r) => _err(404));
      await GoogleCalendarRemote(gone.client).delete(ev(googleId: 'g1'));
      final none = Fake((r) => _json({'items': []}));
      await GoogleCalendarRemote(none.client).delete(ev());
      expect(none.reqs.where((r) => r.method == 'DELETE'), isEmpty);
    });
  });

  group('Naptar calendar (find or create once)', () {
    http.Response calList(List<Map<String, Object?>> items) =>
        _json({'items': items});

    test('creates the calendar when none carries the marker', () async {
      final f = Fake((r) {
        if (r.url.path.endsWith('/users/me/calendarList')) return calList([]);
        if (r.method == 'POST' && r.url.path.endsWith('/calendars')) {
          return _json({'id': 'newCal', 'timeZone': bp});
        }
        if (r.url.path.endsWith('/calendars/newCal')) {
          return _json({'timeZone': bp});
        }
        return _json({'items': [], 'nextSyncToken': 'T'});
      });
      await GoogleCalendarRemote(f.client).pull('naptar', null);
      final post = f.reqs.firstWhere((r) => r.method == 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['summary'], 'Naptar');
      expect(body['description'], contains(calendarMarker));
      expect(f.reqs.last.url.path, contains('/calendars/newCal/events'));
    });

    test('reuses an existing marked calendar; several -> the same (smallest id) one', () async {
      final f = Fake((r) {
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
          return _json({'timeZone': bp});
        }
        return _json({'items': [], 'nextSyncToken': 'T'});
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

    test('events are pushed into the Naptar calendar, never into primary', () async {
      final f = Fake((r) {
        if (r.url.path.endsWith('/users/me/calendarList')) {
          return calList([
            {'id': 'nap', 'accessRole': 'owner', 'description': calendarMarker},
          ]);
        }
        if (r.method == 'GET') return _json({'items': []});
        return _json({'id': 'g', 'etag': 'e'});
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
    });
  });

  group('colours and AI flag', () {
    test('pull maps colorId and the ai marker; push sends them back', () async {
      final f = Fake(
        (r) => _json({
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

      final out = Fake(
        (r) => r.method == 'GET'
            ? _json({'items': []})
            : _json({'id': 'g', 'etag': 'e'}),
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
        final f = Fake((r) {
          if (r.url.path.contains('/events/gMaster/instances')) {
            return _json({
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
          return _json({'id': 'gMaster_20260505T070000Z', 'etag': 'E7'});
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
      final f = Fake((r) => _json({'id': 'inst', 'etag': 'E'}));
      await GoogleCalendarRemote(f.client)
          .upsert(override(googleId: 'inst'), masterGoogleId: 'gMaster');
      expect(f.reqs.where((r) => r.url.path.contains('/instances')), isEmpty);
      expect(f.reqs.last.method, 'PATCH');
    });

    test('a cancelled override cancels exactly that occurrence', () async {
      final f = Fake((r) => _json({'id': 'inst', 'etag': 'E'}));
      await GoogleCalendarRemote(f.client).upsert(
        override(googleId: 'inst', cancelled: true),
        masterGoogleId: 'gMaster',
      );
      expect((jsonDecode(f.reqs.last.body) as Map)['status'], 'cancelled');
    });

    test(
      'missing instance or missing series id fail loudly, never silently',
      () async {
        final none = Fake((r) => _json({'items': []}));
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
      final f = Fake(
        (r) => r.method == 'GET'
            ? _json({'items': []})
            : _json({'id': 'g', 'etag': 'e'}),
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
