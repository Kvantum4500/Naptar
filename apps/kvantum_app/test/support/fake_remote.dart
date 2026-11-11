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

  /// Which account / calendar this fake claims to be (changed by tests to
  /// simulate a different login or a re-created calendar).
  RemoteIdentity who = const RemoteIdentity(
    account: 'me@example.com',
    calendar: 'cal-1',
  );

  /// While set, `pull` behaves as if the calendar did not exist any more.
  bool calendarGone = false;

  /// Events the adapter "could not read" in the next pulls.
  List<SkippedRemote> skipped = const [];

  /// Google id -> the appEventId to report for it, whatever was pushed (an
  /// instance of a series carries a COPY of the series' appEventId).
  final Map<String, String> inheritedAppId = {};

  /// The sync token of every pull (null: a full listing).
  final List<String?> pullTokens = [];

  /// The Google id each upload carried (null: it was not linked).
  final List<String?> upsertLinks = [];

  /// Pushes in the order they arrived: (op, local id).
  final List<(String, String)> pushLog = [];

  /// Fails the Nth upsert (1-based) with this error instead of storing it.
  final Map<int, Object> failUpsertAt = {};
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
  Future<RemoteIdentity> identity(String calendarId) async {
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    return who;
  }

  @override
  Future<PullResult> pull(String calendarId, String? syncToken) async {
    pullCalls++;
    pullTokens.add(syncToken);
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    if (calendarGone) throw CalendarGoneError();
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
            appEventId:
                inheritedAppId[g] ??
                appIdToGoogle.entries
                    .where((x) => x.value == g)
                    .firstOrNull
                    ?.key,
            iCalUid: 'uid-$g',
            cancelled: cancelled,
            isInstance: e.recurringEventId != null,
            originalStart: e.originalStart,
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
      skipped: skipped,
    );
  }

  @override
  Future<PushResult> upsert(CalEvent event, {String? masterGoogleId}) async {
    if (failWith != null) throw failWith!;
    if (offline) throw TransientSyncError('offline');
    upsertCalls++;
    pushLog.add(('upsert', event.id));
    upsertLinks.add(event.googleId);
    final failure = failUpsertAt[upsertCalls];
    if (failure != null) throw failure;
    var existing = appIdToGoogle[event.id] ?? event.googleId;
    // Like Google: a deleted event is not found again by our own id; writing
    // it makes a NEW event.
    if (existing != null && (_cancelled[existing] ?? false)) existing = null;
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
    pushLog.add(('delete', event.id));
    final g = event.googleId ?? appIdToGoogle[event.id];
    if (g != null && events.containsKey(g)) {
      _cancelled[g] = true;
      _touch(g);
    }
  }
}
