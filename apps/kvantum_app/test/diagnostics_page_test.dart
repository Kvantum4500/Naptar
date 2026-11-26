import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/diag/newer_format.dart';
import 'package:kvantum_app/diag/request_stats.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/channel_status.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/backup_io.dart';
import 'package:kvantum_app/ui/diagnostics_page.dart';
import 'package:kvantum_app/update/update_dialog.dart'
    show currentBuildProvider;
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

const _title = 'Titkos edzés a Kiss Jánossal';

class _Io implements BackupIo {
  final saved = <({String name, String text, String mime, String title})>[];

  @override
  Future<bool> save(
    String fileName,
    String text, {
    String mimeType = 'text/calendar',
    String dialogTitle = 'Naptár mentése',
  }) async {
    saved.add((name: fileName, text: text, mime: mimeType, title: dialogTitle));
    return true;
  }

  @override
  Future<String?> pick() async => null;
}

/// A controller that only records what the page asks of it.
class _Ctl extends SyncController {
  _Ctl(this.initial);
  final SyncState initial;
  final calls = <String>[];

  @override
  SyncState build() => initial;
  @override
  Future<void> syncNow({bool manual = false}) async =>
      calls.add(manual ? 'now-manual' : 'now');
  @override
  void requestSync() => calls.add('request');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  // 2026-11-12 14:30 local
  final now = DateTime(2026, 11, 12, 14, 30);

  late AppDatabase db;
  late EventRepository events;
  late MemoryDiagSink sink;
  late DiagLog log;
  late _Io io;
  late _Ctl ctl;
  String? copied;

  SyncState state({SyncBindingMismatch? mismatch}) => SyncState(
    configured: true,
    signedIn: true,
    lastSync: now,
    pending: 1,
    mismatch: mismatch,
    channels: {
      channelCalendar: ChannelStatus(
        lastTry: now,
        lastOk: now.subtract(const Duration(minutes: 10)),
        code: 'refused',
        text: 'Naptár: 1 módosítást nem sikerült elküldeni, újrapróbálom.',
        failed: 1,
      ),
      channelDrive: ChannelStatus(lastTry: now, lastOk: now),
    },
  );

