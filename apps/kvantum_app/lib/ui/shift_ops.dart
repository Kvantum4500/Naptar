import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';

const kNightTitle = 'Éjszakai műszak';
const kDayTitle = 'Nappali műszak';

/// The shift hours currently set on the Beosztás page (minutes after midnight
/// and length in minutes).
class ShiftHours {
  const ShiftHours({
    this.nightStart = 18 * 60,
    this.nightMinutes = 12 * 60,
    this.dayStart = 6 * 60,
    this.dayMinutes = 12 * 60,
  });
  final int nightStart;
  final int nightMinutes;
  final int dayStart;
  final int dayMinutes;
}

bool _isNight(CalEvent e) => e.title == kNightTitle;
bool _isKnown(CalEvent e) => e.title == kNightTitle || e.title == kDayTitle;

DateTime _at(DateTime wall, int minutes) => DateTime.utc(
  wall.year,
  wall.month,
  wall.day,
).add(Duration(minutes: minutes));

/// Day shift <-> night shift on the same start day, with the hours currently
/// set on the page. The shift is marked as modified, so regenerating keeps it.
/// Returns false for events that are not a known shift type.
Future<bool> swapShiftType(
  EventRepository repo,
  CalEvent e,
  ShiftHours h,
) async {
  if (!isShiftNotes(e.notes) || !_isKnown(e)) return false;
  final toNight = !_isNight(e);
  final start = _at(e.start, toNight ? h.nightStart : h.dayStart);
  final end = start.add(
    Duration(minutes: toNight ? h.nightMinutes : h.dayMinutes),
  );
  await repo.saveLocal(
    e.copyWith(
      title: toNight ? kNightTitle : kDayTitle,
      start: start,
      end: end,
      notes: kShiftEditedMarker,
    ),
  );
  return true;
}

/// One extra shift (e.g. overtime or a swap with a colleague), marked as
/// modified so regenerating keeps it.
Future<CalEvent> addExtraShift(
  EventRepository repo,
  DateTime day, {
  required bool night,
  required ShiftHours hours,
  required String tzid,
}) async {
  final start = _at(day, night ? hours.nightStart : hours.dayStart);
  final e = CalEvent(
    id: const Uuid().v4(),
    calendarId: kNaptarCalendar,
    title: night ? kNightTitle : kDayTitle,
    notes: kShiftEditedMarker,
    start: start,
    end: start.add(
      Duration(minutes: night ? hours.nightMinutes : hours.dayMinutes),
    ),
    tzid: tzid,
  );
  await repo.saveLocal(e);
  return e;
}
