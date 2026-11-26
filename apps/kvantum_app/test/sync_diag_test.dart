import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/diag/newer_format.dart';
import 'package:kvantum_app/diag/request_stats.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/channel_status.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_engine.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_remote.dart';

/// Stands in for what an exception says: it must never reach the screen.
const _secret = 'titkos-szöveg-123';

class _Auth implements AuthGateway {
  _Auth({this.failSignIn = false});
  final bool failSignIn;
  @override
  Future<http.Client?> restore() async => null;
  @override
  Future<http.Client> signIn() async {
    if (failSignIn) throw Exception(_secret);
    return http.Client();
  }

  @override
  Future<void> signOut() async {}
}

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

/// The finance database "breaks" in the middle of a run, outside the guards
/// of the three channels.
class _BrokenFinance extends FinanceRepository {
  _BrokenFinance(super.db);
  @override
  Future<int> dirtyCount() async => throw StateError(_secret);
}

CalEvent ev(String id) => CalEvent(
  id: id,
  calendarId: 'naptar',
  title: 't$id',
  tzid: 'Europe/Budapest',
  start: floating(2026, 5, 4, 9),
  end: floating(2026, 5, 4, 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late EventRepository repo;
  late FakeRemote remote;
  late FakeDrive drive;
  late MemoryDiagSink sink;
  late DiagLog log;
  late DateTime now;
  late List<_Timer> timers;
  ProviderContainer? c;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = EventRepository(db);
    remote = FakeRemote();
    drive = FakeDrive();
    sink = MemoryDiagSink();
    now = DateTime.utc(2026, 11, 12, 12);
    log = DiagLog(now: () => now)..attach(sink);
    timers = [];
    c = null;
  });
  tearDown(() async {
    if (c != null) {
      await c!.read(syncControllerProvider.notifier).signOut();
      c!.dispose();
    }
    await db.close();
  });

  SyncController make({AuthGateway? auth, List<Override> extra = const []}) {
    c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        googleConfiguredProvider.overrideWithValue(true),
        authGatewayProvider.overrideWithValue(auth ?? _Auth()),
        remoteFactoryProvider.overrideWithValue((_) => remote),
        driveFactoryProvider.overrideWithValue((_) => drive),
        syncPaceProvider.overrideWithValue(Duration.zero),
        syncClockProvider.overrideWithValue(() => now),
        syncSchedulerProvider.overrideWithValue((d, f) {
          final t = _Timer(d, f);
          timers.add(t);
          return t;
        }),
        diagLogProvider.overrideWithValue(log),
        ...extra,
      ],
    );
    return c!.read(syncControllerProvider.notifier);
  }

  SyncState st() => c!.read(syncControllerProvider);

  Future<List<DiagEntry>> logged() async {
    await log.flush();
    return [for (final l in sink.lines) DiagEntry.tryParse(l)!];
  }

  group('the controller', () {
    test(
      'an unexpected failure of a channel: Hungarian line, a log entry',
      () async {
        remote.failWith = StateError(_secret);
        final ctl = make();
        await ctl.signIn();

        expect(st().error, contains('váratlan hiba'));
        expect(st().error, isNot(contains(_secret)));
        expect(st().error, isNot(contains('StateError')));
        final e = (await logged()).singleWhere(
          (e) => e.code == 'calendar.unexpected',
        );
        expect(e.area, 'sync');
        expect(e.error, startsWith('StateError'));
        expect(st().channels[channelCalendar]!.code, 'unexpected');
        expect(st().channels[channelCalendar]!.lastOk, isNull);
        // the other channels went on
        expect(st().channels[channelDrive]!.ok, isTrue);
      },
    );

    test(
      'every channel reports what it found, and keeps the last good time',
      () async {
        final ctl = make();
        await ctl.signIn();
        final t0 = now;
        expect(st().channels.keys, containsAll(syncChannels));
        for (final ch in syncChannels) {
          expect(st().channels[ch]!.ok, isTrue, reason: ch);
          expect(st().channels[ch]!.lastOk, t0, reason: ch);
          expect(st().channels[ch]!.lastTry, t0, reason: ch);
        }

        now = t0.add(const Duration(minutes: 5));
        remote.offline = true;
        await ctl.syncNow(manual: true);

        final cal = st().channels[channelCalendar]!;
        expect(cal.code, 'transient');
        expect(cal.text, contains('Naptár'));
        expect(cal.lastTry, now);
        expect(cal.lastOk, t0, reason: 'the last time it worked');
        expect(
          st().channels[channelDrive]!.lastOk,
          now,
          reason: 'Drive is fine',
        );
      },
    );

    test(
      'a refused upload shows as a problem of the calendar channel',
      () async {
        await repo.saveLocal(ev('a'));
        remote.failUpsertAt[1] = ItemRejectedError(400, 'invalid', _secret);
        final ctl = make();
        await ctl.signIn();
        final cal = st().channels[channelCalendar]!;
        expect(cal.code, 'refused');
        expect(cal.failed, 1);
        expect(cal.text, contains('1 módosítást'));
      },
    );

    test(
      'a failure outside the channel guards does not hang the sync',
      () async {
        final ctl = make(
          extra: [financeRepoProvider.overrideWithValue(_BrokenFinance(db))],
        );
        await ctl.signIn();

        expect(st().syncing, isFalse, reason: 'not "syncing" for ever');
        expect(st().error, contains('váratlan hiba'));
        expect(st().error, isNot(contains(_secret)));
        expect(
          timers.where((t) => !t.cancelled),
          isNotEmpty,
          reason: 'the next run is still planned',
        );
        expect(st().nextAttempt, isNotNull);
        final e = (await logged()).singleWhere((e) => e.code == 'run.crashed');
        expect(e.error, startsWith('StateError'));
      },
    );

    test(
      'a failed sign-in: Hungarian text, no exception text, a log entry',
      () async {
        final ctl = make(auth: _Auth(failSignIn: true));
        await ctl.signIn();
        expect(st().signedIn, isFalse);
        expect(st().error, startsWith('A bejelentkezés nem sikerült'));
        expect(st().error, isNot(contains(_secret)));
        expect(
          (await logged()).map((e) => '${e.area}/${e.code}'),
          contains('auth/signin.failed'),
        );
      },
    );

    test('an expired login is logged', () async {
      remote.failWith = Exception('invalid_grant');
      final ctl = make();
      await ctl.signIn();
      expect(st().signedIn, isFalse);
      expect(
        (await logged()).map((e) => '${e.area}/${e.code}'),
        contains('auth/expired'),
      );
    });

    test(
      'the counted requests are added to the stored table after a run',
      () async {
        final stats = RequestStats(now: () => now)
          ..record('calendar', status: 200)
          ..record('calendar', status: 429)
          ..record('drive', status: 500);
        final ctl = make(
          extra: [requestStatsProvider.overrideWithValue(stats)],
        );
        await ctl.signIn();

        final t = RequestStats.decode(await repo.meta(RequestStats.metaKey));
        final today = t[dayKeyOf(now)]!;
        expect(today['calendar']!.calls, 2);
        expect(today['calendar']!.throttled, 1);
        expect(today['drive']!.server, 1);
        // and they are not counted a second time
        await ctl.syncNow(manual: true);
        final again = RequestStats.decode(
          await repo.meta(RequestStats.metaKey),
        );
        expect(again[dayKeyOf(now)]!['calendar']!.calls, 2);
      },
    );

    test(
      'files of a newer version are remembered, and forgotten when gone',
      () async {
        final id = drive.externalWrite(
          'task-t1.json',
          '{"v":2,"id":"t1","kind":"task","f":{"title":"x"}}',
        );
        final ctl = make();
        await ctl.signIn();

        expect(st().channels[channelDrive]!.code, 'newer');
        final seen = decodeNewerFormat(await repo.meta(newerFormatKey));
        expect(seen.keys, ['drive']);
        expect(seen['drive']!.count, 1);
        expect((await logged()).map((e) => e.code), contains('newer_format'));

        drive.externalDelete(id);
        await ctl.syncNow();
        expect(await repo.meta(newerFormatKey), isNull);
        expect(st().channels[channelDrive]!.ok, isTrue);
      },
    );
  });

  group('updateSightings', () {
    final t0 = DateTime.utc(2026, 11, 12, 12);

    test('notes a channel, keeps the others, clears at zero', () {
      var s = updateSightings({}, now: t0, drive: 2);
      expect(s['drive']!.count, 2);
      s = updateSightings(s, now: t0, finance: 1);
      expect(s.keys.toSet(), {'drive', 'finance'});
      s = updateSightings(s, now: t0, drive: 0);
      expect(s.keys, ['finance']);
      s = updateSightings(s, now: t0, drive: null, finance: null);
      expect(s.keys, ['finance'], reason: 'not looked at: keep what is known');
    });

    test('the time moves on at most once an hour', () {
      var s = updateSightings({}, now: t0, drive: 1);
      s = updateSightings(
        s,
        now: t0.add(const Duration(minutes: 30)),
        drive: 1,
      );
      expect(s['drive']!.at, t0);
      s = updateSightings(s, now: t0.add(const Duration(hours: 1)), drive: 1);
      expect(s['drive']!.at, t0.add(const Duration(hours: 1)));
      s = updateSightings(s, now: t0.add(const Duration(hours: 1)), drive: 3);
      expect(s['drive']!.count, 3, reason: 'a changed number is written now');
    });

    test('is stored and read back', () {
      final s = updateSightings({}, now: t0, drive: 2, finance: 1);
      final back = decodeNewerFormat(encodeNewerFormat(s));
      expect(back['drive']!.count, 2);
      expect(back['finance']!.at, t0);
      expect(decodeNewerFormat('{{{'), isEmpty);
      expect(decodeNewerFormat(null), isEmpty);
    });
  });

  group('the calendar engine writes down why an upload failed', () {
    SyncEngine engine({int maxAttempts = 2}) =>
        SyncEngine(repo, remote, log: log, maxAttempts: maxAttempts);

    test(
      'a refusal: a code in the database, a code in the log, no text',
      () async {
        await repo.saveLocal(ev('a'));
        remote.failUpsertAt[1] = ItemRejectedError(400, 'invalid', _secret);
        final r = await engine().sync('naptar');

        expect(r.failed, 1);
        final item = (await repo.pending()).single;
        expect((item.attempts, item.lastError), (1, 'rejected:400:invalid'));
        final e = (await logged()).singleWhere(
          (e) => e.code == 'push.rejected',
        );
        expect(e.data['err'], 'rejected:400:invalid');
        expect(e.data['op'], 'upsert');
        expect(e.data['try'], 1);
        expect(e.data['parked'], false);
        expect(sink.lines.join('\n'), isNot(contains(_secret)));
      },
    );

    test('the last allowed attempt says the item is parked', () async {
      await repo.saveLocal(ev('a'));
      remote.failUpsertAt[1] = ItemRejectedError(400, 'invalid', _secret);
      remote.failUpsertAt[2] = ItemRejectedError(400, 'invalid', _secret);
      final eng = engine();
      await eng.sync('naptar');
      now = now.add(const Duration(minutes: 2)); // past the flood window
      final r = await eng.sync('naptar');
      expect(r.parked, 1);
      final e = (await logged()).where((e) => e.code == 'push.rejected').last;
      expect(e.data['parked'], true);
      expect(e.data['try'], 2);
    });

    test('a conflict is a code too', () async {
      await repo.saveLocal(ev('a'));
      remote.failUpsertAt[1] = ConflictException();
      await engine().sync('naptar');
      expect((await repo.pending()).single.lastError, 'conflict');
      expect((await logged()).map((e) => e.code), contains('push.conflict'));
    });

    test('a limit stops the run, costs no attempt and is logged', () async {
      await repo.saveLocal(ev('a'));
      remote.failUpsertAt[1] = TransientSyncError.throttled(_secret);
      final r = await engine().sync('naptar');
      expect(r.stoppedEarly, isTrue);
      final item = (await repo.pending()).single;
      expect((item.attempts, item.lastError), (0, 'transient:limit'));
      final e = (await logged()).singleWhere((e) => e.code == 'push.transient');
      expect(e.data['err'], 'transient:limit');
      expect(sink.lines.join('\n'), isNot(contains(_secret)));
    });

    test('a bug is logged with its type and stored as a code', () async {
      await repo.saveLocal(ev('a'));
      remote.failUpsertAt[1] = StateError(_secret);
      await engine().sync('naptar');
      expect((await repo.pending()).single.lastError, 'unexpected:stateerror');
      final e = (await logged()).singleWhere(
        (e) => e.code == 'push.unexpected',
      );
      expect(e.error, startsWith('StateError'));
      expect(e.data['err'], 'unexpected:stateerror');
    });

    test('the title of an event never gets into the log', () async {
      CalEvent titled(String id) => CalEvent(
        id: id,
        calendarId: 'naptar',
        title: 'Titkos fogorvos $id',
        tzid: 'Europe/Budapest',
        start: floating(2026, 5, 4, 9),
        end: floating(2026, 5, 4, 10),
      );
      await repo.saveLocal(titled('a'));
      await repo.saveLocal(titled('b'));
      remote.failUpsertAt[1] = ItemRejectedError(400, 'invalid', _secret);
      remote.failUpsertAt[2] = StateError(_secret);
      await engine().sync('naptar');
      expect(
        (await logged()).map((e) => e.code),
        containsAll(['push.rejected', 'push.unexpected']),
      );
      expect(sink.lines.join('\n'), isNot(contains('Titkos')));
    });

    test('events that cannot be read are logged once, by id', () async {
      remote.skipped = const [SkippedRemote('g-bad', 'unknown time zone')];
      final eng = engine();
      final r1 = await eng.sync('naptar');
      now = now.add(const Duration(minutes: 5));
      await eng.sync('naptar');
      expect(r1.skippedRemote, 1);
      final skipped = (await logged()).where(
        (e) => e.code == 'calendar.skipped',
      );
      expect(skipped, hasLength(1));
      expect(skipped.single.data['id'], 'g-bad');
    });
  });

  group('the Drive engine writes down what it swallows', () {
    late RecordRepository records;
    var clock = 1000;
    setUp(() {
      clock = 1000;
      records = RecordRepository(db, deviceId: 'A', clock: () => ++clock);
    });

    DriveSyncEngine engine() => DriveSyncEngine(records, drive, log: log);

    test('a refused upload: the record kind and the error type', () async {
      await records.edit(kindTask, 't1', taskFields(title: 'Bevásárlás'));
      drive.failWrite = StateError(_secret);
      final r = await engine().sync();
      expect(r.failed, 1);
      final e = (await logged()).singleWhere((e) => e.code == 'push.failed');
      expect(e.area, 'drive');
      expect(e.data['kind'], 'task');
      expect(e.error, startsWith('StateError'));
      expect(sink.lines.join('\n'), isNot(contains('Bevásárlás')));
    });

    test('a damaged file: counted and written down by kind', () async {
      drive.externalWrite('task-t1.json', 'ez nem json');
      final r = await engine().sync();
      expect(r.skippedCorrupt, 1);
      final e = (await logged()).singleWhere((e) => e.code == 'file.corrupt');
      expect(e.data['kind'], 'task');
    });

    test('a lapsed page token starts a full pass, and says so', () async {
      await records.edit(kindTask, 't1', taskFields(title: 'x'));
      final eng = engine();
      await eng.sync();
      drive.expireToken = true;
      now = now.add(const Duration(minutes: 5));
      await eng.sync();
      expect((await logged()).map((e) => e.code), contains('token_expired'));
    });
  });

  group('the event store writes down what it cannot show', () {
    late EventRepository logged0;
    setUp(() => logged0 = EventRepository(db, log: log));

    CalEvent series(String id, {String rule = 'FREQ=DAILY', int year = 1970}) =>
        CalEvent(
          id: id,
          calendarId: 'naptar',
          title: 'Titkos sorozat',
          tzid: 'Europe/Budapest',
          start: floating(year, 1, 1, 9),
          end: floating(year, 1, 1, 10),
          rrule: rule,
        );

    test('a series that runs into the 20 000 limit: once, by id', () async {
      await logged0.saveLocal(series('cap'));
      final from = DateTime.utc(2030, 1, 1), to = DateTime.utc(2030, 2, 1);
      await logged0.occurrences(from, to);
      await logged0.occurrences(from, to);
      final capped = (await logged()).where((e) => e.code == 'expand.capped');
      expect(capped, hasLength(1), reason: 'once per run, not per redraw');
      expect(capped.single.data['id'], 'cap');
      expect(sink.lines.join('\n'), isNot(contains('Titkos')));
    });

    test('an ordinary series does not trigger it', () async {
      await logged0.saveLocal(series('ok', year: 2026));
      await logged0.occurrences(
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 6, 1),
      );
      expect((await logged()).where((e) => e.code == 'expand.capped'), isEmpty);
    });

    test('the store the app itself uses (the provider) has the log', () async {
      make();
      final store = c!.read(repoProvider);
      await store.saveLocal(series('bad', rule: 'FREQ=NEVER'));
      await store.occurrences(
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 6, 1),
      );
      expect(
        (await logged()).where((e) => e.code == 'expand.failed'),
        hasLength(1),
      );
    });

    test('a series that cannot be read: once, by id and error type', () async {
      await logged0.saveLocal(series('bad', rule: 'FREQ=NEVER'));
      await logged0.saveLocal(series('fine', year: 2026));
      final from = DateTime.utc(2026, 5, 1), to = DateTime.utc(2026, 6, 1);
      final first = await logged0.occurrences(from, to);
      await logged0.occurrences(from, to);
      expect(first, isNotEmpty, reason: 'the others still show');
      final failed = (await logged()).where((e) => e.code == 'expand.failed');
      expect(failed, hasLength(1));
      expect(failed.single.data['id'], 'bad');
      expect(failed.single.error, isNotNull);
      expect(sink.lines.join('\n'), isNot(contains('Titkos')));
    });
  });
}
