import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/sync/timeout_client.dart';

/// A clock the test moves: the timers of what runs in [run] are fake (a
/// deadline is checked to the millisecond, and no real time passes). A stream
/// that is cancelled on its first error lets the error through only after a
/// hop over the real microtask queue; [advance] turns that queue too.
class Clock {
  final async = FakeAsync();

  T run<T>(T Function() body) => async.run((_) => body());

  Future<void> advance(Duration by) async {
    async.elapse(by);
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue(times: 3);
      async.flushMicrotasks();
    }
  }
}

void main() {
  const short = Duration(milliseconds: 60);
  const ms = Duration(milliseconds: 1);
  final url = Uri.parse('https://example.test/x');

  test(
    'a call that never answers ends in a TimeoutException, not before',
    () async {
      final clock = Clock();
      Object? error;
      clock.run(() {
        final never = Completer<http.Response>();
        TimeoutClient(MockClient((_) => never.future), responseTimeout: short)
            .get(url)
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
      });
      await clock.advance(short - ms);
      expect(error, isNull, reason: 'the time is not up yet');
      await clock.advance(ms);
      expect(error, isA<TimeoutException>());
    },
  );

  test('a body that stalls half way ends in a TimeoutException', () async {
    final clock = Clock();
    Object? error;
    late StreamController<List<int>> body;
    clock.run(() {
      body = StreamController<List<int>>();
      TimeoutClient(
            MockClient.streaming(
              (req, _) async => http.StreamedResponse(body.stream, 200),
            ),
            idleTimeout: short,
          )
          .get(url)
          .then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          );
    });
    await clock.settle();
    clock.run(() => body.add([1, 2, 3])); // one chunk, then silence
    await clock.advance(short - ms);
    expect(error, isNull, reason: 'the silence is not long enough yet');
    await clock.advance(ms);
    expect(error, isA<TimeoutException>());
    unawaited(clock.run(() => body.close()));
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

  group('a slow but steady body is not cut off', () {
    const idle = Duration(milliseconds: 300);

    /// A call whose body gets one chunk after each of [gaps] (the time before
    /// that chunk); what it came to once the body is closed.
    Future<({String? body, Object? error})> run(List<Duration> gaps) async {
      final clock = Clock();
      String? text;
      Object? error;
      late StreamController<List<int>> body;
      clock.run(() {
        body = StreamController<List<int>>();
        TimeoutClient(
              MockClient.streaming(
                (req, _) async => http.StreamedResponse(body.stream, 200),
              ),
              idleTimeout: idle,
            )
            .get(url)
            .then<void>(
              (r) {
                text = r.body;
              },
              onError: (Object e) {
                error = e;
              },
            );
      });
      await clock.settle();
      for (final (i, gap) in gaps.indexed) {
        await clock.advance(gap);
        if (error != null) break;
        clock.run(() => body.add([104 + i]));
        await clock.settle();
      }
      unawaited(clock.run(() => body.close()));
      await clock.settle();
      return (body: text, error: error);
    }

    test('the idle time starts again with every chunk', () async {
      // four chunks 100 ms apart: 400 ms in all, more than the idle time, but
      // no silence of 300 ms
      final r = await run([
        for (var i = 0; i < 4; i++) const Duration(milliseconds: 100),
      ]);
      expect(r.error, isNull);
      expect(r.body, 'hijk');
    });

    test('a silence of just under the idle time is let through', () async {
      final r = await run([const Duration(milliseconds: 299)]);
      expect(r.error, isNull);
      expect(r.body, 'h');
    });

    test('a silence of the idle time is not', () async {
      final r = await run([idle]);
      expect(r.error, isA<TimeoutException>());
    });
  });
}
