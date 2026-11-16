import 'dart:convert';

import 'intake.dart' show minuteText;
import 'models.dart';
import 'sync_record.dart';

// The diary ("Napló"): what happened to the user, in words and with pictures.
//
// Where it lives: ONE synced record per ENTRY ([kindJournal], id = a uuid).
// The text of an entry goes to Drive and into the backup like the check-ins do;
// the PICTURES do not: a record only says which pictures belong to the entry
// (an id, a size), the files themselves stay on the device that took them in
// (the other devices show a place-holder). A deletion is the usual soft delete
// of a record, so "Visszavonás" can take it back.
//
// The time of an entry is a floating wall-clock time ("2026-11-16T08:15"), no
// zone: the diary says when it felt like, wherever the device is.
//
// Everything here is pure: the app hands over the records it has and shows what
// comes back.

/// The longest title, in characters.
const maxJournalTitle = 80;

/// The longest text, in characters.
const maxJournalText = 20000;

/// The most pictures one entry holds.
const maxJournalPhotos = 12;

/// The largest size a picture is believed to have (bytes): a record that says
/// more is damaged or forged.
const maxPhotoBytes = 64 * 1024 * 1024;

/// The largest side a picture is believed to have (pixels).
const maxPhotoSide = 30000;

/// The file endings a picture may have on disk. The name of a file is its id
/// and one of these, never the name the file had when it was chosen: a path or
/// a person's name must not get into the diary.
const photoExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
  'heic',
  'heif',
};

final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

/// Control characters except the line break and the tab.
final _controls = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]');

/// Zero-width and bidirectional-formatting characters: invisible, so they
/// would hide text from a search or an eye.
final _invisible = RegExp(r'\p{Cf}', unicode: true);

/// One line: no control or invisible characters, one space between words.
String _oneLine(String s) => s
    .replaceAll(_invisible, '')
    .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F\u2028\u2029]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Free text: line breaks kept (as "\n"), control and invisible characters
/// gone, no blank space at the ends.
String _cleanText(String s) => s
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(_invisible, '')
    .replaceAll(_controls, '')
    .trim();

String _cut(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  if (end > 0) {
    final last = s.codeUnitAt(end - 1);
    // (never cut a pair of surrogates in two)
    if (last >= 0xD800 && last <= 0xDBFF) end--;
  }
  return s.substring(0, end).trimRight();
}

int? _intIn(Object? v, int lo, int hi) {
  final n = v is num ? v.toInt() : null;
  return (n == null || n < lo || n > hi) ? null : n;
}

/// "2026-11-16T08:15" for a floating time.
String journalAtText(DateTime at) =>
    '${isoDay(at)}T${minuteText(at.hour * 60 + at.minute)}';

/// A floating time out of "2026-11-16T08:15"; null when it is not a real time
/// ("2026-02-30T08:15" is none).
DateTime? parseJournalAt(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):([0-5]\d)$')
      .firstMatch(v);
  if (m == null) return null;
  final y = int.parse(m[1]!);
  final mo = int.parse(m[2]!);
  final d = int.parse(m[3]!);
  final at = DateTime.utc(y, mo, d, int.parse(m[4]!), int.parse(m[5]!));
  return at.year == y && at.month == mo && at.day == d ? at : null;
}

/// A picture that belongs to an entry: where it is on the device (its id and
/// ending name the file), how big it is, how many bytes it takes. A size of 0
/// says "not known" (a file that could not be read as a picture is kept as it
/// was).
class PhotoRef {
  const PhotoRef({
    required this.id,
    this.ext = 'jpg',
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
  });

  /// A picture out of what a record holds; null when it is not usable (an id
  /// that could carry a path, an ending that is not a picture's, a size that
  /// cannot be).
  static PhotoRef? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !_safeId.hasMatch(id)) return null;
    final ext = json['x'] ?? 'jpg';
    if (ext is! String || !photoExtensions.contains(ext)) return null;
    final w = _intIn(json['w'] ?? 0, 0, maxPhotoSide);
    final h = _intIn(json['h'] ?? 0, 0, maxPhotoSide);
    final b = _intIn(json['b'] ?? 0, 0, maxPhotoBytes);
    if (w == null || h == null || b == null) return null;
    return PhotoRef(id: id, ext: ext, width: w, height: h, bytes: b);
  }

  final String id;
  final String ext;
  final int width;
  final int height;
  final int bytes;

  /// The name of the file on the device.
  String get fileName => '$id.$ext';

  Map<String, Object?> toJson() => {
    'id': id,
    if (ext != 'jpg') 'x': ext,
    'w': width,
    'h': height,
    'b': bytes,
  };

  @override
  bool operator ==(Object other) =>
      other is PhotoRef &&
      other.id == id &&
      other.ext == ext &&
      other.width == width &&
      other.height == height &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(id, ext, width, height, bytes);

  @override
  String toString() => 'PhotoRef($fileName, ${width}x$height, $bytes B)';
}

