import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The calls made to one service on one day, by how they ended.
class RequestCounts {
  RequestCounts({
    this.calls = 0,
    this.ok = 0,
    this.client = 0,
    this.throttled = 0,
    this.server = 0,
    this.failed = 0,
  });

  /// Every call.
  int calls;

  /// Answered, and not with an error status.
  int ok;

  /// Answered with 4xx, except 429.
  int client;

  /// Answered with 429 (too many requests).
  int throttled;

  /// Answered with 5xx.
  int server;

  /// No answer at all: no connection, timeout, closed client.
  int failed;

  RequestCounts copy() => RequestCounts(
    calls: calls,
    ok: ok,
    client: client,
    throttled: throttled,
    server: server,
    failed: failed,
  );

  void add(RequestCounts o) {
    calls += o.calls;
    ok += o.ok;
    client += o.client;
    throttled += o.throttled;
    server += o.server;
    failed += o.failed;
  }

  Map<String, int> toJson() => {
    'c': calls,
    'ok': ok,
    'e4': client,
    't': throttled,
    'e5': server,
    'x': failed,
  };

  factory RequestCounts.fromJson(Object? j) {
    int n(String k) =>
        j is Map && j[k] is int && (j[k] as int) > 0 ? j[k] as int : 0;
    return RequestCounts(
      calls: n('c'),
      ok: n('ok'),
      client: n('e4'),
      throttled: n('t'),
      server: n('e5'),
      failed: n('x'),
    );
  }
}

/// day (`2026-11-12`) -> service -> counts
typedef RequestTable = Map<String, Map<String, RequestCounts>>;

/// The services the counters tell apart.
const requestServices = ['calendar', 'drive', 'other'];

/// Which service a request goes to, from its path (the Google client library
/// calls the same host for both).
String serviceOfPath(String path) {
  if (path.startsWith('/calendar/')) return 'calendar';
  if (path.startsWith('/drive/') || path.startsWith('/upload/drive/')) {
    return 'drive';
  }
  return 'other';
}

/// The date of [t] on the device, as a sortable key.
String dayKeyOf(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final l = t.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

/// How many requests the app made, per service and day, for the Diagnostics
/// page ("did I hit the quota?"). Only numbers: not a single address or
/// content.
///
/// Calls are counted in memory ([record]) and added to what is stored by
/// [flush] (after each sync run), so a busy sync does not write the database
/// for every request. The last [keepDays] days are kept.
class RequestStats {
  RequestStats({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The `meta` key of the stored table.
  static const metaKey = 'diag.req';

  static const keepDays = 7;

  final DateTime Function() _now;
  final RequestTable _fresh = {};

  void record(String service, {int? status, bool failed = false}) {
    final day = _fresh.putIfAbsent(dayKeyOf(_now()), () => {});
    final c = day.putIfAbsent(service, RequestCounts.new);
    c.calls++;
    if (failed || status == null) {
      c.failed++;
    } else if (status == 429) {
      c.throttled++;
    } else if (status >= 500) {
      c.server++;
    } else if (status >= 400) {
      c.client++;
    } else {
      c.ok++;
    }
  }

  /// Adds what was counted since the last call to the stored table. When the
  /// write fails the counts are kept for the next try, and the error is
  /// rethrown.
  Future<void> flush(
    Future<String?> Function(String key) read,
    Future<void> Function(String key, String? value) write,
  ) async {
    if (_fresh.isEmpty) return;
    final batch = _copy(_fresh);
    _fresh.clear();
    try {
      final stored = decode(await read(metaKey));
      _mergeInto(stored, batch);
      _prune(stored);
      await write(metaKey, jsonEncode(encode(stored)));
    } on Object {
      _mergeInto(_fresh, batch);
      rethrow;
    }
  }

  /// The stored table plus what is not stored yet.
  Future<RequestTable> read(Future<String?> Function(String key) read) async {
    final table = decode(await read(metaKey));
    _mergeInto(table, _fresh);
    return table;
  }

  static RequestTable decode(String? json) {
    final out = <String, Map<String, RequestCounts>>{};
    if (json == null) return out;
    try {
      final j = jsonDecode(json);
      if (j is! Map) return out;
      for (final d in j.entries) {
        final v = d.value;
        if (v is! Map) continue;
        out['${d.key}'] = {
          for (final s in v.entries)
            '${s.key}': RequestCounts.fromJson(s.value),
        };
      }
    } on FormatException {
      // a damaged value is replaced by the next write
    }
    return out;
  }

  static Map<String, Object?> encode(RequestTable t) => {
    for (final d in t.entries)
      d.key: {for (final s in d.value.entries) s.key: s.value.toJson()},
  };

  static RequestTable _copy(RequestTable t) => {
    for (final d in t.entries)
      d.key: {for (final s in d.value.entries) s.key: s.value.copy()},
  };

  static void _mergeInto(RequestTable target, RequestTable source) {
    for (final d in source.entries) {
      final day = target.putIfAbsent(d.key, () => {});
      for (final s in d.value.entries) {
        day.putIfAbsent(s.key, RequestCounts.new).add(s.value);
      }
    }
  }

  static void _prune(RequestTable t) {
    final days = t.keys.toList()..sort();
    for (final d in days.take(math.max(0, days.length - keepDays))) {
      t.remove(d);
    }
  }
}

/// The counters of the running app.
final requestStatsProvider = Provider<RequestStats>((ref) => RequestStats());
