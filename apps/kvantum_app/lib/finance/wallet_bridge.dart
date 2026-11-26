import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../diag/diag_log.dart';

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

  /// The notifications collected so far. They are handed out, but NOT forgotten
  /// until [ack]: if the app dies while booking them, the next call returns
  /// them again (booking is idempotent).
  Future<List<WalletNotification>> drain();

  /// Everything [drain] returned has been booked: forget it.
  Future<void> ack();

  /// Throws the queue away (the feature is switched off).
  Future<void> clear();

  Future<void> openListenerSettings();

  /// App info page (where "Allow restricted settings" lives for sideloaded apps).
  Future<void> openAppInfo();
}

class ChannelWalletBridge implements WalletBridge {
  ChannelWalletBridge({this._log})
    : _ch = const MethodChannel('kvantum/wallet');
  final MethodChannel _ch;
  final DiagLog? _log;

  @override
  bool get supported => Platform.isAndroid;

  Future<T?> _call<T>(String method) async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<T>(method);
    } on PlatformException catch (e, st) {
      _log?.error('wallet', 'channel.$method', e, st);
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
    } on FormatException catch (e, st) {
      // an unreadable queue would come back forever: drop it
      _log?.error('wallet', 'queue.dropped', e, st);
      await ack();
      return const [];
    }
  }

  @override
  Future<void> ack() async {
    await _call<void>('ack');
  }

  @override
  Future<void> clear() async {
    await _call<void>('clear');
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
