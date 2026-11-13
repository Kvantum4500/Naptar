import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'windows_reminders.dart';

/// Shows a notification at once (the budget alerts). A separate thing from the
/// [ReminderScheduler](reminders.dart), which keeps a plan of notifications for
/// later: this one has no plan, and what it shows is never taken back by it.
abstract interface class BudgetNotifier {
  /// Whether this device can show such notifications at all.
  bool get supported;

  /// Asks the user for the notification permission; true when granted.
  Future<bool> ensurePermission();

  /// Shows a notification now. Showing an id again replaces the earlier one,
  /// so the same news does not pile up.
  Future<void> show({
    required int id,
    required String title,
    required String body,
  });
}

class NoopBudgetNotifier implements BudgetNotifier {
  @override
  bool get supported => false;
  @override
  Future<bool> ensurePermission() async => false;
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {}
}

/// Android: a local notification on its own channel, so that the user can
/// silence the budget alerts without silencing the reminders.
class AndroidBudgetNotifier implements BudgetNotifier {
  AndroidBudgetNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _init;

  static const channelId = 'budget';
  static const channelName = 'Költségkeret';

  /// A text of several lines (the list of many categories) opens up to all of
  /// them; a short one stays as it is.
  @visibleForTesting
  static NotificationDetails detailsFor(String body) => NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription:
          'Szól, ha egy kiadási kategória eléri vagy túllépi a havi keretét',
      importance: Importance.defaultImportance,
      styleInformation: body.contains('\n')
          ? BigTextStyleInformation(body)
          : null,
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
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    await _ensureInit();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: detailsFor(body),
    );
  }
}

/// Windows: a toast through the connection the reminders use too.
class WindowsBudgetNotifier implements BudgetNotifier {
  WindowsBudgetNotifier(this.backend);
  final ToastBackend backend;

  @override
  bool get supported => true;

  /// Windows needs no permission; this says whether the program could register
  /// itself with the notification system.
  @override
  Future<bool> ensurePermission() => backend.init();

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!await backend.init()) {
      throw StateError('Windows notifications could not be started');
    }
    await backend.show(id: id, title: title, body: body);
  }
}

/// The notifier of a platform (a function of flags, so that it can be tried on
/// any machine).
BudgetNotifier budgetNotifierFor({
  required bool android,
  required bool windows,
  required ToastBackend Function() toastBackend,
}) {
  if (android) return AndroidBudgetNotifier();
  if (windows) return WindowsBudgetNotifier(toastBackend());
  return NoopBudgetNotifier();
}

final budgetNotifierProvider = Provider<BudgetNotifier>(
  (ref) => budgetNotifierFor(
    android: !kIsWeb && Platform.isAndroid,
    windows: !kIsWeb && Platform.isWindows,
    toastBackend: () => ref.read(toastBackendProvider),
  ),
);

/// The ids of the budget notifications lie in this range: above the morning
/// summaries (1 600 000 000 and the days since 1970), below the test
/// notification (2 000 000 001) and the largest id a device takes.
const budgetNotificationIdBase = 1700000000;
const budgetNotificationIdRange = 100000000;

/// The id of the notification about [key] (a category id, or the combined
/// message's key) in the month [monthKey]: the same news in the same month gets
/// the same id and replaces itself. (FNV-1a, because the hash code of a string
/// is not promised to stay the same from one run to the next.)
int budgetNotificationId(String monthKey, String key) {
  var h = 0x811c9dc5;
  for (final unit in '$monthKey|$key'.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return budgetNotificationIdBase + h % budgetNotificationIdRange;
}
