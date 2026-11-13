import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import 'db.dart';

const _kTx = 'tx';
const _kCategory = 'category';
const _kBudget = 'budget';
const _kRecurring = 'recurring';
const _kGoal = 'goal';
const _kDeposit = 'deposit';

/// The version of the finance backup file this build writes and reads.
const financeBackupVersion = 1;

/// A record that was deleted: enough to put it back
/// ([FinanceRepository.undelete]).
class DeletedRef {
  const DeletedRef(this.kind, this.id, this.updatedAt);
  final String kind;
  final String id;

  /// The stamp of the deletion mark. A record is put back only while it still
  /// is exactly this mark: if anything wrote it since (another device, an
  /// edit), putting the old version back would overwrite newer data.
  final int updatedAt;
}

/// A transaction an import wrote: enough to take the import back
/// ([FinanceRepository.undoImport]).
class ImportMark {
  const ImportMark(this.id, this.updatedAt);
  final String id;

  /// The stamp the import gave it. An import is taken back only while every
  /// transaction it wrote still has this stamp: one that was edited since (here
  /// or on another device) is no longer what the import wrote.
  final int updatedAt;
}

/// Local finance store. The database file on the device is the source of
/// truth; [FinRows.dirty] marks what still has to be mailed to other devices.
class FinanceRepository {
  FinanceRepository(this.db, {int Function()? clock, this.onChanged})
    : _clock = clock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final AppDatabase db;
  final int Function() _clock;

  /// Called after the user changes something (so a mail run can be started).
  final void Function()? onChanged;

  int now() => _clock();
  String newId() => const Uuid().v4();

  /// The stamp for a new version of a record: the clock, but at least one
  /// millisecond after the version it replaces (see [RecordRepository.edit]).
  Future<int> _nextStamp(String kind, String id) async {
    final row = await (db.select(
      db.finRows,
    )..where((t) => t.kind.equals(kind) & t.id.equals(id))).getSingleOrNull();
    final prev = row?.updatedAt ?? 0;
    final clock = now();
    return clock > prev ? clock : prev + 1;
  }

  /// The newest stamp of any finance record, in milliseconds.
  Future<int?> newestStamp() async =>
      (await (db.selectOnly(
        db.finRows,
      )..addColumns([db.finRows.updatedAt.max()])).getSingle()).read(
        db.finRows.updatedAt.max(),
      );

  // ----------------------------------------------------------------- reads

  Stream<List<T>> _watch<T>(String kind, T? Function(Object?) parse) =>
      (db.select(db.finRows)..where((t) => t.kind.equals(kind))).watch().map(
        (rows) => [
          for (final r in rows)
            if (!r.deleted) ?_parse(r.json, parse),
        ],
      );

  Future<List<T>> _all<T>(
    String kind,
    T? Function(Object?) parse, {
    bool deleted = false,
  }) async {
    final rows = await (db.select(
      db.finRows,
    )..where((t) => t.kind.equals(kind))).get();
    return [
      for (final r in rows)
        if (deleted || !r.deleted) ?_parse(r.json, parse),
    ];
  }

