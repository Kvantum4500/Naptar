import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show BigTextStyleInformation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/weather_service.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/notify/reminders.dart';
import 'package:kvantum_app/notify/summary_plan.dart' show summaryHorizonDays;
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

/// A forecast service that answers what it is told to and remembers the asks.
class _FakeWeather extends WeatherService {
  _FakeWeather() : super(http.Client());
  List<DayWeather>? answer;
  final calls = <({Place place, int days})>[];

  @override
  Future<List<DayWeather>?> forecast(
    Place place, {
    int days = 7,
    String timezone = 'Europe/Budapest',
  }) async {
    calls.add((place: place, days: days));
    return answer;
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

  group('planReminders: the morning summary', () {
    final now = at(12, 10); // 12 Nov 10:00
    const settings = ReminderSettings(summaryMinutes: 450); // 7:30
    DaySummary sum(String x) => DaySummary('Ma: $x', 'szöveg $x');
    final summaries = {
      floating(2026, 11, 12): sum('csütörtök'), // 7:30 is already over
      floating(2026, 11, 13): sum('péntek'),
      floating(2026, 11, 14): sum('szombat'),
      floating(2026, 11, 19): sum('csütörtök+7'),
      floating(2026, 11, 20): sum('túl messze'),
    };

    test('one per day with a text, at the chosen time, none in the past', () {
      final p = planReminders(
        nowUtc: now,
        settings: settings,
        shifts: const [],
        checkedInDays: {},
        summaries: summaries,
      );
      expect(p.map((r) => r.atUtc), [
        at(13, 7, 30),
        at(14, 7, 30),
        at(19, 7, 30),
      ]);
      expect(p.first.title, 'Ma: péntek');
      expect(p.first.body, 'szöveg péntek');
    });

    test('reaches today and seven days, no further', () {
      final p = planReminders(
        nowUtc: at(12, 6), // before 7:30, so today counts
        settings: settings,
        shifts: const [],
        checkedInDays: {},
        summaries: summaries,
      );
      expect(p.map((r) => r.title), [
        'Ma: csütörtök',
        'Ma: péntek',
        'Ma: szombat',
        'Ma: csütörtök+7',
      ]);
      expect(
        p.map((r) => r.title),
        isNot(contains('Ma: túl messze')),
        reason: 'the day after today+7 is beyond the horizon',
      );
    });

    test('nothing when the summary is off, whatever the texts', () {
      expect(
        planReminders(
          nowUtc: now,
          settings: const ReminderSettings(checkIn: false),
          shifts: const [],
          checkedInDays: {},
          summaries: summaries,
        ),
        isEmpty,
      );
    });

    test('a day without a text has no notification', () {
      final p = planReminders(
        nowUtc: now,
        settings: settings,
        shifts: const [],
        checkedInDays: {},
        summaries: {floating(2026, 11, 14): sum('szombat')},
      );
      expect(p.map((r) => r.title), ['Ma: szombat']);
    });

    test('the id is the day: stable, apart from the check-ins\' ids', () {
      final p = planReminders(
        nowUtc: now,
        settings: const ReminderSettings(summaryMinutes: 450, checkIn: true),
        shifts: const [],
        checkedInDays: {},
        summaries: {floating(2026, 11, 13): sum('péntek')},
        horizonDays: 2,
      );
      final summary = p.singleWhere((r) => r.title == 'Ma: péntek');
      final days = floating(2026, 11, 13).millisecondsSinceEpoch ~/ 86400000;
      expect(summary.id, summaryReminderIdBase + days);
      expect(summary.id, isNot(1500000000 + days));
      expect(p.map((r) => r.id).toSet().length, p.length);
      expect(summaryReminderIdBase, greaterThan(1500000000 + 40000));
      expect(summaryReminderIdBase + 40000, lessThan(2000000001));
    });

    test('sorted with the others by time', () {
      final p = planReminders(
        nowUtc: now,
        settings: const ReminderSettings(
          summaryMinutes: 450,
          checkIn: true,
          shiftLeadMinutes: 60,
        ),
        shifts: [(startUtc: at(14, 8), title: 'Reggeli műszak')],
        checkedInDays: {},
        summaries: {floating(2026, 11, 14): sum('szombat')},
        horizonDays: 3,
      );
      expect(p.map((r) => r.atUtc), [...p.map((r) => r.atUtc)]..sort());
      // the shift reminder (07:00) comes before the summary (07:30) of the day
      final onThe14th = p.where(
        (r) => r.atUtc.isAfter(at(14, 0)) && r.atUtc.isBefore(at(14, 12)),
      );
      expect(onThe14th.map((r) => r.title), ['Reggeli műszak', 'Ma: szombat']);
    });

    test('the time of day is the zone\'s, also over a clock change', () {
      // 25 Oct 2026: the clocks go back at 03:00 -> a 7:30 summary is at 06:30 UTC
      final p = planReminders(
        nowUtc: resolveWallClock(bp, floating(2026, 10, 24, 12)),
        settings: settings,
        shifts: const [],
        checkedInDays: {},
        summaries: {
          floating(2026, 10, 24): sum('szombat'),
          floating(2026, 10, 25): sum('vasárnap'),
        },
      );
      expect(p.map((r) => r.atUtc), [DateTime.utc(2026, 10, 25, 6, 30)]);
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
    'the morning summary time is remembered, and only the offered ones',
    () async {
      final m = <String, String?>{};
      final store = ReminderSettingsStore(
        read: (k) async => m[k],
        write: (k, v) async => m[k] = v,
      );
      expect((await store.load()).summaryMinutes, 0, reason: 'off by default');
      await store.save(const ReminderSettings(summaryMinutes: 450));
      expect(m['rem.summary'], '450');
      expect((await store.load()).summaryMinutes, 450);
      for (final bad in ['100', '361', '-30', 'x', '', '1440']) {
        m['rem.summary'] = bad;
        expect((await store.load()).summaryMinutes, 0, reason: bad);
      }
      await store.save(const ReminderSettings());
      expect(m['rem.summary'], isNull, reason: 'off is no entry');
    },
  );

  test('a summary alone counts as a reminder, and survives a copy', () {
    expect(const ReminderSettings(summaryMinutes: 420).any, isTrue);
    expect(const ReminderSettings().any, isFalse);
    final c = const ReminderSettings(
      shiftLeadMinutes: 60,
      checkIn: true,
      summaryMinutes: 420,
    ).copyWith(shiftLeadMinutes: 120);
    expect((c.shiftLeadMinutes, c.checkIn, c.summaryMinutes), (120, true, 420));
    expect(summaryChoices.first, 360);
    expect(summaryChoices.last, 540);
    expect(summaryTimeLabel(360), '6:00');
    expect(summaryTimeLabel(450), '7:30');
    expect(summaryTimeLabel(540), '9:00');
  });

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
    late _FakeWeather weather;

    DateTime? fixedNow;
    setUp(() async {
      db = await newDb();
      fake = FakeScheduler();
      timers = ManualTimers();
      weather = _FakeWeather();
      fixedNow = DateTime.utc(2026, 11, 12, 9);
      c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          reminderSchedulerProvider.overrideWithValue(fake),
          reminderTimerProvider.overrideWithValue(timers.make),
          appClockProvider.overrideWithValue(() => fixedNow!),
          weatherServiceProvider.overrideWithValue(weather),
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
      // (a rebuild of the provider cancels the old wait, then starts a new one)
      await until(() => timers.live > 0);
      timers.made.lastWhere((m) => m.live()).fire();
      await until(() => fake.pendingReads > before);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    /// Everything the sync watches has answered and every wait that started
    /// meanwhile is over: only a real change can start the next one.
    Future<void> settle() async {
      await c.read(tasksProvider.future);
      await c.read(eventsTickProvider.future);
      await fireLast();
      while (timers.live > 0) {
        await fireLast();
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(timers.live, 0);
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

    test('the morning summary is made from the events and the tasks', () async {
      // tomorrow (Friday 13 Nov): a visit at 14:00 and a task due that day
      await EventRepository(db).saveLocal(
        CalEvent(
          id: 'v1',
          calendarId: kNaptarCalendar,
          title: 'Fogorvos',
          start: floating(2026, 11, 13, 14),
          end: floating(2026, 11, 13, 15),
          tzid: bp,
        ),
      );
      await RecordRepository(db).edit(
        kindTask,
        't1',
        taskFields(title: 'Számla befizetése', due: floating(2026, 11, 13)),
      );
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      // (the tasks come in as a stream; a plan made before they are there is
      // made again when they arrive)
      await c.read(tasksProvider.future);
      await until(() => timers.made.where((m) => m.live()).isNotEmpty);
      await fireLast();
      final r = fake.device.values.single;
      expect(r.atUtc, at(13, 7, 30));
      expect(r.title, 'Ma: péntek, nov. 13.');
      expect(r.body.split('\n'), [
        '14:00 Fogorvos',
        'Feladat: Számla befizetése',
      ]);
    });

    test(
      'a changed event rewrites the text, nothing else is touched',
      () async {
        await EventRepository(db).saveLocal(
          CalEvent(
            id: 'v1',
            calendarId: kNaptarCalendar,
            title: 'Fogorvos',
            start: floating(2026, 11, 13, 14),
            end: floating(2026, 11, 13, 15),
            tzid: bp,
          ),
        );
        await turnOn(const ReminderSettings(summaryMinutes: 450));
        await fireLast();
        final first = fake.device.values.single;
        expect(first.body, '14:00 Fogorvos');
        // moved to 16:00
        await EventRepository(db).saveLocal(
          CalEvent(
            id: 'v1',
            calendarId: kNaptarCalendar,
            title: 'Fogorvos',
            start: floating(2026, 11, 13, 16),
            end: floating(2026, 11, 13, 17),
            tzid: bp,
            version: 2,
          ),
        );
        await until(() => timers.made.where((m) => m.live()).isNotEmpty);
        await fireLast();
        final second = fake.device.values.single;
        expect(second.id, first.id, reason: 'same day, same notification');
        expect(second.body, '16:00 Fogorvos');
      },
    );

    Future<void> visitTomorrow() => EventRepository(db).saveLocal(
      CalEvent(
        id: 'v1',
        calendarId: kNaptarCalendar,
        title: 'Fogorvos',
        start: floating(2026, 11, 13, 14),
        end: floating(2026, 11, 13, 15),
        tzid: bp,
      ),
    );

    final place = Place(name: 'Szeged', lat: 46.25, lon: 20.15);
    final rainy = DayWeather(
      day: floating(2026, 11, 13),
      tMin: 2,
      tMax: 8,
      precipProb: 70,
      code: 61,
    );

    test(
      'the weather line is the forecast of the place for that day',
      () async {
        weather.answer = [
          DayWeather(day: floating(2026, 11, 12), tMin: 9, tMax: 12, code: 0),
          rainy,
        ];
        await visitTomorrow();
        await c.read(aiSettingsProvider.future);
        await c
            .read(aiSettingsProvider.notifier)
            .change(AiSettings(place: place));
        await turnOn(const ReminderSettings(summaryMinutes: 450));
        await fireLast();
        expect(weather.calls, hasLength(1));
        expect(weather.calls.single.place, place);
        // today and the eight days of the plan: the forecast starts today
        expect(weather.calls.single.days, summaryHorizonDays + 1);
        expect(fake.device.values.single.body.split('\n'), [
          'Időjárás: ${weatherLine(rainy)}',
          '14:00 Fogorvos',
        ]);
      },
    );

    test('with the switch off the forecast is not asked for', () async {
      weather.answer = [rainy];
      await visitTomorrow();
      await c.read(aiSettingsProvider.future);
      await c
          .read(aiSettingsProvider.notifier)
          .change(AiSettings(place: place, weather: false));
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await fireLast();
      expect(weather.calls, isEmpty);
      expect(fake.device.values.single.body, '14:00 Fogorvos');
    });

    test('without a place the forecast is not asked for', () async {
      weather.answer = [rainy];
      await visitTomorrow();
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await fireLast();
      expect(weather.calls, isEmpty);
      expect(fake.device.values.single.body, '14:00 Fogorvos');
    });

    test('a forecast that is not to be had leaves the line out', () async {
      weather.answer = null;
      await visitTomorrow();
      await c.read(aiSettingsProvider.future);
      await c
          .read(aiSettingsProvider.notifier)
          .change(AiSettings(place: place));
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await fireLast();
      expect(weather.calls, hasLength(1));
      expect(fake.device.values.single.body, '14:00 Fogorvos');
    });

    test('a new place makes a new plan', () async {
      weather.answer = [rainy];
      await visitTomorrow();
      await c.read(aiSettingsProvider.future);
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await settle();
      expect(fake.device.values.single.body, '14:00 Fogorvos');

      await c
          .read(aiSettingsProvider.notifier)
          .change(AiSettings(place: place));
      await until(() => timers.live > 0);
      await fireLast();
      expect(fake.device.values.single.body.split('\n'), [
        'Időjárás: ${weatherLine(rainy)}',
        '14:00 Fogorvos',
      ]);
    });

    test('the new day moves the eight days on', () async {
      // an event nine days ahead: outside the plan today, inside it tomorrow
      await EventRepository(db).saveLocal(
        CalEvent(
          id: 'far',
          calendarId: kNaptarCalendar,
          title: 'Konferencia',
          start: floating(2026, 11, 20, 9),
          end: floating(2026, 11, 20, 10),
          tzid: bp,
        ),
      );
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await settle();
      expect(fake.device, isEmpty);

      fixedNow = DateTime.utc(2026, 11, 13, 9);
      c.read(todayProvider.notifier).refresh();
      await until(() => timers.live > 0);
      await fireLast();
      expect(fake.device.values.single.atUtc, at(20, 7, 30));
      expect(fake.device.values.single.body, '09:00 Konferencia');
    });

    test('the summary of today also tells what is over by then', () async {
      // 05:00 in Budapest; the summary is for 7:30; the visit was at 3:00
      fixedNow = DateTime.utc(2026, 11, 12, 4);
      await EventRepository(db).saveLocal(
        CalEvent(
          id: 'early',
          calendarId: kNaptarCalendar,
          title: 'Korai vizsgálat',
          start: floating(2026, 11, 12, 3),
          end: floating(2026, 11, 12, 4),
          tzid: bp,
        ),
      );
      await turnOn(const ReminderSettings(summaryMinutes: 450));
      await fireLast();
      final r = fake.device.values.single;
      expect(r.atUtc, at(12, 7, 30));
      expect(r.body, '03:00 Korai vizsgálat');
    });

    test('with the summary off, no tasks or places are looked at', () async {
      await turnOn(const ReminderSettings(shiftLeadMinutes: 60));
      await fireLast();
      expect(fake.device, isEmpty);
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

  group('how an Android reminder looks', () {
    test('a short one is plain', () {
      final d = AndroidReminderScheduler.detailsFor(
        PlannedReminder(1, at(13, 7), 'Cím', 'Egy sor'),
      );
      expect(d.android!.channelId, 'reminders');
      expect(d.android!.styleInformation, isNull);
    });

    test('a text of several lines opens up to all of them', () {
      final d = AndroidReminderScheduler.detailsFor(
        PlannedReminder(1, at(13, 7), 'Ma', '14:00 Fogorvos\nFeladat: Számla'),
      );
      expect(d.android!.channelId, 'reminders');
      final style = d.android!.styleInformation;
      expect(style, isA<BigTextStyleInformation>());
      expect(
        (style! as BigTextStyleInformation).bigText,
        '14:00 Fogorvos\nFeladat: Számla',
      );
    });
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

    Finder summaryField() => find.widgetWithText(
      DropdownButtonFormField<int>,
      'Reggeli összefoglaló',
    );

    Future<void> chooseSummary(WidgetTester tester, String time) async {
      await tester.scrollUntilVisible(
        summaryField(),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(summaryField());
      await tester.pumpAndSettle();
      await tester.tap(summaryField());
      await tester.pumpAndSettle();
      await tester.tap(find.text(time).last);
      await tester.pumpAndSettle();
    }

    ReminderSettings stored(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(SettingsPage)))
            .read(reminderSettingsProvider)
            .value!;

    testWidgets('the morning summary: off at first, the choice is stored', (
      tester,
    ) async {
      await boot(tester);
      await tester.scrollUntilVisible(
        summaryField(),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: summaryField(), matching: find.text('Ki')),
        findsOneWidget,
      );
      expect(stored(tester).summaryMinutes, 0);
      await chooseSummary(tester, '7:30');
      expect(stored(tester).summaryMinutes, 450);
      expect(
        find.descendant(of: summaryField(), matching: find.text('7:30')),
        findsOneWidget,
      );
      // the words say what it is and that the text can be seen on the lock screen
      expect(
        find.textContaining('zárolt képernyőn is látszhat'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a refused permission leaves the summary off, and shows it', (
      tester,
    ) async {
      await boot(tester, grant: false);
      await chooseSummary(tester, '8:00');
      expect(
        find.textContaining('Az értesítések le vannak tiltva'),
        findsOneWidget,
      );
      expect(stored(tester).summaryMinutes, 0);
      expect(
        find.descendant(of: summaryField(), matching: find.text('Ki')),
        findsOneWidget,
        reason: 'the field shows what is in force, not what was tried',
      );
      expect(
        find.descendant(of: summaryField(), matching: find.text('8:00')),
        findsNothing,
      );
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
