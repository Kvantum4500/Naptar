import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import 'reminders.dart' show PlannedReminder, ReminderScheduler;

/// The part of the Windows notification plugin the scheduler needs, behind an
/// interface so that it can be tried without Windows.
abstract class ToastBackend {
  /// Registers the program with Windows (once); false when that did not work.
  Future<bool> init();

  /// The ids of the toasts Windows holds for later. Windows says nothing else
  /// about them (no text, no time).
  Future<Set<int>> pendingIds();

  /// Takes the toast with this id off Windows' list (nothing if there is none).
  Future<void> cancel(int id);

  /// Hands [r] to Windows, to be shown at its time even when the program is
  /// closed. Scheduling an id again does NOT replace the earlier toast.
  Future<void> schedule(PlannedReminder r);

  /// Shows a toast right now (nothing is scheduled; it is not on the pending
  /// list). Showing an id again replaces the toast with that id.
  Future<void> show({
    required int id,
    required String title,
    required String body,
  });
}

/// [ToastBackend] on the notification plugin (its Windows part: scheduled toast
/// notifications of the system, which need no running program).
class PluginToastBackend implements ToastBackend {
  PluginToastBackend({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// What Windows calls this program in the notification centre. The id and
  /// the GUID must never change: the toasts already scheduled belong to them.
  static const appName = 'Kvantum Naptár';
  static const appUserModelId = 'Kvantum.Naptar';
  static const guid = '7d3f9a52-1c4e-4b8a-9e60-2f5a8c1d4b73';

  @override
  Future<bool> init() async {
    if (_ready) return true;
    try {
      _ready =
          await _plugin.initialize(
            settings: const InitializationSettings(
              windows: WindowsInitializationSettings(
                appName: appName,
                appUserModelId: appUserModelId,
                guid: guid,
              ),
            ),
          ) ??
          false;
    } catch (_) {
      _ready = false; // (tried again next time)
    }
    return _ready;
  }

  @override
  Future<Set<int>> pendingIds() async => {
    for (final p in await _plugin.pendingNotificationRequests()) p.id,
  };

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> schedule(PlannedReminder r) => _plugin.zonedSchedule(
    id: r.id,
    title: r.title,
    body: r.body,
    scheduledDate: tz.TZDateTime.from(r.atUtc, tz.UTC),
    notificationDetails: const NotificationDetails(
      windows: WindowsNotificationDetails(),
    ),
    // (an Android setting; Windows ignores it)
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) => _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      windows: WindowsNotificationDetails(),
    ),
  );
}

/// The one connection to the Windows notification system, shared by the
/// reminders and the budget alerts (the program registers with Windows once).
final toastBackendProvider = Provider<ToastBackend>(
  (_) => PluginToastBackend(),
);

/// A scheduler that can hand the system one notification for the user to see,
/// so that they can find out at once whether the reminders reach them.
abstract interface class TestableReminders {
  /// Schedules a notification that shows in [delay] and belongs to no plan
  /// (the plan never takes it back).
  Future<void> scheduleTest(Duration delay);
}

