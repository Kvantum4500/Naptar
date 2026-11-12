import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/diag/request_stats.dart';
import 'package:kvantum_app/sync/retry_after_client.dart';

void main() {
  group('serviceOfPath', () {
    test('tells the Google services apart by their path', () {
      expect(serviceOfPath('/calendar/v3/calendars/x/events'), 'calendar');
      expect(serviceOfPath('/drive/v3/files'), 'drive');
      expect(serviceOfPath('/upload/drive/v3/files/abc'), 'drive');
      expect(serviceOfPath('/oauth2/v4/token'), 'other');
      expect(serviceOfPath(''), 'other');
    });
  });

  group('RetryAfterClient counts the calls', () {
    final calendar = Uri.parse(
      'https://www.googleapis.com/calendar/v3/c/events',
    );
    final drive = Uri.parse('https://www.googleapis.com/drive/v3/files');

    test('by how they ended, per service', () async {
      final answers = <int>[200, 404, 429, 500, 503];
      var i = 0;
      final stats = RequestStats(now: () => DateTime(2026, 11, 12, 10));
      final client = RetryAfterClient(
        MockClient((_) async => http.Response('', answers[i++])),
        stats: stats,
      );
      await client.get(calendar); // 200
      await client.get(calendar); // 404
      await client.get(drive); // 429
      await client.get(drive); // 500
      await client.get(drive); // 503

      final t = await stats.read((_) async => null);
      final today = t['2026-11-12']!;
      final cal = today['calendar']!;
      expect(
        [cal.calls, cal.ok, cal.client, cal.throttled, cal.server],
        [2, 1, 1, 0, 0],
      );
      final dr = today['drive']!;
      expect(
        [dr.calls, dr.ok, dr.client, dr.throttled, dr.server],
        [3, 0, 0, 1, 2],
      );
    });

    test(
      'a call that gets no answer is counted and the error goes on',
      () async {
        final stats = RequestStats(now: () => DateTime(2026, 11, 12, 10));
        final fail = <Object>[
          const SocketException('nincs hálózat'),
          TimeoutException('lassú'),
        ];
        var i = 0;
        final client = RetryAfterClient(
          MockClient((_) async => throw fail[i++]),
          stats: stats,
        );
        await expectLater(
          client.get(calendar),
          throwsA(isA<SocketException>()),
        );
        await expectLater(client.get(drive), throwsA(isA<TimeoutException>()));

        final t = (await stats.read((_) async => null))['2026-11-12']!;
        expect(t['calendar']!.failed, 1);
        expect(t['drive']!.failed, 1);
        expect(t['calendar']!.calls, 1);
      },
    );

    test('the Retry-After behaviour is unchanged by the counting', () async {
      final client = RetryAfterClient(
        MockClient(
          (_) async => http.Response('', 429, headers: {'retry-after': '30'}),
        ),
        stats: RequestStats(),
      );
      await client.get(calendar);
      expect(client.takeRetryAfter(), const Duration(seconds: 30));
    });
  });

  group('RequestStats', () {
    late Map<String, String> store;
    Future<String?> read(String k) async => store[k];
    Future<void> write(String k, String? v) async {
      if (v == null) {
        store.remove(k);
      } else {
        store[k] = v;
      }
    }

    setUp(() => store = {});

    test('flush adds to what is stored, and counts each call once', () async {
      var now = DateTime(2026, 11, 12, 10);
      final stats = RequestStats(now: () => now);
      stats.record('calendar', status: 200);
      stats.record('calendar', status: 200);
      await stats.flush(read, write);
      stats.record('calendar', status: 500);
      await stats.flush(read, write);
      await stats.flush(read, write); // nothing new: nothing written

      final t = RequestStats.decode(store[RequestStats.metaKey]);
      final c = t['2026-11-12']!['calendar']!;
      expect([c.calls, c.ok, c.server], [3, 2, 1]);

      // a new run of the app (a new object) adds to the same table
      final again = RequestStats(now: () => now);
      again.record('drive', status: 200);
      await again.flush(read, write);
      final t2 = RequestStats.decode(store[RequestStats.metaKey]);
      expect(t2['2026-11-12']!['calendar']!.calls, 3);
      expect(t2['2026-11-12']!['drive']!.calls, 1);

      now = DateTime(2026, 11, 13, 0, 5);
      again.record('drive', status: 200);
      final both = await again.read(read);
      expect(both.keys, containsAll(['2026-11-12', '2026-11-13']));
    });

    test('read shows what is not stored yet', () async {
      final stats = RequestStats(now: () => DateTime(2026, 11, 12));
      stats.record('drive', status: 200);
      final t = await stats.read(read);
      expect(t['2026-11-12']!['drive']!.calls, 1);
      expect(store, isEmpty, reason: 'reading does not write');
    });

    test('only the last seven days are kept', () async {
      var day = 1;
      final stats = RequestStats(now: () => DateTime(2026, 11, day));
      for (day = 1; day <= 9; day++) {
        stats.record('calendar', status: 200);
        await stats.flush(read, write);
      }
      final t = RequestStats.decode(store[RequestStats.metaKey]);
      expect(t.keys.toList()..sort(), [
        for (var d = 3; d <= 9; d++) '2026-11-0$d',
      ]);
    });

    test('a failed write keeps the counts for the next time', () async {
      final stats = RequestStats(now: () => DateTime(2026, 11, 12));
      stats.record('calendar', status: 200);
      stats.record('calendar', status: 200);
      await expectLater(
        stats.flush(read, (k, v) async => throw StateError('lemez')),
        throwsStateError,
      );
      stats.record('calendar', status: 200);
      await stats.flush(read, write);
      final c = RequestStats.decode(
        store[RequestStats.metaKey],
      )['2026-11-12']!['calendar']!;
      expect(c.calls, 3, reason: 'nothing lost, nothing counted twice');
    });

    test('a damaged stored value is replaced, not fatal', () async {
      store[RequestStats.metaKey] = '{{{ nem json';
      final stats = RequestStats(now: () => DateTime(2026, 11, 12));
      stats.record('calendar', status: 200);
      await stats.flush(read, write);
      final t = RequestStats.decode(store[RequestStats.metaKey]);
      expect(t['2026-11-12']!['calendar']!.calls, 1);
    });

    test('odd values in the stored table read as zero', () {
      final t = RequestStats.decode(
        '{"2026-11-12":{"drive":{"c":"sok","ok":-4,"e4":2.5}},"x":5}',
      );
      final c = t['2026-11-12']!['drive']!;
      expect([c.calls, c.ok, c.client], [0, 0, 0]);
    });
  });
}
