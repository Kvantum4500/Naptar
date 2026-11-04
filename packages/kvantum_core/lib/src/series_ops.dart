import 'event.dart';
import 'recurrence.dart';

/// Result of "this and following" edits.
class SplitResult {
  const SplitResult({
    required this.truncated,
    required this.newSeries,
    required this.droppedOverrides,
  });

  /// The old series ended right before the split; null when the split point
  /// is the very first instance (the whole series is simply replaced).
  final CalEvent? truncated;

  /// The new series starting at the split point (carries the edits).
  final CalEvent newSeries;

  /// Exception instances at/after the split point; they belonged to the old
  /// series tail and must be removed by the caller.
  final List<CalEvent> droppedOverrides;
}

/// "Only this instance": the exception event that overrides one occurrence.
CalEvent makeOverride({
  required CalEvent master,
  required DateTime originalStart,
  required CalEvent edited,
  required String newId,
}) => CalEvent(
  id: newId,
  calendarId: master.calendarId,
  title: edited.title,
  notes: edited.notes,
  location: edited.location,
  start: edited.start,
  end: edited.end,
  tzid: master.tzid,
  allDay: master.allDay,
  recurringEventId: master.id,
  originalStart: originalStart,
  colorId: edited.colorId,
);

/// "Only this instance" delete: the master gets an EXDATE.
CalEvent deleteInstance(CalEvent master, DateTime originalStart) {
  if (master.exdates.contains(originalStart)) return master;
  return master.copyWith(exdates: [...master.exdates, originalStart]);
}

/// "This and following" delete: the series ends before [splitAt]. Null means
/// the first instance was chosen, i.e. the whole series should be deleted.
CalEvent? deleteFollowing(CalEvent master, DateTime splitAt) {
  final cut = truncateSeries(master, splitAt);
  if (cut == null) return null;
  return cut.copyWith(
    exdates: [
      for (final x in master.exdates)
        if (x.isBefore(splitAt)) x,
    ],
  );
}

/// "This and following" edit. [edited] carries the new title/time/rule for the
/// part of the series from [splitAt] on; [newId] is the id for the new series.
SplitResult splitSeries({
  required CalEvent master,
  required DateTime splitAt,
  required CalEvent edited,
  required String newId,
  List<CalEvent> overrides = const [],
}) {
  final rule = parseRule(master.rrule!);
  final before = rule
      .getInstances(start: master.start)
      .takeWhile((d) => d.isBefore(splitAt))
      .length;

  var newRrule = edited.rrule ?? master.rrule!;
  // Same rule as before with a COUNT: only the remaining alkalmak continue.
  if (rule.count != null && newRrule == master.rrule) {
    final remaining = (rule.count! - before).clamp(1, rule.count!);
    newRrule = newRrule.replaceAll(RegExp(r'COUNT=\d+'), 'COUNT=$remaining');
  }

  final shift = edited.start.difference(splitAt);
  final newSeries = CalEvent(
    id: newId,
    calendarId: master.calendarId,
    title: edited.title,
    notes: edited.notes,
    location: edited.location,
    start: edited.start,
    end: edited.end,
    tzid: master.tzid,
    allDay: master.allDay,
    rrule: newRrule,
    exdates: [
      for (final x in master.exdates)
        if (!x.isBefore(splitAt)) x.add(shift),
    ],
    colorId: edited.colorId,
  );

  final truncated = before == 0 ? null : deleteFollowing(master, splitAt);
  return SplitResult(
    truncated: truncated,
    newSeries: newSeries,
    droppedOverrides: [
      for (final o in overrides)
        if (o.originalStart != null && !o.originalStart!.isBefore(splitAt)) o,
    ],
  );
}

/// "All events": applies [edited] to the master and keeps exceptions/EXDATEs
/// attached by shifting their original start times with the series.
({CalEvent master, List<CalEvent> overrides}) editAll({
  required CalEvent master,
  required CalEvent edited,
  List<CalEvent> overrides = const [],
}) {
  final shift = edited.start.difference(master.start);
  final newMaster = master.copyWith(
    title: edited.title,
    notes: edited.notes,
    location: edited.location,
    start: edited.start,
    end: edited.end,
    allDay: edited.allDay,
    rrule: edited.rrule,
    clearRrule: edited.rrule == null,
    exdates: [for (final x in master.exdates) x.add(shift)],
    colorId: edited.colorId,
    clearColor: edited.colorId == null,
  );
  final moved = shift == Duration.zero
      ? overrides
      : [
          for (final o in overrides)
            o.copyWith(
              originalStart: o.originalStart?.add(shift),
              recurringEventId: master.id,
            ),
        ];
  return (master: newMaster, overrides: moved);
}
