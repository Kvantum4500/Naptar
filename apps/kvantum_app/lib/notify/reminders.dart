import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:timezone/timezone.dart' as tz;

import '../ai/ai_providers.dart'
    show aiSettingsProvider, weatherServiceProvider;
import '../diag/diag_log.dart';
import '../providers.dart';
import '../ui/day_utils.dart';
import 'summary_plan.dart';
import 'windows_reminders.dart';

/// What the user wants to be reminded of. Everything is off by default.
class ReminderSettings {
  const ReminderSettings({
    this.shiftLeadMinutes = 0,
    this.checkIn = false,
    this.summaryMinutes = 0,
  });

  /// Minutes before a shift starts (0 = no shift reminder).
  final int shiftLeadMinutes;

  /// A reminder in the evening to fill in the daily check-in.
  final bool checkIn;

  /// The morning summary of the day, at this many minutes after midnight (one
  /// of [summaryChoices]; 0 = none).
  final int summaryMinutes;

  bool get any => shiftLeadMinutes > 0 || checkIn || summaryMinutes > 0;

  ReminderSettings copyWith({
    int? shiftLeadMinutes,
    bool? checkIn,
    int? summaryMinutes,
  }) => ReminderSettings(
    shiftLeadMinutes: shiftLeadMinutes ?? this.shiftLeadMinutes,
    checkIn: checkIn ?? this.checkIn,
    summaryMinutes: summaryMinutes ?? this.summaryMinutes,
  );
}

/// The times the morning summary can be set to: 6:00 to 9:00, every half hour
/// (minutes after midnight).
const summaryChoices = [360, 390, 420, 450, 480, 510, 540];

/// 450 -> "7:30".
String summaryTimeLabel(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

class ReminderSettingsStore {
  ReminderSettingsStore({required this.read, required this.write});
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String? value) write;

  Future<ReminderSettings> load() async {
    final lead = int.tryParse(await read('rem.shift') ?? '') ?? 0;
    final summary = int.tryParse(await read('rem.summary') ?? '') ?? 0;
    return ReminderSettings(
      shiftLeadMinutes: const {0, 60, 120, 180}.contains(lead) ? lead : 0,
      checkIn: (await read('rem.checkin')) == 'on',
      summaryMinutes: summaryChoices.contains(summary) ? summary : 0,
    );
  }

  Future<void> save(ReminderSettings s) async {
    await write(
      'rem.shift',
      s.shiftLeadMinutes == 0 ? null : '${s.shiftLeadMinutes}',
    );
    await write('rem.checkin', s.checkIn ? 'on' : null);
    await write(
      'rem.summary',
      s.summaryMinutes == 0 ? null : '${s.summaryMinutes}',
    );
  }
}

class PlannedReminder {
  const PlannedReminder(this.id, this.atUtc, this.title, this.body);
  final int id;
  final DateTime atUtc;
  final String title;
  final String body;

  // (compared by the instant: a time made with the time-zone package equals
  // no other DateTime with `==`, not even the same moment read back from the
  // device - every evening reminder looked "changed" and was set again)
  @override
  bool operator ==(Object other) =>
      other is PlannedReminder &&
      other.id == id &&
      other.atUtc.microsecondsSinceEpoch == atUtc.microsecondsSinceEpoch &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode =>
      Object.hash(id, atUtc.microsecondsSinceEpoch, title, body);

  @override
  String toString() => 'PlannedReminder($id, $atUtc, $title)';
}

/// Hour (wall clock) of the evening check-in reminder.
const checkInReminderHour = 20;

