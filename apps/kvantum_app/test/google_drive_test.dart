import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/drive/google_drive_remote.dart';

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
