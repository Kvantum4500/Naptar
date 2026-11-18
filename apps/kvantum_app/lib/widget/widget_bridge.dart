import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The way to the home-screen widget (Android): the app hands over the text
/// the widget shows, the platform side stores it and redraws the widget.
abstract class WidgetBridge {
  /// False where there is no widget (the app does not even prepare the text).
  bool get active;

  /// Whether the user has put the widget on a home screen. Nothing is
  /// prepared or handed over while it is not there.
  Future<bool> isPlaced();

  /// Hands over the snapshot (see widgetSnapshot). True when a widget took it
  /// (false: the widget was taken off a moment ago).
  Future<bool> update(String snapshot);
}

/// Where there is no widget: nothing is done.
class NoopWidgetBridge implements WidgetBridge {
  const NoopWidgetBridge();

  @override
  bool get active => false;

  @override
  Future<bool> isPlaced() async => false;

  @override
  Future<bool> update(String snapshot) async => false;
}

/// Android: the `kvantum/widget` channel of MainActivity.
class MethodChannelWidgetBridge implements WidgetBridge {
  const MethodChannelWidgetBridge([
    this.channel = const MethodChannel(channelName),
  ]);

  static const channelName = 'kvantum/widget';
  final MethodChannel channel;

  @override
  bool get active => true;

  @override
  Future<bool> isPlaced() async =>
      await channel.invokeMethod<bool>('isPlaced') ?? false;

  @override
  Future<bool> update(String snapshot) async =>
      await channel.invokeMethod<bool>('update', snapshot) ?? false;
}

final widgetBridgeProvider = Provider<WidgetBridge>(
  (ref) => !kIsWeb && Platform.isAndroid
      ? const MethodChannelWidgetBridge()
      : const NoopWidgetBridge(),
);