/// Pure planning: which notifications should exist right now. Only future
/// ones, at most [maxCount], soonest first. [checkedInDays] are floating dates
/// that already have a check-in (no reminder for those evenings).
List<PlannedReminder> planReminders({
  required DateTime nowUtc,
  required ReminderSettings settings,
  required List<({DateTime startUtc, String title})> shifts,
  required Set<DateTime> checkedInDays,
  Map<DateTime, DaySummary> summaries = const {},
  String tzid = defaultTz,
  int horizonDays = 14,
  int maxCount = 60,
}) {
  final out = <PlannedReminder>[];
  if (settings.shiftLeadMinutes > 0) {
    for (final s in shifts) {
      final at = s.startUtc.subtract(
        Duration(minutes: settings.shiftLeadMinutes),
      );
      if (!at.isAfter(nowUtc)) continue;
      if (at.isAfter(nowUtc.add(Duration(days: horizonDays)))) continue;
      final w = toWallClock(tzid, s.startUtc);
      final lead = settings.shiftLeadMinutes ~/ 60;
      out.add(
        PlannedReminder(
          s.startUtc.millisecondsSinceEpoch ~/ 60000, // unique per shift start
          at,
          s.title,
          '${lead == 1 ? '1 óra' : '$lead óra'} múlva kezdődik: ${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}',
        ),
      );
    }
  }
  if (settings.checkIn) {
    final today = toWallClock(tzid, nowUtc);
    for (var i = 0; i <= horizonDays; i++) {
      final day = floating(
        today.year,
        today.month,
        today.day,
      ).add(Duration(days: i));
      if (checkedInDays.contains(day)) continue;
      final at = resolveWallClock(
        tzid,
        floating(day.year, day.month, day.day, checkInReminderHour),
      );
      if (!at.isAfter(nowUtc)) continue;
      out.add(
        PlannedReminder(
          1500000000 + day.millisecondsSinceEpoch ~/ 86400000,
          at,
          'Napi check-in',
          'Hogy vagy ma? Pár koppintás az energiaszintről és a hangulatról.',
        ),
      );
    }
  }
  if (settings.summaryMinutes > 0) {
    final today = toWallClock(tzid, nowUtc);
    final hour = settings.summaryMinutes ~/ 60;
    final minute = settings.summaryMinutes % 60;
    for (var i = 0; i <= summaryHorizonDays; i++) {
      final day = floating(
        today.year,
        today.month,
        today.day,
      ).add(Duration(days: i));
      final summary = summaries[day];
      if (summary == null) continue;
      final at = resolveWallClock(
        tzid,
        floating(day.year, day.month, day.day, hour, minute),
      );
      if (!at.isAfter(nowUtc)) continue;
      out.add(
        PlannedReminder(
          summaryReminderIdBase + day.millisecondsSinceEpoch ~/ 86400000,
          at,
          summary.title,
          summary.body,
        ),
      );
    }
  }
  out.sort((a, b) => a.atUtc.compareTo(b.atUtc));
  return out.take(maxCount).toList();
}

/// The ids of the morning summaries: this plus the number of days since 1970
/// (above the check-ins' 1 500 000 000, below the test notification's id).
const summaryReminderIdBase = 1600000000;

/// What has to happen on the device so that it holds the planned reminders.
class ReminderChanges {
  const ReminderChanges({this.cancel = const [], this.schedule = const []});

  /// Ids the device has but the plan no longer wants.
  final List<int> cancel;

  /// Reminders that are new or whose time or text changed (scheduling one
  /// again replaces the one with the same id).
  final List<PlannedReminder> schedule;

  bool get isEmpty => cancel.isEmpty && schedule.isEmpty;
}

/// The difference between what the device holds ([previous]) and the plan
/// ([next]). Reminders are told apart by id; when the plan has an id twice, the
/// later one counts (as it does on the device).
ReminderChanges diffReminders(
  List<PlannedReminder> previous,
  List<PlannedReminder> next,
) {
  final have = {for (final r in previous) r.id: r};
  final want = {for (final r in next) r.id: r};
  return ReminderChanges(
    cancel: [
      for (final id in have.keys)
        if (!want.containsKey(id)) id,
    ],
    schedule: [
      for (final r in want.values)
        if (have[r.id] != r) r,
    ],
  );
}

/// Puts the planned reminders on the device. Only the difference is touched:
/// cancelling everything and scheduling it all again on every change of the
/// calendar loses reminders when the app stops in between, and the device
/// would do the work again for a sync that changes ninety events.
abstract class ReminderScheduler {
  bool get supported;

  /// Asks the user for the notification permission; true when granted.
  Future<bool> ensurePermission();

  /// The reminders the device holds right now.
  Future<List<PlannedReminder>> pending();
  Future<void> cancel(Iterable<int> ids);
  Future<void> schedule(Iterable<PlannedReminder> reminders);
}

/// Makes the device hold exactly [plan] and says what it had to change.
Future<ReminderChanges> syncReminders(
  ReminderScheduler scheduler,
  List<PlannedReminder> plan,
) async {
  final changes = diffReminders(await scheduler.pending(), plan);
  if (changes.cancel.isNotEmpty) await scheduler.cancel(changes.cancel);
  if (changes.schedule.isNotEmpty) await scheduler.schedule(changes.schedule);
  return changes;
}

