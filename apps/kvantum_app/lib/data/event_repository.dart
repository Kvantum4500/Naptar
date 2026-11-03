import 'package:drift/drift.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'db.dart';

String _wall(DateTime d) =>
    d.toIso8601String().replaceAll('Z', '').split('.').first;
DateTime _parseWall(String s) => DateTime.parse('${s}Z');

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
      deleted: Value(deleted),
    );

class OutboxItem {
  const OutboxItem(this.seq, this.event, this.op, this.attempts);
  final int seq;
  final CalEvent event;
  final String op; // upsert | delete
  final int attempts;
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

  Future<CalEvent?> byId(String id) async {
    final r = await (db.select(
      db.eventRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _fromRow(r);
  }

  /// Local edit: persists the event and queues ONE pending upsert per event
  /// (later edits replace the earlier queued op instead of piling up).
  Future<void> saveLocal(CalEvent e) => db.transaction(() async {
    await db.into(db.eventRows).insertOnConflictUpdate(_toRow(e));
    await _queue(e.id, 'upsert');
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
      out.add(OutboxItem(r.seq, _fromRow(ev), r.op, r.attempts));
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

  Future<void> markFailed(OutboxItem item, String error) =>
      (db.update(db.outboxRows)..where((t) => t.seq.equals(item.seq))).write(
        OutboxRowsCompanion(
          attempts: Value(item.attempts + 1),
          lastError: Value(error),
        ),
      );

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
      out.addAll(expand(e, from, to, overrides: overrides[e.id] ?? const []));
    }
    out.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    return out;
  }
}
