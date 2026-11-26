// The expansion as it was before the optimisation (REL-20): the reference the
// faster one must agree with. Kept verbatim on purpose, including the parse
// without any cache; do not "improve" it.
import 'package:kvantum_core/kvantum_core.dart';
import 'package:rrule/rrule.dart';

const _maxIterations = 20000;

RecurrenceRule referenceParse(String rule) {
  var s = rule.trim();
  if (s.startsWith('RRULE:')) s = s.substring('RRULE:'.length);
  final parts = s.split(';').where((p) {
    final u = p.trim().toUpperCase();
    return !(u.startsWith('WKST=') && u != 'WKST=MO');
  });
  return RecurrenceRule.fromString('RRULE:${parts.join(';')}');
}

List<Occurrence> referenceExpand(
  CalEvent master,
  DateTime from,
  DateTime to, {
  List<CalEvent> overrides = const [],
}) {
  if (master.cancelled) return const [];
  assert(from.isUtc && to.isUtc);
  final byOriginal = <DateTime, CalEvent>{
    for (final o in overrides)
      if (o.originalStart != null) o.originalStart!: o,
  };
  final exdates = master.exdates.toSet();
  final out = <Occurrence>[];

  Occurrence build(
    CalEvent e,
    DateTime wallStart,
    DateTime original, {
    required bool isOverride,
  }) {
    if (master.allDay && !isOverride) {
      final days = master.end.difference(master.start);
      return Occurrence(
        eventId: e.id,
        title: e.title,
        startUtc: wallStart,
        endUtc: wallStart.add(days),
        originalStart: original,
        allDay: true,
        colorId: e.colorId,
        recurring: master.isRecurring,
        isShift: isShiftNotes(e.notes),
        aiGenerated: e.aiGenerated,
      );
    }
    if (isOverride) {
      return Occurrence(
        eventId: e.id,
        title: e.title,
        startUtc: e.startUtc,
        endUtc: e.endUtc,
        originalStart: original,
        allDay: e.allDay,
        tzid: e.tzid,
        isOverride: true,
        colorId: e.colorId,
        recurring: true,
        isShift: isShiftNotes(e.notes),
        aiGenerated: e.aiGenerated,
      );
    }
    final s = resolveWallClock(master.tzid!, wallStart);
    final duration = master.endUtc.difference(master.startUtc);
    return Occurrence(
      eventId: e.id,
      title: e.title,
      startUtc: s,
      endUtc: s.add(duration),
      originalStart: original,
      allDay: false,
      tzid: master.tzid,
      colorId: e.colorId,
      recurring: master.isRecurring,
      isShift: isShiftNotes(e.notes),
      aiGenerated: e.aiGenerated,
    );
  }

  if (!master.isRecurring) {
    final o = build(master, master.start, master.start, isOverride: false);
    return o.overlaps(from, to) ? [o] : const [];
  }

  // +-1 day slack covers every zone offset between wall-clock and UTC.
  final limit = to.add(const Duration(days: 2));
  var n = 0;
  for (final wall in referenceParse(
    master.rrule!,
  ).getInstances(start: master.start)) {
    if (wall.isAfter(limit) || ++n > _maxIterations) break;
    if (exdates.contains(wall)) continue;
    final override = byOriginal[wall];
    if (override != null) {
      if (override.cancelled) continue;
      final o = build(override, wall, wall, isOverride: true);
      if (o.overlaps(from, to)) out.add(o);
      continue;
    }
    final o = build(master, wall, wall, isOverride: false);
    if (o.overlaps(from, to)) out.add(o);
  }
  // Overrides moved INTO the window from an original date outside the scan.
  for (final o in overrides) {
    if (o.cancelled || o.originalStart == null) continue;
    if (out.any((x) => x.originalStart == o.originalStart)) continue;
    if (o.originalStart!.isAfter(limit)) {
      final occ = build(
        o,
        o.originalStart!,
        o.originalStart!,
        isOverride: true,
      );
      if (occ.overlaps(from, to)) out.add(occ);
    }
  }
  out.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  return out;
}
