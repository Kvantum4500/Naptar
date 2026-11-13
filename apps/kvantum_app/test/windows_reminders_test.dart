import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/notify/reminder_test_button.dart';
import 'package:kvantum_app/notify/reminders.dart';
import 'package:kvantum_app/notify/windows_autostart.dart';
import 'package:kvantum_app/notify/windows_reminders.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'reminders_test.dart' show FakeScheduler;
import 'support/fake_toasts.dart';
import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  // 2026-11-12 10:00 in Budapest
  final now = resolveWallClock(bp, floating(2026, 11, 12, 10));
  DateTime inMinutes(int m) => now.add(Duration(minutes: m));

  late FakeToasts toasts;
  late Map<String, String?> notes;
  late WindowsReminderScheduler win;

  PlannedReminder r(int id, int minutes, [String title = 'Éjszakai műszak']) =>
      PlannedReminder(id, inMinutes(minutes), title, 'Hamarosan kezdődik');

  setUp(() {
    toasts = FakeToasts();
    notes = {};
    win = WindowsReminderScheduler(
      backend: toasts,
      read: (k) async => notes[k],
      write: (k, v) async => v == null ? notes.remove(k) : notes[k] = v,
      now: () => now,
    );
  });

  group('the scheduler', () {
    test(
      'is there on Windows, and needs no permission, only a start',
      () async {
        expect(win.supported, isTrue);
        expect(await win.ensurePermission(), isTrue);
        toasts.initOk = false;
        expect(await win.ensurePermission(), isFalse);
      },
    );

    test('hands over what is planned, and remembers it', () async {
      await win.schedule([r(1, 60), r(2, 180)]);
      expect(toasts.os, {1, 2});
      expect(
        toasts.handedOver.map((x) => x.title),
        everyElement('Éjszakai műszak'),
      );
      final back = await win.pending();
      expect(back.map((x) => x.id), unorderedEquals([1, 2]));
      // Windows says only the ids; the rest comes from the note
      expect(back.firstWhere((x) => x.id == 2), r(2, 180));
    });

    test('a plan that is already on Windows costs no call at all', () async {
      final plan = [r(1, 60), r(2, 180)];
      await syncReminders(win, plan);
      toasts.calls.clear();
      final changes = await syncReminders(win, plan);
      expect(changes.isEmpty, isTrue);
      expect(toasts.calls, isEmpty);
    });

    test(
      'a change of time or text replaces the toast, never doubles it',
      () async {
        await syncReminders(win, [r(1, 60), r(2, 180)]);
        toasts.calls.clear();
        await syncReminders(win, [r(1, 90), r(2, 180)]);
        // the old toast of 1 is taken off before the new one is handed over
        expect(toasts.calls, ['cancel 1', 'schedule 1']);
        expect(toasts.os, {1, 2});
        expect(
          (await win.pending())
              .firstWhere((x) => x.id == 1)
              .atUtc
              .millisecondsSinceEpoch,
          inMinutes(90).millisecondsSinceEpoch,
        );
      },
    );

    test('taking a toast off also takes its note', () async {
      await win.schedule([r(1, 60), r(2, 180)]);
      await win.cancel([1]);
      final notes1 = notes[WindowsReminderScheduler.planKey]!;
      expect(notes1, isNot(contains('"id":1,')));
      expect(notes1, contains('"id":2,'));
      await win.cancel([2]);
      expect(notes, isEmpty, reason: 'nothing left to remember');
      expect(toasts.os, isEmpty);
    });

    test('a reminder no longer wanted is taken off', () async {
      await syncReminders(win, [r(1, 60), r(2, 180)]);
      await syncReminders(win, [r(2, 180)]);
      expect(toasts.os, {2});
      expect((await win.pending()).map((x) => x.id), [2]);
    });

    test('a reminder that is due at once is not handed over', () async {
      // (Windows refuses a time that has passed; 19 seconds is too close)
      await win.schedule([
        PlannedReminder(1, now.subtract(const Duration(hours: 1)), 'régi', ''),
        PlannedReminder(
          2,
          now.add(const Duration(seconds: 19)),
          'mindjárt',
          '',
        ),
        PlannedReminder(
          3,
          now.add(const Duration(seconds: 21)),
          'elég messze',
          '',
        ),
      ]);
      expect(toasts.os, {3});
      expect((await win.pending()).single.title, 'elég messze');
    });

    test('what Windows showed meanwhile is forgotten', () async {
      await win.schedule([r(1, 60), r(2, 180)]);
      toasts.shown(1);
      expect((await win.pending()).map((x) => x.id), [2]);
      // and it is gone from the note too (not read again and again)
      expect(
        notes[WindowsReminderScheduler.planKey],
        isNot(contains('"id":1')),
      );
      expect(notes[WindowsReminderScheduler.planKey], contains('"id":2'));
    });

    test(
      'a toast Windows holds without a note is replaced, or taken off',
      () async {
        await win.schedule([r(9, 120)]);
        toasts.os.addAll([7, 8]); // (their notes were lost)
        final back = await win.pending();
        expect(back.map((x) => x.id), unorderedEquals([7, 8, 9]));
        // such a toast equals no plan: wanted ones are handed over again ...
        toasts.calls.clear();
        await syncReminders(win, [r(7, 60), r(9, 120)]);
        expect(toasts.calls, ['cancel 8', 'cancel 7', 'schedule 7']);
        // ... and the unwanted one is gone, the good one left alone
        expect(toasts.os, {7, 9});
      },
    );

    test('with nothing handed over, Windows is not even asked', () async {
      toasts.os.add(7); // (something from before the notes were lost)
      expect(await win.pending(), isEmpty);
      await syncReminders(win, const []);
      expect(toasts.inits, 0, reason: 'not started, not registered');
      expect(toasts.calls, isEmpty);
      // ... and not after everything was taken off again
      toasts.os.clear();
      await win.schedule([r(1, 60)]);
      await win.cancel([1]);
      toasts.inits = 0;
      expect(await win.pending(), isEmpty);
      expect(toasts.inits, 0);
    });

    test(
      'the first thing handed over clears toasts no note explains',
      () async {
        toasts.os.addAll([7, 8, WindowsReminderScheduler.testId]);
        await win.schedule([r(1, 60)]);
        expect(toasts.os, {1, WindowsReminderScheduler.testId});
        expect(toasts.calls, contains('cancel 7'));
        expect(toasts.calls, contains('cancel 8'));
        expect(
          toasts.calls,
          isNot(contains('cancel ${WindowsReminderScheduler.testId}')),
          reason: 'a test notification waiting to be shown stays',
        );
      },
    );

    test('an unreadable note is no note', () async {
      for (final junk in [
        'nem json',
        '{"a":1}',
        '[1,2,3]',
        '[{"id":"x","at":1}]',
        '[{"id":4}]',
      ]) {
        notes[WindowsReminderScheduler.planKey] = junk;
        toasts.os.clear();
        expect(await win.pending(), isEmpty, reason: junk);
      }
      // a junk entry loses only itself, not the good ones beside it
      notes[WindowsReminderScheduler.planKey] =
          '[{"id":"x","at":1},{"id":3,"at":${inMinutes(60).millisecondsSinceEpoch},"t":"jó","b":"szöveg"},{"id":4}]';
      toasts.os.addAll([3, 4]);
      final good = await win.pending();
      expect(good.where((x) => x.title == 'jó').map((x) => x.id), [3]);
      // and a good one is written over it
      notes[WindowsReminderScheduler.planKey] = 'nem json';
      await win.schedule([r(1, 60)]);
      expect((await win.pending()).single.id, 1);
    });

    test('cancelling takes the toast off and out of the note', () async {
      await win.schedule([r(1, 60), r(2, 180)]);
      await win.cancel([1, 99]); // (99 was never there)
      expect(toasts.os, {2});
      expect((await win.pending()).map((x) => x.id), [2]);
    });

    test('without a start nothing is held, nothing is touched', () async {
      toasts.initOk = false;
      expect(await win.pending(), isEmpty);
      await win.cancel([1]);
      expect(toasts.calls, isEmpty);
      await expectLater(win.schedule([r(1, 60)]), throwsStateError);
      expect(toasts.calls, isEmpty);
      expect(notes, isEmpty);
    });

    test('a refusal half way keeps a note of what was handed over', () async {
      toasts.failAt = 2; // the second scheduling is refused
      await expectLater(
        win.schedule([r(1, 60), r(2, 180), r(3, 240)]),
        throwsStateError,
      );
      expect(toasts.os, {1});
      toasts.failAt = 0;
      expect((await win.pending()).map((x) => x.id), [1]);
      // the next run hands over the rest, and 1 is not doubled
      toasts.calls.clear();
      await syncReminders(win, [r(1, 60), r(2, 180), r(3, 240)]);
      expect(toasts.calls, [
        'cancel 2',
        'schedule 2',
        'cancel 3',
        'schedule 3',
      ]);
    });

    test('the title and text come back as they went', () async {
      await win.schedule([
        PlannedReminder(
          5,
          inMinutes(60),
          'Műszak & „idézet” <b>',
          '1 óra múlva: 18:00',
        ),
      ]);
      final back = (await win.pending()).single;
      expect(back.title, 'Műszak & „idézet” <b>');
      expect(back.body, '1 óra múlva: 18:00');
    });

    group('the test notification', () {
      const half = Duration(seconds: 30);

      test('is handed over for its time, with no note and no plan', () async {
        await win.scheduleTest(half);
        final t = toasts.handedOver.single;
        expect(t.id, WindowsReminderScheduler.testId);
        expect(
          t.atUtc.millisecondsSinceEpoch,
          now.add(half).millisecondsSinceEpoch,
        );
        expect(toasts.os, {WindowsReminderScheduler.testId});
        expect(notes, isEmpty, reason: 'nothing of it is remembered');
        expect(
          await win.pending(),
          isEmpty,
          reason: 'the plan does not see it',
        );
      });

      test('its id is outside every id a plan uses', () {
        // shifts: minutes since 1970; check-ins: 1 500 000 000 + days
        final shift = DateTime.utc(2100).millisecondsSinceEpoch ~/ 60000;
        final checkIn =
            1500000000 + DateTime.utc(2100).millisecondsSinceEpoch ~/ 86400000;
        expect(WindowsReminderScheduler.testId, greaterThan(shift));
        expect(WindowsReminderScheduler.testId, greaterThan(checkIn));
        expect(WindowsReminderScheduler.testId, lessThan(1 << 31));
      });

      test('a plan that follows does not take it back', () async {
        await win.scheduleTest(half);
        toasts.calls.clear();
        await syncReminders(win, [r(1, 60)]);
        await syncReminders(win, const []);
        expect(
          toasts.calls.where(
            (c) => c.endsWith('${WindowsReminderScheduler.testId}'),
          ),
          isEmpty,
          reason: 'neither cancelled nor handed over again',
        );
        expect(toasts.os, {WindowsReminderScheduler.testId});
      });

      test('a second test replaces the first, never doubles it', () async {
        await win.scheduleTest(half);
        await win.scheduleTest(half);
        final id = WindowsReminderScheduler.testId;
        expect(toasts.calls, [
          'cancel $id',
          'schedule $id',
          'cancel $id',
          'schedule $id',
        ]);
        expect(toasts.os, {id});
      });

      test('says so when Windows cannot be started', () async {
        toasts.initOk = false;
        await expectLater(win.scheduleTest(half), throwsA(isA<StateError>()));
        expect(toasts.handedOver, isEmpty);
      });
    });
  });

  group('the toast backend of the plugin', () {
    test('has an identity that Windows accepts and that never changes', () {
      // (the plugin stops with an invalid GUID; the toasts scheduled belong
      // to these values)
      expect(
        PluginToastBackend.guid,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(PluginToastBackend.guid, '7d3f9a52-1c4e-4b8a-9e60-2f5a8c1d4b73');
      expect(PluginToastBackend.appUserModelId, 'Kvantum.Naptar');
      expect(PluginToastBackend.appName, 'Kvantum Naptár');
    });
  });

  group('the choice of the scheduler', () {
    ReminderScheduler pick({bool android = false, bool windows = false}) =>
        reminderSchedulerFor(
          android: android,
          windows: windows,
          read: (k) async => notes[k],
          write: (k, v) async => v == null ? notes.remove(k) : notes[k] = v,
          now: () => now,
          toastBackend: () => toasts,
        );

    test('Android has its own, Windows the toasts, the rest none', () {
      expect(pick(android: true), isA<AndroidReminderScheduler>());
      expect(pick(windows: true), isA<WindowsReminderScheduler>());
      final other = pick();
      expect(other, isA<NoopReminderScheduler>());
      expect(other.supported, isFalse);
    });

    test('the Windows one works on the notes of the database', () async {
      final s = pick(windows: true);
      await s.schedule([r(1, 60)]);
      expect(notes[WindowsReminderScheduler.planKey], contains('"id":1'));
    });
  });

  group('what the user is told', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('when the notifications cannot be switched on', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        remindersBlockedHelp(),
        contains('Windows értesítési beállításait'),
      );
      expect(remindersBlockedHelp(), isNot(contains('Android')));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(remindersBlockedHelp(), contains('Android beállításaiban'));
    });
  });

  group('the settings page', () {
    late AppDatabase db;

    /// Shows the page as on [platform]. The override is put back inside the
    /// test: the framework checks it before the tear-downs run.
    Future<void> onPlatform(
      WidgetTester tester, {
      required TargetPlatform platform,
      required ReminderScheduler scheduler,
      required Future<void> Function() body,
      WindowsAutostart? autostart,
      Size size = const Size(900, 6400),
      double? textScale,
    }) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        useSize(tester, size: size);
        db = await newDb();
        await tester.pumpWidget(
          app(
            const SettingsPage(),
            db,
            textScale: textScale,
            extra: [
              apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null)),
              reminderSchedulerProvider.overrideWithValue(scheduler),
              autostartProvider.overrideWithValue(autostart),
              currentBuildProvider.overrideWith((ref) async => 7),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      await shutdown(tester, db);
    }

    testWidgets('on Windows it says who shows the reminders, and when', (
      tester,
    ) async {
      await onPlatform(
        tester,
        platform: TargetPlatform.windows,
        scheduler: FakeScheduler(),
        body: () async {
          expect(
            find.textContaining('A Windows jeleníti meg őket'),
            findsOneWidget,
          );
          expect(find.textContaining('Pár percet késhetnek'), findsNothing);
        },
      );
    });

    testWidgets('on Android it keeps the old words', (tester) async {
      await onPlatform(
        tester,
        platform: TargetPlatform.android,
        scheduler: FakeScheduler(),
        body: () async {
          expect(find.textContaining('Pár percet késhetnek'), findsOneWidget);
          expect(
            find.textContaining('A Windows jeleníti meg őket'),
            findsNothing,
          );
        },
      );
    });

    testWidgets('a refusal on Windows points to the Windows settings', (
      tester,
    ) async {
      await onPlatform(
        tester,
        platform: TargetPlatform.windows,
        scheduler: FakeScheduler(grant: false),
        body: () async {
          final sw = find.text('Napi check-in emlékeztető (20:00)');
          await tester.ensureVisible(sw);
          await tester.pumpAndSettle();
          await tester.tap(sw);
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Windows értesítési beállításait'),
            findsOneWidget,
          );
        },
      );
    });

    testWidgets('on Windows the switch for starting with Windows is there', (
      tester,
    ) async {
      await onPlatform(
        tester,
        platform: TargetPlatform.windows,
        scheduler: FakeScheduler(),
        autostart: WindowsAutostart(
          backend: _NoEntry(),
          executable: r'C:\app\kvantum_app.exe',
        ),
        body: () async {
          expect(find.byKey(const Key('autostart')), findsOneWidget);
          expect(find.text('Indítás a Windows-szal'), findsOneWidget);
        },
      );
    });

    group('the button that tries a notification', () {
      WindowsReminderScheduler windows(FakeToasts toasts) =>
          WindowsReminderScheduler(
            backend: toasts,
            read: (k) async => null,
            write: (k, v) async {},
            now: () => now,
          );

      testWidgets('is there where the scheduler can do it, and does it', (
        tester,
      ) async {
        final toasts = FakeToasts();
        await onPlatform(
          tester,
          platform: TargetPlatform.windows,
          scheduler: windows(toasts),
          body: () async {
            final button = find.byKey(const Key('reminder-test'));
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(toasts.os, {WindowsReminderScheduler.testId});
            // half a minute from now, as the words say
            expect(ReminderTestButton.delay, const Duration(seconds: 30));
            expect(
              toasts.handedOver.single.atUtc.millisecondsSinceEpoch,
              now.add(ReminderTestButton.delay).millisecondsSinceEpoch,
            );
            expect(
              find.textContaining('fél perc múlva megjelenik'),
              findsOneWidget,
            );
            expect(find.textContaining('Értesítések oldalán'), findsOneWidget);
          },
        );
      });

      testWidgets('cannot be pressed again while it works', (tester) async {
        final gate = Completer<void>();
        final toasts = _SlowToasts(gate);
        await onPlatform(
          tester,
          platform: TargetPlatform.windows,
          scheduler: windows(toasts),
          body: () async {
            final button = find.byKey(const Key('reminder-test'));
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            await tester.tap(button);
            await tester.pump();
            expect(
              tester.widget<OutlinedButton>(button).onPressed,
              isNull,
              reason: 'busy: a second press would hand over a second one',
            );
            await tester.tap(button, warnIfMissed: false);
            gate.complete();
            await tester.pumpAndSettle();
            expect(toasts.schedules, 1);
            expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
          },
        );
      });

      testWidgets('tells plainly when Windows refuses', (tester) async {
        final toasts = FakeToasts()..initOk = false;
        await onPlatform(
          tester,
          platform: TargetPlatform.windows,
          scheduler: windows(toasts),
          body: () async {
            final button = find.byKey(const Key('reminder-test'));
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(
              find.textContaining('nem sikerült beütemezni'),
              findsOneWidget,
            );
            expect(find.textContaining('StateError'), findsNothing);
            expect(
              find.textContaining('fél perc múlva megjelenik'),
              findsNothing,
            );
          },
        );
      });

      testWidgets('is not offered where the scheduler cannot do it', (
        tester,
      ) async {
        await onPlatform(
          tester,
          platform: TargetPlatform.android,
          scheduler: FakeScheduler(),
          body: () async {
            expect(find.byKey(const Key('reminder-test')), findsNothing);
          },
        );
      });
    });

    testWidgets('on a narrow screen with the largest text nothing overflows', (
      tester,
    ) async {
      final toasts = FakeToasts();
      await onPlatform(
        tester,
        platform: TargetPlatform.windows,
        scheduler: WindowsReminderScheduler(
          backend: toasts,
          read: (k) async => null,
          write: (k, v) async {},
          now: () => now,
        ),
        autostart: WindowsAutostart(
          backend: _NoEntry(),
          executable: r'C:\app\kvantum_app.exe',
        ),
        size: const Size(360, 800),
        textScale: 2.0,
        body: () async {
          final button = find.byKey(const Key('reminder-test'));
          // (the list builds what is on the screen: scroll down to it)
          await tester.scrollUntilVisible(
            button,
            400,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('autostart')), findsOneWidget);
          // the whole button is on the screen, not cut off at the side
          final rect = tester.getRect(button);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(360));
        },
      );
    });

    testWidgets('where there is no startup entry there is no switch', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        await onPlatform(
          tester,
          platform: platform,
          scheduler: FakeScheduler(),
          body: () async {
            expect(find.byKey(const Key('autostart')), findsNothing);
            // (the reminders themselves are there)
            expect(
              find.text('Napi check-in emlékeztető (20:00)'),
              findsOneWidget,
            );
          },
        );
      }
    });

    testWidgets(
      'where there are no reminders it says on which devices there are',
      (tester) async {
        await onPlatform(
          tester,
          platform: TargetPlatform.linux,
          scheduler: NoopReminderScheduler(),
          body: () async {
            expect(
              find.textContaining('Androidon és Windowson működnek'),
              findsOneWidget,
            );
          },
        );
      },
    );
  });
}

/// A startup list with nothing in it.
class _NoEntry implements AutostartBackend {
  @override
  Future<String?> readCommand() async => null;
  @override
  Future<bool> blockedByWindows() async => false;
  @override
  Future<void> writeCommand(String command) async {}
  @override
  Future<void> allow() async {}
  @override
  Future<void> removeCommand() async {}
}

/// Windows takes its time over handing a toast over.
class _SlowToasts extends FakeToasts {
  _SlowToasts(this.gate);
  final Completer<void> gate;
  int schedules = 0;

  @override
  Future<void> schedule(PlannedReminder r) async {
    schedules++;
    await gate.future;
    await super.schedule(r);
  }
}