/// The pictures of an entry as the text of one record field.
String encodePhotos(List<PhotoRef> photos) =>
    jsonEncode([for (final p in photos) p.toJson()]);

/// The pictures out of the text of a record field: the usable ones, at most
/// [maxJournalPhotos], each id once. Anything else gives none.
List<PhotoRef> decodePhotos(Object? value) {
  if (value is! String || value.isEmpty) return const [];
  final Object? j;
  try {
    j = jsonDecode(value);
  } on FormatException {
    return const [];
  }
  if (j is! List) return const [];
  final out = <PhotoRef>[];
  final seen = <String>{};
  for (final item in j) {
    final p = PhotoRef.tryParse(item);
    if (p == null || !seen.add(p.id)) continue;
    out.add(p);
    if (out.length == maxJournalPhotos) break;
  }
  return out;
}

/// One entry of the diary.
class JournalEntry {
  const JournalEntry._({
    required this.id,
    required this.at,
    required this.title,
    required this.text,
    required this.photos,
  });

  /// An entry made from what the user typed, every part checked (an
  /// [ArgumentError] with a sentence to show). Control and invisible
  /// characters are taken out of the words; an entry has to hold something: a
  /// title, a text or a picture.
  factory JournalEntry.checked({
    required String id,
    required DateTime at,
    String title = '',
    String text = '',
    List<PhotoRef> photos = const [],
  }) {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError('Az azonosító nem megfelelő.');
    }
    final t = _oneLine(title);
    final body = _cleanText(text);
    if (t.length > maxJournalTitle) {
      throw ArgumentError('A cím legföljebb $maxJournalTitle karakter lehet.');
    }
    if (body.length > maxJournalText) {
      throw ArgumentError(
        'A szöveg legföljebb $maxJournalText karakter lehet.',
      );
    }
    if (photos.length > maxJournalPhotos) {
      throw ArgumentError(
        'Egy bejegyzéshez legföljebb $maxJournalPhotos kép tartozhat.',
      );
    }
    if ({for (final p in photos) p.id}.length != photos.length) {
      throw ArgumentError('Ugyanaz a kép kétszer szerepel.');
    }
    if (t.isEmpty && body.isEmpty && photos.isEmpty) {
      throw ArgumentError('Írj valamit, vagy tölts fel egy képet.');
    }
    return JournalEntry._(
      id: id,
      at: DateTime.utc(at.year, at.month, at.day, at.hour, at.minute),
      title: t,
      text: body,
      photos: List.unmodifiable(photos),
    );
  }

  /// The entry a record holds; null when it is not usable (a corrupt file must
  /// never crash the diary: that entry is simply not shown). Words that are
  /// too long are cut, pictures that are not usable are left out; without a
  /// real time it cannot be placed. (A deleted record is still read: whoever
  /// lists the entries leaves those out, see [journalEntries].)
  static JournalEntry? fromRecord(SyncRecord record) {
    if (record.kind != kindJournal || !_safeId.hasMatch(record.id)) {
      return null;
    }
    final at = parseJournalAt(record['at']);
    if (at == null) return null;
    final title = record['title'];
    final text = record['text'];
    return JournalEntry._(
      id: record.id,
      at: at,
      title: _cut(_oneLine(title is String ? title : ''), maxJournalTitle),
      text: _cut(_cleanText(text is String ? text : ''), maxJournalText),
      photos: List.unmodifiable(decodePhotos(record['photos'])),
    );
  }

  final String id;

  /// When it is about (a floating time: a UTC wall clock).
  final DateTime at;
  final String title;

  /// May hold line breaks.
  final String text;
  final List<PhotoRef> photos;

  /// The day it belongs to (a floating date: a UTC midnight).
  DateTime get day => DateTime.utc(at.year, at.month, at.day);

  /// "08:15".
  String get timeText => minuteText(at.hour * 60 + at.minute);

  /// What a list shows as the head: the title, else the first line of the text
  /// (cut short), else what the entry is made of.
  String get heading {
    if (title.isNotEmpty) return title;
    for (final line in text.split('\n')) {
      final l = _oneLine(line);
      if (l.isNotEmpty) return _cut(l, 60);
    }
    return photos.isEmpty
        ? 'Üres bejegyzés'
        : photos.length == 1
        ? '1 kép'
        : '${photos.length} kép';
  }

  /// The change that writes this entry into its record: every part is a field
  /// of its own, so a title changed on one device and a text changed on another
  /// both stay (the pictures are ONE field: the list is one wish).
  Map<String, Object?> get fields => {
    'at': journalAtText(at),
    'title': title,
    'text': text,
    'photos': encodePhotos(photos),
  };

  @override
  bool operator ==(Object other) =>
      other is JournalEntry &&
      other.id == id &&
      other.at == at &&
      other.title == title &&
      other.text == text &&
      _samePhotos(other.photos, photos);

  @override
  int get hashCode => Object.hash(id, at, title, text, photos.length);
}