  T? _parse<T>(String json, T? Function(Object?) parse) {
    try {
      return parse(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  Stream<List<FinTx>> watchTx() => _watch(_kTx, FinTx.fromJson);
  Stream<List<FinCategory>> watchCategories() =>
      _watch(_kCategory, FinCategory.fromJson);
  Stream<List<FinBudget>> watchBudgets() =>
      _watch(_kBudget, FinBudget.fromJson);
  Stream<List<FinRecurring>> watchRecurring() =>
      _watch(_kRecurring, FinRecurring.fromJson);
  Stream<List<FinGoal>> watchGoals() => _watch(_kGoal, FinGoal.fromJson);
  Stream<List<FinDeposit>> watchDeposits() =>
      _watch(_kDeposit, FinDeposit.fromJson);

  Future<List<FinTx>> txs() => _all(_kTx, FinTx.fromJson);
  Future<List<FinCategory>> categories() =>
      _all(_kCategory, FinCategory.fromJson);
  Future<List<FinBudget>> budgets() => _all(_kBudget, FinBudget.fromJson);
  Future<List<FinRecurring>> recurring() =>
      _all(_kRecurring, FinRecurring.fromJson);
  Future<List<FinGoal>> goals() => _all(_kGoal, FinGoal.fromJson);
  Future<List<FinDeposit>> deposits() => _all(_kDeposit, FinDeposit.fromJson);

  /// Forgets the markers of records deleted before [olderThanMs]. A marker only
  /// exists so that a device which still has the record learns it is gone; one
  /// that has been away for that long would bring the record back, which is the
  /// price of not keeping markers for ever. Returns how many rows went.
  Future<int> purgeTombstones(int olderThanMs) =>
      (db.delete(db.finRows)..where(
            (t) =>
                t.deleted.equals(true) &
                t.updatedAt.isSmallerThanValue(olderThanMs),
          ))
          .go();

  // ---------------------------------------------------------------- writes

  Future<void> _put(
    String kind,
    String id,
    Map<String, Object?> json,
    int updatedAt,
    bool deleted, {
    bool dirty = true,
  }) => db
      .into(db.finRows)
      .insertOnConflictUpdate(
        FinRowsCompanion.insert(
          kind: kind,
          id: id,
          json: jsonEncode(json),
          updatedAt: Value(updatedAt),
          deleted: Value(deleted),
          dirty: Value(dirty),
        ),
      );

  Future<void> saveTx(FinTx t) async {
    await db.transaction(() async {
      final x = t.copyWith(updatedAt: await _nextStamp(_kTx, t.id));
      await _put(_kTx, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  Future<void> saveCategory(FinCategory c) async {
    await db.transaction(() async {
      final x = c.copyWith(updatedAt: await _nextStamp(_kCategory, c.id));
      await _put(_kCategory, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  Future<void> saveBudget(FinBudget b) async {
    await db.transaction(() async {
      final x = b.copyWith(updatedAt: await _nextStamp(_kBudget, b.id));
      await _put(_kBudget, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  Future<void> saveRecurring(FinRecurring r) async {
    await db.transaction(() async {
      final x = r.copyWith(updatedAt: await _nextStamp(_kRecurring, r.id));
      await _put(_kRecurring, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  Future<void> saveGoal(FinGoal g) async {
    await db.transaction(() async {
      final x = g.copyWith(updatedAt: await _nextStamp(_kGoal, g.id));
      await _put(_kGoal, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  Future<void> saveDeposit(FinDeposit d) async {
    await db.transaction(() async {
      final x = d.copyWith(updatedAt: await _nextStamp(_kDeposit, d.id));
      await _put(_kDeposit, x.id, x.toJson(), x.updatedAt, x.deleted);
    });
    onChanged?.call();
  }

  /// The deletion mark of a record, if it is deleted right now.
  Future<DeletedRef?> _mark(String kind, String id) async {
    final row = await (db.select(
      db.finRows,
    )..where((t) => t.kind.equals(kind) & t.id.equals(id))).getSingleOrNull();
    if (row == null || !row.deleted) return null;
    return DeletedRef(kind, id, row.updatedAt);
  }

  /// Deleting leaves a tombstone, so the deletion reaches the other devices.
  /// The deletes return what they deleted, so it can be put back with
  /// [undelete] (empty: there was nothing to delete).
  Future<List<DeletedRef>> deleteTx(String id) async {
    for (final t in await _all(_kTx, FinTx.fromJson)) {
      if (t.id == id) {
        await saveTx(t.copyWith(deleted: true));
        return [?await _mark(_kTx, id)];
      }
    }
    return const [];
  }

  Future<List<DeletedRef>> deleteBudget(String categoryId) async {
    for (final b in await budgets()) {
      if (b.id == categoryId) {
        await saveBudget(b.copyWith(deleted: true));
        return [?await _mark(_kBudget, categoryId)];
      }
    }
    return const [];
  }

  Future<List<DeletedRef>> deleteRecurring(String id) async {
    for (final r in await recurring()) {
      if (r.id == id) {
        await saveRecurring(r.copyWith(deleted: true));
        return [?await _mark(_kRecurring, id)];
      }
    }
    return const [];
  }

  /// Deleting a goal also removes its deposits.
  Future<List<DeletedRef>> deleteGoal(String id) => db.transaction(() async {
    final refs = <DeletedRef>[];
    for (final g in await goals()) {
      if (g.id == id) {
        await saveGoal(g.copyWith(deleted: true));
        final m = await _mark(_kGoal, id);
        if (m != null) refs.add(m);
      }
    }
    for (final d in await deposits()) {
      if (d.goalId == id) {
        await saveDeposit(d.copyWith(deleted: true));
        final m = await _mark(_kDeposit, d.id);
        if (m != null) refs.add(m);
      }
    }
    return refs;
  });

  Future<List<DeletedRef>> deleteDeposit(String id) async {
    for (final d in await deposits()) {
      if (d.id == id) {
        await saveDeposit(d.copyWith(deleted: true));
        return [?await _mark(_kDeposit, id)];
      }
    }
    return const [];
  }

  /// Puts deleted records back, all or nothing, and only while every one of
  /// them is still exactly the deletion mark it was (see [DeletedRef]). Returns
  /// whether it did.
  ///
  /// A transaction whose category was deleted meanwhile comes back as
  /// "Besorolatlan" instead of pointing at a category that is gone.
  Future<bool> undelete(List<DeletedRef> refs) => db.transaction(() async {
    if (refs.isEmpty) return false;
    final rows = <FinRow>[];
    for (final r in refs) {
      final row =
          await (db.select(db.finRows)
                ..where((t) => t.kind.equals(r.kind) & t.id.equals(r.id)))
              .getSingleOrNull();
      if (row == null || !row.deleted || row.updatedAt != r.updatedAt) {
        return false;
      }
      rows.add(row);
    }
    final categoriesNow = {for (final c in await categories()) c.id};
    String category(String id) =>
        id == kUncategorized || categoriesNow.contains(id)
        ? id
        : kUncategorized;
    for (final row in rows) {
      switch (row.kind) {
        case _kTx:
          final t = _parse(row.json, FinTx.fromJson);
          if (t != null) {
            await saveTx(
              t.copyWith(deleted: false, categoryId: category(t.categoryId)),
            );
          }
        case _kCategory:
          final c = _parse(row.json, FinCategory.fromJson);
          if (c != null) await saveCategory(c.copyWith(deleted: false));
        case _kBudget:
          final b = _parse(row.json, FinBudget.fromJson);
          if (b != null) await saveBudget(b.copyWith(deleted: false));
        case _kRecurring:
          final r = _parse(row.json, FinRecurring.fromJson);
          if (r != null) {
            await saveRecurring(
              r.copyWith(deleted: false, categoryId: category(r.categoryId)),
            );
          }
        case _kGoal:
          final g = _parse(row.json, FinGoal.fromJson);
          if (g != null) await saveGoal(g.copyWith(deleted: false));
        case _kDeposit:
          final d = _parse(row.json, FinDeposit.fromJson);
          if (d != null) await saveDeposit(d.copyWith(deleted: false));
      }
    }
    return true;
  });

  /// How many live transactions / rules still use a category.
  Future<int> categoryUsage(String id) async {
    final t = (await txs()).where((x) => x.categoryId == id).length;
    final r = (await recurring()).where((x) => x.categoryId == id).length;
    return t + r;
  }

  /// Deletes a category (and its budget) only when nothing uses it. Returns
  /// what was deleted, or null when it is in use (or unknown).
  Future<List<DeletedRef>?> deleteCategory(String id) =>
      db.transaction(() async {
        if (await categoryUsage(id) > 0) return null;
        for (final c in await categories()) {
          if (c.id == id) {
            await saveCategory(c.copyWith(deleted: true));
            return <DeletedRef>[
              ?await _mark(_kCategory, id),
              ...await deleteBudget(id),
            ];
          }
        }
        return null;
      });

  // ------------------------------------------------------------- mailing

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

  /// Records to put into a letter: the changed ones, or everything (including
  /// deletion marks) for a new device.
  Future<List<MailRecord>> mailRecords({required bool onlyDirty}) async {
    final q = db.select(db.finRows);
    if (onlyDirty) q.where((t) => t.dirty.equals(true));
    final out = <MailRecord>[];
    for (final r in await q.get()) {
      try {
        out.add(MailRecord(r.kind, r.id, jsonDecode(r.json), r.updatedAt));
      } on FormatException {
        // an unreadable row cannot be mailed
      }
    }
    return out;
  }

  Future<int> dirtyCount() async => (await (db.select(
    db.finRows,
  )..where((t) => t.dirty.equals(true))).get()).length;

  /// After a letter reached everybody: the records are no longer "changed",
  /// unless they were edited again in the meantime.
  Future<void> markClean(Iterable<MailRecord> sent) async {
    for (final r in sent) {
      await (db.update(db.finRows)..where(
            (t) =>
                t.kind.equals(r.kind) &
                t.id.equals(r.id) &
                t.updatedAt.equals(r.updatedAt),
          ))
          .write(const FinRowsCompanion(dirty: Value(false)));
    }
  }

  /// Merges one record from a letter: the newer one wins; on equal times the
  /// larger JSON text wins, so every device decides the same way. Returns
  /// true when the local copy changed.
  Future<bool> applyIncoming(String kind, Object? data) =>
      db.transaction(() => _applyIncoming(kind, data));

  /// A whole letter at once: one unit (a failure half-way leaves nothing
  /// half-applied) and one change for the screens. Returns how many records
  /// changed this device's data.
  Future<int> applyIncomingAll(Iterable<(String kind, Object? data)> records) =>
      db.transaction(() async {
        var n = 0;
        for (final (kind, data) in records) {
          if (await _applyIncoming(kind, data)) n++;
        }
        return n;
      });

  Future<bool> _applyIncoming(String kind, Object? data) async {
    final rec = _decodeRecord(kind, data);
    if (rec == null) return false;
    final existing =
        await (db.select(db.finRows)
              ..where((t) => t.kind.equals(kind) & t.id.equals(rec.id)))
            .getSingleOrNull();
    if (existing != null) {
      if (existing.updatedAt > rec.updatedAt) return false;
      if (existing.updatedAt == rec.updatedAt &&
          jsonEncode(rec.json).compareTo(existing.json) <= 0) {
        return false;
      }
    }
    await _put(
      kind,
      rec.id,
      rec.json,
      rec.updatedAt,
      rec.deleted,
      dirty: false,
    );
    return true;
  }

  // ------------------------------------------------------------ merchants

  static const _merchantKey = 'fin.merchantCat';

  Future<Map<String, String>> _merchantMap() async {
    final text = await meta(_merchantKey);
    if (text == null) return {};
    try {
      final j = jsonDecode(text);
      return j is Map
          ? {for (final e in j.entries) '${e.key}': '${e.value}'}
          : {};
    } on FormatException {
      return {};
    }
  }

  /// The category the user last gave this merchant, if any.
  Future<String?> merchantCategory(String merchant) async {
    final key = merchantKey(merchant);
    if (key.isEmpty) return null;
    final id = (await _merchantMap())[key];
    if (id == null) return null;
    // forget categories that no longer exist
    final alive = (await categories()).any((c) => c.id == id);
    return alive ? id : null;
  }

  /// Remembers the category for a merchant and files the transactions of that
  /// merchant that are still uncategorized there too.
  Future<int> rememberMerchant(String merchant, String categoryId) async {
    final key = merchantKey(merchant);
    if (key.isEmpty || categoryId == kUncategorized) return 0;
    final map = await _merchantMap();
    map[key] = categoryId;
    while (map.length > 300) {
      map.remove(map.keys.first);
    }
    return db.transaction(() async {
      await setMeta(_merchantKey, jsonEncode(map));
      var n = 0;
      for (final t in await txs()) {
        if (t.categoryId == kUncategorized && merchantKey(t.merchant) == key) {
          await saveTx(t.copyWith(categoryId: categoryId));
          n++;
        }
      }
      return n;
    });
  }

  Future<bool> hasTx(String id) => _exists(_kTx, id);

  // ------------------------------------------------------------ currencies

  static String _rateKey(String currency) => 'fin.rate.$currency';

  /// The rate (forints for one unit) last used for [currency], if any: the
  /// editor offers it for the next transaction in that currency.
  Future<double?> lastRate(String currency) async {
    final text = await meta(_rateKey(currency));
    return text == null ? null : parseRate(text);
  }

  Future<void> rememberRate(String currency, double rate) =>
      setMeta(_rateKey(currency), formatRate(rate));

  // ------------------------------------------------------------ bank import

  /// The ids of every transaction there is, deleted ones included: a row of a
  /// bank file that was imported once and deleted since is not to come back.
  Future<Set<String>> allTxIds() async {
    final rows =
        await (db.selectOnly(db.finRows)
              ..addColumns([db.finRows.id])
              ..where(db.finRows.kind.equals(_kTx)))
            .get();
    return {for (final r in rows) r.read(db.finRows.id)!};
  }

  /// The categories remembered for [merchants] (by [merchantKey]), those that
  /// still exist: merchant as given to category id.
  Future<Map<String, String>> merchantCategories(
    Iterable<String> merchants,
  ) async {
    final map = await _merchantMap();
    final alive = {for (final c in await categories()) c.id};
    return {
      for (final m in merchants)
        if (alive.contains(map[merchantKey(m)])) m: map[merchantKey(m)]!,
    };
  }

  /// Adds the transactions of a bank file, all or none. One whose id is in the
  /// books already (deleted or not) is left alone. Returns what was written,
  /// to take it back ([undoImport]).
  Future<List<ImportMark>> addImported(List<FinTx> items) async {
    final marks = await db.transaction(() async {
      final known = await allTxIds();
      final out = <ImportMark>[];
      for (final t in items) {
        if (!known.add(t.id)) continue;
        final x = t.copyWith(updatedAt: await _nextStamp(_kTx, t.id));
        await _put(_kTx, x.id, x.toJson(), x.updatedAt, false);
        out.add(ImportMark(x.id, x.updatedAt));
      }
      return out;
    });
    if (marks.isNotEmpty) onChanged?.call();
    return marks;
  }

  /// Takes an import back: marks what it wrote as deleted, all or none, and
  /// only while every one is still exactly as the import left it. Returns
  /// whether it did.
  Future<bool> undoImport(List<ImportMark> marks) async {
    final done = await db.transaction(() async {
      if (marks.isEmpty) return false;
      final rows = <FinRow>[];
      for (final m in marks) {
        final row =
            await (db.select(db.finRows)
                  ..where((t) => t.kind.equals(_kTx) & t.id.equals(m.id)))
                .getSingleOrNull();
        if (row == null || row.updatedAt != m.updatedAt) {
          return false;
        }
        rows.add(row);
      }
      for (final row in rows) {
        final t = _parse(row.json, FinTx.fromJson);
        if (t == null) continue;
        final x = t.copyWith(
          deleted: true,
          updatedAt: await _nextStamp(_kTx, t.id),
        );
        await _put(_kTx, x.id, x.toJson(), x.updatedAt, true);
      }
      return true;
    });
    if (done) onChanged?.call();
    return done;
  }

  static String _bankMapKey(List<String> header) =>
      'fin.bank.${fingerprint(headerSignature(header))}';

  /// The columns chosen the last time for a file with this header, if they
  /// still fit it. Stays on this device.
  Future<BankMapping?> bankMapping(List<String> header) async {
    final text = await meta(_bankMapKey(header));
    if (text == null) return null;
    try {
      return BankMapping.fromJson(jsonDecode(text), header.length);
    } on FormatException {
      return null;
    }
  }

  Future<void> rememberBankMapping(List<String> header, BankMapping m) =>
      header.isEmpty
      ? Future.value()
      : setMeta(_bankMapKey(header), jsonEncode(m.toJson()));

  // ------------------------------------------------------ defaults, repeats

  Future<bool> _exists(String kind, String id) async =>
      await (db.select(db.finRows)
            ..where((t) => t.kind.equals(kind) & t.id.equals(id)))
          .getSingleOrNull() !=
      null;

  /// Seeds the default categories. Their ids are fixed, so every device
  /// creates the same rows and nothing needs to be mailed for them.
  Future<void> ensureDefaults() => db.transaction(() async {
    for (final c in defaultCategories()) {
      if (!await _exists(_kCategory, c.id)) {
        await _put(_kCategory, c.id, c.toJson(), 0, false, dirty: false);
      }
    }
  });

  /// Creates the transactions the recurring rules expect in [year]/[month]
  /// that do not exist yet (a deleted one is NOT brought back). Generated
  /// rows have a fixed id and need no mailing: every device derives them.
  Future<int> ensureRecurring(int year, int month) => db.transaction(() async {
    var created = 0;
    for (final t in dueRecurring(await recurring(), year, month)) {
      if (await _exists(_kTx, t.id)) continue;
      await _put(_kTx, t.id, t.toJson(), t.updatedAt, false, dirty: false);
      created++;
    }
    return created;
  });

  // ------------------------------------------------------- backup (JSON)

  /// All live records as one JSON text (the manual backup).
  Future<String> exportJson() async {
    final rows = await (db.select(
      db.finRows,
    )..where((t) => t.deleted.equals(false))).get();
    return jsonEncode({
      'format': 'kvantum-finance',
      'version': financeBackupVersion,
      'records': [
        for (final r in rows) {'kind': r.kind, 'data': jsonDecode(r.json)},
      ],
    });
  }

  /// Restores a backup: creates missing records and updates older ones; never
  /// deletes. Unusable records are counted and skipped.
  ///
  /// A backup made by a NEWER version of the app (its `version` is higher than
  /// [financeBackupVersion]) is not read: it may hold what this version does
  /// not know, and restoring half of it would look like success. `newer` says so.
  ///
  /// With [dryRun] nothing is written: the counts say what a restore would do.
  Future<({int added, int updated, int skipped, bool recognized, bool newer})>
  importJson(String text, {bool dryRun = false}) async {
    Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      return (
        added: 0,
        updated: 0,
        skipped: 0,
        recognized: false,
        newer: false,
      );
    }
    final list = root is Map ? root['records'] : null;
    if (list is! List) {
      return (
        added: 0,
        updated: 0,
        skipped: 0,
        recognized: false,
        newer: false,
      );
    }
    final version = (root as Map)['version'];
    if (version is num && version > financeBackupVersion) {
      return (added: 0, updated: 0, skipped: 0, recognized: true, newer: true);
    }
    return db.transaction(() async {
      var added = 0, updated = 0, skipped = 0;
      for (final item in list) {
        final kind = item is Map ? item['kind'] : null;
        final data = item is Map ? item['data'] : null;
        final rec = _decodeRecord('$kind', data);
        if (rec == null) {
          skipped++;
          continue;
        }
        final existing =
            await (db.select(db.finRows)
                  ..where((t) => t.kind.equals(rec.kind) & t.id.equals(rec.id)))
                .getSingleOrNull();
        if (existing == null) {
          if (!dryRun) {
            await _put(rec.kind, rec.id, rec.json, rec.updatedAt, rec.deleted);
          }
          added++;
        } else if (rec.updatedAt > existing.updatedAt) {
          if (!dryRun) {
            await _put(rec.kind, rec.id, rec.json, rec.updatedAt, rec.deleted);
          }
          updated++;
        }
      }
      return (
        added: added,
        updated: updated,
        skipped: skipped,
        recognized: true,
        newer: false,
      );
    });
  }

  /// Whether this build knows records of [kind] (a letter may carry kinds of
  /// a newer version).
  bool knowsKind(String kind) => const {
    _kTx,
    _kCategory,
    _kBudget,
    _kRecurring,
    _kGoal,
    _kDeposit,
  }.contains(kind);

  _Rec? _decodeRecord(String kind, Object? data) {
    switch (kind) {
      case _kTx:
        final x = FinTx.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
      case _kCategory:
        final x = FinCategory.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
      case _kBudget:
        final x = FinBudget.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
      case _kRecurring:
        final x = FinRecurring.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
      case _kGoal:
        final x = FinGoal.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
      case _kDeposit:
        final x = FinDeposit.fromJson(data);
        return x == null
            ? null
            : _Rec(kind, x.id, x.toJson(), x.updatedAt, x.deleted);
    }
    return null;
  }
}

/// One record as it travels in a letter.
class MailRecord {
  const MailRecord(this.kind, this.id, this.data, this.updatedAt);
  final String kind;
  final String id;
  final Object? data;
  final int updatedAt;

  Map<String, Object?> toJson() => {'kind': kind, 'data': data};
}

class _Rec {
  const _Rec(this.kind, this.id, this.json, this.updatedAt, this.deleted);
  final String kind;
  final String id;
  final Map<String, Object?> json;
  final int updatedAt;
  final bool deleted;
}
