import 'dart:convert';

/// The `meta` key that remembers that items written by a NEWER version of the
/// app were seen (such files are left alone, never read or overwritten, until
/// this version is updated).
const newerFormatKey = 'diag.newerFormat';

/// What a channel found that a newer version wrote, and when it last saw it.
class NewerSighting {
  const NewerSighting(this.count, this.at);
  final int count;
  final DateTime at;
}

/// channel (`drive`, `finance`) -> what it found
typedef NewerSightings = Map<String, NewerSighting>;

NewerSightings decodeNewerFormat(String? json) {
  final out = <String, NewerSighting>{};
  if (json == null) return out;
  try {
    final j = jsonDecode(json);
    if (j is! Map) return out;
    for (final e in j.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final n = v['n'], at = DateTime.tryParse('${v['at']}');
      if (n is int && n > 0 && at != null) {
        out['${e.key}'] = NewerSighting(n, at.toUtc());
      }
    }
  } on FormatException {
    // replaced by the next write
  }
  return out;
}

String encodeNewerFormat(NewerSightings s) => jsonEncode({
  for (final e in s.entries)
    e.key: {'n': e.value.count, 'at': e.value.at.toUtc().toIso8601String()},
});

/// [old] after a run in which the Drive channel found [drive] such items and
/// the finance mailbox [finance] (null: that channel was not looked at
/// cleanly in this run, so what is known about it stays). Zero clears it: the
/// app was updated, or the files are gone.
///
/// The time of an unchanged sighting moves on at most once an hour, so a
/// lasting situation does not write the database at every run.
NewerSightings updateSightings(
  NewerSightings old, {
  required DateTime now,
  int? drive,
  int? finance,
}) {
  final out = Map<String, NewerSighting>.of(old);
  void put(String channel, int? n) {
    if (n == null) return;
    if (n <= 0) {
      out.remove(channel);
      return;
    }
    final prev = out[channel];
    if (prev == null ||
        prev.count != n ||
        now.difference(prev.at) >= const Duration(hours: 1)) {
      out[channel] = NewerSighting(n, now);
    }
  }

  put('drive', drive);
  put('finance', finance);
  return out;
}
