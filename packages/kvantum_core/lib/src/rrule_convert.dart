import 'recurrence.dart';
import 'time.dart';

final _until = RegExp(r'UNTIL=(\d{8})(?:T(\d{6})Z?)?');

String _p2(int n) => n.toString().padLeft(2, '0');
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${_p2(d.month)}${_p2(d.day)}';
String _hms(DateTime d) => '${_p2(d.hour)}${_p2(d.minute)}${_p2(d.second)}';

DateTime _parseUntil(String ymd, String? hms) => DateTime.utc(
  int.parse(ymd.substring(0, 4)),
  int.parse(ymd.substring(4, 6)),
  int.parse(ymd.substring(6, 8)),
  hms == null ? 23 : int.parse(hms.substring(0, 2)),
  hms == null ? 59 : int.parse(hms.substring(2, 4)),
  hms == null ? 59 : int.parse(hms.substring(4, 6)),
);

/// Google / iCalendar -> local. The UNTIL of both is a UTC instant (timed) or
/// a date (all-day). Locally UNTIL is a FLOATING wall-clock limit (the day on which
/// an occurrence may still start), which is what the recurrence engine and
/// the rule editor work with.
String rruleFromGoogle(String rule, String? tzid, {required bool allDay}) {
  return rule.replaceAllMapped(_until, (m) {
    final ymd = m[1]!;
    final hms = m[2];
    if (hms == null || allDay || tzid == null) {
      // Date-only (or all-day): the whole day counts.
      return 'UNTIL=${ymd}T235959Z';
    }
    final wall = toWallClock(tzid, _parseUntil(ymd, hms));
    return 'UNTIL=${_ymd(wall)}T${_hms(wall)}Z';
  });
}

/// Local -> Google / iCalendar. For timed events the floating UNTIL is replaced by the UTC
/// instant of the LAST occurrence that is allowed, so a zone offset can never
/// let one extra occurrence slip in or out. All-day rules use the date form.
String rruleToGoogle(
  String rule,
  DateTime start,
  String? tzid, {
  required bool allDay,
}) {
  final m = _until.firstMatch(rule);
  if (m == null) return rule;
  final limit = _parseUntil(m[1]!, m[2]);
  if (allDay || tzid == null) {
    return rule.replaceFirst(_until, 'UNTIL=${_ymd(limit)}');
  }
  DateTime? last;
  var n = 0;
  for (final d in parseRule(rule).getInstances(start: start)) {
    if (d.isAfter(limit) || ++n > 20000) break;
    last = d;
  }
  final instant = resolveWallClock(tzid, last ?? start);
  return rule.replaceFirst(_until, 'UNTIL=${_ymd(instant)}T${_hms(instant)}Z');
}
