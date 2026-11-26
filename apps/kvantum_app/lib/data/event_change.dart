import 'dart:math' show max;

import 'package:drift/drift.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'db.dart';
import 'event_repository.dart';

/// What a row of the event table is, as far as taking a change back goes.
enum RowState {
  /// There is no such row (never existed, was removed, or was never uploaded
  /// and then deleted).
  gone,

  /// A deleted event whose deletion has not been uploaded yet.
  tombstone,

  /// A normal event.
  live,
}

/// A row's state and version: enough to see whether anything touched it since.
class RowSig {
  const RowSig(this.state, this.version);
  final RowState state;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is RowSig && other.state == state && other.version == version;

  @override
  int get hashCode => Object.hash(state, version);

  @override
  String toString() => '${state.name}@$version';
}

/// A change made to the events as ONE unit, with what is needed to take it
/// back ("Visszavonás").
class EventChangeSet {
  const EventChangeSet({
    this.before = const [],
    this.created = const {},
    this.after = const {},
  });

  /// The rows the change removed or rewrote, as they were BEFORE it. A series
  /// master comes before its exceptions, so they can be put back in that order.
  final List<CalEvent> before;

  /// Ids that did not exist before the change.
  final Set<String> created;

  /// Every touched row right after the change.
  final Map<String, RowSig> after;

  /// Nothing was changed.
  bool get isEmpty => before.isEmpty && created.isEmpty;

  /// Every id the change touched.
  Set<String> get ids => {for (final e in before) e.id, ...created};

  /// This change followed by [later] (e.g. two deletions of one series in one
  /// batch): taking the result back undoes both. A row keeps its EARLIEST
  /// image and its LATEST signature.
  EventChangeSet merge(EventChangeSet later) {
    final seen = {for (final e in before) e.id};
    return EventChangeSet(
      before: _mastersFirst([
        ...before,
        for (final e in later.before)
          if (!seen.contains(e.id)) e,
      ]),
      created: {...created, ...later.created},
      after: {...after, ...later.after},
    );
  }
}

/// Whether a row is still as the change left it. A deletion that has been
/// uploaded meanwhile (the tombstone is gone) is not an edit by anybody: it is
/// just the end of the upload, so taking the change back is still possible.
bool _unchanged(RowSig now, RowSig then) =>
    now == then ||
    (then.state == RowState.tombstone && now.state == RowState.gone);

List<CalEvent> _mastersFirst(List<CalEvent> rows) => [
  ...rows.where((e) => e.recurringEventId == null),
  ...rows.where((e) => e.recurringEventId != null),
];

/// Undo support for the event store, built on its public API.
extension EventChanges on EventRepository {
  /// The state and version of one row right now.
  Future<RowSig> signatureOf(String id) async {
    final r = await (db.select(
      db.eventRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return const RowSig(RowState.gone, 0);
    return RowSig(r.deleted ? RowState.tombstone : RowState.live, r.version);
  }

  /// Runs [change] as one unit and describes it: the rows in [existing] as
  /// they were before, the ids in [created] (they did not exist), and the
  /// state every touched row is in afterwards. The images are read inside the
  /// same transaction, so they are exactly what the change replaced.
  Future<EventChangeSet> tracked({
    required Iterable<String> existing,
    Iterable<String> created = const [],
    required Future<void> Function() change,
  }) => db.transaction(() async {
    final before = <CalEvent>[];
    for (final id in {...existing}) {
      // already deleted: nothing to bring back
      if (await isTombstone(id)) continue;
      final e = await byId(id);
      if (e != null) before.add(e);
    }
    await change();
    final ids = {for (final e in before) e.id, ...created};
    return EventChangeSet(
      before: _mastersFirst(before),
      created: {...created},
      after: {for (final id in ids) id: await signatureOf(id)},
    );
  });

  /// Takes [set] back, but only if nothing touched its rows since (all or
  /// nothing: otherwise it would overwrite somebody's newer edit). Returns
  /// whether it did.
  ///
  /// The new events go away again; the removed or rewritten ones come back,
  /// the series master first, with a higher version so the screens refresh.
  /// A row whose deletion was already uploaded (it is gone) comes back WITHOUT
  /// the old links to Google: those events no longer exist there, so the next
  /// upload creates it again.
  Future<bool> undoChange(EventChangeSet set) => db.transaction(() async {
    for (final e in set.after.entries) {
      if (!_unchanged(await signatureOf(e.key), e.value)) return false;
    }
    for (final id in set.created) {
      await deleteLocal(id);
    }
    for (final image in set.before) {
      final stored = await byId(image.id);
      await saveLocal(
        image.copyWith(version: max(stored?.version ?? 0, image.version) + 1),
      );
      if (stored == null) await clearLinks([image.id]);
    }
    return true;
  });

  /// What to hold back from the upload for these events: the master of the
  /// series for an exception (the hold on a master covers all its exceptions),
  /// the event itself otherwise.
  Future<Set<String>> seriesKeysOf(Iterable<String> ids) async {
    final keys = <String>{};
    for (final id in ids) {
      keys.add((await byId(id))?.recurringEventId ?? id);
    }
    return keys;
  }

  /// Cuts the link to Google of these events (id, etag, iCalUID); the next
  /// upload creates them again.
  Future<void> clearLinks(Iterable<String> ids) =>
      (db.update(db.eventRows)..where((t) => t.id.isIn(ids.toList()))).write(
        const EventRowsCompanion(
          googleId: Value(null),
          etag: Value(null),
          iCalUid: Value(null),
        ),
      );
}