bool _samePhotos(List<PhotoRef> a, List<PhotoRef> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One day of the diary, with its entries (the latest first).
class JournalDay {
  const JournalDay(this.day, this.entries);

  /// A floating date.
  final DateTime day;
  final List<JournalEntry> entries;
}

/// The entries of the records, as they are shown: deleted ones and ones that
/// are not usable left out, the newest first (by time, then by id so the order
/// is the same on every device).
List<JournalEntry> journalEntries(Iterable<SyncRecord> records) {
  final out = <JournalEntry>[];
  for (final r in records) {
    if (r.deleted) continue;
    final e = JournalEntry.fromRecord(r);
    if (e != null) out.add(e);
  }
  out.sort((a, b) {
    final c = b.at.compareTo(a.at);
    return c != 0 ? c : b.id.compareTo(a.id);
  });
  return out;
}

/// The entries grouped by day, the latest day first.
List<JournalDay> journalDays(List<JournalEntry> entries) {
  final days = <DateTime, List<JournalEntry>>{};
  for (final e in entries) {
    (days[e.day] ??= []).add(e);
  }
  final keys = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final d in keys) JournalDay(d, days[d]!)];
}

/// The first lines of a text for a list: at most [maxLines] non-empty lines,
/// at most [maxChars] characters, "…" where it was cut.
String journalExcerpt(String text, {int maxLines = 3, int maxChars = 240}) {
  final lines = [
    for (final l in text.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  final more = lines.length > maxLines;
  var out = lines.take(maxLines).join('\n');
  var cut = more;
  if (out.length > maxChars) {
    out = _cut(out, maxChars);
    cut = true;
  }
  return cut ? '$out…' : out;
}

/// What the user began to write and has not saved: kept on the device (not a
/// synced record) so that an app the system closed while the gallery was open
/// can offer to go on. It is for a NEW entry only.
class JournalDraft {
  const JournalDraft({
    required this.id,
    required this.at,
    this.title = '',
    this.text = '',
    this.photos = const [],
  });

  /// The id the entry will have.
  final String id;
  final DateTime at;
  final String title;
  final String text;
  final List<PhotoRef> photos;

  /// Whether there is nothing in it worth offering back.
  bool get isEmpty =>
      title.trim().isEmpty && text.trim().isEmpty && photos.isEmpty;

  String encode() => jsonEncode({
    'id': id,
    'at': journalAtText(at),
    'title': title,
    'text': text,
    'photos': encodePhotos(photos),
  });

  /// Reads what [encode] wrote; null when it is not a usable draft (it is then
  /// simply not offered).
  static JournalDraft? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final id = j['id'];
    final at = parseJournalAt(j['at']);
    if (id is! String || !_safeId.hasMatch(id) || at == null) return null;
    final title = j['title'];
    final body = j['text'];
    final d = JournalDraft(
      id: id,
      at: at,
      title: _cut(_oneLine(title is String ? title : ''), maxJournalTitle),
      text: _cut(_cleanText(body is String ? body : ''), maxJournalText),
      photos: decodePhotos(j['photos']),
    );
    return d.isEmpty ? null : d;
  }
}
