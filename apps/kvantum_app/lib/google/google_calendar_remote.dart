import 'dart:async';
import 'dart:io';

import 'package:googleapis/calendar/v3.dart' as g;
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';

import '../sync/remote.dart';

const _appKey = 'appEventId';

/// [RemoteCalendar] backed by the Google Calendar API v3.
///
/// Known limitations (documented, not silent):
///  * RDATE lines and multiple RRULEs are ignored.
///  * Pushing edits of single recurring instances is not implemented yet
///    (they are pulled and displayed correctly).
class GoogleCalendarRemote implements RemoteCalendar {
  GoogleCalendarRemote(this._client, {this.window = const Duration(days: 31)});

  final http.Client _client;

  /// Full syncs only fetch events ending after now - [window] (reduced data
  /// mode); the sync token remembers this filter.
  final Duration window;

  String? _calendarTz;
  g.CalendarApi get _api => g.CalendarApi(_client);

  Future<String> _tz(String calendarId) async => _calendarTz ??=
      (await _guard(() => _api.calendars.get(calendarId))).timeZone ?? 'UTC';

  // ---------------------------------------------------------------- pull

  @override
  Future<PullResult> pull(String calendarId, String? syncToken) async {
    final tz = await _tz(calendarId);
    final changes = <RemoteChange>[];
    String? page;
    String? next;
    do {
      final g.Events res;
      try {
        res = await _guard(
          () => _api.events.list(
            calendarId,
            syncToken: syncToken,
            timeMin: syncToken == null
                ? DateTime.now().toUtc().subtract(window)
                : null,
            showDeleted: true,
            singleEvents: false,
            maxResults: 250,
            pageToken: page,
          ),
        );
      } on _Gone {
        throw SyncTokenExpired();
      }
      for (final e in res.items ?? const <g.Event>[]) {
        final c = _toChange(e, calendarId, tz);
        if (c != null) changes.add(c);
      }
      page = res.nextPageToken;
      next = res.nextSyncToken ?? next;
    } while (page != null);
    return PullResult(changes, next);
  }

  RemoteChange? _toChange(g.Event e, String calendarId, String defaultTz) {
    final id = e.id;
    if (id == null) return null;
    final cancelled = e.status == 'cancelled';
    final master = e.recurringEventId;
    RemoteEvent ref(bool cancelledFlag) => RemoteEvent(
      calendarId: calendarId,
      googleId: id,
      etag: e.etag ?? '',
      appEventId: e.extendedProperties?.private?[_appKey],
      iCalUid: e.iCalUID,
      cancelled: cancelledFlag,
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

    final rec = _parseRecurrence(e.recurrence, tz);
    return RemoteChange(
      ref: ref(false),
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
      ),
    );
  }

  DateTime _wall(g.EventDateTime d, String tz) {
    if (d.date != null) {
      return floating(d.date!.year, d.date!.month, d.date!.day);
    }
    return toWallClock(tz, d.dateTime!.toUtc());
  }

  // -------------------------------------------------------------- push

  @override
  Future<PushResult> upsert(CalEvent event) async {
    if (event.isException) {
      throw UnsupportedError(
        'Pushing single-instance edits is not implemented yet',
      );
    }
    final body = _toGoogle(event);
    var googleId = event.googleId;
    // Idempotency: a previous attempt may have created the event before we
    // could record its id. Look it up by our own id instead of inserting twice.
    googleId ??= await _findByAppId(event.calendarId, event.id);

    if (googleId == null) {
      final created = await _guard(
        () => _api.events.insert(body, event.calendarId),
      );
      return PushResult(created.id!, created.etag ?? '');
    }
    try {
      final api = g.CalendarApi(_IfMatch(_client, event.etag));
      final updated = await _guard(
        () => api.events.update(body, event.calendarId, googleId!),
      );
      return PushResult(updated.id!, updated.etag ?? '');
    } on _Gone {
      // Deleted remotely but edited locally: local wins, recreate.
      final created = await _guard(
        () => _api.events.insert(body, event.calendarId),
      );
      return PushResult(created.id!, created.etag ?? '');
    }
  }

  @override
  Future<void> delete(CalEvent event) async {
    final id = event.googleId ?? await _findByAppId(event.calendarId, event.id);
    if (id == null) return;
    try {
      await _guard(() => _api.events.delete(event.calendarId, id));
    } on _Gone {
      // already gone
    }
  }

  Future<String?> _findByAppId(String calendarId, String appId) async {
    final res = await _guard(
      () => _api.events.list(
        calendarId,
        privateExtendedProperty: ['$_appKey=$appId'],
        showDeleted: false,
        maxResults: 1,
      ),
    );
    return res.items?.firstOrNull?.id;
  }

  g.Event _toGoogle(CalEvent e) {
    final ev = g.Event()
      ..summary = e.title
      ..description = e.notes.isEmpty ? null : e.notes
      ..location = e.location.isEmpty ? null : e.location
      ..extendedProperties = (g.EventExtendedProperties()
        ..private = {_appKey: e.id});
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
    if (e.isRecurring) {
      final rule = e.rrule!.startsWith('RRULE:')
          ? e.rrule!
          : 'RRULE:${e.rrule}';
      ev.recurrence = [rule, ..._exdateLines(e)];
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
/// in the event's zone, the form our recurrence engine compares against.
ParsedRecurrence parseRecurrenceLines(List<String>? lines, String tz) =>
    _parseRecurrence(lines, tz);

ParsedRecurrence _parseRecurrence(List<String>? lines, String tz) {
  String? rrule;
  final ex = <DateTime>[];
  for (final line in lines ?? const <String>[]) {
    if (line.startsWith('RRULE:')) {
      rrule ??= line.substring(6);
    } else if (line.startsWith('EXDATE')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final params = line.substring(0, colon);
      for (final raw in line.substring(colon + 1).split(',')) {
        final v = raw.trim();
        final y = int.tryParse(v.substring(0, 4)),
            mo = int.tryParse(v.substring(4, 6)),
            d = int.tryParse(v.substring(6, 8));
        if (y == null || mo == null || d == null) continue;
        if (params.contains('VALUE=DATE') || v.length == 8) {
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

class _Gone implements Exception {}

/// Maps API/network failures to the engine's error vocabulary.
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on g.DetailedApiRequestError catch (e) {
    final s = e.status ?? 0;
    final reason = e.errors.firstOrNull?.reason ?? '';
    if (s == 404 || s == 410) throw _Gone();
    if (s == 412) throw ConflictException();
    if (s == 401) throw TransientSyncError('auth');
    if (s == 429 ||
        s >= 500 ||
        (s == 403 && reason.toLowerCase().contains('ratelimit'))) {
      throw TransientSyncError('http $s $reason');
    }
    rethrow;
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
