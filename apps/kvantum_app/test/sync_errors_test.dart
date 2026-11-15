import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/retry_after_client.dart';

void main() {
  group('classifyApiError', () {
    // status, reason, domain, message, location -> what the sync does
    final table = <(int, String?, String?, String?, String?, ApiFailure)>[
      // usage limits: wait and try again, never give the item up
      (429, null, null, null, null, ApiFailure.throttled),
      (
        429,
        'rateLimitExceeded',
        'usageLimits',
        null,
        null,
        ApiFailure.throttled,
      ),
      (
        403,
        'rateLimitExceeded',
        'usageLimits',
        null,
        null,
        ApiFailure.throttled,
      ),
      (
        403,
        'userRateLimitExceeded',
        'usageLimits',
        null,
        null,
        ApiFailure.throttled,
      ),
      (
        403,
        'calendarUsageLimitsExceeded',
        'usageLimits',
        null,
        null,
        ApiFailure.throttled,
      ),
      (403, 'quotaExceeded', 'usageLimits', null, null, ApiFailure.throttled),
      (
        403,
        'sharingRateLimitExceeded',
        'global',
        null,
        null,
        ApiFailure.throttled,
      ),
      (403, 'somethingNew', 'usageLimits', null, null, ApiFailure.throttled),
      (
        403,
        'dailyLimitExceeded',
        'usageLimits',
        null,
        null,
        ApiFailure.dailyLimit,
      ),
      (429, 'dailyLimitExceeded', null, null, null, ApiFailure.dailyLimit),
      // permissions are about THIS item
      (
        403,
        'forbiddenForNonOrganizer',
        'calendar',
        null,
        null,
        ApiFailure.itemRejected,
      ),
      (
        403,
        'requiredAccessLevel',
        'calendar',
        null,
        null,
        ApiFailure.itemRejected,
      ),
      (403, 'forbidden', 'global', null, null, ApiFailure.itemRejected),
      // the server's bad moment
      (500, null, null, null, null, ApiFailure.server),
      (502, null, null, null, null, ApiFailure.server),
      (503, 'backendError', 'global', null, null, ApiFailure.server),
      (504, null, null, null, null, ApiFailure.server),
      (408, null, null, null, null, ApiFailure.server),
      // the rest of the vocabulary
      (401, 'authError', 'global', null, null, ApiFailure.auth),
      (404, 'notFound', 'global', null, null, ApiFailure.gone),
      (410, 'deleted', 'global', null, null, ApiFailure.gone),
      (412, 'conditionNotMet', 'global', null, null, ApiFailure.conflict),
      (
        400,
        'invalid',
        'global',
        'Invalid sync token value.',
        null,
        ApiFailure.tokenInvalid,
      ),
      (
        400,
        'invalid',
        'global',
        'Invalid Value',
        'pageToken',
        ApiFailure.tokenInvalid,
      ),
      (
        400,
        'invalid',
        'global',
        'Invalid page token',
        null,
        ApiFailure.tokenInvalid,
      ),
      (
        400,
        'invalid',
        'global',
        'The specified time range is empty.',
        null,
        ApiFailure.itemRejected,
      ),
      (400, 'badRequest', 'global', null, null, ApiFailure.itemRejected),
      (409, 'duplicate', 'global', null, null, ApiFailure.itemRejected),
      (0, null, null, null, null, ApiFailure.itemRejected),
    ];

    for (final (status, reason, domain, message, location, want) in table) {
      test(
        '$status ${reason ?? '-'} ${message ?? location ?? ''} -> $want',
        () {
          expect(
            classifyApiError(
              status: status,
              reason: reason,
              domain: domain,
              message: message,
              location: location,
            ),
            want,
          );
        },
      );
    }

    test('matching is case-insensitive', () {
      expect(
        classifyApiError(
          status: 403,
          reason: 'CALENDARUSAGELIMITSEXCEEDED',
          domain: 'UsageLimits',
        ),
        ApiFailure.throttled,
      );
    });

    test('only the moment-bound failures count as transient', () {
      const transient = {
        ApiFailure.throttled,
        ApiFailure.dailyLimit,
        ApiFailure.server,
        ApiFailure.auth,
      };
      for (final f in ApiFailure.values) {
        expect(isTransientFailure(f), transient.contains(f), reason: '$f');
      }
    });
  });

  group('Retry-After', () {
    final now = DateTime.utc(2026, 11, 11, 12);

    test('seconds', () {
      expect(parseRetryAfter('120', now: now), const Duration(seconds: 120));
      expect(parseRetryAfter(' 7 ', now: now), const Duration(seconds: 7));
      expect(parseRetryAfter('0', now: now), Duration.zero);
    });

    test('an HTTP date is the time until then', () {
      expect(
        parseRetryAfter('Wed, 11 Nov 2026 12:05:00 GMT', now: now),
        const Duration(minutes: 5),
      );
    });

    test('nonsense, the past and negative values mean no hint', () {
      expect(parseRetryAfter(null, now: now), isNull);
      expect(parseRetryAfter('', now: now), isNull);
      expect(parseRetryAfter('soon', now: now), isNull);
      expect(parseRetryAfter('-5', now: now), isNull);
      expect(
        parseRetryAfter('Wed, 11 Nov 2026 11:00:00 GMT', now: now),
        isNull,
      );
    });

    test('a huge wait is capped: we look again after an hour at most', () {
      expect(parseRetryAfter('86400', now: now), maxRetryAfter);
      expect(
        parseRetryAfter('Thu, 12 Nov 2026 12:00:00 GMT', now: now),
        maxRetryAfter,
      );
    });

    test(
      'the client remembers the header of the latest failure, once',
      () async {
        var status = 429;
        Map<String, String> headers = {'retry-after': '30'};
        final client = RetryAfterClient(
          MockClient((r) async => http.Response('x', status, headers: headers)),
          now: () => now,
        );
        await client.get(Uri.parse('https://example.com/a'));
        expect(client.takeRetryAfter(), const Duration(seconds: 30));
        expect(client.takeRetryAfter(), isNull, reason: 'taken once');

        // a failure without the header leaves no hint
        status = 503;
        headers = {};
        await client.get(Uri.parse('https://example.com/b'));
        expect(client.takeRetryAfter(), isNull);

        // a success clears a hint that nobody asked for
        status = 429;
        headers = {'retry-after': '10'};
        await client.get(Uri.parse('https://example.com/c'));
        status = 200;
        await client.get(Uri.parse('https://example.com/d'));
        expect(client.takeRetryAfter(), isNull);
      },
    );

    test('retryAfterOf is silent for any other client', () {
      expect(
        retryAfterOf(MockClient((r) async => http.Response('', 200))),
        isNull,
      );
    });
  });

  group('RemoteIdentity', () {
    const a = RemoteIdentity(account: 'anna@example.com', calendar: 'cal-1');

    test('is stored as one key and read back', () {
      final back = RemoteIdentity.tryParse(a.key)!;
      expect(back, a);
      expect(RemoteIdentity.tryParse(null), isNull);
      expect(RemoteIdentity.tryParse('no-separator'), isNull);
    });

    test('a calendar id may contain the separator character', () {
      const odd = RemoteIdentity(account: 'a@b.hu', calendar: 'x|y@group');
      // the LAST separator splits: the account never contains one
      expect(RemoteIdentity.tryParse(odd.key)!.calendar, 'y@group');
    });

    test('another calendar or another account is a different identity', () {
      expect(
        a.matches(
          const RemoteIdentity(account: 'anna@example.com', calendar: 'cal-2'),
        ),
        isFalse,
      );
      expect(
        a.matches(
          const RemoteIdentity(account: 'bela@example.com', calendar: 'cal-1'),
        ),
        isFalse,
      );
      expect(
        a.matches(
          const RemoteIdentity(account: 'anna@example.com', calendar: 'cal-1'),
        ),
        isTrue,
      );
    });

    test('an unknown account never counts as a change', () {
      const unknown = RemoteIdentity(account: '', calendar: 'cal-1');
      expect(a.matches(unknown), isTrue);
      expect(unknown.matches(a), isTrue);
    });

    test('the address is shown with most of the name hidden', () {
      expect(a.maskedAccount, 'a***@example.com');
      expect(
        const RemoteIdentity(account: '', calendar: 'c').maskedAccount,
        '(ismeretlen fiók)',
      );
      expect(
        const RemoteIdentity(account: 'x@y.hu', calendar: 'c').maskedAccount,
        'x@y.hu',
      );
      expect(a.maskedAccount.contains('nna'), isFalse);
    });

    test('a binding mismatch knows whether the ACCOUNT changed', () {
      const same = RemoteIdentity(
        account: 'anna@example.com',
        calendar: 'cal-2',
      );
      const other = RemoteIdentity(
        account: 'bela@example.com',
        calendar: 'cal-9',
      );
      expect(
        const SyncBindingMismatch(stored: a, current: same).accountChanged,
        isFalse,
      );
      expect(
        const SyncBindingMismatch(stored: a, current: other).accountChanged,
        isTrue,
      );
    });
  });

  group('errors read as text, never as a class dump', () {
    test('the sync exceptions have their own text', () {
      expect(SyncTokenExpired().toString(), isNot(contains('Instance of')));
      expect(ConflictException().toString(), isNot(contains('Instance of')));
      expect(CalendarGoneError().toString(), isNot(contains('Instance of')));
      expect(TransientSyncError('x').toString(), contains('x'));
    });

    test('the hints of the two constructors', () {
      final plain = TransientSyncError('net', const Duration(seconds: 5));
      expect(plain.throttled, isFalse);
      expect(plain.retryAfter, const Duration(seconds: 5));
      final hot = TransientSyncError.throttled('limit', dailyLimit: true);
      expect(hot.throttled, isTrue);
      expect(hot.dailyLimit, isTrue);
      expect(hot.retryAfter, isNull);
    });

    test('a rejection keeps its reason short', () {
      final e = ItemRejectedError(400, 'invalid', 'x' * 500);
      expect(e.toString().length, lessThan(160));
      expect(e.toString(), startsWith('http 400 invalid'));
    });
  });
}
