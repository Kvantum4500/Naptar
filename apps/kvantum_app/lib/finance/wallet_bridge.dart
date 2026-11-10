import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// One notification captured from the Wallet app.
class WalletNotification {
  const WalletNotification({
    required this.title,
    required this.text,
    required this.timeMs,
  });
  final String title;
  final String text;
  final int timeMs;
}

/// The (Android only) link to the notification listener, behind an interface
/// so everything above it can be tested without a phone.
abstract class WalletBridge {
  bool get supported;

  /// Whether the user has granted "notification access" to this app.
  Future<bool> isEnabled();

  /// The notifications collected since the last call (the queue is emptied).
  Future<List<WalletNotification>> drain();

  Future<void> openListenerSettings();

  /// App info page (where "Allow restricted settings" lives for sideloaded apps).
  Future<void> openAppInfo();
}

class ChannelWalletBridge implements WalletBridge {
  ChannelWalletBridge() : _ch = const MethodChannel('kvantum/wallet');
  final MethodChannel _ch;

  @override
  bool get supported => Platform.isAndroid;

  Future<T?> _call<T>(String method) async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> isEnabled() async => await _call<bool>('isEnabled') ?? false;

  @override
  Future<List<WalletNotification>> drain() async {
    final text = await _call<String>('drain');
    if (text == null || text.isEmpty) return const [];
    try {
      final list = jsonDecode(text);
      if (list is! List) return const [];
      return [
        for (final o in list)
          if (o is Map && o['time'] is num)
            WalletNotification(
              title: '${o['title'] ?? ''}',
              text: '${o['text'] ?? ''}',
              timeMs: (o['time'] as num).toInt(),
            ),
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> openListenerSettings() async {
    await _call<void>('openListenerSettings');
  }

  @override
  Future<void> openAppInfo() async {
    await _call<void>('openAppInfo');
  }
}
