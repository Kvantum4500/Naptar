import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_change.dart';
import '../data/event_repository.dart';
import 'event_editor.dart' show Scope;

/// Deletes one occurrence of an event: a single event goes away; for a series
/// [scope] decides whether only this day, this and the following days, or the
/// whole series is removed.
///
/// The editor and the assistant share this: it reads the event and its
/// exceptions fresh, changes everything in ONE transaction (a crash cannot
/// leave an EXDATE without the exception deleted), and describes the change so
/// it can be taken back ([EventRepository.undoChange]).
///
/// Returns null when the event no longer exists.
Future<EventChangeSet?> deleteEvent(
  EventRepository repo, {
  required String eventId,
  required DateTime originalStart,
  required bool recurring,
  required Scope scope,
}) async {
  final changes = await repo.atomically(() async {
    final e = await repo.byId(eventId);
    if (e == null || await repo.isTombstone(eventId)) {
      return const EventChangeSet();
    }
    if (!recurring && !e.isRecurring && !e.isException) {
      return repo.tracked(
        existing: [e.id],
        change: () => repo.deleteLocal(e.id),
      );
    }
    final master = e.isException ? await repo.byId(e.recurringEventId!) : e;
    if (master == null) {
      return repo.tracked(
        existing: [e.id],
        change: () => repo.deleteLocal(e.id),
      );
    }
    final overrides = await repo.overridesOf(master.id);
    final everything = [for (final x in overrides) x.id, master.id];
    return repo.tracked(
      existing: everything,
      change: () async {
        switch (scope) {
          case Scope.only:
            await repo.saveLocal(deleteInstance(master, originalStart));
            if (e.isException) await repo.deleteLocal(e.id);
          case Scope.following:
            final cut = deleteFollowing(master, originalStart);
            if (cut == null) {
              await repo.deleteAll(everything);
            } else {
              await repo.saveLocal(cut);
              await repo.deleteAll([
                for (final x in overrides)
                  if (x.originalStart != null &&
                      !x.originalStart!.isBefore(originalStart))
                    x.id,
              ]);
            }
          case Scope.all:
            await repo.deleteAll(everything);
        }
      },
    );
  });
  return changes.isEmpty ? null : changes;
}

/// [deleteEvent] for an occurrence as the calendar views and the assistant
/// know it. Returns false when the event no longer exists.
Future<bool> deleteOccurrence(
  EventRepository repo,
  Occurrence o,
  Scope scope,
) async =>
    await deleteEvent(
      repo,
      eventId: o.eventId,
      originalStart: o.originalStart,
      recurring: o.recurring,
      scope: scope,
    ) !=
    null;
