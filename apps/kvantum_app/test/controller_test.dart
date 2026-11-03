import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_core/kvantum_core.dart';

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
  calendarId: 'primary',
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

    ProviderContainer make(FakeAuth auth, {bool configured = true}) {
      db = AppDatabase(NativeDatabase.memory());
      remote = FakeRemote();
      final c = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          googleConfiguredProvider.overrideWithValue(configured),
          authGatewayProvider.overrideWithValue(auth),
          remoteFactoryProvider.overrideWithValue((_) => remote),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

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
      expect(s.error, contains('Belépés sikertelen'));
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
}
