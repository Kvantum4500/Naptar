import 'package:kvantum_app/finance/wallet_bridge.dart';

class FakeWallet implements WalletBridge {
  FakeWallet({
    this.supported = true,
    this.enabled = true,
    List<WalletNotification>? queue,
  }) : queue = queue ?? [];

  @override
  final bool supported;
  bool enabled;
  final List<WalletNotification> queue;
  int drains = 0;
  int listenerOpened = 0;
  int appInfoOpened = 0;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<List<WalletNotification>> drain() async {
    drains++;
    final out = [...queue];
    queue.clear();
    return out;
  }

  @override
  Future<void> openListenerSettings() async => listenerOpened++;

  @override
  Future<void> openAppInfo() async => appInfoOpened++;
}

WalletNotification note(String title, String text, int timeMs) =>
    WalletNotification(title: title, text: text, timeMs: timeMs);