class NoopReminderScheduler implements ReminderScheduler {
  @override
  bool get supported => false;
  @override
  Future<bool> ensurePermission() async => false;
  @override
  Future<List<PlannedReminder>> pending() async => const [];
  @override
  Future<void> cancel(Iterable<int> ids) async {}
  @override
  Future<void> schedule(Iterable<PlannedReminder> reminders) async {}
}

/// A pending notification of the device as a [PlannedReminder]. The time
/// travels in the payload (the device does not report it). One without a
/// payload (made by an older version) gets time 0, so it never equals a plan
/// and is replaced.
PlannedReminder plannedFromPending(
  int id,
  String? title,
  String? body,
  String? payload,
) => PlannedReminder(
  id,
  DateTime.fromMillisecondsSinceEpoch(
    int.tryParse(payload ?? '') ?? 0,
    isUtc: true,
  ),
  title ?? '',
  body ?? '',
);

/// Android only: local scheduled notifications (no server involved). Uses
/// inexact alarms, so a reminder may arrive a few minutes late but needs no
/// special permission.
class AndroidReminderScheduler implements ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _init;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Emlékeztetők',
      channelDescription: 'Műszak, napi check-in és reggeli összefoglaló',
      importance: Importance.defaultImportance,
    ),
  );

  /// How a reminder looks: a text of several lines (the morning summary)
  /// opens up to all of them, a short one stays as it is.
  @visibleForTesting
  static NotificationDetails detailsFor(PlannedReminder r) =>
      r.body.contains('\n') ? _bigText(r) : _details;

  static NotificationDetails _bigText(PlannedReminder r) => NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Emlékeztetők',
      channelDescription: 'Műszak, napi check-in és reggeli összefoglaló',
      importance: Importance.defaultImportance,
      styleInformation: BigTextStyleInformation(r.body),
    ),
  );

  @override
  bool get supported => true;

  Future<void> _ensureInit() => _init ??= () async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
  }();

  @override
  Future<bool> ensurePermission() async {
    await _ensureInit();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<List<PlannedReminder>> pending() async {
    await _ensureInit();
    return [
      for (final p in await _plugin.pendingNotificationRequests())
        plannedFromPending(p.id, p.title, p.body, p.payload),
    ];
  }

  @override
  Future<void> cancel(Iterable<int> ids) async {
    await _ensureInit();
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
  }

  @override
  Future<void> schedule(Iterable<PlannedReminder> reminders) async {
    await _ensureInit();
    for (final r in reminders) {
      await _plugin.zonedSchedule(
        id: r.id,
        title: r.title,
        body: r.body,
        scheduledDate: tz.TZDateTime.from(r.atUtc, tz.UTC),
        notificationDetails: detailsFor(r),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: '${r.atUtc.millisecondsSinceEpoch}',
      );
    }
  }
}

/// The scheduler of a platform: Android has its alarm manager, Windows its
/// scheduled toasts, anything else no reminders. (The choice is a function of
/// flags so that it can be tried on any machine.)
ReminderScheduler reminderSchedulerFor({
  required bool android,
  required bool windows,
  required Future<String?> Function(String key) read,
  required Future<void> Function(String key, String? value) write,
  required DateTime Function() now,
  ToastBackend Function()? toastBackend,
}) {
  if (android) return AndroidReminderScheduler();
  if (windows) {
    return WindowsReminderScheduler(
      backend: (toastBackend ?? PluginToastBackend.new)(),
      read: read,
      write: write,
      now: now,
    );
  }
  return NoopReminderScheduler();
}

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => reminderSchedulerFor(
    android: !kIsWeb && Platform.isAndroid,
    windows: !kIsWeb && Platform.isWindows,
    // (looked up when needed: nothing touches the database before that)
    read: (k) => ref.read(recordRepoProvider).meta(k),
    write: (k, v) => ref.read(recordRepoProvider).setMeta(k, v),
    now: () => ref.read(appClockProvider)(),
    toastBackend: () => ref.read(toastBackendProvider),
  ),
);

/// What to tell the user when the notifications could not be switched on.
String remindersBlockedHelp() => defaultTargetPlatform == TargetPlatform.windows
    ? 'Az értesítések nem indíthatók el. Nézd meg a Windows értesítési '
          'beállításait (Rendszer → Értesítések), és hogy a „Ne zavarjanak” / '
          'Fókusz mód nincs-e bekapcsolva.'
    : 'Az értesítések le vannak tiltva. Engedélyezd az Android beállításaiban '
          '(Alkalmazások → Kvantum Naptár → Értesítések).';

