import 'dart:async';
import 'dart:io';

import 'package:googleapis/calendar/v3.dart' as g;
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_repository.dart' show kNaptarCalendar;
import '../sync/api_errors.dart';
import '../sync/remote.dart';
import '../sync/retry_after_client.dart';

const _appKey = 'appEventId';
const _aiKey = 'ai';

/// Marker stored in the description of the calendar the app owns, so every
/// device finds the SAME calendar instead of creating another one.
const calendarMarker = 'kvantum-naptar-v1';

/// [RemoteCalendar] backed by the Google Calendar API v3.
///
/// The local logical calendar id [kNaptarCalendar] is mapped to the real
/// "Naptar" calendar, which is found (or created once) on first use. Any other
/// id is used as-is.
///
/// Known limitations (documented, not silent): RDATE lines and multiple
/// RRULEs are ignored.
class GoogleCalendarRemote implements RemoteCalendar {
  GoogleCalendarRemote(
    this._client, {
    this.window = const Duration(days: 31),
    this.calendarName = 'Naptar',
    this.calendarTz = 'Europe/Budapest',
  });

  final http.Client _client;

  /// Full syncs only fetch events ending after now - [window] (reduced data
  /// mode); the sync token remembers this filter.
  final Duration window;
  final String calendarName;
  final String calendarTz;

  final Map<String, String> _tzCache = {};
  String? _naptarId;
  String? _account;
  g.CalendarApi get _api => g.CalendarApi(_client);

  /// Runs an API call and maps its failures to the sync vocabulary, with the
  /// server's `Retry-After` when the client in use records it.
  Future<T> _g<T>(Future<T> Function() call) =>
      _guard(call, retryAfter: () => retryAfterOf(_client));

  // ---------------------------------------------------------- calendar

  /// Real Google calendar id for a logical one (finds or creates "Naptar").
  Future<String> _cal(String logical) async {
    if (logical != kNaptarCalendar) return logical;
    return _naptarId ??= await _findOrCreate();
  }

  /// The calendar turned out not to exist: the next call looks it up again.
  void _forgetCalendar() {
    _naptarId = null;
    _tzCache.clear();
  }

  @override
  Future<RemoteIdentity> identity(String calendarId) async {
    final real = await _cal(calendarId);
    // The id of the primary calendar is the account's address: a free way to
    // tell accounts apart without asking for any extra permission.
    _account ??= (await _g(() => _api.calendars.get('primary'))).id ?? '';
    return RemoteIdentity(account: _account!, calendar: real);
  }

  Future<String> _findOrCreate() async {
    final found = <g.CalendarListEntry>[];
    String? page;
    do {
      final res = await _g(
        () => _api.calendarList.list(
          pageToken: page,
          minAccessRole: 'owner',
          showHidden: true,
        ),
      );
      found.addAll(
        (res.items ?? const <g.CalendarListEntry>[]).where(
          (c) =>
              c.deleted != true &&
              c.accessRole == 'owner' &&
              (c.description ?? '').contains(calendarMarker),
        ),
      );
      page = res.nextPageToken;
    } while (page != null);
    if (found.isNotEmpty) {
      // Several devices may have raced the first creation: all of them pick
      // the same one (smallest id), so they converge on a single calendar.
      found.sort((a, b) => (a.id ?? '').compareTo(b.id ?? ''));
      return found.first.id!;
    }
    final created = await _g(
      () => _api.calendars.insert(
        g.Calendar(
          summary: calendarName,
          description: 'Kvantum Naptár ($calendarMarker)',
          timeZone: calendarTz,
        ),
      ),
    );
    return created.id!;
  }

  Future<String> _tz(String realId) async => _tzCache[realId] ??=
      (await _g(() => _api.calendars.get(realId))).timeZone ?? 'UTC';

  // ---------------------------------------------------------------- pull

