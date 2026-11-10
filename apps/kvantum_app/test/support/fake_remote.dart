import 'dart:async';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:kvantum_app/sync/remote.dart';

/// In-memory stand-in for Google Calendar with etags, sync tokens and
/// idempotent upserts (keyed by appEventId, like extendedProperties).
class FakeRemote implements RemoteCalendar {
  final Map<String, CalEvent> events = {}; // googleId -> event
  final Map<String, String> appIdToGoogle = {};
  final Map<String, int> _rev = {};
  final Map<String, bool> _cancelled = {};
  int _clock = 0;
  int _nextId = 1;
  bool isCancelled(String g) => _cancelled[g] ?? false;
  bool offline = false;

  /// When set, a FULL listing only returns events ending after this instant
  /// and reports the window, like the real adapter's "reduced data mode".
  DateTime? windowStartUtc;

  /// While set, `pull` waits for it: a slow or hung connection.
  Completer<void>? gate;
  int pullCalls = 0;

  /// Makes every call fail with this error (e.g. an expired login).
  Object? failWith;
  bool expireToken = false;
  int upsertCalls = 0;
  final Map<String, int> _changedAt = {};

  String _etag(String g) => 'etag-${_rev[g]}';

  void _touch(String g) {
    _rev[g] = (_rev[g] ?? 0) + 1;
    _changedAt[g] = ++_clock;
  }

  /// Simulates an edit made directly in Google Calendar / on another device.
  String externalCreate(CalEvent e, {String? master}) {
    final g = 'g${_nextId++}';
    events[g] = e.copyWith(id: 'ext-$g', recurringEventId: master);
    _touch(g);
    return g;
  }

  void externalUpdate(String g, CalEvent Function(CalEvent) f) {
    events[g] = f(events[g]!);
    _touch(g);
  }

  void externalDelete(String g) {
    _cancelled[g] = true;
    _touch(g);
  }

  @override
  Future<PullResult> pull(String calendarId, String? syncToken) async {
    pullCalls++;
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    if (expireToken && syncToken != null) {
      expireToken = false;
      throw SyncTokenExpired();
    }
    final since = syncToken == null ? 0 : int.parse(syncToken);
    final out = <RemoteChange>[];
    for (final g in events.keys) {
      if ((_changedAt[g] ?? 0) <= since) continue;
      final cancelled = _cancelled[g] ?? false;
      if (syncToken == null && cancelled) continue; // full list omits deleted
      final e = events[g]!;
      if (syncToken == null &&
          windowStartUtc != null &&
          !e.endUtc.isAfter(windowStartUtc!)) {
        continue; // outside the requested window
      }
      out.add(
        RemoteChange(
          ref: RemoteEvent(
            calendarId: calendarId,
            googleId: g,
            etag: _etag(g),
            appEventId: appIdToGoogle.entries
                .where((x) => x.value == g)
                .firstOrNull
                ?.key,
            iCalUid: 'uid-$g',
            cancelled: cancelled,
          ),
          event: cancelled ? null : e,
          masterGoogleId: e.recurringEventId,
        ),
      );
    }
    return PullResult(
      out,
      '$_clock',
      windowStartUtc: syncToken == null ? windowStartUtc : null,
    );
  }

  @override
  Future<PushResult> upsert(CalEvent event, {String? masterGoogleId}) async {
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    upsertCalls++;
    final existing = appIdToGoogle[event.id] ?? event.googleId;
    if (existing != null && events.containsKey(existing)) {
      if (event.etag != null && event.etag != _etag(existing)) {
        throw ConflictException();
      }
      events[existing] = event;
      _touch(existing);
      return PushResult(existing, _etag(existing));
    }
    final g = 'g${_nextId++}';
    appIdToGoogle[event.id] = g;
    events[g] = event;
    _touch(g);
    return PushResult(g, _etag(g));
  }

  @override
  Future<void> delete(CalEvent event) async {
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    final g = event.googleId ?? appIdToGoogle[event.id];
    if (g != null && events.containsKey(g)) {
      _cancelled[g] = true;
      _touch(g);
    }
  }
}
