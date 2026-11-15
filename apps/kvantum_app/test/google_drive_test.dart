import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/drive/google_drive_remote.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/retry_after_client.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _err(int status, String message, [String reason = '']) => _json({
  'error': {
    'code': status,
    'message': message,
    'errors': [
      {'reason': reason},
    ],
  },
}, status);

class Fake {
  Fake(this.handler) {
    client = MockClient((r) async {
      reqs.add(r);
      return handler(r);
    });
  }
  final http.Response Function(http.Request r) handler;
  final List<http.Request> reqs = [];
  late final http.Client client;
}

http.Response _media(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

bool _isMedia(http.Request r) => r.url.queryParameters['alt'] == 'media';

void main() {
  group('full listing', () {
    test(
      'takes the start token BEFORE listing and downloads only record files',
      () async {
        final f = Fake((r) {
          final p = r.url.path;
          if (p.endsWith('/changes/startPageToken')) {
            return _json({'startPageToken': '77'});
          }
          if (p.endsWith('/drive/v3/files') && r.method == 'GET') {
            expect(r.url.queryParameters['spaces'], 'appDataFolder');
            return _json({
              'files': [
                {'id': 'a', 'name': 'task-1.json'},
                {'id': 'b', 'name': 'photo.png'},
                {'id': 'c', 'name': 'checkin-2026-11-04.json'},
              ],
            });
          }
          if (_isMedia(r)) return _media('{"id":"x"}');
          return http.Response('', 404);
        });
        final res = await GoogleDriveRemote(f.client).pull(null);
        expect(res.full, isTrue);
        expect(res.nextToken, '77');
        expect(res.files.map((x) => x.name), [
          'task-1.json',
          'checkin-2026-11-04.json',
        ]);
        final order = f.reqs.map((r) => r.url.path).toList();
        expect(
          order.indexWhere((p) => p.endsWith('/startPageToken')),
          lessThan(order.indexWhere((p) => p.endsWith('/drive/v3/files'))),
        );
        expect(
          f.reqs.any((r) => r.url.path.endsWith('/files/b')),
          isFalse,
        ); // foreign file not downloaded
      },
    );

    test('paging collects every page', () async {
      var page = 0;
      final f = Fake((r) {
        final p = r.url.path;
        if (p.endsWith('/startPageToken')) {
          return _json({'startPageToken': '1'});
        }
        if (p.endsWith('/drive/v3/files')) {
          page++;
          return page == 1
              ? _json({
                  'nextPageToken': 'P2',
                  'files': [
                    {'id': 'a', 'name': 'task-1.json'},
                  ],
                })
              : _json({
                  'files': [
                    {'id': 'b', 'name': 'task-2.json'},
                  ],
                });
        }
        return _media('{}');
      });
      final res = await GoogleDriveRemote(f.client).pull(null);
      expect(res.files.length, 2);
    });
  });

  group('a file bigger than the app writes is skipped by the listings', () {
    http.Response media(http.Request r) =>
        r.url.path.endsWith('/big') ? _media('x' * 50) : _media('{"id":"ok"}');

    test('full listing: the others come, the big one does not', () async {
      final f = Fake((r) {
        final p = r.url.path;
        if (p.endsWith('/changes/startPageToken')) {
          return _json({'startPageToken': '77'});
        }
        if (p.endsWith('/drive/v3/files') && r.method == 'GET') {
          return _json({
            'files': [
              {'id': 'big', 'name': 'task-1.json'},
              {'id': 'ok', 'name': 'task-2.json'},
            ],
          });
        }
        if (_isMedia(r)) return media(r);
        return http.Response('', 404);
      });
      final res = await GoogleDriveRemote(
        f.client,
        maxReadBytes: 20,
      ).pull(null);
      expect([for (final x in res.files) x.id], ['ok']);
      expect(res.nextToken, '77');
    });

    test('incremental: the same, and the token still moves on', () async {
      final f = Fake((r) {
        if (r.url.path.endsWith('/drive/v3/changes')) {
          return _json({
            'newStartPageToken': '90',
            'changes': [
              {
                'fileId': 'big',
                'removed': false,
                'file': {'id': 'big', 'name': 'task-1.json', 'trashed': false},
              },
              {
                'fileId': 'ok',
                'removed': false,
                'file': {'id': 'ok', 'name': 'task-2.json', 'trashed': false},
              },
            ],
          });
        }
        if (_isMedia(r)) return media(r);
        return http.Response('', 404);
      });
      final res = await GoogleDriveRemote(
        f.client,
        maxReadBytes: 20,
      ).pull('80');
      expect([for (final x in res.files) x.id], ['ok']);
      expect(res.nextToken, '90');
    });
  });

  group('incremental changes', () {
    test(
      'maps changed, removed and trashed files; ignores foreign names',
      () async {
        final f = Fake((r) {
          final p = r.url.path;
          if (p.endsWith('/drive/v3/changes')) {
            expect(r.url.queryParameters['spaces'], 'appDataFolder');
            expect(r.url.queryParameters['includeRemoved'], 'true');
            return _json({
              'newStartPageToken': '90',
              'changes': [
                {
                  'fileId': 'a',
                  'removed': false,
                  'file': {'id': 'a', 'name': 'task-1.json', 'trashed': false},
                },
                {'fileId': 'gone', 'removed': true},
                {
                  'fileId': 'tr',
                  'removed': false,
                  'file': {'id': 'tr', 'name': 'task-2.json', 'trashed': true},
                },
                {
                  'fileId': 'x',
                  'removed': false,
                  'file': {'id': 'x', 'name': 'other.txt', 'trashed': false},
                },
              ],
            });
          }
          if (_isMedia(r)) return _media('{"hello":1}');
          return http.Response('', 404);
        });
        final res = await GoogleDriveRemote(f.client).pull('80');
        expect(res.full, isFalse);
        expect(res.nextToken, '90');
        expect(res.files.single.id, 'a');
        expect(res.removedIds, ['gone', 'tr']);
      },
    );

    group('does the finance mail have news?', () {
      Future<DrivePull> pullWith(List<Map<String, Object?>> changes) {
        final f = Fake((r) {
          if (r.url.path.endsWith('/drive/v3/changes')) {
            return _json({'newStartPageToken': '90', 'changes': changes});
          }
          if (_isMedia(r)) return _media('{"hello":1}');
          return http.Response('', 404);
        });
        return GoogleDriveRemote(f.client).pull('80');
      }

      Map<String, Object?> file(String id, String name) => {
        'fileId': id,
        'removed': false,
        'file': {'id': id, 'name': name, 'trashed': false},
      };

      test('only record files changed: no news for the mailbox', () async {
        final res = await pullWith([file('a', 'task-1.json')]);
        expect(res.finChanged, isFalse);
        expect((await pullWith([])).finChanged, isFalse);
      });

      test('a letter or a peer note appeared: news', () async {
        expect(
          (await pullWith([file('l', 'fin-letter-aaaa-to-bbbb-1-0.json')]))
              .finChanged,
          isTrue,
        );
        expect(
          (await pullWith([file('p', 'fin-peer-aaaa.json')])).finChanged,
          isTrue,
        );
      });

      test(
        'a file disappeared (a letter may have been collected): news',
        () async {
          final res = await pullWith([
            {'fileId': 'gone', 'removed': true},
          ]);
          expect(res.finChanged, isTrue);
        },
      );

      test('a full listing always says so', () async {
        final f = Fake((r) {
          if (r.url.path.endsWith('/drive/v3/changes/startPageToken')) {
            return _json({'startPageToken': '5'});
          }
          return _json({'files': []});
        });
        expect(
          (await GoogleDriveRemote(f.client).pull(null)).finChanged,
          isTrue,
        );
      });
    });

    group('failures keep their meaning (limits are not rejections)', () {
      test(
        'a usage limit is transient, throttled, with the server\'s wish',
        () async {
          final inner = MockClient(
            (r) async => http.Response(
              jsonEncode({
                'error': {
                  'code': 403,
                  'message': 'x',
                  'errors': [
                    {
                      'reason': 'userRateLimitExceeded',
                      'domain': 'usageLimits',
                    },
                  ],
                },
              }),
              403,
              headers: {
                'content-type': 'application/json',
                'retry-after': '20',
              },
            ),
          );
          try {
            await GoogleDriveRemote(RetryAfterClient(inner)).pull('80');
            fail('should have thrown');
          } on DriveTransientError catch (e) {
            expect(e.throttled, isTrue);
            expect(e.dailyLimit, isFalse);
            expect(e.retryAfter, const Duration(seconds: 20));
          }
        },
      );

      test('a daily limit is marked', () async {
        final f = Fake((r) => _err(403, 'x', 'dailyLimitExceeded'));
        try {
          await GoogleDriveRemote(f.client).pull('80');
          fail('should have thrown');
        } on DriveTransientError catch (e) {
          expect(e.dailyLimit, isTrue);
        }
      });

      test('5xx is transient but not a limit; a refusal is neither', () async {
        final down = Fake((r) => _err(503, 'x'));
        try {
          await GoogleDriveRemote(down.client).pull('80');
          fail('should have thrown');
        } on DriveTransientError catch (e) {
          expect(e.throttled, isFalse);
        }
        final no = Fake((r) => _err(403, 'x', 'forbidden'));
        await expectLater(
          GoogleDriveRemote(no.client).pull('80'),
          throwsA(isA<ItemRejectedError>()),
        );
      });
    });

    test('follows nextPageToken until a newStartPageToken arrives', () async {
      var calls = 0;
      final f = Fake((r) {
        if (r.url.path.endsWith('/drive/v3/changes')) {
          calls++;
          return calls == 1
              ? _json({'nextPageToken': 'N1', 'changes': []})
              : _json({'newStartPageToken': 'END', 'changes': []});
        }
        return http.Response('', 404);
      });
      final res = await GoogleDriveRemote(f.client).pull('80');
      expect(calls, 2);
      expect(res.nextToken, 'END');
    });

    test(
      'an invalid page token becomes DriveTokenExpired (-> full resync)',
      () async {
        final f = Fake((r) => _err(400, 'Invalid Value for pageToken'));
        await expectLater(
          GoogleDriveRemote(f.client).pull('bad'),
          throwsA(isA<DriveTokenExpired>()),
        );
      },
    );
  });

  group('read / write / find / delete', () {
    test('read returns the text; a missing file is null', () async {
      final ok = Fake(
        (r) => http.Response(
          '{"k":"árvíztűrő"}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      expect(await GoogleDriveRemote(ok.client).read('a'), '{"k":"árvíztűrő"}');
      final gone = Fake((r) => _err(404, 'not found'));
      expect(await GoogleDriveRemote(gone.client).read('a'), isNull);
    });

    group('a file bigger than the app ever writes is not read', () {
      GoogleDriveRemote limited(String body) =>
          GoogleDriveRemote(Fake((r) => _media(body)).client, maxReadBytes: 10);

      test('exactly the limit is read, one byte more is refused', () async {
        expect(await limited('0123456789').read('a'), '0123456789');
        await expectLater(
          limited('0123456789X').read('a'),
          throwsA(isA<DriveFileTooBig>()),
        );
      });

      test('the limit counts bytes, not letters', () async {
        // "é" is two bytes: five of them are ten, six are too many
        expect(await limited('ééééé').read('a'), 'ééééé');
        await expectLater(
          limited('éééééé').read('a'),
          throwsA(isA<DriveFileTooBig>()),
        );
      });

      test(
        'what arrives is counted when the server announced no size',
        () async {
          GoogleDriveRemote streamed(List<List<int>> chunks) =>
              GoogleDriveRemote(
                MockClient.streaming(
                  (req, body) async => http.StreamedResponse(
                    Stream.fromIterable(chunks),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  ),
                ),
                maxReadBytes: 10,
              );
          expect(
            await streamed([utf8.encode('01234'), utf8.encode('56789')])
                .read('a'),
            '0123456789',
          );
          await expectLater(
            streamed([
              utf8.encode('01234'),
              utf8.encode('56789'),
              utf8.encode('X'),
            ]).read('a'),
            throwsA(isA<DriveFileTooBig>()),
          );
        },
      );

      test('the limit of the app is a few megabytes', () {
        expect(driveMaxReadBytes, greaterThanOrEqualTo(5 * 1024 * 1024));
        expect(driveMaxReadBytes, lessThanOrEqualTo(16 * 1024 * 1024));
      });
    });

    test('create puts the file in appDataFolder with the content', () async {
      final f = Fake((r) => _json({'id': 'new1'}));
      final id = await GoogleDriveRemote(f.client)
          .write(name: 'task-1.json', content: '{"a":"é"}');
      expect(id, 'new1');
      final r = f.reqs.single;
      expect(r.method, 'POST');
      expect(r.url.path, contains('/upload/drive/v3/files'));
      expect(r.body, contains('"name":"task-1.json"'));
      expect(r.body, contains('appDataFolder'));
      // the content travels base64-encoded inside the multipart body
      expect(r.body, contains(base64.encode(utf8.encode('{"a":"é"}'))));
    });

    test(
      'update overwrites by id (PATCH) and recreates when the file vanished',
      () async {
        final upd = Fake((r) => _json({'id': 'f1'}));
        expect(
          await GoogleDriveRemote(upd.client)
              .write(fileId: 'f1', name: 'n', content: '{}'),
          'f1',
        );
        expect(upd.reqs.single.method, 'PATCH');
        expect(upd.reqs.single.url.path, endsWith('/files/f1'));

        var n = 0;
        final gone = Fake(
          (r) => ++n == 1 ? _err(404, 'File not found') : _json({'id': 'f2'}),
        );
        expect(
          await GoogleDriveRemote(gone.client)
              .write(fileId: 'f1', name: 'task-1.json', content: '{}'),
          'f2',
        );
        expect(gone.reqs.last.method, 'POST');
      },
    );

    test('findByName escapes quotes and returns ids oldest first', () async {
      final f = Fake(
        (r) => _json({
          'files': [
            {'id': 'a'},
            {'id': 'b'},
          ],
        }),
      );
      final ids = await GoogleDriveRemote(f.client).findByName("task-o'x.json");
      expect(ids, ['a', 'b']);
      final q = f.reqs.single.url.queryParameters['q']!;
      expect(q, contains(r"o\'x"));
      expect(f.reqs.single.url.queryParameters['orderBy'], 'createdTime');
    });

    test('delete ignores an already deleted file', () async {
      final f = Fake((r) => _err(404, 'gone'));
      await GoogleDriveRemote(f.client).delete('x');
    });
  });

  test(
    'rate limits, server errors, auth and network problems are retryable',
    () async {
      for (final h in <http.Response Function(http.Request)>[
        (r) => _err(429, 'slow down', 'rateLimitExceeded'),
        (r) => _err(403, 'x', 'userRateLimitExceeded'),
        (r) => _err(503, 'x'),
        (r) => _err(401, 'x'),
        (r) => throw const SocketException('no net'),
      ]) {
        await expectLater(
          GoogleDriveRemote(Fake(h).client).pull('1'),
          throwsA(isA<DriveTransientError>()),
        );
      }
    },
  );

  test('a real permission error is not hidden as retryable', () async {
    await expectLater(
      GoogleDriveRemote(
        Fake(
          (r) =>
              _err(403, 'insufficientPermissions', 'insufficientPermissions'),
        ).client,
      ).pull('1'),
      throwsA(isNot(isA<DriveTransientError>())),
    );
  });
}