  @override
  Future<PullResult> pull(String calendarId, String? syncToken) async {
    final real = await _cal(calendarId);
    final String tz;
    try {
      tz = await _tz(real);
    } on _Gone {
      _forgetCalendar();
      throw CalendarGoneError();
    }
    final changes = <RemoteChange>[];
    final skipped = <SkippedRemote>[];
    String? page;
    String? next;
    // Computed once: every page of one listing must use the same filter.
    final timeMin = syncToken == null
        ? DateTime.now().toUtc().subtract(window)
        : null;
    do {
      final g.Events res;
      try {
        res = await _g(
          () => _api.events.list(
            real,
            syncToken: syncToken,
            timeMin: timeMin,
            showDeleted: true,
            singleEvents: false,
            maxResults: 250,
            pageToken: page,
          ),
        );
      } on _Gone catch (gone) {
        // 410 = the sync token is no longer valid (list everything again);
        // 404 = the calendar itself is gone (look it up again next time).
        if (gone.status == 404) {
          _forgetCalendar();
          throw CalendarGoneError();
        }
        throw SyncTokenExpired();
      }
      for (final e in res.items ?? const <g.Event>[]) {
        // One event the adapter cannot read (unknown zone, broken EXDATE)
        // must not stop the others from arriving.
        try {
          final c = _toChange(e, calendarId, tz);
          if (c != null) changes.add(c);
        } catch (err) {
          skipped.add(SkippedRemote(e.id ?? '?', _short(err)));
        }
      }
      page = res.nextPageToken;
      next = res.nextSyncToken ?? next;
    } while (page != null);
    return PullResult(changes, next, windowStartUtc: timeMin, skipped: skipped);
  }

  RemoteChange? _toChange(g.Event e, String calendarId, String defaultTz) {
    final id = e.id;
    if (id == null) return null;
    final cancelled = e.status == 'cancelled';
    final master = e.recurringEventId;
    RemoteEvent ref(bool cancelledFlag, [DateTime? originalStart]) =>
        RemoteEvent(
          calendarId: calendarId,
          googleId: id,
          etag: e.etag ?? '',
          appEventId: e.extendedProperties?.private?[_appKey],
          iCalUid: e.iCalUID,
          cancelled: cancelledFlag,
          isInstance: master != null,
          originalStart: originalStart,
        );

    // A cancelled single/series is a deletion; a cancelled INSTANCE of a series
    // is an exception (hides that one occurrence) and must be kept as such.
    if (cancelled && !(master != null && e.originalStartTime != null)) {
      return RemoteChange(ref: ref(true));
    }
    final tz = e.start?.timeZone ?? e.originalStartTime?.timeZone ?? defaultTz;
    final original = e.originalStartTime == null
        ? null
        : _wall(e.originalStartTime!, tz);
    final startDt = e.start ?? e.originalStartTime;
    if (startDt == null) return null;
    final allDay = startDt.date != null;
    final start = _wall(startDt, tz);
    var end = e.end == null ? start : _wall(e.end!, tz);
    if (end.isBefore(start)) end = start;

    final rec = _parseRecurrence(e.recurrence, tz, allDay: allDay);
    return RemoteChange(
      ref: ref(false, original),
      masterGoogleId: master,
      event: CalEvent(
        id: 'remote-$id', // placeholder, the engine assigns the real id
        calendarId: calendarId,
        title: e.summary ?? '',
        notes: e.description ?? '',
        location: e.location ?? '',
        start: start,
        end: end,
        allDay: allDay,
        tzid: allDay ? null : tz,
        rrule: rec.rrule,
        exdates: rec.exdates,
        recurringEventId: master == null ? null : 'pending-master',
        originalStart: original,
        cancelled: cancelled,
        etag: e.etag,
        iCalUid: e.iCalUID,
        colorId: e.colorId,
        aiGenerated: e.extendedProperties?.private?[_aiKey] == '1',
      ),
    );
  }

  /// A short, harmless description of why an event could not be read (the
  /// error type and a trimmed message; never the event's own text).
  String _short(Object err) {
    final t = '$err'.replaceAll(RegExp(r'\s+'), ' ');
    return '${err.runtimeType}: ${t.length > 120 ? t.substring(0, 120) : t}';
  }

