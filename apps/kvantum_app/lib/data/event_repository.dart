import 'package:drift/drift.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'db.dart';

String _wall(DateTime d) =>
    d.toIso8601String().replaceAll('Z', '').split('.').first;
DateTime _parseWall(String s) => DateTime.parse('${s}Z');

/// Local (logical) id of the app's own Google calendar. The Google adapter
/// maps it to the real calendar id, so offline-created events do not depend
/// on the account.
const kNaptarCalendar = 'naptar';

CalEvent _fromRow(EventRow r) => CalEvent(
  id: r.id,
  calendarId: r.calendarId,
  title: r.title,
  notes: r.notes,
  location: r.location,
  start: _parseWall(r.startWall),
  end: _parseWall(r.endWall),
  tzid: r.tzid,
  allDay: r.allDay,
  rrule: r.rrule,
  exdates: r.exdates.isEmpty
      ? const []
      : r.exdates.split(',').map(_parseWall).toList(),
  recurringEventId: r.recurringEventId,
  originalStart: r.originalStart == null ? null : _parseWall(r.originalStart!),
  cancelled: r.cancelled,
  version: r.version,
  googleId: r.googleId,
  etag: r.etag,
  iCalUid: r.iCalUid,
  colorId: r.colorId,
  aiGenerated: r.aiGenerated,
);

EventRowsCompanion _toRow(CalEvent e, {bool deleted = false}) =>
    EventRowsCompanion(
      id: Value(e.id),
      calendarId: Value(e.calendarId),
      title: Value(e.title),
      notes: Value(e.notes),
      location: Value(e.location),
      startWall: Value(_wall(e.start)),
      endWall: Value(_wall(e.end)),
      tzid: Value(e.tzid),
      allDay: Value(e.allDay),
      rrule: Value(e.rrule),
      exdates: Value(e.exdates.map(_wall).join(',')),
      recurringEventId: Value(e.recurringEventId),
      originalStart: Value(
        e.originalStart == null ? null : _wall(e.originalStart!),
      ),
      cancelled: Value(e.cancelled),
      version: Value(e.version),
      googleId: Value(e.googleId),
      etag: Value(e.etag),
      iCalUid: Value(e.iCalUid),
      colorId: Value(e.colorId),
      aiGenerated: Value(e.aiGenerated),
      deleted: Value(deleted),
    );

class OutboxItem {
  const OutboxItem(
    this.seq,
    this.event,
    this.op,
    this.attempts, [
    this.lastError,
  ]);
  final int seq;
  final CalEvent event;
  final String op; // upsert | delete
  final int attempts;

  /// Why the last try did not go through (null: it has not been tried or the
  /// reason was only that the network / a limit made it wait).
  final String? lastError;
}

class EventRepository {
  EventRepository(this.db);
  final AppDatabase db;

  Future<List<CalEvent>> all() async {
    final rows = await (db.select(
      db.eventRows,
    )..where((t) => t.deleted.equals(false))).get();
    return rows.map(_fromRow).toList();
  }

  Stream<List<CalEvent>> watchAll() =>
      (db.select(db.eventRows)..where((t) => t.deleted.equals(false)))
          .watch()
          .map((rows) => rows.map(_fromRow).toList());

  /// Exception instances belonging to a series master.
  Future<List<CalEvent>> overridesOf(String masterId) async {
    final rows =
        await (db.select(db.eventRows)..where(
              (t) =>
                  t.recurringEventId.equals(masterId) & t.deleted.equals(false),
            ))
            .get();
    return rows.map(_fromRow).toList();
  }