/// Reminders as Windows toasts: the system keeps them and shows them on time,
/// also when the program is closed (the program updates them whenever it runs).
///
/// Windows tells the program which toasts it holds, but not what they say or
/// when they are due; so the program writes down what it handed over (in the
/// settings table) and reads Windows' list only to see which of them have
/// been shown since.
class WindowsReminderScheduler implements ReminderScheduler, TestableReminders {
  WindowsReminderScheduler({
    required this.backend,
    required this.read,
    required this.write,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ToastBackend backend;
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String? value) write;
  final DateTime Function() _now;

  /// Where the plan handed to Windows is written down.
  static const planKey = 'rem.win.plan';

  /// The id of the test notification: beyond every id a plan uses (shifts are
  /// minutes since 1970, check-ins start at 1 500 000 000).
  static const testId = 2000000001;

  /// A reminder due sooner than this is not handed over: it is shown (or
  /// missed) by the time Windows would take it, and a time in the past is
  /// refused.
  static const minLead = Duration(seconds: 20);

  @override
  bool get supported => true;

  /// Windows needs no permission; this says whether the program could register
  /// itself with the notification system.
  @override
  Future<bool> ensurePermission() => backend.init();

  @override
  Future<void> scheduleTest(Duration delay) async {
    if (!await backend.init()) {
      throw StateError('Windows notifications could not be started');
    }
    // (not written in the notes, and hidden from pending(): the plan neither
    // sees it nor takes it back before it is shown)
    await backend.cancel(testId);
    await backend.schedule(
      PlannedReminder(
        testId,
        _now().toUtc().add(delay),
        'Kvantum Naptár – próba',
        'Ha ezt látod, az emlékeztetők megérkeznek. A programot be is '
            'zárhatod: a Windows akkor is megmutatja őket.',
      ),
    );
  }

  @override
  Future<List<PlannedReminder>> pending() async {
    final held = {for (final r in await _load()) r.id: r};
    // Nothing handed over, nothing to look at: Windows is not even asked.
    // (Somebody who never turned a reminder on does not get the program
    // registered with the notification system just by starting it.)
    if (held.isEmpty) return const [];
    if (!await backend.init()) return const [];
    final os = (await backend.pendingIds()).where((id) => id != testId).toSet();
    // a toast Windows holds without a note of ours (the settings were lost, an
    // older version): reported with a time that equals no plan, so that it is
    // replaced - or taken off when the plan does not want it
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final out = [
      for (final id in os) held[id] ?? PlannedReminder(id, epoch, '', ''),
    ];
    // the ones that were shown meanwhile are no longer ours to remember
    final kept = [
      for (final r in held.values)
        if (os.contains(r.id)) r,
    ];
    if (kept.length != held.length) await _save(kept);
    return out;
  }

  @override
  Future<void> cancel(Iterable<int> ids) async {
    if (!await backend.init()) return;
    final held = {for (final r in await _load()) r.id: r};
    try {
      for (final id in ids) {
        await backend.cancel(id);
        held.remove(id);
      }
    } finally {
      await _save(held.values.toList());
    }
  }

  @override
  Future<void> schedule(Iterable<PlannedReminder> reminders) async {
    if (!await backend.init()) {
      throw StateError('Windows notifications could not be started');
    }
    final held = {for (final r in await _load()) r.id: r};
    final plan = reminders.toList();
    final wanted = {for (final r in plan) r.id};
    // Toasts that no note explains (the notes were lost): the plan is the
    // truth, and they would only fire at times it does not know of. (The ones
    // the plan hands over again are taken off below, one by one.)
    for (final id in await backend.pendingIds()) {
      if (id != testId && !held.containsKey(id) && !wanted.contains(id)) {
        await backend.cancel(id);
      }
    }
    final earliest = _now().toUtc().add(minLead);
    try {
      for (final r in plan) {
        // handing over an id again would show the toast twice
        await backend.cancel(r.id);
        held.remove(r.id);
        if (!r.atUtc.isAfter(earliest)) continue;
        await backend.schedule(r);
        held[r.id] = r;
      }
    } finally {
      // (what was handed over before a failure is written down all the same)
      await _save(held.values.toList());
    }
  }

  Future<List<PlannedReminder>> _load() async {
    try {
      final text = await read(planKey);
      if (text == null || text.isEmpty) return const [];
      final list = jsonDecode(text);
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map && e['id'] is int && e['at'] is int)
            PlannedReminder(
              e['id'] as int,
              DateTime.fromMillisecondsSinceEpoch(e['at'] as int, isUtc: true),
              '${e['t'] ?? ''}',
              '${e['b'] ?? ''}',
            ),
      ];
    } catch (_) {
      return const []; // (unreadable notes are no notes)
    }
  }

  Future<void> _save(List<PlannedReminder> reminders) => write(
    planKey,
    reminders.isEmpty
        ? null
        : jsonEncode([
            for (final r in reminders)
              {
                'id': r.id,
                'at': r.atUtc.millisecondsSinceEpoch,
                't': r.title,
                'b': r.body,
              },
          ]),
  );
}