  DateTime _wall(g.EventDateTime d, String tz) {
    if (d.date != null) {
      return floating(d.date!.year, d.date!.month, d.date!.day);
    }
    return toWallClock(tz, d.dateTime!.toUtc());
  }

  // -------------------------------------------------------------- push

  @override
  Future<PushResult> upsert(CalEvent event, {String? masterGoogleId}) async {
    final real = await _cal(event.calendarId);
    if (event.isException) {
      if (masterGoogleId == null) {
        throw StateError('instance edit needs the series Google id');
      }
      return _upsertInstance(real, event, masterGoogleId);
    }
    final body = _toGoogle(event);
    var googleId = event.googleId;
    // Idempotency: a previous attempt may have created the event before we
    // could record its id. Look it up by our own id instead of inserting twice.
    googleId ??= await _findByAppId(real, event.id);

    if (googleId == null) return _insert(real, body);
    try {
      return await _update(real, googleId, body);
    } on _Gone {
      // Deleted remotely but edited locally: local wins, recreate.
      return _insert(real, body);
    }
  }

  Future<PushResult> _insert(String real, g.Event body) async {
    final created = await _g(() => _api.events.insert(body, real));
    return PushResult(created.id!, created.etag ?? '');
  }

  /// Changes OUR fields of an existing event and leaves everything else as
  /// Google has it. A plain `update` replaces the whole event, which would
  /// wipe what only exists on the Google side (reminders, guests, the Meet
  /// link, availability ...) at every edit made here. So: read the current
  /// event, put our fields on it, write it back with its own etag; if somebody
  /// changed it in between (412), read again.
  Future<PushResult> _update(String real, String googleId, g.Event ours) async {
    for (var attempt = 0; ; attempt++) {
      final current = await _g(() => _api.events.get(real, googleId));
      if (current.status == 'cancelled') throw _Gone(410);
      final merged = _overlay(current, ours);
      try {
        final api = g.CalendarApi(_IfMatch(_client, current.etag));
        final updated = await _g(
          () => api.events.update(merged, real, googleId),
        );
        return PushResult(updated.id!, updated.etag ?? '');
      } on ConflictException {
        if (attempt >= 2) rethrow;
      }
    }
  }

  /// [ours] laid over [current]: the fields the app owns come from [ours],
  /// all others (and unknown recurrence lines / private keys) stay.
  g.Event _overlay(g.Event current, g.Event ours) {
    final merged = current
      ..summary = ours.summary
      ..description = ours.description
      ..location = ours.location
      ..colorId = ours.colorId
      ..start = ours.start
      ..end = ours.end;
    if (ours.status == 'cancelled') merged.status = 'cancelled';

    final theirLines = current.recurrence ?? const <String>[];
    merged.recurrence = ours.recurrence == null
        ? null
        : [
            ...ours.recurrence!,
            // lines the app cannot edit (RDATE, EXRULE) are kept as they are
            for (final l in theirLines)
              if (l.startsWith('RDATE') || l.startsWith('EXRULE')) l,
          ];

    final priv = <String, String>{
      ...?current.extendedProperties?.private,
      ...?ours.extendedProperties?.private,
    };
    if (ours.extendedProperties?.private?.containsKey(_aiKey) != true) {
      priv.remove(_aiKey);
    }
    merged.extendedProperties =
        (current.extendedProperties ?? g.EventExtendedProperties())
          ..private = priv;
    return merged;
  }

