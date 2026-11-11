import 'package:drift/drift.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import 'db.dart';

/// The meta key of the Drive change token (where the record sync left off).
const driveTokenKey = 'drivePageToken';

/// Local store of the Drive-synced records (tasks, check-ins).
class RecordRepository {
  RecordRepository(this.db, {String? deviceId, int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch) {
    _deviceId = deviceId;
  }

  final AppDatabase db;

  /// Stable id of this installation (created once, kept in the database);
  /// breaks timestamp ties identically on every device.
  late String? _deviceId;
  Future<String> deviceId() async {
    final known = _deviceId;
    if (known != null) return known;
    var id = await meta('deviceId');
    if (id == null) {
      id = const Uuid().v4().substring(0, 8);
      await setMeta('deviceId', id);
    }
    return _deviceId = id;
  }

  final int Function() _clock;

  int now() => _clock();

  SyncRecord _decode(RecordRow r) => SyncRecord.decode(r.json);

  Stream<List<SyncRecord>> watch(String kind) =>
      (db.select(db.recordRows)..where((t) => t.kind.equals(kind))).watch().map(
        (rows) => [for (final r in rows) ?_tryDecode(r)],
      );

  SyncRecord? _tryDecode(RecordRow r) {
    try {
      return _decode(r);
    } on FormatException {
      return null; // a corrupt row must not take the whole list down
    }
  }

  Future<List<SyncRecord>> all(String kind) async {
    final rows = await (db.select(
      db.recordRows,
    )..where((t) => t.kind.equals(kind))).get();
    return [for (final r in rows) ?_tryDecode(r)];
  }

  Future<SyncRecord?> get(String kind, String id) async {
    final r = await (db.select(
      db.recordRows,
    )..where((t) => t.kind.equals(kind) & t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _tryDecode(r);
  }

  /// Creates or edits a record locally (marks it for upload).
  Future<SyncRecord> edit(
    String kind,
    String id,
    Map<String, Object?> changes,
  ) async {
    final base = await get(kind, id) ?? SyncRecord(id: id, kind: kind);
    final next = base.edit(changes, ts: now(), dev: await deviceId());
    await _put(next, dirty: true);
    return next;
  }

  /// Soft delete: a tombstone that is synced like any other change.
  Future<void> delete(String kind, String id) async {
    final base = await get(kind, id);
    if (base == null) return;
    await _put(
      base.edit({'deleted': true}, ts: now(), dev: await deviceId()),
      dirty: true,
    );
  }

  /// Merges a record read from Drive. The row stays dirty only when the local
  /// side still has information the remote copy lacks.
  Future<void> applyRemote(SyncRecord remote) async {
    final local = await get(remote.kind, remote.id);
    final merged = local == null ? remote : local.merge(remote);
    await _put(merged, dirty: !merged.sameAs(remote));
  }

  /// Queues a record for upload again (e.g. its Drive file disappeared).
  Future<void> markDirty(String kind, String id) =>
      (db.update(db.recordRows)
            ..where((t) => t.kind.equals(kind) & t.id.equals(id)))
          .write(const RecordRowsCompanion(dirty: Value(true)));

  /// "Start the record sync over": forget where the Drive listing stopped and
  /// which file belongs to which record (they may belong to ANOTHER account's
  /// Drive), and queue every record for a check against Drive. Nothing is
  /// deleted: the merge keeps whatever either side has.
  Future<void> resetSync() => db.transaction(() async {
    await setMeta(driveTokenKey, null);
    await db.delete(db.driveFileRows).go();
    await db
        .update(db.recordRows)
        .write(const RecordRowsCompanion(dirty: Value(true)));
  });

  Future<List<SyncRecord>> dirty() async {
    final rows = await (db.select(
      db.recordRows,
    )..where((t) => t.dirty.equals(true))).get();
    return [for (final r in rows) ?_tryDecode(r)];
  }

  Future<int> dirtyCount() async =>
      (await (db.selectOnly(db.recordRows)
                ..addColumns([db.recordRows.id.count()])
                ..where(db.recordRows.dirty.equals(true)))
              .getSingle())
          .read(db.recordRows.id.count()) ??
      0;

  /// Clears the dirty flag only if the row still holds exactly what was
  /// uploaded; an edit made while the upload ran stays queued.
  Future<void> markClean(SyncRecord uploaded) async {
    final row =
        await (db.select(db.recordRows)..where(
              (t) => t.kind.equals(uploaded.kind) & t.id.equals(uploaded.id),
            ))
            .getSingleOrNull();
    if (row == null) return;
    final cur = _tryDecode(row);
    if (cur != null && cur.sameAs(uploaded)) {
      await (db.update(db.recordRows)..where(
            (t) => t.kind.equals(uploaded.kind) & t.id.equals(uploaded.id),
          ))
          .write(const RecordRowsCompanion(dirty: Value(false)));
    }
  }

  Future<void> _put(SyncRecord r, {required bool dirty}) => db
      .into(db.recordRows)
      .insertOnConflictUpdate(
        RecordRowsCompanion(
          kind: Value(r.kind),
          id: Value(r.id),
          json: Value(r.encode()),
          dirty: Value(dirty),
          updatedAt: Value(r.updatedAt),
        ),
      );

  // ----- Drive file bookkeeping

  Future<String?> fileId(String name) async => (await (db.select(
    db.driveFileRows,
  )..where((t) => t.name.equals(name))).getSingleOrNull())?.fileId;

  Future<void> setFileId(String name, String fileId) => db
      .into(db.driveFileRows)
      .insertOnConflictUpdate(
        DriveFileRowsCompanion(name: Value(name), fileId: Value(fileId)),
      );

  Future<String?> nameOfFile(String fileId) async => (await (db.select(
    db.driveFileRows,
  )..where((t) => t.fileId.equals(fileId))).getSingleOrNull())?.name;

  Future<void> forgetFile(String fileId) =>
      (db.delete(db.driveFileRows)..where((t) => t.fileId.equals(fileId))).go();

  // ----- small key/value store (page token, device id)

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
}
