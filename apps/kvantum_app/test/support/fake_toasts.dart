import 'package:kvantum_app/notify/reminders.dart' show PlannedReminder;
import 'package:kvantum_app/notify/windows_reminders.dart';

/// What the Windows notification centre does with the toasts it is given.
class FakeToasts implements ToastBackend {
  bool initOk = true;
  int inits = 0;

  /// The ids of the toasts Windows holds.
  final os = <int>{};

  /// Every call in order: "cancel 5", "schedule 5".
  final calls = <String>[];
  final handedOver = <PlannedReminder>[];

  /// Every toast shown right away: id, title, body.
  final shownNow = <({int id, String title, String body})>[];

  /// Makes showing fail (Windows refuses).
  bool failShow = false;

  /// Makes scheduling fail from this call on (counted from 1; 0 = never).
  int failAt = 0;
  int _schedules = 0;

  @override
  Future<bool> init() async {
    inits++;
    return initOk;
  }

  @override
  Future<Set<int>> pendingIds() async => {...os};

  @override
  Future<void> cancel(int id) async {
    calls.add('cancel $id');
    os.remove(id);
  }

  @override
  Future<void> schedule(PlannedReminder r) async {
    _schedules++;
    if (failAt != 0 && _schedules >= failAt) {
      throw StateError('Windows refused');
    }
    calls.add('schedule ${r.id}');
    handedOver.add(r);
    os.add(r.id);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (failShow) throw StateError('Windows refused');
    calls.add('show $id');
    shownNow.add((id: id, title: title, body: body));
  }

  /// Windows showed the toast: it is no longer on its list.
  void shown(int id) => os.remove(id);
}