  /// Changes ONE occurrence of a series (an "exception").
  Future<PushResult> _upsertInstance(
    String real,
    CalEvent e,
    String masterGoogleId,
  ) async {
    var instanceId = e.googleId;
    if (instanceId == null) {
      final orig = e.originalStart!;
      final DateTime from;
      final DateTime to;
      if (e.allDay) {
        from = DateTime.utc(orig.year, orig.month, orig.day);
        to = from.add(const Duration(days: 1));
      } else {
        final at = resolveWallClock(e.tzid!, orig);
        from = at.subtract(const Duration(minutes: 1));
        to = at.add(const Duration(minutes: 1));
      }
      final res = await _g(
        () => _api.events.instances(
          real,
          masterGoogleId,
          timeMin: from,
          timeMax: to,
          showDeleted: true,
          maxResults: 20,
        ),
      );
      final tz = await _tz(real);
      final hit = (res.items ?? const <g.Event>[]).where((i) {
        final o = i.originalStartTime;
        if (o == null) return false;
        return _wall(o, e.tzid ?? tz) == orig;
      }).firstOrNull;
      if (hit?.id == null) {
        throw StateError(
          'Az ismétlődés ezen példánya nem található a Google-ben.',
        );
      }
      instanceId = hit!.id;
    }
    final body = _toGoogle(e, instance: true);
    final patched = await _g(() => _api.events.patch(body, real, instanceId!));
    return PushResult(patched.id!, patched.etag ?? '');
  }

  @override
  Future<void> delete(CalEvent event) async {
    final real = await _cal(event.calendarId);
    final id = event.googleId ?? await _findByAppId(real, event.id);
    if (id == null) return;
    try {
      await _g(() => _api.events.delete(real, id));
    } on _Gone {
      // already gone
    }
  }

  Future<String?> _findByAppId(String real, String appId) async {
    final res = await _g(
      () => _api.events.list(
        real,
        privateExtendedProperty: ['$_appKey=$appId'],
        showDeleted: false,
        maxResults: 1,
      ),
    );
    return res.items?.firstOrNull?.id;
  }

  g.Event _toGoogle(CalEvent e, {bool instance = false}) {
    final ev = g.Event()
      ..summary = e.title
      ..description = e.notes.isEmpty ? null : e.notes
      ..location = e.location.isEmpty ? null : e.location
      ..colorId = e.colorId
      ..extendedProperties = (g.EventExtendedProperties()
        ..private = {_appKey: e.id, if (e.aiGenerated) _aiKey: '1'});
    if (e.cancelled) ev.status = 'cancelled';
    if (e.allDay) {
      ev.start = g.EventDateTime(
        date: DateTime.utc(e.start.year, e.start.month, e.start.day),
      );
      ev.end = g.EventDateTime(
        date: DateTime.utc(e.end.year, e.end.month, e.end.day),
      );
    } else {
      ev.start = g.EventDateTime(dateTime: e.startUtc, timeZone: e.tzid);
      ev.end = g.EventDateTime(dateTime: e.endUtc, timeZone: e.tzid);
    }
    if (!instance && e.isRecurring) {
      final raw = e.rrule!.startsWith('RRULE:')
          ? e.rrule!.substring(6)
          : e.rrule!;
      final rule = rruleToGoogle(raw, e.start, e.tzid, allDay: e.allDay);
      ev.recurrence = ['RRULE:$rule', ..._exdateLines(e)];
    }
    return ev;
  }

  List<String> _exdateLines(CalEvent e) => [
    for (final x in e.exdates)
      e.allDay
          ? 'EXDATE;VALUE=DATE:${_ymd(x)}'
          : 'EXDATE;TZID=${e.tzid}:${_ymd(x)}T${_hms(x)}',
  ];
}

String _p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
String _ymd(DateTime d) => '${_p(d.year, 4)}${_p(d.month)}${_p(d.day)}';
String _hms(DateTime d) => '${_p(d.hour)}${_p(d.minute)}${_p(d.second)}';

class ParsedRecurrence {
  const ParsedRecurrence(this.rrule, this.exdates);
  final String? rrule;
  final List<DateTime> exdates;
}

/// Parses Google's `recurrence` lines. EXDATE values may be floating with
/// TZID, UTC (`...Z`) or dates (`VALUE=DATE`); all become floating wall-clock
/// in the event's zone, the form our recurrence engine compares against. UNTIL
/// is converted from Google's UTC form to the floating form used locally.
ParsedRecurrence parseRecurrenceLines(
  List<String>? lines,
  String tz, {
  bool allDay = false,
}) => _parseRecurrence(lines, tz, allDay: allDay);

