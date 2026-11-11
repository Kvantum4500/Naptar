import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_repository.dart';
import 'event_editor.dart' show Scope;

/// Deletes one occurrence of an event, the same way the editor does:
/// a single event goes away; for a series [scope] decides whether only this
/// day, this and the following days, or the whole series is removed.
/// Returns false when the event no longer exists.
Future<bool> deleteOccurrence(
  EventRepository repo,
  Occurrence o,
  Scope scope,
) async {
  final e = await repo.byId(o.eventId);
  if (e == null) return false;
  if (!o.recurring && !e.isRecurring && !e.isException) {
    await repo.deleteLocal(e.id);
    return true;
  }
  final master = e.isException ? await repo.byId(e.recurringEventId!) : e;
  if (master == null) {
    await repo.deleteLocal(e.id);
    return true;
  }
  final overrides = await repo.overridesOf(master.id);
  final orig = o.originalStart;

  Future<void> deleteSeries() =>
      repo.deleteAll([for (final x in overrides) x.id, master.id]);

  // All or nothing, and one change for the screens.
  await repo.atomically(() async {
    switch (scope) {
      case Scope.only:
        await repo.saveLocal(deleteInstance(master, orig));
        if (e.isException) await repo.deleteLocal(e.id);
      case Scope.following:
        final cut = deleteFollowing(master, orig);
        if (cut == null) {
          await deleteSeries();
        } else {
          await repo.saveLocal(cut);
          await repo.deleteAll([
            for (final x in overrides)
              if (x.originalStart != null && !x.originalStart!.isBefore(orig))
                x.id,
          ]);
        }
      case Scope.all:
        await deleteSeries();
    }
  });
  return true;
}
