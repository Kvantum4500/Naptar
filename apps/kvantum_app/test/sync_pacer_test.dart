import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_pacer.dart';

/// A "random" source that always answers the same.
class _Fixed implements Random {
  _Fixed(this.v);
  final double v;
  @override
  double nextDouble() => v;
  @override
  bool nextBool() => v > .5;
  @override
  int nextInt(int max) => (v * max).floor();
}

void main() {
  group('the beat while things go well', () {
    final p = SyncPacer(random: _Fixed(.5));

    test('a minute while there is something to do, then slower and slower', () {
      Duration at(int q) => p.afterSuccess(quietRuns: q);
      for (final q in [0, 1, 2]) {
        expect(at(q), const Duration(seconds: 60), reason: 'quiet $q');
      }
      for (final q in [3, 4, 5]) {
        expect(at(q), const Duration(minutes: 3), reason: 'quiet $q');
      }
      for (final q in [6, 8, 11]) {
        expect(at(q), const Duration(minutes: 5), reason: 'quiet $q');
      }
      for (final q in [12, 30, 1000]) {
        expect(at(q), const Duration(minutes: 10), reason: 'quiet $q');
      }
    });

    test('never slower than ten minutes, never faster than a minute', () {
      for (var q = 0; q < 200; q++) {
        final d = p.afterSuccess(quietRuns: q);
        expect(d, greaterThanOrEqualTo(const Duration(seconds: 60)));
        expect(d, lessThanOrEqualTo(const Duration(minutes: 10)));
      }
    });
  });

  group('the beat after failures', () {
    Duration fail(
      int n, {
      double jitter = .5,
      Duration? retryAfter,
      bool throttled = false,
      bool daily = false,
    }) => SyncPacer(random: _Fixed(jitter)).afterFailure(
      failures: n,
      retryAfter: retryAfter,
      throttled: throttled,
      dailyLimit: daily,
    );

    test('doubles each time: a minute, 2, 4 ... (middle of the spread)', () {
      expect(fail(1), const Duration(seconds: 60));
      expect(fail(2), const Duration(seconds: 120));
      expect(fail(3), const Duration(seconds: 240));
    });

    test('a network problem is never waited out longer than five minutes', () {
      expect(fail(4), const Duration(seconds: 300));
      expect(fail(9), const Duration(seconds: 300));
      expect(fail(500), const Duration(seconds: 300));
    });

    test('a limit may be waited out up to fifteen minutes', () {
      expect(fail(4, throttled: true), const Duration(seconds: 480));
      expect(fail(5, throttled: true), const Duration(seconds: 900));
      expect(fail(50, throttled: true), const Duration(seconds: 900));
    });

    test('the spread is plus/minus a fifth', () {
      expect(fail(2, jitter: 0), const Duration(seconds: 96)); // 120 * .8
      expect(
        fail(2, jitter: .9999999),
        lessThanOrEqualTo(const Duration(seconds: 144)),
      );
      expect(
        fail(2, jitter: .9999999),
        greaterThanOrEqualTo(const Duration(seconds: 143)),
      );
    });

    test('whatever the dice say, the wait stays inside the spread', () {
      final r = Random(7);
      final p = SyncPacer(random: r);
      for (var n = 1; n <= 12; n++) {
        for (final t in [false, true]) {
          final cap = t ? 900 : 300;
          final mid = (60 * pow(2, n - 1)).clamp(0, cap).toInt();
          for (var i = 0; i < 50; i++) {
            final d = p.afterFailure(failures: n, throttled: t).inSeconds;
            expect(
              d,
              inInclusiveRange((mid * .8).round(), (mid * 1.2).round()),
            );
          }
        }
      }
    });

    test('never sooner than the server asked', () {
      expect(
        fail(1, retryAfter: const Duration(minutes: 7)),
        const Duration(minutes: 7),
      );
      expect(
        fail(5, throttled: true, retryAfter: const Duration(seconds: 5)),
        const Duration(seconds: 900),
        reason: 'a short Retry-After does not shorten the backoff',
      );
    });

    test('a daily limit is waited out for at least half an hour', () {
      expect(
        fail(1, throttled: true, daily: true, jitter: 0),
        const Duration(minutes: 30),
      );
      expect(
        fail(5, throttled: true, daily: true),
        greaterThanOrEqualTo(const Duration(minutes: 30)),
      );
    });

    test('a count below one is read as the first failure', () {
      expect(fail(0), fail(1));
      expect(fail(-3), fail(1));
    });
  });

  group('the Hungarian texts', () {
    test(
      'a limit, a daily limit and a plain network problem read differently',
      () {
        final limit = transientText(
          'Naptár',
          TransientSyncError.throttled('x'),
        );
        final daily = transientText(
          'Naptár',
          TransientSyncError.throttled('x', dailyLimit: true),
        );
        final net = transientText('Naptár', TransientSyncError('offline'));
        expect({limit, daily, net}.length, 3);
        expect(limit, contains('korlátozza'));
        expect(daily, contains('mára'));
        expect(net, contains('kapcsolat'));
        for (final t in [limit, daily, net]) {
          expect(t, startsWith('Naptár: '));
          expect(t, isNot(contains('Instance of')));
          expect(t, isNot(contains('Exception')));
        }
      },
    );

    test('the planned wait is spelled out', () {
      final t = transientText('Drive', null, next: const Duration(minutes: 5));
      expect(t, contains('5 perc múlva'));
      expect(
        transientText('Drive', null, next: const Duration(seconds: 50)),
        contains('egy perc múlva'),
      );
      expect(
        transientText('Drive', null, next: const Duration(hours: 2)),
        contains('2 óra múlva'),
      );
    });

    test('parked, refused, skipped and surprising problems', () {
      expect(parkedText('Naptár', 2), contains('2 módosítást'));
      expect(refusedText('Naptár', 3), contains('3 módosítást'));
      expect(skippedText('Naptár', 1), contains('1 Google-esemény'));
      expect(unexpectedText('Drive'), startsWith('Drive: váratlan hiba'));
      expect(calendarGoneText, contains('Google-naptár'));
    });

    test('the linking question names the accounts and offers the way out', () {
      final account = bindingBody(
        accountChanged: true,
        stored: 'a***@gmail.com',
        current: 'b***@gmail.com',
      );
      expect(account, contains('a***@gmail.com'));
      expect(account, contains('b***@gmail.com'));
      expect(account, contains('megállt'));
      final calendar = bindingBody(
        accountChanged: false,
        stored: 'cal-1',
        current: 'cal-2',
      );
      expect(calendar, contains('törölték vagy újra létrehozták'));
      expect(bindingFreshConfirm(12), contains('12 esemény'));
      expect(resetBody, contains('visszateszi'));
    });
  });
}