ParsedRecurrence _parseRecurrence(
  List<String>? lines,
  String tz, {
  bool allDay = false,
}) {
  String? rrule;
  final ex = <DateTime>[];
  for (final line in lines ?? const <String>[]) {
    if (line.startsWith('RRULE:')) {
      rrule ??= rruleFromGoogle(line.substring(6), tz, allDay: allDay);
    } else if (line.startsWith('EXDATE')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      // `VALUE=DATE` is a whole day; `VALUE=DATE-TIME` (which also starts with
      // those characters) is a time of day: the parameters are compared whole
      final dateOnly = line
          .substring(0, colon)
          .toUpperCase()
          .split(';')
          .any((p) => p.trim() == 'VALUE=DATE');
      for (final raw in line.substring(colon + 1).split(',')) {
        final v = raw.trim();
        if (v.length < 8) continue;
        final y = int.tryParse(v.substring(0, 4)),
            mo = int.tryParse(v.substring(4, 6)),
            d = int.tryParse(v.substring(6, 8));
        if (y == null || mo == null || d == null) continue;
        if (dateOnly || v.length == 8) {
          ex.add(floating(y, mo, d));
        } else {
          final h = int.parse(v.substring(9, 11)),
              mi = int.parse(v.substring(11, 13)),
              s = int.parse(v.substring(13, 15));
          if (v.endsWith('Z')) {
            ex.add(toWallClock(tz, DateTime.utc(y, mo, d, h, mi, s)));
          } else {
            ex.add(floating(y, mo, d, h, mi, s));
          }
        }
      }
    }
  }
  return ParsedRecurrence(rrule, ex);
}

// ------------------------------------------------------------ plumbing

class _Gone implements Exception {
  _Gone(this.status);
  final int status;
}

/// Maps API/network failures to the engine's error vocabulary (see
/// [classifyApiError]). [retryAfter] supplies the server's `Retry-After`.
Future<T> _guard<T>(
  Future<T> Function() call, {
  Duration? Function()? retryAfter,
}) async {
  try {
    return await call();
  } on g.DetailedApiRequestError catch (e) {
    final status = e.status ?? 0;
    final detail = e.errors.firstOrNull;
    final kind = classifyApiError(
      status: status,
      reason: detail?.reason,
      domain: detail?.domain,
      message: e.message,
      location: detail?.location,
    );
    final wait = retryAfter?.call();
    final what = 'http $status ${detail?.reason ?? ''}'.trim();
    switch (kind) {
      case ApiFailure.gone:
        throw _Gone(status);
      case ApiFailure.conflict:
        throw ConflictException();
      case ApiFailure.tokenInvalid:
        throw SyncTokenExpired();
      case ApiFailure.auth:
        throw TransientSyncError('auth', wait);
      case ApiFailure.throttled:
        throw TransientSyncError.throttled(what, retryAfter: wait);
      case ApiFailure.dailyLimit:
        throw TransientSyncError.throttled(
          what,
          retryAfter: wait,
          dailyLimit: true,
        );
      case ApiFailure.server:
        throw TransientSyncError(what, wait);
      case ApiFailure.itemRejected:
        throw ItemRejectedError(status, detail?.reason, e.message);
    }
  } on SocketException catch (e) {
    throw TransientSyncError(e.message);
  } on http.ClientException catch (e) {
    throw TransientSyncError(e.message);
  } on TimeoutException {
    throw TransientSyncError('timeout');
  }
}

/// Adds `If-Match` so Google rejects the write (412) when the event changed.
class _IfMatch extends http.BaseClient {
  _IfMatch(this._inner, this._etag);
  final http.Client _inner;
  final String? _etag;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_etag != null && _etag.isNotEmpty) request.headers['If-Match'] = _etag;
    return _inner.send(request);
  }
}