final reminderSettingsStoreProvider = Provider<ReminderSettingsStore>((ref) {
  final r = ref.watch(recordRepoProvider);
  return ReminderSettingsStore(read: r.meta, write: r.setMeta);
});

class ReminderSettingsNotifier extends AsyncNotifier<ReminderSettings> {
  @override
  Future<ReminderSettings> build() =>
      ref.watch(reminderSettingsStoreProvider).load();

  Future<void> change(ReminderSettings s) async {
    await ref.read(reminderSettingsStoreProvider).save(s);
    state = AsyncData(s);
  }
}

final reminderSettingsProvider =
    AsyncNotifierProvider<ReminderSettingsNotifier, ReminderSettings>(
      ReminderSettingsNotifier.new,
    );

/// How long the reminders wait for the calendar to settle before the device
/// is touched (a sync that changes ninety events announces ninety changes).
final reminderDebounceProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 1500),
);

/// Starts the timer of the wait above (replaceable by tests).
final reminderTimerProvider =
    Provider<Timer Function(Duration, void Function())>((_) => Timer.new);

/// Runs of the reminder sync, one after the other.
class _ReminderRuns {
  Future<void> last = Future.value();
}

final _reminderRunsProvider = Provider<_ReminderRuns>((_) => _ReminderRuns());

/// Keeps the device's notifications in step with the calendar, the check-ins
/// and the settings. Watch it once from the home page.
///
/// Every change of the inputs starts the wait anew (the earlier wait is
/// cancelled when the provider rebuilds), so a burst of changes costs one
/// plan and one look at the device.
final reminderSyncProvider = Provider<void>((ref) {
  final settings = ref.watch(reminderSettingsProvider).value;
  ref.watch(eventsTickProvider);
  ref.watch(checkInsProvider);
  // (at midnight the days the plans reach move on)
  ref.watch(todayProvider);
  final summaryOn = (settings?.summaryMinutes ?? 0) > 0;
  if (summaryOn) {
    // the summary tells about the tasks, and its weather line needs the place
    ref.watch(tasksProvider);
    ref.watch(aiSettingsProvider);
  }
  final scheduler = ref.read(reminderSchedulerProvider);
  if (settings == null || !scheduler.supported) return;
  final runs = ref.read(_reminderRunsProvider);
  final timer = ref.read(reminderTimerProvider)(
    ref.read(reminderDebounceProvider),
    () {
      // everything the run needs is taken now: it must not touch [ref]
      // after the provider has been rebuilt or disposed
      final repo = ref.read(repoProvider);
      final now = ref.read(appClockProvider)().toUtc();
      final done = {
        for (final c
            in ref.read(checkInsProvider).value ?? const <CheckInView>[])
          if (c.date != null) c.date!,
      };
      final tasks = summaryOn
          ? (ref.read(tasksProvider).value ?? const <TaskView>[])
          : const <TaskView>[];
      // the weather line: only with a place, and when the user lets the
      // forecast be used (the same switch as for the assistant)
      final ai = summaryOn ? ref.read(aiSettingsProvider).value : null;
      final place = (ai != null && ai.weather) ? ai.place : null;
      final weather = place == null ? null : ref.read(weatherServiceProvider);
      runs.last = runs.last.then((_) async {
        try {
          // the whole of today counts for the summary, not only what is left
          final occurrences = settings.shiftLeadMinutes > 0 || summaryOn
              ? await repo.occurrences(
                  resolveWallClock(defaultTz, todayIn(now)),
                  now.add(const Duration(days: 16)),
                )
              : const <Occurrence>[];
          final shifts = settings.shiftLeadMinutes > 0
              ? [
                  for (final o in occurrences)
                    if (o.isShift && !o.allDay)
                      (startUtc: o.startUtc, title: o.title),
                ]
              : <({DateTime startUtc, String title})>[];
          final forecast = summaryOn && weather != null && place != null
              ? await weather.forecast(place, days: summaryHorizonDays + 1)
              : null;
          await syncReminders(
            scheduler,
            planReminders(
              nowUtc: now,
              settings: settings,
              shifts: shifts,
              checkedInDays: done,
              summaries: summaryOn
                  ? summariesFor(
                      nowUtc: now,
                      occurrences: occurrences,
                      tasks: tasks,
                      forecast: forecast,
                    )
                  : const {},
            ),
          );
        } catch (e, st) {
          // reminders are a convenience; never break the app because of them
          ref.read(diagLogProvider).error('app', 'reminders.failed', e, st);
        }
      });
    },
  );
  ref.onDispose(timer.cancel);
});
