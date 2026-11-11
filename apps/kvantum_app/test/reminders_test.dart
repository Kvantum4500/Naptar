import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/notify/reminders.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

DateTime at(int d, int h, [int m = 0]) =>
    resolveWallClock(bp, floating(2026, 11, d, h, m));

class FakeScheduler implements ReminderScheduler {
  FakeScheduler({this.grant = true});
  final bool grant;
  final calls = <List<PlannedReminder>>[];
  @override
  bool get supported => true;
  @override
  Future<bool> ensurePermission() async => grant;
  @override
  Future<void> replaceAll(List<PlannedReminder> r) async => calls.add(r);
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

  test(
    'the sync provider puts shift reminders on the device and cancels when off',
    () async {
      final db = await newDb();
      final fake = FakeScheduler();
      final c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          reminderSchedulerProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(() async {
        c.dispose();
        await db.close();
      });
      // a shift two days from now (generated shifts carry the marker)
      final start = DateTime.now().toUtc().add(const Duration(days: 2));
      final wall = toWallClock(bp, start);
      await EventRepository(db).saveLocal(
        CalEvent(
          id: 's1',
          calendarId: kNaptarCalendar,
          title: 'Éjszakai műszak',
          notes: kShiftMarker,
          start: floating(wall.year, wall.month, wall.day, 18),
          end: floating(
            wall.year,
            wall.month,
            wall.day,
            18,
          ).add(const Duration(hours: 12)),
          tzid: bp,
        ),
      );
      await c.read(reminderSettingsProvider.future);
      await c
          .read(reminderSettingsProvider.notifier)
          .change(const ReminderSettings(shiftLeadMinutes: 120));
      c.listen(reminderSyncProvider, (_, _) {}, fireImmediately: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(fake.calls, isNotEmpty);
      expect(fake.calls.last.map((r) => r.title), ['Éjszakai műszak']);

      await c
          .read(reminderSettingsProvider.notifier)
          .change(const ReminderSettings());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(fake.calls.last, isEmpty);
    },
  );

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
