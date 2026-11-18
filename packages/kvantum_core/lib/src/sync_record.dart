import 'dart:convert';

/// The version of the record file format this build writes and reads.
const syncRecordVersion = 1;

/// A record file written by a NEWER version of the app. It is not read (it may
/// hold what this version does not know) and, above all, not overwritten.
class NewerFormatException extends FormatException {
  NewerFormatException(this.version)
    : super('A rekord újabb formátumú (v$version).');
  final int version;
}

/// One value of one field, stamped with the time and device of the last write.
class FieldValue {
  const FieldValue(this.value, this.ts, this.dev);
  final Object? value;

  /// Milliseconds since epoch (UTC) of the write.
  final int ts;
  final String dev;

  /// True when [this] should replace [other]: newer timestamp wins, equal
  /// timestamps are decided by device id so every device picks the same one.
  bool beats(FieldValue other) =>
      ts != other.ts ? ts > other.ts : dev.compareTo(other.dev) > 0;

  Map<String, Object?> toJson() => {'v': value, 't': ts, 'd': dev};
  static FieldValue fromJson(Map<String, dynamic> j) =>
      FieldValue(j['v'], (j['t'] as num).toInt(), '${j['d']}');

  @override
  bool operator ==(Object other) =>
      other is FieldValue &&
      other.value == value &&
      other.ts == ts &&
      other.dev == dev;
  @override
  int get hashCode => Object.hash(value, ts, dev);
}

/// A synced record (task, check-in, ...) merged field by field, last writer
/// wins per field. Concurrent edits of DIFFERENT fields on two devices both
/// survive; for the same field the later write wins deterministically.
class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.kind,
    this.fields = const {},
  });
  final String id;
  final String kind;
  final Map<String, FieldValue> fields;

  Object? operator [](String key) => fields[key]?.value;
  bool get deleted => this['deleted'] == true;

  /// Newest write time over all fields.
  int get updatedAt =>
      fields.values.fold<int>(0, (m, f) => f.ts > m ? f.ts : m);

  /// Applies [changes] as writes made at [ts] by [dev]. Unchanged values are
  /// not re-stamped, so merely saving a form does not steal other devices' edits.
  SyncRecord edit(
    Map<String, Object?> changes, {
    required int ts,
    required String dev,
  }) {
    final next = {...fields};
    changes.forEach((k, v) {
      if (next[k]?.value != v || !next.containsKey(k)) {
        next[k] = FieldValue(v, ts, dev);
      }
    });
    return SyncRecord(id: id, kind: kind, fields: next);
  }

  /// Field-wise merge; commutative, associative and idempotent.
  SyncRecord merge(SyncRecord other) {
    assert(other.id == id && other.kind == kind, 'merging different records');
    final next = {...fields};
    other.fields.forEach((k, v) {
      final mine = next[k];
      if (mine == null || v.beats(mine)) next[k] = v;
    });
    return SyncRecord(id: id, kind: kind, fields: next);
  }

  bool sameAs(SyncRecord other) {
    if (fields.length != other.fields.length) return false;
    for (final e in fields.entries) {
      if (other.fields[e.key] != e.value) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'v': syncRecordVersion,
    'id': id,
    'kind': kind,
    'f': {for (final e in fields.entries) e.key: e.value.toJson()},
  };

  String encode() => jsonEncode(toJson());

  /// Parses a stored record; throws [FormatException] for anything malformed
  /// (a corrupt Drive file must never crash the sync).
  static SyncRecord decode(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Hibás rekord (nem JSON).');
    }
    if (j is Map<String, dynamic>) {
      final v = j['v'];
      if (v is num && v > syncRecordVersion) {
        throw NewerFormatException(v.toInt());
      }
    }
    if (j is! Map<String, dynamic> ||
        j['id'] is! String ||
        j['kind'] is! String ||
        j['f'] is! Map) {
      throw const FormatException('Hibás rekord (hiányzó mezők).');
    }
    final f = <String, FieldValue>{};
    for (final e in (j['f'] as Map).entries) {
      final v = e.value;
      if (v is! Map<String, dynamic> || v['t'] is! num || v['d'] is! String) {
        throw FormatException('Hibás mező: ${e.key}');
      }
      f['${e.key}'] = FieldValue.fromJson(v);
    }
    return SyncRecord(
      id: j['id'] as String,
      kind: j['kind'] as String,
      fields: f,
    );
  }
}
