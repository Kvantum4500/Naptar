import 'package:kvantum_app/notify/budget_notify.dart';

/// A device that shows what it is told to, and remembers it.
class FakeBudgetNotifier implements BudgetNotifier {
  FakeBudgetNotifier({this.isSupported = true, this.grant = true});

  final bool isSupported;

  /// Whether the user lets notifications through.
  bool grant;

  /// Makes showing fail (the system refuses).
  bool failShow = false;

  int permissionAsks = 0;
  final shown = <({int id, String title, String body})>[];

  @override
  bool get supported => isSupported;

  @override
  Future<bool> ensurePermission() async {
    permissionAsks++;
    return grant;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (failShow) throw StateError('the device refused');
    shown.add((id: id, title: title, body: body));
  }
}
