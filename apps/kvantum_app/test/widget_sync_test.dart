import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/notify/reminders.dart' show reminderTimerProvider;
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_app/widget/widget_bridge.dart';
import 'package:kvantum_app/widget/widget_sync.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';
import 'support/turns.dart';

/// The platform side of the widget, as far as the app can tell.
class FakeWidgetBridge implements WidgetBridge {
  /// Whether the user has the widget on a home screen.
  bool placed = true;

  /// Thrown by [update] while set (the platform side refusing).
  Object? failUpdate;

  /// When set, [isPlaced] waits for it.
  Completer<void>? gate;

  /// Runs right after [isPlaced] has answered (the user is quick).
  void Function()? afterLook;

  int looks = 0;
  int attempts = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final updates = <String>[];

  @override
  bool get active => true;

  @override
  Future<bool> isPlaced() async {
    looks++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (gate != null) await gate!.future;
      final answer = placed;
      afterLook?.call();
      return answer;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<bool> update(String snapshot) async {
    attempts++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (failUpdate != null) throw failUpdate!;
      if (!placed) return false;
      updates.add(snapshot);
      return true;
    } finally {
      inFlight--;
    }
  }
}

Future<void> until(bool Function() ok) => turnUntil(ok);

Map<String, Object?> decode(String snapshot) =>
    jsonDecode(snapshot) as Map<String, Object?>;

List<String> firstDayLines(String snapshot) {
  final day = (decode(snapshot)['days'] as List).first as Map;
  return [for (final l in day['lines'] as List) l as String];
}

