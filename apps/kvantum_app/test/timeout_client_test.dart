import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/sync/timeout_client.dart';

void main() {
  const short = Duration(milliseconds: 60);
  final url = Uri.parse('https://example.test/x');

  test('a call that never answers ends in a TimeoutException', () async {
    final never = Completer<http.Response>();
    final c = TimeoutClient(
      MockClient((_) => never.future),
      responseTimeout: short,
    );
    await expectLater(c.get(url), throwsA(isA<TimeoutException>()));
  });

  test('a body that stalls half way ends in a TimeoutException', () async {
    final body = StreamController<List<int>>();
    final c = TimeoutClient(
      MockClient.streaming(
        (req, _) async => http.StreamedResponse(body.stream, 200),
      ),
      idleTimeout: short,
    );
    body.add([1, 2, 3]); // one chunk, then silence
    await expectLater(c.get(url), throwsA(isA<TimeoutException>()));
    await body.close();
  });

  test('a normal answer passes through unchanged', () async {
    final c = TimeoutClient(
      MockClient(
        (_) async => http.Response('hello', 200, headers: {'x-a': 'b'}),
      ),
    );
    final r = await c.get(url);
    expect(r.statusCode, 200);
    expect(r.body, 'hello');
    expect(r.headers['x-a'], 'b');
  });

  test('a slow but steady body is not cut off', () async {
    final body = StreamController<List<int>>();
    final c = TimeoutClient(
      MockClient.streaming(
        (req, _) async => http.StreamedResponse(body.stream, 200),
      ),
      idleTimeout: const Duration(milliseconds: 300),
    );
    final done = c.get(url);
    for (final chunk in [
      [104, 105],
      [33],
    ]) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      body.add(chunk);
    }
    await body.close();
    expect((await done).body, 'hi!');
  });
}
