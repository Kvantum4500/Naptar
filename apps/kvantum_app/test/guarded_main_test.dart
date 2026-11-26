import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/diag/guarded.dart';

import 'support/turns.dart';

void main() {
  late MemoryDiagSink sink;
  late DiagLog log;

  setUp(() {
    sink = MemoryDiagSink();
    log = DiagLog()..attach(sink);
  });

  List<DiagEntry> written() => [
    for (final l in sink.lines) DiagEntry.tryParse(l)!,
  ];

  test('a framework error is logged and still handed on', () async {
    final shown = <FlutterErrorDetails>[];
    final saved = FlutterError.onError;
    FlutterError.onError = shown.add;
    final restore = installErrorHooks(log);
    addTearDown(() {
      restore();
      FlutterError.onError = saved;
    });

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('boom'), library: 'test lib'),
    );
    await log.flush();

    expect(shown, hasLength(1), reason: 'the old handler still runs');
    final e = written().single;
    expect(e.area, 'app');
    expect(e.code, 'flutter');
    expect(e.error, startsWith('StateError'));
    expect(e.data['lib'], 'test lib');
  });

  test('an error from the platform is logged and counts as handled', () async {
    final saved = PlatformDispatcher.instance.onError;
    final restore = installErrorHooks(log);
    addTearDown(() {
      restore();
      PlatformDispatcher.instance.onError = saved;
    });

    final handled = PlatformDispatcher.instance.onError!(
      ArgumentError('rossz'),
      StackTrace.current,
    );
    await log.flush();

    expect(handled, isTrue);
    final e = written().single;
    expect(e.code, 'platform');
    expect(e.error, startsWith('ArgumentError'));
    expect(e.stack, isNotEmpty);
  });

  test('restoring puts the old handlers back', () {
    final oldFlutter = FlutterError.onError;
    final oldPlatform = PlatformDispatcher.instance.onError;
    final restore = installErrorHooks(log);
    expect(FlutterError.onError, isNot(same(oldFlutter)));
    restore();
    expect(FlutterError.onError, same(oldFlutter));
    expect(PlatformDispatcher.instance.onError, oldPlatform);
  });

  test('an async error nobody awaited reaches the log', () async {
    final done = Completer<void>();
    runGuarded(() async {
      // nobody listens to this future: its error is "uncaught"
      unawaited(Future<void>(() => throw StateError('késői hiba')));
      await turns(); // the turn in which it throws is among these
      done.complete();
    }, log);
    await done.future;
    await log.flush();

    final e = written().singleWhere((e) => e.code == 'zone');
    expect(e.error, startsWith('StateError'));
  });

  test('an error thrown by the body itself reaches the log too', () async {
    runGuarded(() async => throw const FormatException('induláskor'), log);
    await turns();
    await log.flush();
    expect(written().map((e) => e.code), contains('zone'));
  });
}
