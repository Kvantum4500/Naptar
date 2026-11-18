import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diag_log.dart';

/// Makes the three places an error can fall through write to [log]: the
/// framework (a widget that fails to build, a failed layout), the platform
/// dispatcher (an error in a callback from the engine) and, with [runGuarded],
/// the zone of the app (an async error nobody awaited).
///
/// The framework still prints what it printed before. Returns a function that
/// puts the old handlers back (tests).
void Function() installErrorHooks(DiagLog log) {
  final oldFlutter = FlutterError.onError;
  final oldPlatform = PlatformDispatcher.instance.onError;

  FlutterError.onError = (details) {
    log.error('app', 'flutter', details.exception, details.stack, {
      if (details.library != null) 'lib': details.library,
    });
    (oldFlutter ?? FlutterError.presentError)(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('app', 'platform', error, stack);
    return true; // handled: it is in the log
  };

  return () {
    FlutterError.onError = oldFlutter;
    PlatformDispatcher.instance.onError = oldPlatform;
  };
}

/// Runs [body] in a zone whose uncaught async errors go to [log] instead of
/// vanishing. The binding must be initialised inside [body] (Flutter wants it
/// in the same zone as `runApp`).
void runGuarded(Future<void> Function() body, DiagLog log) {
  runZonedGuarded<Future<void>>(
    body,
    (error, stack) => log.error('app', 'zone', error, stack),
  );
}
