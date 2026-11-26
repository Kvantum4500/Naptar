import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_change.dart';
import '../data/event_repository.dart';

/// Moves ONE occurrence to a new local wall-clock time, the way the editor's
/// "only this event" does: a single event is changed in place; for a series
/// only that day is overridden (or the existing exception is updated).
///
/// It runs as one unit and describes what it changed, so it can be taken back
/// with "Visszavonás" ([EventRepository.undoChange]): the old times of a single
/// event, or the exception row that was created for one day of a series.
///
/// Returns null when the event no longer exists. That includes an event that
/// was deleted but whose deletion has not been uploaded yet: `byId` still
/// finds it, and saving it would bring it back to life.
Future<EventChangeSet?> moveOccurrence(
  EventRepository repo,
  Occurrence o,
  DateTime newStart,
  DateTime newEnd,
) => repo.atomically(() async {
  final e = await repo.byId(o.eventId);
  if (e == null || await repo.isTombstone(o.eventId)) return null;
  final moved = e.copyWith(start: newStart, end: newEnd);
  if (e.isException || (!o.recurring && !e.isRecurring)) {
    return repo.tracked(existing: [e.id], change: () => repo.saveLocal(moved));
  }
  // one day of a series: an exception row of its own, with a new id
  final newId = const Uuid().v4();
  return repo.tracked(
    existing: const [],
    created: [newId],
    change: () => repo.saveLocal(
      makeOverride(
        master: e,
        originalStart: o.originalStart,
        edited: moved,
        newId: newId,
      ),
    ),
  );
});
