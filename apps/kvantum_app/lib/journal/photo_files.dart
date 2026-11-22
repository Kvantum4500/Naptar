import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A picture file as the store lists it.
class StoredPhoto {
  const StoredPhoto(this.name, this.size, this.modified);
  final String name;
  final int size;
  final DateTime modified;
}

final _fileName = RegExp(
  r'^[A-Za-z0-9_-]{1,40}\.(jpg|jpeg|png|webp|gif|bmp|heic|heif)$',
);

/// Whether [name] is a name a picture file of the diary may have: an id and a
/// picture's ending, nothing else (no path, no dots in front, no spaces).
bool isPhotoFileName(String name) => _fileName.hasMatch(name);

/// The ending of the file a picture is written to first (and then moved to its
/// name): what is left of a write that was cut short.
const photoTempEnding = '.tmp';

/// Whether [name] is the half-written file of a picture: a picture's name and
/// [photoTempEnding], nothing else.
bool isPhotoTempName(String name) =>
    name.endsWith(photoTempEnding) &&
    isPhotoFileName(name.substring(0, name.length - photoTempEnding.length));

/// Where the pictures of the diary are kept: a folder on the device (next to
/// the database; in memory in tests). They are not records and do not travel:
/// the other devices of the user only know that the picture exists.
abstract class PhotoFiles {
  Future<bool> exists(String name);

  /// The bytes of the picture, or null when it is not here.
  Future<Uint8List?> read(String name);

  /// Writes the picture; throws when it cannot (the disk is full, ...).
  Future<void> write(String name, Uint8List bytes);

  Future<void> delete(String name);

  /// Every picture file there is (files that are not named like ours are not
  /// listed: they are not ours to touch).
  Future<List<StoredPhoto>> list();

  /// The half-written files that a write cut short left behind (named like a
  /// picture, with [photoTempEnding] after it). They are not pictures and are
  /// not in [list].
  Future<List<StoredPhoto>> listLeftovers();

  /// Removes one of them, by the name [listLeftovers] gave.
  Future<void> deleteLeftover(String name);
}

/// The pictures in a folder.
class DirPhotoFiles implements PhotoFiles {
  const DirPhotoFiles(this.dir);
  final Directory dir;

  File _file(String name) {
    if (!isPhotoFileName(name)) {
      throw ArgumentError.value(name, 'name', 'not a picture file name');
    }
    return File(p.join(dir.path, name));
  }

  @override
  Future<bool> exists(String name) => _file(name).exists();

  @override
  Future<Uint8List?> read(String name) async {
    final f = _file(name);
    try {
      return await f.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final f = _file(name);
    await dir.create(recursive: true);
    // (a half-written picture is never the one that is looked at: it is
    // written under another name and then moved)
    final tmp = File('${f.path}$photoTempEnding');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String name) async {
    final f = _file(name);
    try {
      await f.delete();
    } on PathNotFoundException {
      // (already gone)
    }
  }

  @override
  Future<List<StoredPhoto>> list() => _filesNamed(isPhotoFileName);

  @override
  Future<List<StoredPhoto>> listLeftovers() => _filesNamed(isPhotoTempName);

  @override
  Future<void> deleteLeftover(String name) async {
    if (!isPhotoTempName(name)) {
      throw ArgumentError.value(name, 'name', 'not a half-written picture');
    }
    try {
      await File(p.join(dir.path, name)).delete();
    } on PathNotFoundException {
      // (already gone)
    }
  }

  /// The files (not folders, not links) of the folder whose name [wanted]
  /// accepts; none when there is no folder yet.
  Future<List<StoredPhoto>> _filesNamed(
    bool Function(String name) wanted,
  ) async {
    if (!await dir.exists()) return const [];
    final out = <StoredPhoto>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!wanted(name)) continue;
      final stat = await e.stat();
      out.add(StoredPhoto(name, stat.size, stat.modified));
    }
    return out;
  }
}

/// The pictures in memory (tests, and until the app knows where its folder is).
class MemoryPhotoFiles implements PhotoFiles {
  MemoryPhotoFiles({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _bytes = <String, Uint8List>{};
  final _modified = <String, DateTime>{};
  final _leftovers = <String, StoredPhoto>{};

  /// What the next write throws (a full disk, in a test); null: nothing.
  Object? failWrite;

  /// The names there are.
  Iterable<String> get names => _bytes.keys;

  /// Puts a file there as if it had been written [age] ago.
  void put(String name, Uint8List bytes, {Duration age = Duration.zero}) {
    _bytes[name] = bytes;
    _modified[name] = _clock().subtract(age);
  }

  /// The names of the half-written files there are.
  Iterable<String> get leftoverNames => _leftovers.keys;

  /// Puts the half-written file of a picture there as if a write had been cut
  /// short [age] ago ([name] is the name of the leftover: the picture's name
  /// and [photoTempEnding]).
  void putLeftover(String name, {int size = 1, Duration age = Duration.zero}) {
    if (!isPhotoTempName(name)) {
      throw ArgumentError.value(name, 'name', 'not a half-written picture');
    }
    _leftovers[name] = StoredPhoto(name, size, _clock().subtract(age));
  }

  @override
  Future<bool> exists(String name) async => _bytes.containsKey(name);

  @override
  Future<Uint8List?> read(String name) async => _bytes[name];

  @override
  Future<void> write(String name, Uint8List bytes) async {
    if (!isPhotoFileName(name)) {
      throw ArgumentError.value(name, 'name', 'not a picture file name');
    }
    final f = failWrite;
    if (f != null) throw f;
    put(name, bytes);
  }

  @override
  Future<void> delete(String name) async {
    _bytes.remove(name);
    _modified.remove(name);
  }

  @override
  Future<List<StoredPhoto>> list() async => [
    for (final e in _bytes.entries)
      if (isPhotoFileName(e.key))
        StoredPhoto(e.key, e.value.length, _modified[e.key]!),
  ];

  @override
  Future<List<StoredPhoto>> listLeftovers() async => [..._leftovers.values];

  @override
  Future<void> deleteLeftover(String name) async {
    if (!isPhotoTempName(name)) {
      throw ArgumentError.value(name, 'name', 'not a half-written picture');
    }
    _leftovers.remove(name);
  }
}
