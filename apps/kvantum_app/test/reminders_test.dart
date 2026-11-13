import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/notify/reminders.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

DateTime at(int d, int h, [int m = 0]) =>
    resolveWallClock(bp, floating(2026, 11, d, h, m));

/// A device that holds what it was told, and remembers every call.
class FakeScheduler implements ReminderScheduler {
  FakeScheduler({this.grant = true, List<PlannedReminder> initial = const []})
    : device = {for (final r in initial) r.id: r};
  final bool grant;

  /// What the device holds now, by id.
  final Map<int, PlannedReminder> device;

  /// Every id ever cancelled, and every reminder ever scheduled, in order.
  final cancelled = <int>[];
  final scheduled = <PlannedReminder>[];
  var pendingReads = 0;

  @override
  bool get supported => true;
  @override
  Future<bool> ensurePermission() async => grant;
  @override
  Future<List<PlannedReminder>> pending() async {
    pendingReads++;
    return device.values.toList();
  }

  @override
  Future<void> cancel(Iterable<int> ids) async {
    for (final id in ids) {
      cancelled.add(id);
      device.remove(id);
    }
  }

  @override
  Future<void> schedule(Iterable<PlannedReminder> reminders) async {
    for (final r in reminders) {
      scheduled.add(r);
      device[r.id] = r;
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('planReminders', () {
    final now = at(12, 10); // 12 Nov 10:00
    final shifts = [
      (startUtc: at(12, 18), title: 'Éjszakai műszak'),
      (startUtc: at(13, 18), title: 'Éjszakai műszak'),
      (startUtc: at(12, 11), title: 'Nappali műszak'), // starts in 1 h
    ];

    test('everything is off by default', () {
      expect(
        planReminders(
          nowUtc: now,
          settings: const ReminderSettings(),
          shifts: shifts,
          checkedInDays: {},
        ),
        isEmpty,
      );
    });

    test(
      'shift reminders fire the chosen time before, past ones are skipped',
      () {
        final p = planReminders(
          nowUtc: now,
          settings: const ReminderSettings(shiftLeadMinutes: 120),
          shifts: shifts,
          checkedInDays: {},
        );
        // the 11:00 shift would have been reminded at 09:00 = already past
        expect(p.length, 2);
        expect(p.first.atUtc, at(12, 16));
        expect(p.first.title, 'Éjszakai műszak');
        expect(p.first.body, '2 óra múlva kezdődik: 18:00');
        expect(p.last.atUtc, at(13, 16));
        expect(p.map((r) => r.id).toSet().length, 2);
      },
    );

    test('check-in reminder at 20:00, not for days that already have one', () {
      final p = planReminders(
        nowUtc: now,
        settings: const ReminderSettings(checkIn: true),
        shifts: const [],
        checkedInDays: {floating(2026, 11, 12)},
        horizonDays: 3,
      );
      expect(p.map((r) => r.atUtc), [at(13, 20), at(14, 20), at(15, 20)]);
    });

    test(
      'check-in evening already over today means the first one is tomorrow',
      () {
        final p = planReminders(
          nowUtc: at(12, 21),
          settings: const ReminderSettings(checkIn: true),
          shifts: const [],
          checkedInDays: {},
          horizonDays: 1,
        );
        expect(p.single.atUtc, at(13, 20));
      },
    );

    test('the count is capped and sorted', () {
      final many = [
        for (var i = 0; i < 100; i++)
          (startUtc: at(12, 18).add(Duration(hours: i * 2)), title: 'x'),
      ];
      final p = planReminders(
        nowUtc: now,
        settings: const ReminderSettings(shiftLeadMinutes: 60),
        shifts: many,
        checkedInDays: {},
        maxCount: 10,
      );
      expect(p.length, 10);
      expect(
        [for (var i = 1; i < p.length; i++) p[i].atUtc.isAfter(p[i - 1].atUtc)]
            .every((b) => b),
        isTrue,
      );
    });
  });

  test(
    'settings are remembered, and bad stored values fall back to off',
    () async {
      final m = <String, String?>{};
      final store = ReminderSettingsStore(
        read: (k) async => m[k],
        write: (k, v) async => m[k] = v,
      );
      await store.save(
        const ReminderSettings(shiftLeadMinutes: 180, checkIn: true),
      );
      final s = await store.load();
      expect([s.shiftLeadMinutes, s.checkIn], [180, true]);
      m['rem.shift'] = '77';
      expect((await store.load()).shiftLeadMinutes, 0);
    },
  );

  group('diffReminders: only the difference reaches the device', () {
    test('a plan with time-zone times equals what the device reports', () {
      // (the evening reminders are made with the time-zone package, whose
      // times do not equal a plain DateTime of the same moment)
      final plan = planReminders(
        nowUtc: at(12, 10),
        settings: const ReminderSettings(checkIn: true),
        shifts: const [],
        checkedInDays: {},
      );
      expect(plan, isNotEmpty);
      final onDevice = [
        for (final p in plan)
          plannedFromPending(
            p.id,
            p.title,
            p.body,
            '${p.atUtc.millisecondsSinceEpoch}',
          ),
      ];
      expect(diffReminders(onDevice, plan).isEmpty, isTrue);
      // the same moment is one reminder, whichever kind of time holds it
      expect(onDevice.map((r) => r.hashCode), plan.map((r) => r.hashCode));
      expect({...onDevice, ...plan}.length, plan.length);
    });

    PlannedReminder r(
      int id,
      int day, [
      String title = 'x',
      String body = 'b',
    ]) => PlannedReminder(id, at(day, 16), title, body);

    test('nothing changed, nothing to do', () {
      final a = [r(1, 12), r(2, 13)];
      expect(diffReminders(a, [r(1, 12), r(2, 13)]).isEmpty, isTrue);
      expect(diffReminders(const [], const []).isEmpty, isTrue);
    });

    test('new ones are scheduled, vanished ones cancelled, the rest left', () {
      final d = diffReminders([r(1, 12), r(2, 13)], [r(2, 13), r(3, 14)]);
      expect(d.cancel, [1]);
      expect(d.schedule.map((x) => x.id), [3]);
    });

    test('a changed time or text replaces the reminder, no cancel', () {
      final d = diffReminders(
        [r(1, 12), r(2, 13), r(3, 14)],
        [r(1, 12, 'x', 'b'), r(2, 14), r(3, 14, 'y')],
      );
      expect(d.cancel, isEmpty);
      expect(d.schedule.map((x) => x.id), [2, 3]);
      final body = diffReminders([r(1, 12)], [r(1, 12, 'x', 'más')]);
      expect(body.schedule.map((x) => x.id), [1]);
    });

    test('an id twice in the plan counts once, the later one', () {
      final d = diffReminders(const [], [r(1, 12), r(1, 13)]);
      expect(d.schedule, hasLength(1));
      expect(d.schedule.single.atUtc, at(13, 16));
      // and then it is stable: the device holds the later one
      expect(diffReminders(d.schedule, [r(1, 12), r(1, 13)]).isEmpty, isTrue);
    });
  });

  group('syncReminders on a device', () {
    PlannedReminder r(int id, int day, [String title = 'x']) =>
        PlannedReminder(id, at(day, 16), title, 'b');

    test(
      'the first run schedules everything, the second touches nothing',
      () async {
        final dev = FakeScheduler();
        await syncReminders(dev, [r(1, 12), r(2, 13)]);
        expect(dev.scheduled.map((x) => x.id), [1, 2]);
        expect(dev.cancelled, isEmpty);

        await syncReminders(dev, [r(1, 12), r(2, 13)]);
        expect(dev.scheduled, hasLength(2), reason: 'nothing scheduled again');
        expect(dev.cancelled, isEmpty);
        expect(dev.pendingReads, 2);
      },
    );

    test('one shift less cancels that one only', () async {
      final dev = FakeScheduler(initial: [r(1, 12), r(2, 13), r(3, 14)]);
      await syncReminders(dev, [r(1, 12), r(3, 14)]);
      expect(dev.cancelled, [2]);
      expect(dev.scheduled, isEmpty);
      expect(dev.device.keys, unorderedEquals([1, 3]));
    });

    test(
      'a changed lead time moves the reminders without cancelling',
      () async {
        final dev = FakeScheduler(initial: [r(1, 12), r(2, 13)]);
        await syncReminders(dev, [
          PlannedReminder(1, at(12, 15), 'x', 'b'),
          PlannedReminder(2, at(13, 15), 'x', 'b'),
        ]);
        expect(dev.cancelled, isEmpty);
        expect(dev.device[1]!.atUtc, at(12, 15));
        expect(dev.device[2]!.atUtc, at(13, 15));
      },
    );

    test('what an older version left behind is replaced or removed', () async {
      // no time on record (time 0): never equal to a plan
      final dev = FakeScheduler(
        initial: [
          plannedFromPending(1, 'x', 'b', null),
          plannedFromPending(9, 'régi', 'b', null),
        ],
      );
      await syncReminders(dev, [r(1, 12)]);
      expect(dev.cancelled, [9]);
      expect(dev.device[1], r(1, 12));
    });

    test('a failure in the middle is repaired by the next run', () async {
      final dev = _FailingOnce(initial: [r(1, 12)]);
      await expectLater(
        syncReminders(dev, [r(1, 12), r(2, 13), r(3, 14)]),
        throwsA(anything),
      );
      await syncReminders(dev, [r(1, 12), r(2, 13), r(3, 14)]);
      expect(dev.device.keys, unorderedEquals([1, 2, 3]));
    });
  });

  test('the time of a pending notification travels in its payload', () {
    final p = plannedFromPending(
      5,
      'Cím',
      'Szöveg',
      '${at(12, 16).millisecondsSinceEpoch}',
    );
    expect(p, PlannedReminder(5, at(12, 16), 'Cím', 'Szöveg'));
    final bare = plannedFromPending(5, null, null, 'nem szám');
    expect(bare.atUtc, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    expect((bare.title, bare.body), ('', ''));
  });

  group('the sync provider', () {
    late AppDatabase db;
    late FakeScheduler fake;
    late ManualTimers timers;
    late ProviderContainer c;

    DateTime? fixedNow;
    setUp(() async {
      db = await newDb();
      fake = FakeScheduler();
      timers = ManualTimers();
      fixedNow = DateTime.utc(2026, 11, 12, 9);
      c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          reminderSchedulerProvider.overrideWithValue(fake),
          reminderTimerProvider.overrideWithValue(timers.make),
          appClockProvider.overrideWithValue(() => fixedNow!),
        ],
      );
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<void> shiftOn(int day, {String id = 's1'}) =>
        EventRepository(db).saveLocal(
          CalEvent(
            id: id,
            calendarId: kNaptarCalendar,
            title: 'Éjszakai műszak',
            notes: kShiftMarker,
            start: floating(2026, 11, day, 18),
            end: floating(2026, 11, day, 18).add(const Duration(hours: 12)),
            tzid: bp,
          ),
        );

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 400 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<void> turnOn(ReminderSettings s) async {
      await c.read(reminderSettingsProvider.future);
      await c.read(reminderSettingsProvider.notifier).change(s);
      c.listen(reminderSyncProvider, (_, _) {}, fireImmediately: true);
      await until(() => timers.live > 0);
    }

    Future<void> fireLast() async {
      final before = fake.pendingReads;
      timers.made.lastWhere((m) => m.live()).fire();
      await until(() => fake.pendingReads > before);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test(
      'puts shift reminders on the device and cancels them when off',
      () async {
        await shiftOn(14);
        await turnOn(const ReminderSettings(shiftLeadMinutes: 120));
        await fireLast();
        expect(fake.device.values.map((r) => r.title), ['Éjszakai műszak']);
        expect(fake.device.values.single.atUtc, at(14, 16));

        await c
            .read(reminderSettingsProvider.notifier)
            .change(const ReminderSettings());
        await until(() => timers.live > 0);
        await fireLast();
        expect(fake.device, isEmpty);
        expect(fake.cancelled, hasLength(1));
      },
    );

    test(
      'a burst of changes waits, and then costs one look at the device',
      () async {
        await turnOn(const ReminderSettings(shiftLeadMinutes: 60));
        for (var d = 13; d < 18; d++) {
          await shiftOn(d, id: 's$d');
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        // every change started the wait again; only the newest is still running
        expect(timers.made.length, greaterThan(2));
        expect(timers.live, 1);
        expect(timers.made.last.wait, const Duration(milliseconds: 1500));
        expect(
          fake.pendingReads,
          0,
          reason: 'nothing happens while it settles',
        );

        await fireLast();
        expect(fake.pendingReads, 1);
        expect(fake.device, hasLength(5));
      },
    );

    test('leaving cancels the wait', () async {
      await turnOn(const ReminderSettings(shiftLeadMinutes: 60));
      expect(timers.live, 1);
      c.dispose();
      expect(timers.live, 0);
      expect(fake.pendingReads, 0);
    });

    test(
      'a second look with nothing new changes nothing on the device',
      () async {
        await shiftOn(14);
        await turnOn(const ReminderSettings(shiftLeadMinutes: 120));
        await fireLast();
        final scheduled = fake.scheduled.length;
        // a sync touches the event again without changing it
        await shiftOn(14);
        await until(() => timers.live > 0);
        await fireLast();
        expect(fake.scheduled.length, scheduled);
        expect(fake.cancelled, isEmpty);
      },
    );
  });

  group('settings page', () {
    late AppDatabase db;

    Future<FakeScheduler> boot(WidgetTester tester, {bool grant = true}) async {
      useSize(tester, size: const Size(900, 1600));
      db = await newDb();
      final fake = FakeScheduler(grant: grant);
      await tester.pumpWidget(
        app(
          const SettingsPage(),
          db,
          extra: [
            reminderSchedulerProvider.overrideWithValue(fake),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('a refused permission switches nothing on and says why', (
      tester,
    ) async {
      await boot(tester, grant: false);
      final sw = find.text('Napi check-in emlékeztető (20:00)');
      await tester.scrollUntilVisible(
        sw,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Az értesítések le vannak tiltva'),
        findsOneWidget,
      );
      final s = tester.widget<SwitchListTile>(
        find.widgetWithText(
          SwitchListTile,
          'Napi check-in emlékeztető (20:00)',
        ),
      );
      expect(s.value, isFalse);
      await shutdown(tester, db);
    });

    testWidgets('with permission the choice is stored', (tester) async {
      await boot(tester);
      final sw = find.text('Napi check-in emlékeztető (20:00)');
      await tester.scrollUntilVisible(
        sw,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      final s = tester.widget<SwitchListTile>(
        find.widgetWithText(
          SwitchListTile,
          'Napi check-in emlékeztető (20:00)',
        ),
      );
      expect(s.value, isTrue);
      await shutdown(tester, db);
    });
  });
}

/// A device whose first scheduling attempt fails halfway.
class _FailingOnce extends FakeScheduler {
  _FailingOnce({super.initial});
  var _failed = false;
  @override
  Future<void> schedule(Iterable<PlannedReminder> reminders) async {
    if (!_failed) {
      _failed = true;
      await super.schedule(reminders.take(1));
      throw StateError('a megszakadt');
    }
    await super.schedule(reminders);
  }
}
