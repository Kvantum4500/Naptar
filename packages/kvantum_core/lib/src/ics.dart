import 'dart:convert';

import 'event.dart';
import 'time.dart';

/// iCalendar (RFC 5545) export/import of [CalEvent]s: a portable backup that
/// any calendar program can read. Times are written with an IANA `TZID`
/// (no VTIMEZONE blocks; Google, Apple and Outlook resolve the names).
const _prodId = '-//Naptar//HU';

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';
String _dateTime(DateTime d) =>
    '${_date(d)}T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';

String _esc(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n');

String _unesc(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[++i];
      b.write(n == 'n' || n == 'N' ? '\n' : n);
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

/// Folds a content line to at most 75 octets per physical line.
void _put(StringBuffer out, String line) {
  var cur = StringBuffer();
  var bytes = 0;
  for (final r in line.runes) {
    final ch = String.fromCharCode(r);
    final n = utf8.encode(ch).length;
    if (bytes + n > 74) {
      out.write('$cur\r\n');
      cur = StringBuffer(' ');
      bytes = 1;
    }
    cur.write(ch);
    bytes += n;
  }
  out.write('$cur\r\n');
}

/// Writes [events] (masters, exceptions, single events) as one VCALENDAR.
/// Cancelled events are left out.
String exportIcs(Iterable<CalEvent> events, {DateTime? nowUtc}) {
  final stamp = _dateTime((nowUtc ?? DateTime.now()).toUtc());
  final out = StringBuffer();
  _put(out, 'BEGIN:VCALENDAR');
  _put(out, 'VERSION:2.0');
  _put(out, 'PRODID:$_prodId');
  _put(out, 'CALSCALE:GREGORIAN');
  for (final e in events.where((e) => !e.cancelled)) {
    _put(out, 'BEGIN:VEVENT');
    _put(out, 'UID:${e.isException ? e.recurringEventId : e.id}');
    _put(out, 'DTSTAMP:${stamp}Z');
    if (e.allDay) {
      _put(out, 'DTSTART;VALUE=DATE:${_date(e.start)}');
      _put(out, 'DTEND;VALUE=DATE:${_date(e.end)}');
    } else {
      _put(out, 'DTSTART;TZID=${e.tzid}:${_dateTime(e.start)}');
      _put(out, 'DTEND;TZID=${e.tzid}:${_dateTime(e.end)}');
    }
    if (e.isException && e.originalStart != null) {
      final o = e.originalStart!;
      _put(
        out,
        e.allDay
            ? 'RECURRENCE-ID;VALUE=DATE:${_date(o)}'
            : 'RECURRENCE-ID;TZID=${e.tzid}:${_dateTime(o)}',
      );
    }
    _put(out, 'SUMMARY:${_esc(e.title)}');
    if (e.notes.isNotEmpty) _put(out, 'DESCRIPTION:${_esc(e.notes)}');
    if (e.location.isNotEmpty) _put(out, 'LOCATION:${_esc(e.location)}');
    if (e.isRecurring) {
      _put(out, 'RRULE:${e.rrule!.replaceFirst(RegExp('^RRULE:'), '')}');
    }
    for (final x in e.exdates) {
      _put(
        out,
        e.allDay
            ? 'EXDATE;VALUE=DATE:${_date(x)}'
            : 'EXDATE;TZID=${e.tzid}:${_dateTime(x)}',
      );
    }
    if (e.colorId != null) _put(out, 'X-NAPTAR-COLOR:${e.colorId}');
    if (e.aiGenerated) _put(out, 'X-NAPTAR-AI:1');
    if (e.isException) _put(out, 'X-NAPTAR-ID:${e.id}');
    _put(out, 'END:VEVENT');
  }
  _put(out, 'END:VCALENDAR');
  return out.toString();
}

class _Prop {
  _Prop(this.name, this.params, this.value);
  final String name;
  final Map<String, String> params;
  final String value;
}

_Prop? _parseLine(String line) {
  // name[;param=value]*:value  (quotes in params may hide ':')
  var inQuote = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') inQuote = !inQuote;
    if (c == ':' && !inQuote) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;
  final head = line.substring(0, colon).split(';');
  final params = <String, String>{};
  for (final p in head.skip(1)) {
    final i = p.indexOf('=');
    if (i > 0) {
      params[p.substring(0, i).toUpperCase()] = p
          .substring(i + 1)
          .replaceAll('"', '');
    }
  }
  return _Prop(head.first.toUpperCase(), params, line.substring(colon + 1));
}

/// "20260504", "20260504T090000" or with a trailing Z.
({DateTime value, bool dateOnly, bool utc})? _parseStamp(String v) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$')
      .firstMatch(v.trim());
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  final month = g(2), day = g(3);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return (
    value: DateTime.utc(g(1), month, day, g(4), g(5), g(6)),
    dateOnly: m.group(4) == null,
    utc: m.group(7) != null,
  );
}

class IcsImport {
  const IcsImport(this.events, this.problems);
  final List<CalEvent> events;
  final List<String> problems;
}

/// Reads VEVENTs from an iCalendar text. Never throws: unusable events are
/// skipped and explained in [IcsImport.problems]. Times without a zone and
/// UTC times become wall-clock times in [defaultTz].
IcsImport parseIcs(
  String text, {
  required String calendarId,
  String defaultTz = 'Europe/Budapest',
  int maxEvents = 5000,
}) {
  final problems = <String>[];
  final events = <CalEvent>[];
  final lines = <String>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && lines.isNotEmpty) {
      lines[lines.length - 1] += raw.substring(1);
    } else if (raw.isNotEmpty) {
      lines.add(raw);
    }
  }

  List<_Prop>? cur;
  var depth = 0; // nested components (VALARM...) inside a VEVENT
  for (final l in lines) {
    final p = _parseLine(l);
    if (p == null) continue;
    if (p.name == 'BEGIN' && p.value.toUpperCase() == 'VEVENT') {
      cur = [];
      depth = 0;
    } else if (cur != null && p.name == 'BEGIN') {
      depth++;
    } else if (cur != null && p.name == 'END') {
      if (depth > 0) {
        depth--;
      } else if (p.value.toUpperCase() == 'VEVENT') {
        if (events.length >= maxEvents) {
          problems.add(
            'Legfeljebb $maxEvents esemény olvasható be; a többit kihagytam.',
          );
          break;
        }
        final e = _toEvent(cur, calendarId, defaultTz, problems);
        if (e != null) events.add(e);
        cur = null;
      }
    } else if (cur != null && depth == 0) {
      cur.add(p);
    }
  }
  return IcsImport(events, problems);
}

