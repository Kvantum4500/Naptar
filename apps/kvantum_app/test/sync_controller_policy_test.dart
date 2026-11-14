import 'dart:async';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_engine.dart';
import 'package:kvantum_app/sync/sync_pacer.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_remote.dart';
import 'support/turns.dart';

class _Auth implements AuthGateway {
  @override
  Future<http.Client?> restore() async => null;
  @override
  Future<http.Client> signIn() async => http.Client();
  @override
  Future<void> signOut() async {}
}

/// A timer that only fires when the test says so.
class _Timer implements Timer {
  _Timer(this.delay, this.action);
  final Duration delay;
  final void Function() action;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

/// Always the middle of the spread.
class _Middle implements Random {
  @override
  double nextDouble() => .5;
  @override
  bool nextBool() => true;
  @override
  int nextInt(int max) => 0;
}

CalEvent ev(String id, {int day = 4}) => CalEvent(
  id: id,
  calendarId: 'naptar',
  title: 't$id',
  tzid: 'Europe/Budapest',
  start: floating(2026, 5, day, 9),
  end: floating(2026, 5, day, 10),
);

TransientSyncError limit([Duration? wait]) => TransientSyncError.throttled(
  'http 403 rateLimitExceeded',
  retryAfter: wait,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late FakeRemote remote;
  late FakeDrive drive;
  late ProviderContainer c;
  late SyncController ctl;
  late EventRepository repo;
  late DateTime now;
  late List<_Timer> timers;

  _Timer? live() => timers.where((t) => !t.cancelled).lastOrNull;

  /// Delay of the timer armed by the latest run.
  Duration planned() => live()!.delay;

  SyncState st() => c.read(syncControllerProvider);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
    remote = FakeRemote();
    drive = FakeDrive();
    now = DateTime.utc(2026, 11, 11, 12);
    timers = [];
    c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        googleConfiguredProvider.overrideWithValue(true),
        authGatewayProvider.overrideWithValue(_Auth()),
        remoteFactoryProvider.overrideWithValue((_) => remote),
        driveFactoryProvider.overrideWithValue((_) => drive),
        syncPaceProvider.overrideWithValue(Duration.zero),
        syncClockProvider.overrideWithValue(() => now),
        syncPacerProvider.overrideWithValue(SyncPacer(random: _Middle())),
        syncSchedulerProvider.overrideWithValue((d, f) {
          final t = _Timer(d, f);
          timers.add(t);
          return t;
        }),
      ],
    );
    ctl = c.read(syncControllerProvider.notifier);
  });
  tearDown(() async {
    await ctl.signOut();
    c.dispose();
    await db.close();
  });

  group('the beat', () {
    test('a minute while it is new, then a longer and longer pause', () async {
      await ctl.signIn();
      final delays = [planned()];
      for (var i = 0; i < 5; i++) {
        await ctl.syncNow();
        delays.add(planned());
      }
      expect(delays, [
        for (final s in [60, 60, 180, 180, 180, 300]) Duration(seconds: s),
      ]);
      expect(st().nextAttempt, now.add(const Duration(minutes: 5)));
    });

    test('something to upload brings the lively beat back', () async {
      await ctl.signIn();
      for (var i = 0; i < 4; i++) {
        await ctl.syncNow();
      }
      expect(planned(), const Duration(minutes: 3));
      await repo.saveLocal(ev('a'));
      await ctl.syncNow();
      expect(planned(), const Duration(seconds: 60));
    });

    test('the timer is only armed in the foreground', () async {
      await ctl.signIn();
      expect(live(), isNotNull);
      ctl.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(live(), isNull, reason: 'cancelled in the background');
      await ctl.syncNow();
      expect(live(), isNull, reason: 'and not armed again meanwhile');
      expect(st().nextAttempt, isNotNull, reason: 'but the plan is known');
    });

    test('coming back looks at once only if the last look is old', () async {
      await ctl.signIn();
      final pulls = remote.pullCalls;
      ctl.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 10));
      ctl.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await turns(); // whatever would start, has started
      expect(remote.pullCalls, pulls, reason: '10 s: nothing new to look at');
      expect(live(), isNotNull, reason: 'the timer is back');

      ctl.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 2));
      ctl.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await turnUntil(
        () => remote.pullCalls > pulls,
        what: 'the look after 2 minutes',
      );
      await turns(); // and it is the one look
      expect(remote.pullCalls, pulls + 1, reason: '2 minutes: look now');
    });

    test('a window minimised on a computer keeps the beat', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await ctl.signIn();
      final t = live();
      expect(t, isNotNull);
      ctl.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(live(), same(t), reason: 'a program left open goes on syncing');
      await ctl.syncNow();
      expect(live(), isNotNull, reason: 'and the next look is planned');
      expect(live(), isNot(same(t)));
    });

    test('hidden on a phone stops the beat', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await ctl.signIn();
      ctl.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(live(), isNull);
      await ctl.syncNow();
      expect(live(), isNull);
    });

    test(
      'a computer stops the beat when the window is gone or paused',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await ctl.signIn();
        ctl.didChangeAppLifecycleState(AppLifecycleState.detached);
        expect(live(), isNull);
        ctl.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(live(), isNotNull);
        ctl.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(live(), isNull);
      },
    );

    test('losing focus (inactive) changes nothing', () async {
      await ctl.signIn();
      final t = live();
      ctl.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(live(), same(t));
    });
  });

  group('after a failure', () {
    test(
      'a limit backs off, never sooner than Retry-After, and recovers',
      () async {
        await repo.saveLocal(ev('a'));
        remote.failUpsertAt.addAll({
          1: limit(const Duration(minutes: 7)),
          2: limit(),
          3: limit(),
        });
        await ctl.signIn();
        expect(st().error, contains('korlátozza'));
        expect(st().error, isNot(contains('Instance of')));
        expect(
          planned(),
          const Duration(minutes: 7),
          reason: 'Retry-After wins',
        );
        expect(st().pending, 1);
        expect(st().lastSync, isNull);

        await ctl.syncNow();
        expect(
          planned(),
          const Duration(seconds: 120),
          reason: 'second failure',
        );
        await ctl.syncNow();
        expect(planned(), const Duration(seconds: 240));

        await ctl.syncNow();
        expect(st().error, isNull);
        expect(st().pending, 0);
        expect(
          planned(),
          const Duration(seconds: 60),
          reason: 'all well again',
        );
      },
    );

    test('a network problem is gentler than a limit', () async {
      remote.offline = true;
      await ctl.signIn();
      for (var i = 0; i < 6; i++) {
        await ctl.syncNow();
      }
      expect(planned(), const Duration(minutes: 5));
      expect(st().error, contains('kapcsolat'));
    });

    test('a daily limit waits at least half an hour', () async {
      await repo.saveLocal(ev('a'));
      remote.failUpsertAt[1] = TransientSyncError.throttled(
        'x',
        dailyLimit: true,
      );
      await ctl.signIn();
      expect(planned(), greaterThanOrEqualTo(const Duration(minutes: 30)));
      expect(st().error, contains('mára'));
    });

    test('Drive limits count too, with the server\'s wish', () async {
      drive.failWith = DriveTransientError.throttled(
        'x',
        retryAfter: const Duration(minutes: 10),
      );
      await ctl.signIn();
      expect(st().error, startsWith('Drive:'));
      expect(planned(), const Duration(minutes: 10));
    });

    test('a saved edit does not start a run while backing off', () async {
      remote.offline = true;
      await ctl.signIn();
      timers.clear();
      ctl.requestSync();
      expect(timers, isEmpty, reason: 'the planned run carries the edit');
    });

    test(
      'a saved edit starts a run in a couple of seconds when all is well',
      () async {
        await ctl.signIn();
        timers.clear();
        ctl.requestSync();
        expect(timers.single.delay, const Duration(seconds: 2));
        ctl.requestSync(); // a burst of edits is one run
        expect(timers.where((t) => !t.cancelled).length, 1);
      },
    );

    test(
      '"Szinkron most" does not wait: it runs, and starts the beat over',
      () async {
        remote.offline = true;
        await ctl.signIn();
        await ctl.syncNow();
        expect(planned(), const Duration(seconds: 120));
        final pulls = remote.pullCalls;
        remote.offline = false;
        await ctl.syncNow(manual: true);
        expect(remote.pullCalls, pulls + 1);
        expect(st().error, isNull);
        expect(planned(), const Duration(seconds: 60));
      },
    );

    test(
      'a manual sync that fails starts the ladder from its first step',
      () async {
        remote.offline = true;
        await ctl.signIn();
        for (var i = 0; i < 3; i++) {
          await ctl.syncNow();
        }
        expect(
          planned(),
          const Duration(minutes: 5),
          reason: 'the fourth failure',
        );
        await ctl.syncNow(manual: true);
        expect(planned(), const Duration(seconds: 60), reason: 'a new series');
      },
    );

    test('given-up uploads are tried again by a manual sync only', () async {
      await repo.saveLocal(ev('a'));
      for (var i = 1; i <= 10; i++) {
        remote.failUpsertAt[i] = ItemRejectedError(400, 'invalid', 'x');
      }
      await ctl.signIn(); // 1st refusal (the sign-in sync is a manual one)
      for (var i = 0; i < 4; i++) {
        await ctl.syncNow();
      }
      expect(st().parked, 1);
      expect(st().error, contains('nem erőltetem'));
      final calls = remote.upsertCalls;
      await ctl.syncNow();
      expect(remote.upsertCalls, calls, reason: 'left alone');

      remote.failUpsertAt.clear();
      await ctl.syncNow(manual: true);
      expect(st().parked, 0);
      expect(st().pending, 0);
      expect(st().error, isNull);
    });

    test('the calendar vanishing is said in words and tried again', () async {
      remote.calendarGone = true;
      await ctl.signIn();
      expect(st().error, contains('Google-naptár'));
      expect(live(), isNotNull);
      remote.calendarGone = false;
      await ctl.syncNow();
      expect(st().error, isNull);
    });

    test(
      'events the adapter could not read are reported, not hidden',
      () async {
        remote.externalCreate(ev('x'));
        remote.skipped = const [SkippedRemote('bad', 'FormatException')];
        await ctl.signIn();
        expect(st().error, contains('1 Google-esemény nem olvasható be'));
        expect(st().lastSync, isNotNull, reason: 'the sync itself worked');
      },
    );

    test('a surprise is a Hungarian line, not an exception dump', () async {
      remote.failWith = StateError('secret details');
      await ctl.signIn();
      expect(st().error, contains('váratlan hiba'));
      expect(st().error, isNot(contains('StateError')));
      expect(st().error, isNot(contains('secret details')));
      expect(live(), isNotNull);
    });
  });

  group('more to upload than one run does', () {
    test('the rest follows in seconds, not minutes', () async {
      await repo.saveAll([
        for (var i = 0; i < 155; i++) ev('e$i', day: 1 + i % 28),
      ]);
      await ctl.signIn();
      expect(remote.events.length, 150);
      expect(planned(), SyncPacer.followUp);
      await ctl.syncNow();
      expect(remote.events.length, 155);
      expect(planned(), const Duration(seconds: 60));
    });
  });

  group('another account or calendar', () {
    Future<void> signedInWithOneEvent() async {
      await repo.saveLocal(ev('a'));
      await ctl.signIn();
      expect(remote.events.length, 1);
    }

    void switchAccount() {
      // a different Google account: its calendar is empty
      remote.who = const RemoteIdentity(
        account: 'other@example.com',
        calendar: 'cal-OTHER',
      );
      remote.events.clear();
      remote.appIdToGoogle.clear();
    }

    test('the calendar sync stops and says why; Drive carries on', () async {
      await signedInWithOneEvent();
      switchAccount();
      await c
          .read(recordRepoProvider)
          .edit(kindTask, 't1', taskFields(title: 'Drive megy tovább'));
      final pulls = remote.pullCalls, ups = remote.upsertCalls;
      await ctl.syncNow();
      expect(st().mismatch, isNotNull);
      expect(st().mismatch!.accountChanged, isTrue);
      expect(st().lastSync, isNotNull, reason: 'from the earlier good run');
      expect(remote.pullCalls, pulls);
      expect(remote.upsertCalls, ups);
      expect(await repo.all(), hasLength(1));
      expect(drive.files.values.any((f) => f.name == 'task-t1.json'), isTrue);
    });

    test(
      'keep the local events: they go up to the new calendar, once',
      () async {
        await signedInWithOneEvent();
        switchAccount();
        await ctl.syncNow();
        await repo.saveLocal(
          ev('b', day: 5),
        ); // made while waiting for a decision
        await ctl.keepLocalAfterMismatch();
        expect(st().mismatch, isNull);
        expect(st().error, isNull);
        expect(remote.events.length, 2);
        expect(await repo.meta(syncBindingKey), 'other@example.com|cal-OTHER');
        expect(st().pending, 0);
        await ctl.syncNow();
        expect(st().mismatch, isNull, reason: 'the new link is remembered');
        expect(remote.events.length, 2, reason: 'no duplicates');
        expect(await repo.all(), hasLength(2));
      },
    );

    test(
      'a deletion that waited for the old calendar is not sent to the new one',
      () async {
        await signedInWithOneEvent();
        await repo.saveLocal(ev('c', day: 6));
        await ctl.syncNow(); // both events are in Google now
        switchAccount();
        await ctl.syncNow(); // the question appears
        await repo.deleteLocal('c'); // the deletion waits
        await ctl.keepLocalAfterMismatch();
        expect(remote.pushLog.where((e) => e.$1 == 'delete'), isEmpty);
        expect(await repo.byId('c'), isNull);
        expect(remote.events.length, 1, reason: 'only the event still here');
      },
    );

    test('a fresh start: local events go, the new calendar\'s come', () async {
      await signedInWithOneEvent();
      switchAccount();
      remote.externalCreate(ev('theirs', day: 9));
      await ctl.syncNow();
      await repo.saveLocal(ev('b', day: 5)); // not uploaded yet
      expect(await ctl.localEventCount(), 2);
      await ctl.startFreshAfterMismatch();
      expect(st().mismatch, isNull);
      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.title, 'ttheirs');
      expect(remote.events.length, 1, reason: 'nothing was uploaded');
    });

    test('"later" just leaves the question open', () async {
      await signedInWithOneEvent();
      switchAccount();
      await ctl.syncNow();
      await ctl.syncNow();
      expect(st().mismatch, isNotNull);
      expect(await repo.all(), hasLength(1));
    });

    test('signing out forgets the open question', () async {
      await signedInWithOneEvent();
      switchAccount();
      await ctl.syncNow();
      await ctl.signOut();
      expect(st().mismatch, isNull);
      expect(st().signedIn, isFalse);
    });
  });

  group('"Szinkron alaphelyzetbe"', () {
    test(
      'everything is linked again, nothing is duplicated or deleted',
      () async {
        await repo.saveLocal(ev('a'));
        await repo.saveLocal(ev('b', day: 5));
        await c
            .read(recordRepoProvider)
            .edit(kindTask, 't1', taskFields(title: 'Feladat'));
        await ctl.signIn();
        final before = {for (final e in await repo.all()) e.id: e.googleId};
        String taskFile() => drive.files.values
            .singleWhere((f) => f.name == 'task-t1.json')
            .content;
        final taskBefore = taskFile();
        final creates = drive.creates;
        expect(before.values, everyElement(isNotNull));

        // old events are not part of the (windowed) listing: only the cut
        // link and the lookup by their own id can find them again
        remote.windowStartUtc = DateTime.utc(2026, 11, 1);
        await ctl.resetSync();

        expect(remote.events.length, 2, reason: 'no duplicates in Google');
        final after = {for (final e in await repo.all()) e.id: e.googleId};
        expect(after, before, reason: 'found again by their own ids');
        expect(st().pending, 0);
        expect(st().error, isNull);
        expect(
          drive.files.values.where((f) => f.name == 'task-t1.json'),
          hasLength(1),
          reason: 'the task file is not duplicated',
        );
        expect(taskFile(), taskBefore, reason: 'identical content: no rewrite');
        expect(drive.creates, creates, reason: 'and no new file');
        expect(
          remote.upsertLinks.skip(2),
          everyElement(isNull),
          reason: 'the links were cut before the uploads',
        );
        expect(
          remote.pullTokens.skip(1),
          contains(null),
          reason: 'the listing started from the beginning',
        );
        expect(
          await repo.meta('syncToken:naptar'),
          isNotNull,
          reason: 'and a fresh token afterwards',
        );
      },
    );

    test('a record file that Drive lost comes back', () async {
      await c
          .read(recordRepoProvider)
          .edit(kindTask, 't1', taskFields(title: 'Feladat'));
      await ctl.signIn();
      drive.files.clear(); // Drive lost it without telling anyone
      await ctl.syncNow();
      expect(drive.files.values.any((f) => f.name == 'task-t1.json'), isFalse);
      await ctl.resetSync();
      expect(drive.files.values.any((f) => f.name == 'task-t1.json'), isTrue);
    });

    test('it also gives parked uploads a new chance', () async {
      await repo.saveLocal(ev('a'));
      for (var i = 1; i <= 5; i++) {
        remote.failUpsertAt[i] = ItemRejectedError(400, 'invalid', 'x');
      }
      await ctl.signIn();
      for (var i = 0; i < 4; i++) {
        await ctl.syncNow();
      }
      expect(st().parked, 1);
      await ctl.resetSync();
      expect(st().parked, 0);
      expect(remote.events.length, 1);
    });
  });

  group('the finance mailbox is looked at when there is news', () {
    test(
      'quiet ticks skip it; a fifth tick, news, own changes and "now" do not',
      () async {
        drive.forceFinChanged = false;
        await ctl.signIn(); // tick 0 looks
        final base = drive.listCalls;
        expect(base, greaterThan(0));
        for (var i = 0; i < 4; i++) {
          await ctl.syncNow(); // ticks 1..4
        }
        expect(drive.listCalls, base, reason: 'nothing to look at');
        await ctl.syncNow(); // tick 5
        expect(drive.listCalls, greaterThan(base), reason: 'safety net');

        final afterNet = drive.listCalls;
        drive.forceFinChanged = true; // Drive says: mail files changed
        await ctl.syncNow();
        expect(drive.listCalls, greaterThan(afterNet));

        drive.forceFinChanged = false;
        final afterNews = drive.listCalls;
        await ctl.syncNow();
        expect(drive.listCalls, afterNews);
        await ctl.syncNow(manual: true);
        expect(drive.listCalls, greaterThan(afterNews), reason: 'asked for');
      },
    );

    test('a finance change of our own is sent at once', () async {
      drive.forceFinChanged = false;
      await ctl.signIn();
      await ctl.syncNow();
      final before = drive.listCalls;
      await c
          .read(financeRepoProvider)
          .saveTx(
            FinTx(
              id: 'tx1',
              date: DateTime.utc(2026, 11, 11),
              amount: 1200,
              kind: FinKind.expense,
              merchant: 'Bolt',
            ),
          );
      await ctl.syncNow();
      expect(drive.listCalls, greaterThan(before));
    });
  });
}