CalEvent visit(String id, String title, int hour, {int day = 16}) => CalEvent(
  id: id,
  calendarId: kNaptarCalendar,
  title: title,
  start: floating(2026, 11, day, hour),
  end: floating(2026, 11, day, hour + 1),
  tzid: bp,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  group('the widget sync', () {
    late AppDatabase db;
    late FakeWidgetBridge bridge;
    late ManualTimers timers;
    late ProviderContainer c;
    late MemoryDiagSink sink;
    late DateTime now;

    setUp(() async {
      db = await newDb();
      bridge = FakeWidgetBridge();
      timers = ManualTimers();
      sink = MemoryDiagSink();
      // Monday 16 November 2026, 06:00 in Budapest
      now = DateTime.utc(2026, 11, 16, 5);
      c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          widgetBridgeProvider.overrideWithValue(bridge),
          reminderTimerProvider.overrideWithValue(timers.make),
          appClockProvider.overrideWithValue(() => now),
          diagLogProvider.overrideWithValue(DiagLog()..attach(sink)),
        ],
      );
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<void> start() async {
      c.listen(widgetSyncProvider, (_, _) {}, fireImmediately: true);
      await until(() => timers.live > 0);
    }

    /// The wait is over: the look at the widget and the calendar happens.
    Future<void> fire({int looks = 1}) async {
      final before = bridge.looks;
      // (a rebuild of the provider cancels the old wait, then starts a new one)
      await until(() => timers.live > 0);
      timers.made.lastWhere((m) => m.live()).fire();
      await until(() => bridge.looks >= before + looks);
      // (and the rest of the run: reading the calendar, handing it over)
      await turns();
    }

    /// The app is in front again: the sync looks once more.
    Future<void> comeBack() async {
      c.read(widgetKickProvider.notifier).bump();
      await until(() => timers.live > 0);
    }

    test('hands the days to a widget that is on the home screen', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      await start();
      await fire();
      expect(bridge.updates, hasLength(1));
      final j = decode(bridge.updates.single);
      expect(j['v'], 1);
      expect((j['days'] as List).first['label'], 'hétfő, nov. 16.');
      expect(firstDayLines(bridge.updates.single), ['14:00 Fogorvos']);
    });

    test('waits for the calendar to settle before it looks', () async {
      await start();
      expect(timers.current.wait, const Duration(milliseconds: 1500));
      expect(bridge.looks, 0, reason: 'nothing happens while it settles');
    });

    test('sends nothing while no widget is there', () async {
      bridge.placed = false;
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      await start();
      await fire();
      expect(bridge.looks, 1);
      expect(bridge.attempts, 0);
      expect(bridge.updates, isEmpty);
    });

    test('a calendar that has not changed is not sent again', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      await start();
      await fire();
      await comeBack();
      await fire();
      expect(bridge.looks, 2);
      expect(bridge.updates, hasLength(1));
    });

    test('a change is sent', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      await start();
      await fire();
      await EventRepository(db).saveLocal(visit('v2', 'Edzés', 18));
      await until(() => timers.live > 0);
      await fire();
      expect(bridge.updates, hasLength(2));
      expect(firstDayLines(bridge.updates.last), [
        '14:00 Fogorvos',
        '18:00 Edzés',
      ]);
    });

    test('reads the whole of today and the days ahead', () async {
      final repo = EventRepository(db);
      // 03:00 is over by 06:00 but still on today's list; the 20th is ahead
      await repo.saveLocal(visit('v0', 'Korai', 3));
      await repo.saveLocal(visit('v1', 'Pénteki', 18, day: 20));
      await start();
      await fire();
      final days = decode(bridge.updates.single)['days'] as List;
      List lines(int i) => (days[i] as Map)['lines'] as List;
      expect(lines(0), ['03:00 Korai']);
      expect(lines(4), ['18:00 Pénteki']);
    });

    test(
      'tells of a shift ten days ahead, though no day of the list has it',
      () async {
        await EventRepository(db).saveLocal(
          CalEvent(
            id: 's1',
            calendarId: kNaptarCalendar,
            title: 'Éjszakai műszak',
            notes: kShiftMarker,
            start: floating(2026, 11, 26, 18),
            end: floating(2026, 11, 27, 6),
            tzid: bp,
          ),
        );
        await start();
        await fire();
        final j = decode(bridge.updates.single);
        expect(
          [for (final x in j['shifts'] as List) (x as Map)['text']],
          ['csütörtök, nov. 26. 18:00 Éjszakai műszak'],
        );
      },
    );

    test('a new task is sent', () async {
      await start();
      // (the tasks come in as a stream)
      await c.read(tasksProvider.future);
      await fire();
      expect(firstDayLines(bridge.updates.single), isEmpty);
      await RecordRepository(db).edit(
        kindTask,
        't1',
        taskFields(title: 'Számla', due: floating(2026, 11, 16)),
      );
      await until(
        () => (c.read(tasksProvider).value ?? const []).any(
          (t) => t.title == 'Számla',
        ),
      );
      await fire();
      expect(firstDayLines(bridge.updates.last), ['Feladat: Számla']);
    });

    test(
      'a widget put there later is filled when the app is next in front',
      () async {
        bridge.placed = false;
        await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
        await start();
        await fire();
        expect(bridge.updates, isEmpty);

        bridge.placed = true; // (the user added it on the home screen)
        await comeBack();
        await fire();
        expect(firstDayLines(bridge.updates.single), ['14:00 Fogorvos']);
      },
    );

    test(
      'a widget taken off and put back is filled again with the same text',
      () async {
        await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
        await start();
        await fire();
        expect(bridge.updates, hasLength(1));

        // taken off: the platform side drops its copy with the last widget
        bridge.placed = false;
        await comeBack();
        await fire();
        expect(bridge.updates, hasLength(1));

        // put back: nothing in the calendar changed, but the widget is empty
        bridge.placed = true;
        await comeBack();
        await fire();
        expect(bridge.updates, hasLength(2));
        expect(bridge.updates.last, bridge.updates.first);
      },
    );

    test('a widget taken off between the look and the hand-over is not counted as filled', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      bridge.afterLook = () => bridge.placed = false;
      await start();
      await fire();
      expect(bridge.attempts, 1);
      expect(bridge.updates, isEmpty);

      // put back: the same text goes out again
      bridge.afterLook = null;
      bridge.placed = true;
      await comeBack();
      await fire();
      expect(bridge.updates, hasLength(1));
    });

    test(
      'a refusal by the platform is logged without the text, and tried again',
      () async {
        await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
        bridge.failUpdate = StateError('refused');
        await start();
        await fire();
        expect(bridge.attempts, 1);
        expect(bridge.updates, isEmpty);
        await until(() => sink.lines.isNotEmpty);
        expect(sink.lines, hasLength(1));
        final entry = jsonDecode(sink.lines.single) as Map;
        expect((entry['a'], entry['c']), ('widget', 'update.failed'));
        expect(sink.lines.single, isNot(contains('Fogorvos')));

        bridge.failUpdate = null;
        await comeBack();
        await fire();
        expect(bridge.attempts, 2);
        expect(bridge.updates, hasLength(1));
      },
    );

    test('a look that fails does not stop the next ones', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      bridge.failUpdate = PlatformException(code: 'bad_args');
      await start();
      await fire();
      bridge.failUpdate = null;
      await comeBack();
      await fire();
      expect(bridge.updates, hasLength(1));
    });

    test('a burst of changes costs one look', () async {
      await start();
      for (var h = 8; h < 12; h++) {
        await EventRepository(db).saveLocal(visit('v$h', 'E$h', h));
        await turns();
      }
      expect(timers.made.length, greaterThan(2));
      expect(timers.live, 1);
      expect(bridge.looks, 0);
      await fire();
      expect(bridge.looks, 1);
      expect(bridge.updates, hasLength(1));
      expect(firstDayLines(bridge.updates.single), hasLength(4));
    });

    test('the runs never overlap', () async {
      await EventRepository(db).saveLocal(visit('v1', 'Fogorvos', 14));
      bridge.gate = Completer<void>();
      await start();
      timers.made.lastWhere((m) => m.live()).fire();
      await until(() => bridge.looks == 1);
      // a second run is asked for while the first is still waiting
      await comeBack();
      timers.made.lastWhere((m) => m.live()).fire();
      await turns();
      expect(bridge.looks, 1, reason: 'the second waits for the first');

      bridge.gate!.complete();
      await until(() => bridge.looks == 2);
      await turns();
      expect(bridge.maxInFlight, 1);
      expect(bridge.updates, hasLength(1), reason: 'the same text, once');
    });

    test('the new day is a new look', () async {
      await start();
      // everything the sync watches has answered, and every wait that started
      // meanwhile is over: only the new day can start the next one
      await c.read(tasksProvider.future);
      await c.read(eventsTickProvider.future);
      await fire();
      while (timers.live > 0) {
        await fire();
      }
      await turns();
      expect(timers.live, 0);
      expect(bridge.updates, hasLength(1));
      expect(
        (decode(bridge.updates.single)['days'] as List).first['label'],
        'hétfő, nov. 16.',
      );
      // half past midnight in Budapest: it is Tuesday
      now = DateTime.utc(2026, 11, 16, 23, 30);
      c.read(todayProvider.notifier).refresh();
      await until(() => timers.live > 0);
      await fire();
      expect(bridge.updates, hasLength(2));
      expect(
        (decode(bridge.updates.last)['days'] as List).first['label'],
        'kedd, nov. 17.',
      );
    });

    test('leaving cancels the wait', () async {
      await start();
      expect(timers.live, 1);
      c.dispose();
      expect(timers.live, 0);
      expect(bridge.looks, 0);
    });

    test('where there is no widget at all, nothing is even started', () async {
      final other = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          widgetBridgeProvider.overrideWithValue(const NoopWidgetBridge()),
          reminderTimerProvider.overrideWithValue(timers.make),
        ],
      );
      addTearDown(other.dispose);
      other.listen(widgetSyncProvider, (_, _) {}, fireImmediately: true);
      await turns();
      expect(timers.made, isEmpty);
    });
  });

  group('the bridge', () {
    const channel = MethodChannel(MethodChannelWidgetBridge.channelName);
    final calls = <MethodCall>[];
    Object? answer;

    setUp(() {
      calls.clear();
      answer = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (answer is Exception) throw answer!;
            return answer;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('is on the channel the platform side listens on', () {
      expect(MethodChannelWidgetBridge.channelName, 'kvantum/widget');
      expect(const MethodChannelWidgetBridge().active, isTrue);
    });

    test(
      'asks whether the widget is placed, and takes only a yes for yes',
      () async {
        const bridge = MethodChannelWidgetBridge();
        answer = true;
        expect(await bridge.isPlaced(), isTrue);
        answer = false;
        expect(await bridge.isPlaced(), isFalse);
        answer = null;
        expect(await bridge.isPlaced(), isFalse);
        expect(
          [for (final c in calls) c.method],
          ['isPlaced', 'isPlaced', 'isPlaced'],
        );
      },
    );

    test('hands the snapshot over as the plain text it is', () async {
      const bridge = MethodChannelWidgetBridge();
      answer = true;
      expect(await bridge.update('{"v":1}'), isTrue);
      expect(calls.single.method, 'update');
      expect(calls.single.arguments, '{"v":1}');
    });

    test('says no when the platform side had no widget to take it', () async {
      const bridge = MethodChannelWidgetBridge();
      answer = false;
      expect(await bridge.update('{"v":1}'), isFalse);
      answer = null;
      expect(await bridge.update('{"v":1}'), isFalse);
    });

    test('lets a refusal through (the sync logs it)', () async {
      const bridge = MethodChannelWidgetBridge();
      answer = PlatformException(code: 'bad_args');
      expect(() => bridge.update('x'), throwsA(isA<PlatformException>()));
    });

    test('the platform picks the real bridge only on Android', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // (the tests run on a desktop or a CI machine: never Android)
      expect(c.read(widgetBridgeProvider).active, isFalse);
    });
  });

  group('on the home page', () {
    late AppDatabase db;
    setUp(() async => db = await newDb());

    testWidgets('the sync is kept, and coming back looks again', (
      tester,
    ) async {
      useSize(tester, size: const Size(900, 1400));
      final bridge = FakeWidgetBridge()..placed = false;
      final timers = ManualTimers();
      await tester.pumpWidget(
        app(
          const RootShell(),
          db,
          extra: [
            walletBridgeProvider.overrideWithValue(FakeWallet()),
            widgetBridgeProvider.overrideWithValue(bridge),
            reminderTimerProvider.overrideWithValue(timers.make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(timers.live, 1, reason: 'the home page watches the sync');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RootShell)),
      );
      expect(container.read(widgetKickProvider), 0);

      final waits = timers.made.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(container.read(widgetKickProvider), 1);
      expect(timers.live, 1, reason: 'a new wait started');
      expect(timers.made.length, waits + 1, reason: 'and only one');

      // the wait over: it looks at the widget (nobody put one there)
      await tester.runAsync(() async {
        timers.current.fire();
        await until(() => bridge.looks == 1);
      });
      expect(bridge.looks, 1);
      expect(bridge.updates, isEmpty);
      await shutdown(tester, db);
    });
  });

  group('the settings page', () {
    late AppDatabase db;
    setUp(() async => db = await newDb());

    Future<void> open(WidgetTester tester, WidgetBridge bridge) async {
      useSize(tester, size: const Size(900, 1600));
      await tester.pumpWidget(
        app(
          const SettingsPage(),
          db,
          extra: [
            widgetBridgeProvider.overrideWithValue(bridge),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tells how to put the widget on the home screen, on Android', (
      tester,
    ) async {
      await open(tester, FakeWidgetBridge());
      final title = find.text('Főképernyő-widget');
      await tester.scrollUntilVisible(
        title,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(title, findsOneWidget);
      expect(find.textContaining('tartsd nyomva a főképernyő'), findsOneWidget);
      // (it is honest about who can read the titles there)
      expect(
        find.textContaining('annak is látszik, aki a telefonodra néz'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('says nothing of a widget where there is none', (tester) async {
      await open(tester, const NoopWidgetBridge());
      // the section after it is there, so this part of the page is built
      await tester.scrollUntilVisible(
        find.text('Google Wallet értesítések'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Főképernyő-widget'), findsNothing);
      expect(find.textContaining('Kvantum Naptár” widget'), findsNothing);
      await shutdown(tester, db);
    });
  });
}