CalEvent? _toEvent(
  List<_Prop> props,
  String calendarId,
  String defaultTz,
  List<String> problems,
) {
  _Prop? one(String n) => props.where((p) => p.name == n).firstOrNull;
  final title = _unesc(one('SUMMARY')?.value ?? '').trim();
  final label = title.isEmpty ? '(cím nélküli esemény)' : '„$title”';
  final ds = one('DTSTART');
  if (ds == null) {
    problems.add('$label: nincs kezdési időpont, kihagytam.');
    return null;
  }
  final s = _parseStamp(ds.value);
  if (s == null) {
    problems.add('$label: hibás kezdési időpont, kihagytam.');
    return null;
  }

  var tz = defaultTz;
  final given = ds.params['TZID'];
  if (given != null) {
    try {
      locationOf(given);
      tz = given;
    } catch (_) {
      problems.add(
        '$label: ismeretlen időzóna ($given), $defaultTz-t használom.',
      );
    }
  }
  final allDay = s.dateOnly || ds.params['VALUE'] == 'DATE';

  DateTime wall(_Prop p, ({DateTime value, bool dateOnly, bool utc}) st) =>
      st.utc && !allDay ? toWallClock(tz, st.value) : st.value;

  final start = allDay
      ? DateTime.utc(s.value.year, s.value.month, s.value.day)
      : wall(ds, s);

  DateTime end;
  final de = one('DTEND');
  final dur = one('DURATION');
  final es = de == null ? null : _parseStamp(de.value);
  if (es != null) {
    end = allDay
        ? DateTime.utc(es.value.year, es.value.month, es.value.day)
        : wall(de!, es);
  } else if (dur != null) {
    end = start.add(_duration(dur.value) ?? const Duration(hours: 1));
  } else {
    end = allDay
        ? start.add(const Duration(days: 1))
        : start.add(const Duration(hours: 1));
  }
  if (end.isBefore(start)) end = start;
  if (allDay && !end.isAfter(start)) end = start.add(const Duration(days: 1));

  final uid = one('UID')?.value.trim() ?? '';
  final rid = one('RECURRENCE-ID');
  DateTime? recurrenceWall;
  if (rid != null) {
    final r = _parseStamp(rid.value);
    if (r == null) {
      problems.add('$label: hibás ismétlődés-azonosító, kihagytam.');
      return null;
    }
    recurrenceWall = allDay
        ? DateTime.utc(r.value.year, r.value.month, r.value.day)
        : wall(rid, r);
  }
  if (rid != null && uid.isEmpty) {
    problems.add('$label: kivétel azonosító nélkül, kihagytam.');
    return null;
  }

  final exdates = <DateTime>[];
  for (final x in props.where((p) => p.name == 'EXDATE')) {
    for (final part in x.value.split(',')) {
      final st = _parseStamp(part);
      if (st == null) continue;
      exdates.add(
        allDay
            ? DateTime.utc(st.value.year, st.value.month, st.value.day)
            : wall(x, st),
      );
    }
  }
  final rr = one('RRULE')?.value.trim();

  final id = rid != null
      ? (one('X-NAPTAR-ID')?.value.trim().isNotEmpty ?? false)
            ? one('X-NAPTAR-ID')!.value.trim()
            : '$uid#${recurrenceWall!.toIso8601String()}'
      : (uid.isEmpty
            ? 'ics-${title.hashCode.toRadixString(16)}-${start.millisecondsSinceEpoch}'
            : uid);

  return CalEvent(
    id: id,
    calendarId: calendarId,
    title: title.isEmpty ? '(cím nélkül)' : title,
    notes: _unesc(one('DESCRIPTION')?.value ?? ''),
    location: _unesc(one('LOCATION')?.value ?? ''),
    start: start,
    end: end,
    tzid: allDay ? null : tz,
    allDay: allDay,
    rrule: rr == null || rr.isEmpty ? null : rr,
    exdates: exdates,
    recurringEventId: rid != null ? uid : null,
    originalStart: recurrenceWall,
    colorId: one('X-NAPTAR-COLOR')?.value.trim(),
    aiGenerated: one('X-NAPTAR-AI')?.value.trim() == '1',
  );
}

Duration? _duration(String v) {
  final m = RegExp(
    r'^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(v.trim());
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  return Duration(
    days: g(1) * 7 + g(2),
    hours: g(3),
    minutes: g(4),
    seconds: g(5),
  );
}
