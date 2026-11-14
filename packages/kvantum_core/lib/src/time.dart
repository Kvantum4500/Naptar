import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

export 'package:timezone/timezone.dart' show Location, TZDateTime;

bool _initialized = false;

/// Loads the IANA tz database once. Call before any zone-aware work.
void ensureTimeZones() {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  _initialized = true;
}

tz.Location locationOf(String tzid) {
  ensureTimeZones();
  return tz.getLocation(tzid);
}

/// Windows zone names (what Outlook writes in a `TZID`) and the IANA zone that
/// stands for each (the first, "primary" zone of Unicode CLDR's `windowsZones`).
/// The cities of one Windows zone change to summer time on the same day, so
/// which of them is named does not matter for the instants.
const Map<String, String> windowsZoneNames = {
  'UTC': 'UTC',
  'GMT Standard Time': 'Europe/London',
  'Greenwich Standard Time': 'Atlantic/Reykjavik',
  'W. Europe Standard Time': 'Europe/Berlin',
  'Central Europe Standard Time': 'Europe/Budapest',
  'Central European Standard Time': 'Europe/Warsaw',
  'Romance Standard Time': 'Europe/Paris',
  'E. Europe Standard Time': 'Europe/Chisinau',
  'FLE Standard Time': 'Europe/Kyiv',
  'GTB Standard Time': 'Europe/Bucharest',
  'Turkey Standard Time': 'Europe/Istanbul',
  'Russian Standard Time': 'Europe/Moscow',
  'Eastern Standard Time': 'America/New_York',
  'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver',
  'Pacific Standard Time': 'America/Los_Angeles',
};

final Map<String, String> _windowsByLowerName = {
  for (final e in windowsZoneNames.entries) e.key.toLowerCase(): e.value,
};

/// The IANA zone a `TZID` of a calendar file stands for, or null when it is
/// not a zone this app knows. Understood: an IANA name; a Windows name (any
/// case); an IANA name behind a path, as Thunderbird and Evolution write it
/// (`/mozilla.org/20070129_1/Europe/Berlin`).
String? ianaZoneOf(String tzid) {
  final name = tzid.trim();
  bool known(String zone) {
    try {
      locationOf(zone);
      return true;
    } catch (_) {
      return false;
    }
  }

  if (known(name)) return name;
  final windows = _windowsByLowerName[name.toLowerCase()];
  if (windows != null && known(windows)) return windows;
  final parts = name.split('/').where((p) => p.isNotEmpty).toList();
  for (final n in const [3, 2]) {
    if (parts.length >= n) {
      final tail = parts.sublist(parts.length - n).join('/');
      if (known(tail)) return tail;
    }
  }
  return null;
}

/// A wall-clock time ("floating", no zone) is represented as a UTC-flagged
/// [DateTime] whose fields are the wall-clock fields. This is also what the
/// `rrule` package expects, so recurrence math never sees DST.
DateTime floating(int y, int m, int d, [int h = 0, int mi = 0, int s = 0]) =>
    DateTime.utc(y, m, d, h, mi, s);

/// Resolves a floating wall-clock time in [tzid] to a real instant (UTC).
///
/// DST policy (documented, deterministic):
///  * Spring gap (time does not exist, e.g. 02:30 on 2026-03-29 Budapest):
///    shifted forward by the gap length (-> 03:30).
///  * Autumn overlap (time exists twice, e.g. 02:30 on 2026-10-25):
///    the first occurrence (still summer time) is used.
DateTime resolveWallClock(String tzid, DateTime wall) {
  final loc = locationOf(tzid);
  final t = tz.TZDateTime(
    loc,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
  );
  final sameWall = _wallEquals(t, wall);
  if (!sameWall) {
    // Gap: the package already normalised it; verify it moved forward.
    return t.toUtc();
  }
  // Overlap check: the instant one hour/offset-diff earlier may show the same
  // wall time. Prefer the earlier instant.
  for (final back in const [Duration(hours: 1), Duration(minutes: 30)]) {
    final earlier = t.subtract(back);
    if (_wallEquals(tz.TZDateTime.from(earlier, loc), wall)) {
      return earlier.toUtc();
    }
  }
  return t.toUtc();
}

bool _wallEquals(DateTime a, DateTime wall) =>
    a.year == wall.year &&
    a.month == wall.month &&
    a.day == wall.day &&
    a.hour == wall.hour &&
    a.minute == wall.minute &&
    a.second == wall.second;

/// Converts an instant to the floating wall-clock in [tzid].
DateTime toWallClock(String tzid, DateTime instant) {
  final t = tz.TZDateTime.from(instant, locationOf(tzid));
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// Length of the calendar day [date] (floating y/m/d) in [tzid]: 23, 24 or 25 h.
Duration dayLength(String tzid, DateTime date) {
  final start = resolveWallClock(
    tzid,
    floating(date.year, date.month, date.day),
  );
  final next = date.add(const Duration(days: 1));
  final end = resolveWallClock(tzid, floating(next.year, next.month, next.day));
  return end.difference(start);
}
