import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';

/// Moves ONE occurrence to a new local wall-clock time, the way the editor's
/// "only this event" does: a single event is changed in place; for a series
/// only that day is overridden (or the existing exception is updated).
/// Returns false when the event no longer exists.
Future<bool> moveOccurrence(
  EventRepository repo,
  Occurrence o,
  DateTime newStart,
  DateTime newEnd,
) async {
  final e = await repo.byId(o.eventId);
  if (e == null) return false;
  if (!o.recurring && !e.isRecurring && !e.isException) {
    await repo.saveLocal(e.copyWith(start: newStart, end: newEnd));
    return true;
  }
  if (e.isException) {
    await repo.saveLocal(e.copyWith(start: newStart, end: newEnd));
    return true;
  }
  final master = e;
  await repo.saveLocal(
    makeOverride(
      master: master,
      originalStart: o.originalStart,
      edited: master.copyWith(start: newStart, end: newEnd),
      newId: const Uuid().v4(),
    ),
  );
  return true;
}
