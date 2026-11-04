import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:timezone/timezone.dart' as tz;

import '../providers.dart';
import '../ui/day_utils.dart';

/// What the user wants to be reminded of. Everything is off by default.
class ReminderSettings {
  const ReminderSettings({this.shiftLeadMinutes = 0, this.checkIn = false});

  /// Minutes before a shift starts (0 = no shift reminder).
  final int shiftLeadMinutes;

  /// A reminder in the evening to fill in the daily check-in.
  final bool checkIn;

  bool get any => shiftLeadMinutes > 0 || checkIn;

  ReminderSettings copyWith({int? shiftLeadMinutes, bool? checkIn}) =>
      ReminderSettings(
        shiftLeadMinutes: shiftLeadMinutes ?? this.shiftLeadMinutes,
        checkIn: checkIn ?? this.checkIn,
      );
}

class ReminderSettingsStore {
  ReminderSettingsStore({required this.read, required this.write});
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String? value) write;

  Future<ReminderSettings> load() async {
    final lead = int.tryParse(await read('rem.shift') ?? '') ?? 0;
    return ReminderSettings(
      shiftLeadMinutes: const {0, 60, 120, 180}.contains(lead) ? lead : 0,
      checkIn: (await read('rem.checkin')) == 'on',
    );
  }

  Future<void> save(ReminderSettings s) async {
    await write(
      'rem.shift',
      s.shiftLeadMinutes == 0 ? null : '${s.shiftLeadMinutes}',
    );
    await write('rem.checkin', s.checkIn ? 'on' : null);
  }
}

class PlannedReminder {
  const PlannedReminder(this.id, this.atUtc, this.title, this.body);
  final int id;
  final DateTime atUtc;
  final String title;
  final String body;
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
  out.sort((a, b) => a.atUtc.compareTo(b.atUtc));
  return out.take(maxCount).toList();
}

/// Puts the planned reminders on the device. [replaceAll] makes the device's
/// pending set equal to [reminders] (cancelling everything else).
abstract class ReminderScheduler {
  bool get supported;

  /// Asks the user for the notification permission; true when granted.
  Future<bool> ensurePermission();
  Future<void> replaceAll(List<PlannedReminder> reminders);
}

class NoopReminderScheduler implements ReminderScheduler {
  @override
  bool get supported => false;
  @override
  Future<bool> ensurePermission() async => false;
  @override
  Future<void> replaceAll(List<PlannedReminder> reminders) async {}
}

/// Android only: local scheduled notifications (no server involved). Uses
/// inexact alarms, so a reminder may arrive a few minutes late but needs no
/// special permission.
class AndroidReminderScheduler implements ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _init;

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
  Future<void> replaceAll(List<PlannedReminder> reminders) async {
    await _ensureInit();
    await _plugin.cancelAllPendingNotifications();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'reminders',
        'Emlékeztetők',
        channelDescription: 'Műszak és napi check-in emlékeztetők',
        importance: Importance.defaultImportance,
      ),
    );
    for (final r in reminders) {
      await _plugin.zonedSchedule(
        id: r.id,
        title: r.title,
        body: r.body,
        scheduledDate: tz.TZDateTime.from(r.atUtc, tz.UTC),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (_) => (!kIsWeb && Platform.isAndroid)
      ? AndroidReminderScheduler()
      : NoopReminderScheduler(),
);

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

/// Keeps the device's notifications in step with the calendar, the check-ins
/// and the settings. Watch it once from the home page.
final reminderSyncProvider = Provider<void>((ref) {
  final settings = ref.watch(reminderSettingsProvider).value;
  ref.watch(eventsTickProvider);
  ref.watch(checkInsProvider);
  final scheduler = ref.read(reminderSchedulerProvider);
  if (settings == null || !scheduler.supported) return;
  final job = _chain.then((_) async {
    try {
      final now = DateTime.now().toUtc();
      final shifts = settings.shiftLeadMinutes > 0
          ? [
              for (final o
                  in await ref
                      .read(repoProvider)
                      .occurrences(now, now.add(const Duration(days: 16))))
                if (o.isShift && !o.allDay)
                  (startUtc: o.startUtc, title: o.title),
            ]
          : <({DateTime startUtc, String title})>[];
      final done = {
        for (final c
            in ref.read(checkInsProvider).value ?? const <CheckInView>[])
          if (c.date != null) c.date!,
      };
      await scheduler.replaceAll(
        planReminders(
          nowUtc: now,
          settings: settings,
          shifts: shifts,
          checkedInDays: done,
        ),
      );
    } catch (_) {
      // reminders are a convenience; never break the app because of them
    }
  });
  _chain = job;
});

Future<void> _chain = Future.value();
