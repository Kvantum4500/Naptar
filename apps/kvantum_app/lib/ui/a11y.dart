import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'day_utils.dart';
import 'format.dart';

// How things are read aloud by a screen reader: whole words, whole dates and
// times, one sentence per thing. What a sighted user reads off a colour, a
// position or an icon is put into words here.

/// "péntek, 2026. november 13."
String spokenDay(DateTime d) =>
    '${DateFormat('EEEE', 'hu').format(DateTime(d.year, d.month, d.day))}, '
    '${fmtDate(d)}';

/// "nincs esemény", "1 esemény", "3 esemény".
String spokenCount(int n) => n == 0 ? 'nincs esemény' : '$n esemény';

/// A day cell of the month grid: the weekday and date, how many events, a
/// holiday or a moved working day, and whether it is today or belongs to
/// another month than the one on show.
String spokenCell({
  required DateTime day,
  required int events,
  required bool today,
  required bool inMonth,
  HuDay? special,
}) => [
  spokenDay(day),
  spokenCount(events),
  if (special != null) special.label,
  if (today) 'ma',
  if (!inMonth) 'másik hónap',
].join(', ');

/// How an event is read on [day]: "Edzés, 09:00–10:30" (or "egész nap"; "tart
/// tovább" for a day it only continues on).
String spokenEvent(Occurrence o, DateTime day, {bool withDay = false}) {
  final title = o.title.isEmpty ? '(nincs cím)' : o.title;
  final String when;
  if (o.allDay) {
    when = 'egész nap';
  } else {
    final tz = o.tzid ?? defaultTz;
    final s = toWallClock(tz, o.startUtc), e = toWallClock(tz, o.endUtc);
    when = dateOnly(s) == day
        ? '${fmtTime(s)}–${fmtTime(e)}'
        : 'tart tovább, ${fmtTime(e)}-ig';
  }
  return [title, if (withDay) spokenDay(day), when].join(', ');
}

/// A budget row as one sentence: "Élelmiszer: 3 000 Ft a 10 000 Ft keretből
/// (30%), Maradt: 7 000 Ft" ([hint] is the line under the bar).
String spokenBudget(BudgetStatus b, String name, String hint) =>
    '$name: ${formatHuf(b.spent)} a ${formatHuf(b.limit)} keretből '
    '(${(b.ratio * 100).round()}%), $hint';

/// A row of spending that has no budget: "Közlekedés: 4 500 Ft, a kiadások
/// 20%-a" ([share] is 0…1).
String spokenShare(String name, int amount, double share) =>
    '$name: ${formatHuf(amount)}, a kiadások ${(share * 100).round()}%-a';
