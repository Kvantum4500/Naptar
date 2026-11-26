import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'redact.dart';

// The app's own diagnostics log: a few hundred kilobytes of JSON lines that
// stay on the device. They hold what went wrong and when (codes, ids,
// numbers), never what the user wrote: no titles, notes, amounts, addresses.
// Nothing is sent anywhere; the user decides whether to copy a report out of
// the Diagnostics page.

/// One line of the log.
class DiagEntry {
  const DiagEntry({
    required this.time,
    required this.area,
    required this.code,
    this.data = const {},
    this.error,
    this.stack,
  });

  /// UTC.
  final DateTime time;

  /// Which part of the app: `sync`, `drive`, `app` …
  final String area;

  /// What happened, as a short stable code: `calendar.unexpected` …
  final String code;

  /// Numbers, flags and short codes only.
  final Map<String, Object?> data;

  /// Type and first line of an exception ([safeErrorText]).
  final String? error;

  /// The first frames of the stack ([safeStackText]).
  final String? stack;

  String toLine() => jsonEncode({
    't': time.toUtc().toIso8601String(),
    'a': area,
    'c': code,
    if (data.isNotEmpty) 'd': data,
    if (error != null) 'e': error,
    if (stack != null) 's': stack,
  });

  /// A line of the log, or null when it is not one (a torn last line after a
  /// crash, a file edited by hand).
  static DiagEntry? tryParse(String line) {
    try {
      final j = jsonDecode(line);
      if (j is! Map) return null;
      final t = DateTime.tryParse('${j['t']}');
      final a = j['a'], c = j['c'];
      if (t == null || a is! String || c is! String) return null;
      final d = j['d'];
      return DiagEntry(
        time: t.toUtc(),
        area: a,
        code: c,
        data: d is Map ? {for (final e in d.entries) '${e.key}': e.value} : {},
        error: j['e'] is String ? j['e'] as String : null,
        stack: j['s'] is String ? j['s'] as String : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Where the lines are kept.
abstract class DiagSink {
  Future<void> append(String line);

  /// All lines, oldest first.
  Future<List<String>> readLines();

  Future<void> clear();
}

/// Two files in [dir]: `diag.log` and, once it has grown to [maxBytes], the
/// older `diag.log.1` (the one before that is dropped). So the log never takes
/// more than about twice [maxBytes].
class FileDiagSink implements DiagSink {
  FileDiagSink(this.dir, {this.maxBytes = 256 * 1024});

  final String dir;
  final int maxBytes;

  File get _cur => File(p.join(dir, 'diag.log'));
  File get _old => File(p.join(dir, 'diag.log.1'));

  bool _ready = false;
  int _size = 0;

  Future<void> _prepare() async {
    if (_ready) return;
    await Directory(dir).create(recursive: true);
    _size = await _cur.exists() ? await _cur.length() : 0;
    _ready = true;
  }

  @override
  Future<void> append(String line) async {
    await _prepare();
    final bytes = utf8.encode('$line\n');
    if (_size > 0 && _size + bytes.length > maxBytes) {
      if (await _old.exists()) await _old.delete();
      if (await _cur.exists()) await _cur.rename(_old.path);
      _size = 0;
    }
    await _cur.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    _size += bytes.length;
  }

  Future<List<String>> _linesOf(File f) async {
    if (!await f.exists()) return const [];
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    return const LineSplitter()
        .convert(text)
        .where((l) => l.isNotEmpty)
        .toList();
  }

  @override
  Future<List<String>> readLines() async => [
    ...await _linesOf(_old),
    ...await _linesOf(_cur),
  ];

  @override
  Future<void> clear() async {
    for (final f in [_old, _cur]) {
      if (await f.exists()) await f.delete();
    }
    _size = 0;
  }
}

/// A log in memory (tests).
class MemoryDiagSink implements DiagSink {
  MemoryDiagSink({this.failWith});

  final lines = <String>[];

  /// When set, every write throws it (a full disk, a locked file).
  Object? failWith;

  @override
  Future<void> append(String line) async {
    if (failWith != null) throw failWith!;
    lines.add(line);
  }

  @override
  Future<List<String>> readLines() async => List.of(lines);

  @override
  Future<void> clear() async => lines.clear();
}

/// Writes entries to a [DiagSink] without ever failing the caller: logging is
/// something to rely on while everything else is going wrong.
///
/// Calls return at once; the writes happen one after the other in the
/// background ([flush] waits for them). Until [attach] gives it a sink, the
/// entries are kept in memory (the first ones come before the app knows where
/// its files are). The same message does not fill the file: see [floodWindow].
class DiagLog {
  /// A log that keeps what it gets until [attach] is called.
  DiagLog({
    DateTime Function()? now,
    this.floodWindow = const Duration(seconds: 60),
    this.maxPerMinute = 30,
    this.bufferLimit = 100,
  }) : _now = now ?? DateTime.now,
       _disabled = false;

  /// A log that writes nowhere (the default in tests and previews).
  DiagLog.disabled()
    : _now = DateTime.now,
      _disabled = true,
      floodWindow = Duration.zero,
      maxPerMinute = 0,
      bufferLimit = 0;

  /// The same code from the same place with the same error is written at most
  /// once per window; the rest is only counted.
  final Duration floodWindow;

  /// Everything together is written at most this many times a minute.
  final int maxPerMinute;

  final int bufferLimit;

  final DateTime Function() _now;
  final bool _disabled;

  DiagSink? _sink;
  final _pre = <String>[];
  Future<void> _queue = Future<void>.value();
  final _recent = <String, DateTime>{};
  final _minute = <DateTime>[];
  final _once = <String>{};
  int _suppressed = 0;

  bool get enabled => !_disabled;

  /// From now on the entries go to [sink] (the ones kept so far first).
  void attach(DiagSink sink) {
    if (_disabled) return;
    _sink = sink;
    final early = List<String>.of(_pre);
    _pre.clear();
    for (final line in early) {
      _enqueue(sink, line);
    }
  }

  void info(String area, String code, {Map<String, Object?> data = const {}}) =>
      _add(area, code, data: data);

  /// [error] is reduced to its type and the first line of its message.
  void error(
    String area,
    String code,
    Object error, [
    StackTrace? stack,
    Map<String, Object?> data = const {},
  ]) => _add(area, code, data: data, error: error, stack: stack);

  /// Like [info], but only the first time [key] is seen in this run.
  void infoOnce(
    String key,
    String area,
    String code, {
    Map<String, Object?> data = const {},
  }) {
    if (_disabled || !_once.add(key)) return;
    _add(area, code, data: data);
  }

  /// Like [error], but only the first time [key] is seen in this run.
  void errorOnce(
    String key,
    String area,
    String code,
    Object error, [
    StackTrace? stack,
    Map<String, Object?> data = const {},
  ]) {
    if (_disabled || !_once.add(key)) return;
    _add(area, code, data: data, error: error, stack: stack);
  }

  void _add(
    String area,
    String code, {
    required Map<String, Object?> data,
    Object? error,
    StackTrace? stack,
  }) {
    if (_disabled) return;
    try {
      final text = error == null ? null : safeErrorText(error);
      final now = _now().toUtc();
      if (!_allow('$area|$code|${_head(text)}', now)) return;
      _write(
        DiagEntry(
          time: now,
          area: area,
          code: code,
          data: _clean(data),
          error: text,
          stack: stack == null ? null : safeStackText(stack),
        ).toLine(),
      );
    } on Object {
      // logging must not become the next problem
    }
  }

  static String _head(String? s) =>
      s == null ? '' : s.substring(0, math.min(80, s.length));

  /// Numbers, flags and short, cleaned strings; nothing else gets in.
  static Map<String, Object?> _clean(Map<String, Object?> data) => {
    for (final e in data.entries)
      if (e.value is num || e.value is bool)
        e.key: e.value
      else if (e.value is String)
        e.key: redactAll(e.value as String, max: 60),
  };

  bool _allow(String key, DateTime now) {
    final last = _recent[key];
    if (last != null && now.difference(last) < floodWindow) {
      _suppressed++;
      return false;
    }
    _minute.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_minute.length >= maxPerMinute) {
      _suppressed++;
      return false;
    }
    _recent[key] = now;
    if (_recent.length > 300) {
      _recent.removeWhere((_, t) => now.difference(t) >= floodWindow);
    }
    _minute.add(now);
    if (_suppressed > 0) {
      final n = _suppressed;
      _suppressed = 0;
      _write(
        DiagEntry(
          time: now,
          area: 'diag',
          code: 'suppressed',
          data: {'n': n},
        ).toLine(),
      );
    }
    return true;
  }

  void _write(String line) {
    final sink = _sink;
    if (sink == null) {
      if (_pre.length < bufferLimit) _pre.add(line);
      return;
    }
    _enqueue(sink, line);
  }

  void _enqueue(DiagSink sink, String line) {
    _queue = _queue
        .then<void>((_) => sink.append(line))
        .catchError((Object _) {});
  }

  /// Waits until everything logged so far is written.
  Future<void> flush() => _queue;

  /// The last [n] entries, oldest first (lines that cannot be read are
  /// skipped).
  Future<List<DiagEntry>> tail([int n = 100]) async {
    await flush();
    final sink = _sink;
    if (sink == null) return const [];
    final out = <DiagEntry>[];
    try {
      for (final line in (await sink.readLines()).reversed) {
        final e = DiagEntry.tryParse(line);
        if (e == null) continue;
        out.add(e);
        if (out.length >= n) break;
      }
    } on Object {
      return const [];
    }
    return out.reversed.toList();
  }

  /// Deletes the log.
  Future<void> clear() async {
    await flush();
    _pre.clear();
    try {
      await _sink?.clear();
    } on Object {
      // nothing more to do
    }
  }
}

/// The log of the running app. Tests get one that writes nowhere unless they
/// replace it; `main` replaces it with the file-backed one.
final diagLogProvider = Provider<DiagLog>((ref) => DiagLog.disabled());
