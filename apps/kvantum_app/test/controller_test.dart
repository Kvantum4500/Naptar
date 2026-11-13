import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/remote.dart' show TransientSyncError;
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_remote.dart';

class FakeAuth implements AuthGateway {
  FakeAuth({this.restored = false, this.failSignIn = false});
  final bool restored;
  final bool failSignIn;
  bool signedOut = false;
  @override
  Future<http.Client?> restore() async => restored ? http.Client() : null;
  @override
  Future<http.Client> signIn() async {
    if (failSignIn) throw Exception('cancelled');
    return http.Client();
  }

  @override
  Future<void> signOut() async => signedOut = true;
}

CalEvent ev(String id) => CalEvent(
  id: id,
  calendarId: 'naptar',
  title: 't',
  tzid: 'Europe/Budapest',
  start: floating(2026, 5, 4, 9),
  end: floating(2026, 5, 4, 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTimeZones);

  group('credentials', () {
    test('round-trip keeps refresh token, expiry (UTC) and scopes', () {
      final c = AccessCredentials(
        AccessToken('Bearer', 'tok', DateTime.utc(2026, 11, 3, 12)),
        'refresh-123',
        ['a', 'b'],
      );
      final back = decodeCredentials(encodeCredentials(c))!;
      expect(back.accessToken.data, 'tok');
      expect(back.accessToken.expiry, DateTime.utc(2026, 11, 3, 12));
      expect(back.refreshToken, 'refresh-123');
      expect(back.scopes, ['a', 'b']);
    });
    test('missing or corrupt storage means signed out, never a crash', () {
      expect(decodeCredentials(null), isNull);
      expect(decodeCredentials('not json'), isNull);
      expect(decodeCredentials('{"type":1}'), isNull);
    });
    test(
      'config is empty (not configured) unless provided via dart-define',
      () {
        expect(GoogleConfig.isConfigured, isFalse);
      },
    );
  });

  group('SyncController', () {
    late AppDatabase db;
    late FakeRemote remote;
    late FakeDrive drive;

    ProviderContainer make(FakeAuth auth, {bool configured = true}) {
      db = AppDatabase(NativeDatabase.memory());
      remote = FakeRemote();
      drive = FakeDrive();
      final c = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          googleConfiguredProvider.overrideWithValue(configured),
          authGatewayProvider.overrideWithValue(auth),
          remoteFactoryProvider.overrideWithValue((_) => remote),
          driveFactoryProvider.overrideWithValue((_) => drive),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('the Drive folder of the account is there while signed in, and gone '
        'after signing out (the backup copies are kept in it)', () async {
      final c = make(FakeAuth());
      final ctl = c.read(syncControllerProvider.notifier);
      expect(ctl.driveRemote(), isNull);
      await ctl.signIn();
      expect(ctl.driveRemote(), same(drive));
      await ctl.signOut();
      expect(ctl.driveRemote(), isNull);
      await db.close();
    });

    test('while the changes go up the state says how far they are; after the '
        'run it says nothing', () async {
      final c = make(FakeAuth());
      for (final id in ['a', 'b', 'c']) {
        await EventRepoHelper(db).save(ev(id));
      }
      final wire = Completer<void>();
      remote.upsertGateAt[2] = wire; // the second upload is on the wire
      final run = c.read(syncControllerProvider.notifier).signIn();
      while (remote.upsertCalls < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final mid = c.read(syncControllerProvider);
      expect(mid.syncing, isTrue);
      expect(mid.upload, (done: 1, total: 3));
      wire.complete();
      await run;
      final end = c.read(syncControllerProvider);
      expect(end.syncing, isFalse);
      expect(end.upload, isNull);
      expect(end.pending, 0);
      await db.close();
    });

    test('a run that ends in a failure leaves no progress behind', () async {
      final c = make(FakeAuth());
      for (final id in ['a', 'b']) {
        await EventRepoHelper(db).save(ev(id));
      }
      remote.failUpsertAt[2] = TransientSyncError('offline');
      await c.read(syncControllerProvider.notifier).signIn();
      final s = c.read(syncControllerProvider);
      expect(s.syncing, isFalse);
      expect(s.upload, isNull);
      expect(s.error, isNotNull);
      await db.close();
    });

    test('not configured: nothing happens, no sign-in possible', () async {
      final c = make(FakeAuth(), configured: false);
      expect(c.read(syncControllerProvider).configured, isFalse);
      await c.read(syncControllerProvider.notifier).signIn();
      expect(c.read(syncControllerProvider).signedIn, isFalse);
      await db.close();
    });

    test(
      'sign-in pushes pending local edits and records the sync time',
      () async {
        final c = make(FakeAuth());
        await EventRepoHelper(db).save(ev('a'));
        await c.read(syncControllerProvider.notifier).signIn();
        final s = c.read(syncControllerProvider);
        expect(s.signedIn, isTrue);
        expect(s.syncing, isFalse);
        expect(s.error, isNull);
        expect(s.lastSync, isNotNull);
        expect(s.pending, 0);
        expect(remote.events.length, 1);
        c.read(syncControllerProvider.notifier).signOut();
        await db.close();
      },
    );

    test('restored session signs in silently on start', () async {
      final c = make(FakeAuth(restored: true));
      c.read(syncControllerProvider); // triggers build -> restore
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(syncControllerProvider).signedIn, isTrue);
      c.read(syncControllerProvider.notifier).signOut();
      await db.close();
    });

    test('failed sign-in shows an error and stays signed out', () async {
      final c = make(FakeAuth(failSignIn: true));
      await c.read(syncControllerProvider.notifier).signIn();
      final s = c.read(syncControllerProvider);
      expect(s.signedIn, isFalse);
      expect(s.error, contains('A bejelentkezés nem sikerült'));
      expect(
        s.error,
        isNot(contains('cancelled')),
        reason: 'the text of the exception is not shown',
      );
      expect(s.error, isNot(contains('Exception')));
      await db.close();
    });

    test(
      'offline: keeps the queue, reports it, recovers on next sync',
      () async {
        final c = make(FakeAuth());
        await EventRepoHelper(db).save(ev('a'));
        remote.offline = true;
        final ctl = c.read(syncControllerProvider.notifier);
        await ctl.signIn();
        var s = c.read(syncControllerProvider);
        expect(s.error, isNotNull);
        expect(s.pending, 1);
        remote.offline = false;
        await ctl.syncNow();
        s = c.read(syncControllerProvider);
        expect(s.error, isNull);
        expect(s.pending, 0);
        expect(remote.events.length, 1);
        ctl.signOut();
        await db.close();
      },
    );

    test(
      'tasks and check-ins are uploaded to Drive together with the calendar',
      () async {
        final c = make(FakeAuth());
        await c
            .read(recordRepoProvider)
            .edit(kindTask, 't1', taskFields(title: 'Edzés'));
        await c.read(syncControllerProvider.notifier).signIn();
        final s = c.read(syncControllerProvider);
        expect(s.error, isNull);
        expect(s.pending, 0);
        expect(
          drive.files.values
              .where((f) => !f.name.startsWith('fin-'))
              .single
              .name,
          'task-t1.json',
        );
        c.read(syncControllerProvider.notifier).signOut();
        await db.close();
      },
    );

    test(
      'Drive offline does not block the calendar, and the error names Drive',
      () async {
        final c = make(FakeAuth());
        await EventRepoHelper(db).save(ev('a'));
        await c
            .read(recordRepoProvider)
            .edit(kindTask, 't1', taskFields(title: 'x'));
        drive.offline = true;
        final ctl = c.read(syncControllerProvider.notifier);
        await ctl.signIn();
        var s = c.read(syncControllerProvider);
        expect(remote.events.length, 1); // calendar went through
        expect(s.error, contains('Drive'));
        expect(s.error, isNot(contains('Naptár')));
        expect(s.pending, 1); // the task is still queued
        drive.offline = false;
        await ctl.syncNow();
        s = c.read(syncControllerProvider);
        expect(s.error, isNull);
        expect(s.pending, 0);
        expect(
          drive.files.values.where((f) => !f.name.startsWith('fin-')).length,
          1,
        );
        ctl.signOut();
        await db.close();
      },
    );

    test('a calendar failure does not block Drive', () async {
      final c = make(FakeAuth());
      await c
          .read(recordRepoProvider)
          .edit(kindTask, 't1', taskFields(title: 'x'));
      await EventRepoHelper(db).save(ev('a'));
      remote.offline = true;
      final ctl = c.read(syncControllerProvider.notifier);
      await ctl.signIn();
      final s = c.read(syncControllerProvider);
      expect(
        drive.files.values.where((f) => !f.name.startsWith('fin-')).length,
        1,
      );
      expect(s.error, contains('Naptár'));
      ctl.signOut();
      await db.close();
    });

    const expiredMsg =
        'Failed to obtain access credentials. Error: invalid_grant Token has been expired or revoked. Status code: 400';

    test(
      'an expired Google login is reported once, signs out and keeps the queue',
      () async {
        final auth = FakeAuth();
        final c = make(auth);
        await EventRepoHelper(db).save(ev('a'));
        remote.failWith = Exception(expiredMsg);
        drive.failWith = Exception(expiredMsg);
        final ctl = c.read(syncControllerProvider.notifier);
        await ctl.signIn();
        final s = c.read(syncControllerProvider);
        expect(s.signedIn, isFalse);
        expect(s.syncing, isFalse);
        expect(auth.signedOut, isTrue);
        expect(s.error, contains('lejárt'));
        expect(s.error, isNot(contains('invalid_grant')));
        // the unsent change is still queued locally
        expect((await EventRepoHelper(db).pendingCount()), 1);

        // after signing in again everything goes up
        remote.failWith = null;
        drive.failWith = null;
        await ctl.signIn();
        final after = c.read(syncControllerProvider);
        expect(after.signedIn, isTrue);
        expect(after.error, isNull);
        expect(after.pending, 0);
        await ctl.signOut();
        await db.close();
      },
    );

    test('the expiry is recognised on Drive alone, too', () async {
      final auth = FakeAuth();
      final c = make(auth);
      drive.failWith = Exception(expiredMsg);
      await c.read(syncControllerProvider.notifier).signIn();
      final s = c.read(syncControllerProvider);
      expect(s.signedIn, isFalse);
      expect(s.error, contains('lejárt'));
      await db.close();
    });

    test('a plain network problem does not sign out', () async {
      final c = make(FakeAuth());
      remote.offline = true;
      drive.offline = true;
      await c.read(syncControllerProvider.notifier).signIn();
      final s = c.read(syncControllerProvider);
      expect(s.signedIn, isTrue);
      expect(s.error, isNotNull);
      expect(s.error, isNot(contains('lejárt')));
      await c.read(syncControllerProvider.notifier).signOut();
      await db.close();
    });

    test('what counts as an expired login', () {
      expect(SyncController.isAuthExpired(Exception(expiredMsg)), isTrue);
      expect(SyncController.isAuthExpired('Error: invalid_grant'), isTrue);
      expect(
        SyncController.isAuthExpired('Token has been expired or revoked'),
        isTrue,
      );
      expect(SyncController.isAuthExpired(Exception('offline')), isFalse);
      expect(SyncController.isAuthExpired(const FormatException('x')), isFalse);
      // the auth library uses this wording for ANY failed token request,
      // a Google 5xx / 429 included: that is not an expired login
      expect(
        SyncController.isAuthExpired(
          Exception('Failed to obtain access credentials. Status code: 503'),
        ),
        isFalse,
      );
      expect(
        SyncController.isAuthExpired(
          Exception(
            'Failed to obtain access credentials. Error: temporarily_unavailable Status code: 429',
          ),
        ),
        isFalse,
      );
    });

    test('a Google 5xx at token refresh does not sign the user out', () async {
      final auth = FakeAuth();
      final c = make(auth);
      await EventRepoHelper(db).save(ev('a'));
      remote.failWith = Exception(
        'Failed to obtain access credentials. Status code: 503',
      );
      final ctl = c.read(syncControllerProvider.notifier);
      await ctl.signIn();
      final s = c.read(syncControllerProvider);
      expect(auth.signedOut, isFalse);
      expect(s.signedIn, isTrue);
      expect(s.error, isNotNull);
      expect(s.error, isNot(contains('lejárt')));
      // and it recovers by itself once Google answers again
      remote.failWith = null;
      await ctl.syncNow();
      expect(c.read(syncControllerProvider).error, isNull);
      expect(remote.events.length, 1);
    });

    test(
      'calls during a running sync fold into ONE follow-up run, not a queue',
      () async {
        final c = make(FakeAuth());
        final ctl = c.read(syncControllerProvider.notifier);
        await ctl.signIn();
        remote.pullCalls = 0;
        remote.gate = Completer<void>();
        final first = ctl.syncNow(); // blocks at the gate: a slow connection
        await Future<void>.delayed(Duration.zero);
        expect(remote.pullCalls, 1);

        // the minute timer, coming back to the app, saved edits …
        await Future.wait([ctl.syncNow(), ctl.syncNow(), ctl.syncNow()]);
        expect(remote.pullCalls, 1, reason: 'nobody started a second sync');

        final gate = remote.gate!;
        remote.gate = null; // the follow-up run must not wait
        gate.complete();
        await first;
        expect(remote.pullCalls, 2, reason: 'exactly one follow-up run');
        expect(c.read(syncControllerProvider).syncing, isFalse);
      },
    );

    test('sign-out clears state and credentials', () async {
      final auth = FakeAuth();
      final c = make(auth);
      final ctl = c.read(syncControllerProvider.notifier);
      await ctl.signIn();
      await ctl.signOut();
      expect(auth.signedOut, isTrue);
      expect(c.read(syncControllerProvider).signedIn, isFalse);
      await db.close();
    });
  });
}

class EventRepoHelper {
  EventRepoHelper(this.db);
  final AppDatabase db;
  Future<void> save(CalEvent e) => EventRepository(db).saveLocal(e);
  Future<int> pendingCount() async =>
      (await EventRepository(db).pending()).length;
}