  Future<CalEvent?> byId(String id) async {
    final r = await (db.select(
      db.eventRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _fromRow(r);
  }

  /// Runs [action] as one unit: nothing else reads or writes in between.
  Future<T> atomically<T>(Future<T> Function() action) =>
      db.transaction(action);

  /// Local edit: persists the event and queues ONE pending upsert per event
  /// (later edits replace the earlier queued op instead of piling up).
  ///
  /// The link to Google (id, etag, iCalUID) is written only by the sync. An
  /// editor works on a snapshot taken when it was opened; if the sync updated
  /// the event meanwhile, saving that snapshot would put an old etag back and
  /// every later upload would be refused as outdated. So the stored values win.
  Future<void> saveLocal(CalEvent e) => db.transaction(() async {
    final stored = await byId(e.id);
    final keep = stored == null
        ? e
        : e.copyWith(
            googleId: stored.googleId ?? e.googleId,
            etag: stored.etag ?? e.etag,
            iCalUid: stored.iCalUid ?? e.iCalUid,
            bumpVersion: false,
          );
    await db.into(db.eventRows).insertOnConflictUpdate(_toRow(keep));
    await _queue(e.id, 'upsert');
  });

  /// Several local edits at once: one transaction, one change notification.
  Future<void> saveAll(Iterable<CalEvent> events) => db.transaction(() async {
    for (final e in events) {
      await saveLocal(e);
    }
  });

  /// Several local deletions at once (see [deleteLocal]).
  Future<void> deleteAll(Iterable<String> ids) => db.transaction(() async {
    for (final id in ids) {
      await deleteLocal(id);
    }
  });

  /// Local delete: tombstone so the delete can still be pushed (and survive
  /// offline restarts). Never-synced events are simply removed.
  Future<void> deleteLocal(String id) => db.transaction(() async {
    final e = await byId(id);
    if (e == null) return;
    await (db.delete(db.outboxRows)..where((t) => t.eventId.equals(id))).go();
    if (e.googleId == null) {
      await (db.delete(db.eventRows)..where((t) => t.id.equals(id))).go();
      return;
    }
    await db
        .into(db.eventRows)
        .insertOnConflictUpdate(_toRow(e, deleted: true));
    await db
        .into(db.outboxRows)
        .insert(OutboxRowsCompanion.insert(eventId: id, op: 'delete'));
  });

  /// Applies a remote change WITHOUT queuing anything back (no echo loop).
  Future<void> saveFromRemote(CalEvent e) =>
      db.into(db.eventRows).insertOnConflictUpdate(_toRow(e));

  Future<void> removeFromRemote(String id) => db.transaction(() async {
    await (db.delete(db.eventRows)..where((t) => t.id.equals(id))).go();
    await (db.delete(db.outboxRows)..where((t) => t.eventId.equals(id))).go();
  });

  Future<void> _queue(String eventId, String op) async {
    await (db.delete(
      db.outboxRows,
    )..where((t) => t.eventId.equals(eventId))).go();
    await db
        .into(db.outboxRows)
        .insert(OutboxRowsCompanion.insert(eventId: eventId, op: op));
  }

  Future<List<OutboxItem>> pending() async {
    final rows = await (db.select(
      db.outboxRows,
    )..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();
    final out = <OutboxItem>[];
    for (final r in rows) {
      final ev = await (db.select(
        db.eventRows,
      )..where((t) => t.id.equals(r.eventId))).getSingleOrNull();
      if (ev == null) {
        await (db.delete(
          db.outboxRows,
        )..where((t) => t.seq.equals(r.seq))).go();
        continue;
      }
      out.add(OutboxItem(r.seq, _fromRow(ev), r.op, r.attempts, r.lastError));
    }
    return out;
  }

  Future<void> markPushed(OutboxItem item, {String? googleId, String? etag}) =>
      db.transaction(() async {
        await (db.delete(
          db.outboxRows,
        )..where((t) => t.seq.equals(item.seq))).go();
        if (item.op == 'delete') {
          await (db.delete(
            db.eventRows,
          )..where((t) => t.id.equals(item.event.id))).go();
        } else {
          await (db.update(
            db.eventRows,
          )..where((t) => t.id.equals(item.event.id))).write(
            EventRowsCompanion(googleId: Value(googleId), etag: Value(etag)),
          );
        }
      });

  /// The item itself was refused: one more failed attempt.
  Future<void> markFailed(OutboxItem item, String error) =>
      (db.update(db.outboxRows)..where((t) => t.seq.equals(item.seq))).write(
        OutboxRowsCompanion(
          attempts: Value(item.attempts + 1),
          lastError: Value(error),
        ),
      );

  /// The try did not go through because of the moment (network, a limit): the
  /// reason is kept for display, the attempts are NOT used up.
  Future<void> noteError(OutboxItem item, String error) =>
      (db.update(db.outboxRows)..where((t) => t.seq.equals(item.seq))).write(
        OutboxRowsCompanion(lastError: Value(error)),
      );

  /// Gives every given-up item its attempts back (a manual sync, "retry").
  Future<int> resetAttempts() =>
      (db.update(db.outboxRows)..where((t) => t.attempts.isBiggerThanValue(0)))
          .write(const OutboxRowsCompanion(attempts: Value(0)));

  /// Event id -> the operation waiting for it (the newest one).
  Future<Map<String, String>> pendingOps() async {
    final rows = await (db.select(
      db.outboxRows,
    )..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();
    return {for (final r in rows) r.eventId: r.op};
  }

  /// A deleted event whose deletion has not been uploaded yet.
  Future<bool> isTombstone(String id) async =>
      await (db.select(db.eventRows)
            ..where((t) => t.id.equals(id) & t.deleted.equals(true)))
          .getSingleOrNull() !=
      null;

  // ----- links to Google (reset, re-linking)

  /// Cuts the link of one event and of the exceptions that hang on it, so the
  /// next upload finds or creates the Google event again.
  Future<void> unlink(String id) =>
      (db.update(
        db.eventRows,
      )..where((t) => t.id.equals(id) | t.recurringEventId.equals(id))).write(
        const EventRowsCompanion(
          googleId: Value(null),
          etag: Value(null),
          iCalUid: Value(null),
        ),
      );

  Future<int> countLive(String calendarId) async =>
      (await (db.selectOnly(db.eventRows)
                ..addColumns([db.eventRows.id.count()])
                ..where(
                  db.eventRows.calendarId.equals(calendarId) &
                      db.eventRows.deleted.equals(false),
                ))
              .getSingle())
          .read(db.eventRows.id.count()) ??
      0;

  /// Cuts the Google link of every live event of [calendarId].
  Future<void> unlinkLive(String calendarId) =>
      (db.update(db.eventRows)..where(
            (t) => t.calendarId.equals(calendarId) & t.deleted.equals(false),
          ))
          .write(
            const EventRowsCompanion(
              googleId: Value(null),
              etag: Value(null),
              iCalUid: Value(null),
            ),
          );

  /// Forgets deletions that were still waiting to be uploaded (they belong to
  /// a calendar that is not the one in use any more).
  Future<void> dropTombstones(String calendarId) => db.transaction(() async {
    final ids = [
      for (final r
          in await (db.select(db.eventRows)..where(
                (t) => t.calendarId.equals(calendarId) & t.deleted.equals(true),
              ))
              .get())
        r.id,
    ];
    if (ids.isEmpty) return;
    await (db.delete(db.outboxRows)..where((t) => t.eventId.isIn(ids))).go();
    await (db.delete(db.eventRows)..where((t) => t.id.isIn(ids))).go();
  });

  /// Queues an upload for every live event of [calendarId] (series first, so
  /// their exceptions find them in Google).
  Future<int> requeueLive(String calendarId) => db.transaction(() async {
    final rows =
        await (db.select(db.eventRows)..where(
              (t) => t.calendarId.equals(calendarId) & t.deleted.equals(false),
            ))
            .get();
    final ordered = [
      ...rows.where((r) => r.recurringEventId == null),
      ...rows.where((r) => r.recurringEventId != null),
    ];
    for (final r in ordered) {
      await _queue(r.id, 'upsert');
    }
    return ordered.length;
  });

  /// Removes every event of [calendarId] and everything queued for them.
  Future<void> clearCalendar(String calendarId) => db.transaction(() async {
    final ids = [
      for (final r in await (db.select(
        db.eventRows,
      )..where((t) => t.calendarId.equals(calendarId))).get())
        r.id,
    ];
    if (ids.isEmpty) return;
    await (db.delete(db.outboxRows)..where((t) => t.eventId.isIn(ids))).go();
    await (db.delete(db.eventRows)..where((t) => t.id.isIn(ids))).go();
  });

  /// Puts right what an interrupted run could leave behind: a deleted event
  /// that still has a Google link but no queued deletion gets the deletion
  /// queued again (the user did delete it); one without a link has nothing to
  /// delete over there and goes; queue entries for events that no longer
  /// exist go too.
  Future<({int requeued, int removed, int stale})> purgeOrphans() =>
      db.transaction(() async {
        final queued = {
          for (final r in await db.select(db.outboxRows).get()) r.eventId,
        };
        final dead = await (db.select(
          db.eventRows,
        )..where((t) => t.deleted.equals(true))).get();
        var requeued = 0;
        final unlinked = <String>[];
        for (final r in dead) {
          if (queued.contains(r.id)) continue;
          if (r.googleId == null) {
            unlinked.add(r.id);
          } else {
            await _queue(r.id, 'delete');
            requeued++;
          }
        }
        if (unlinked.isNotEmpty) {
          await (db.delete(
            db.eventRows,
          )..where((t) => t.id.isIn(unlinked))).go();
        }
        final stale = await db.customUpdate(
          'DELETE FROM outbox_rows WHERE event_id NOT IN '
          '(SELECT id FROM event_rows)',
          updates: {db.outboxRows},
          updateKind: UpdateKind.delete,
        );
        return (requeued: requeued, removed: unlinked.length, stale: stale);
      });

  Future<String?> meta(String key) async => (await (db.select(
    db.metaRows,
  )..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      await (db.delete(db.metaRows)..where((t) => t.key.equals(key))).go();
    } else {
      await db
          .into(db.metaRows)
          .insertOnConflictUpdate(
            MetaRowsCompanion.insert(key: key, value: value),
          );
    }
  }

  /// Occurrences overlapping [from]..[to] across all series and singles.
  Future<List<Occurrence>> occurrences(DateTime from, DateTime to) async {
    final events = await all();
    final overrides = <String, List<CalEvent>>{};
    for (final e in events.where((e) => e.isException)) {
      (overrides[e.recurringEventId!] ??= []).add(e);
    }
    final out = <Occurrence>[];
    for (final e in events.where((e) => !e.isException)) {
      try {
        out.addAll(expand(e, from, to, overrides: overrides[e.id] ?? const []));
      } catch (_) {
        // An unreadable rule or time zone hides THAT event only (see
        // [unreadableEvents]); it must never blank the whole calendar.
      }
    }
    out.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    return out;
  }

  /// Events the app cannot expand (unreadable rule, unknown time zone …).
  /// They stay stored untouched but are not shown, so the user is told.
  Future<List<CalEvent>> unreadableEvents() async {
    final out = <CalEvent>[];
    for (final e in await all()) {
      if (e.isException || e.cancelled) continue;
      try {
        expand(e, e.startUtc, e.startUtc.add(const Duration(days: 1)));
      } catch (_) {
        out.add(e);
      }
    }
    return out;
  }
}