  /// Opens the page. [seed] runs against the database before it is shown.
  Future<void> boot(
    WidgetTester tester, {
    Future<void> Function()? seed,
    void Function()? logSeed,
    SyncState? syncState,
    RequestStats? stats,
    List<Override> extra = const [],
  }) async {
    useSize(tester, size: const Size(900, 2600));
    db = await newDb();
    events = EventRepository(db);
    sink = MemoryDiagSink();
    log = DiagLog(now: () => now.toUtc(), maxPerMinute: 1000)..attach(sink);
    io = _Io();
    ctl = _Ctl(syncState ?? state());
    copied = null;
    if (seed != null) await tester.runAsync(seed);
    logSeed?.call();
    await tester.pumpWidget(
      app(
        const DiagnosticsPage(),
        db,
        extra: [
          syncControllerProvider.overrideWith(() => ctl),
          diagLogProvider.overrideWithValue(log),
          clipboardWriterProvider.overrideWithValue((t) async => copied = t),
          backupIoProvider.overrideWithValue(io),
          appClockProvider.overrideWithValue(() => now),
          requestStatsProvider.overrideWithValue(
            stats ?? RequestStats(now: () => now),
          ),
          currentBuildProvider.overrideWith((ref) async => 62),
          ...extra,
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  /// One event whose upload Google refused [times] times.
  Future<void> refused({
    String code = 'rejected:400:invalid',
    int times = 1,
    String title = _title,
  }) async {
    await events.saveLocal(evt('a', title, floating(2026, 11, 13, 9)));
    for (var i = 0; i < times; i++) {
      await events.markFailed((await events.pending()).single, code);
    }
  }

  Future<int> seqOfRefused() async => (await events.pending()).single.seq;

  /// The log's last entries. The log lives in the test's fake-async zone, so
  /// its queue is advanced by [WidgetTester.pump], not by `runAsync`.
  Future<List<DiagEntry>> tail(WidgetTester tester) async {
    final entries = log.tail();
    await tester.pump();
    return entries;
  }

  group('what the page shows', () {
    testWidgets('the app, every sync channel and the refused upload', (
      tester,
    ) async {
      await boot(tester, seed: refused);
      expect(find.text('Verzió: build 62'), findsOneWidget);
      expect(find.textContaining('Adatbázis: séma'), findsOneWidget);
      expect(find.textContaining('esemény 1'), findsOneWidget);
      expect(find.text('Naptár'), findsWidgets);
      expect(
        find.text('Drive (feladatok, check-inek, napló, étkezés, beállítások)'),
        findsOneWidget,
      );
      expect(find.text('Pénzügy (levelek)'), findsOneWidget);
      expect(find.text('Képek (a napló képei, Drive)'), findsOneWidget);
      // (the finance mail and the pictures have not been looked at yet)
      expect(find.text('még nem volt futás'), findsNWidgets(2));
      expect(
        find.textContaining('1 módosítást nem sikerült elküldeni'),
        findsOneWidget,
      );
      // on the screen the title may be shown: it is the user's own device
      expect(find.text(_title), findsOneWidget);
      expect(
        find.textContaining(
          'Módosítás, 1. próba · a Google nem fogadta el (kód: 400, invalid)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no warnings: it says so', (tester) async {
      await boot(tester);
      expect(find.text('Nincs figyelmeztetés.'), findsOneWidget);
      expect(find.text('Elutasított módosítások'), findsNothing);
    });

    testWidgets('requests: today and yesterday, by service', (tester) async {
      var t = now;
      final stats = RequestStats(now: () => t)
        ..record('calendar', status: 200)
        ..record('calendar', status: 200)
        ..record('calendar', status: 429)
        ..record('drive', status: 500);
      t = now.subtract(const Duration(days: 1));
      stats.record('calendar', status: 200);
      await boot(tester, stats: stats);
      expect(
        find.text('Ma · Naptár: 3 hívás (2 rendben, 1 korlátozva)'),
        findsOneWidget,
      );
      expect(
        find.text('Ma · Drive: 1 hívás (0 rendben, 1 szerverhiba)'),
        findsOneWidget,
      );
      expect(find.text('Tegnap · Naptár: 1 hívás (1 rendben)'), findsOneWidget);
    });

    testWidgets('no requests yet', (tester) async {
      await boot(tester);
      expect(find.text('Még nincs adat.'), findsOneWidget);
    });

    testWidgets('the log, newest first', (tester) async {
      await boot(
        tester,
        logSeed: () {
          log.info('sync', 'calendar.parked', data: {'parked': 1});
          log.info('app', 'start');
        },
      );
      expect(find.textContaining('sync/calendar.parked'), findsOneWidget);
      final newer = tester.getTopLeft(find.textContaining('app/start')).dy;
      final older = tester
          .getTopLeft(find.textContaining('sync/calendar.parked'))
          .dy;
      expect(newer, lessThan(older), reason: 'the latest entry is on top');
    });
  });

  group('warnings', () {
    testWidgets('an edit stamped in the future: the clock is ahead', (
      tester,
    ) async {
      await boot(
        tester,
        seed: () async {
          final ahead = now
              .toUtc()
              .add(const Duration(days: 3, hours: 1))
              .millisecondsSinceEpoch;
          final r = RecordRepository(db, deviceId: 'A', clock: () => ahead);
          await r.edit(kindTask, 't1', taskFields(title: 'x'));
        },
      );
      expect(find.byKey(const Key('diag-warning-clock')), findsOneWidget);
      expect(find.textContaining('3 nappal a jövőben'), findsOneWidget);
      expect(find.text('Nincs figyelmeztetés.'), findsNothing);
    });

    testWidgets('files of a newer version of the app', (tester) async {
      await boot(
        tester,
        seed: () => events.setMeta(
          newerFormatKey,
          encodeNewerFormat({'drive': NewerSighting(2, now.toUtc())}),
        ),
      );
      expect(find.byKey(const Key('diag-warning-newer')), findsOneWidget);
      expect(find.textContaining('2 elemet'), findsOneWidget);
    });

    testWidgets('Google limited the requests today', (tester) async {
      final stats = RequestStats(now: () => now)
        ..record('calendar', status: 429);
      await boot(tester, stats: stats);
      expect(find.byKey(const Key('diag-warning-quota')), findsOneWidget);
    });

    testWidgets('another account or calendar waits for a decision', (
      tester,
    ) async {
      await boot(
        tester,
        syncState: state(
          mismatch: const SyncBindingMismatch(
            stored: RemoteIdentity(account: 'a@x.hu', calendar: 'c1'),
            current: RemoteIdentity(account: 'b@x.hu', calendar: 'c2'),
          ),
        ),
      );
      expect(find.byKey(const Key('diag-warning-binding')), findsOneWidget);
    });

    testWidgets('an upload given up on is a warning and says "feladva"', (
      tester,
    ) async {
      await boot(tester, seed: () => refused(times: 5));
      expect(find.byKey(const Key('diag-warning-parked')), findsOneWidget);
      expect(find.textContaining('· feladva'), findsOneWidget);
    });

    testWidgets('an event whose recurrence rule cannot be read', (
      tester,
    ) async {
      await boot(
        tester,
        seed: () => events.saveLocal(
          CalEvent(
            id: 'bad',
            calendarId: 'naptar',
            title: 'Rossz szabály',
            tzid: 'Europe/Budapest',
            start: floating(2026, 5, 4, 9),
            end: floating(2026, 5, 4, 10),
            rrule: 'FREQ=NEVER',
          ),
        ),
      );
      expect(find.byKey(const Key('diag-warning-unreadable')), findsOneWidget);
      expect(
        find.textContaining('1 esemény ismétlődési szabályát'),
        findsOneWidget,
      );
    });

    testWidgets('a recurrence that ran into its limit', (tester) async {
      await boot(
        tester,
        logSeed: () => log.info('events', 'expand.capped', data: {'id': 'x'}),
      );
      expect(find.byKey(const Key('diag-warning-capped')), findsOneWidget);
    });
  });

  group('the report', () {
    testWidgets('copy: numbers and sentences, never a title or an address', (
      tester,
    ) async {
      await boot(
        tester,
        seed: refused,
        logSeed: () => log.error(
          'drive',
          'push.failed',
          Exception('jani.kovacs@example.com 1234567890123'),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('diag-copy')));
      await tester.tap(find.byKey(const Key('diag-copy')));
      await tester.pumpAndSettle();

      final r = copied!;
      expect(r, contains('Verzió: build 62'));
      expect(r, contains('módosítás, 1. próba, a Google nem fogadta el'));
      expect(r, contains('drive/push.failed'));
      expect(r, isNot(contains('Titkos')));
      expect(r, isNot(contains('Kiss János')));
      expect(r, isNot(contains('jani.kovacs')));
      expect(r, isNot(contains('1234567890123')));
      expect(r, contains('[e-mail]'));
      expect(find.text('A jelentés a vágólapra került.'), findsOneWidget);
    });

    testWidgets('save: a plain text file with a dated name', (tester) async {
      await boot(tester, seed: refused);
      await tester.ensureVisible(find.byKey(const Key('diag-copy')));
      await tester.tap(find.byKey(const Key('diag-copy')));
      await tester.pumpAndSettle();
      // let the first message go, so that the second one is shown at once
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('diag-save')));
      await tester.pumpAndSettle();

      final f = io.saved.single;
      expect(f.name, 'kvantum-diagnosztika-20261112-1430.txt');
      expect(f.mime, 'text/plain');
      expect(f.title, 'Diagnosztikai jelentés mentése');
      expect(f.text, copied, reason: 'the same report');
      expect(f.text, isNot(contains('Titkos')));
      expect(find.text('Elmentve.'), findsOneWidget);
    });

    testWidgets('clearing the log asks first', (tester) async {
      await boot(tester, logSeed: () => log.info('app', 'start'));
      expect(find.textContaining('app/start'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('diag-clear')));
      await tester.tap(find.byKey(const Key('diag-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Törlöd a hibanaplót?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('diag-clear-cancel')));
      await tester.pumpAndSettle();
      expect(find.textContaining('app/start'), findsOneWidget);

      await tester.tap(find.byKey(const Key('diag-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('diag-clear-go')));
      await tester.pumpAndSettle();
      expect(find.textContaining('app/start'), findsNothing);
      expect(find.text('A hibanapló üres.'), findsOneWidget);
      expect(await tail(tester), isEmpty);
    });
  });

  group('the buttons', () {
    testWidgets('"Újrapróbálás most" runs a manual sync', (tester) async {
      await boot(tester, seed: refused);
      await tester.ensureVisible(find.byKey(const Key('diag-retry')));
      await tester.tap(find.byKey(const Key('diag-retry')));
      await tester.pump();
      expect(ctl.calls, ['now-manual']);
    });

    testWidgets('"Szinkron most" runs a manual sync', (tester) async {
      await boot(tester);
      await tester.ensureVisible(find.byKey(const Key('diag-sync-now')));
      await tester.tap(find.byKey(const Key('diag-sync-now')));
      await tester.pump();
      expect(ctl.calls, ['now-manual']);
    });

    testWidgets('signed out: the sync buttons wait', (tester) async {
      await boot(tester, syncState: const SyncState(configured: true));
      final b = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('diag-sync-now')),
      );
      expect(b.onPressed, isNull);
    });

    testWidgets(
      'discard asks first, then drops the upload and keeps the event',
      (tester) async {
        await boot(tester, seed: refused);
        final seq = (await tester.runAsync(seqOfRefused))!;
        final button = find.byKey(Key('diag-discard-$seq'));
        await tester.ensureVisible(button);

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Elveted a feltöltést?'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('az eszközön marad'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('diag-discard-cancel')));
        await tester.pumpAndSettle();
        expect(await tester.runAsync(events.pending), hasLength(1));

        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('diag-discard-go')));
        await tester.pumpAndSettle();

        expect(await tester.runAsync(events.pending), isEmpty);
        final all = await tester.runAsync(events.all);
        expect(all!.single.title, _title, reason: 'the event stays');
        expect(find.text('Elutasított módosítások'), findsNothing);
        expect(ctl.calls, contains('request'));
        expect(
          (await tail(tester)).map((e) => e.code),
          contains('outbox.discarded'),
        );
      },
    );
  });
}
