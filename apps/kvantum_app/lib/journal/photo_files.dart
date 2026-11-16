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
    final tmp = File('${f.path}.tmp');
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
  Future<List<StoredPhoto>> list() async {
    if (!await dir.exists()) return const [];
    final out = <StoredPhoto>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!isPhotoFileName(name)) continue;
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

  /// What the next write throws (a full disk, in a test); null: nothing.
  Object? failWrite;

  /// The names there are.
  Iterable<String> get names => _bytes.keys;

  /// Puts a file there as if it had been written [age] ago.
  void put(String name, Uint8List bytes, {Duration age = Duration.zero}) {
    _bytes[name] = bytes;
    _modified[name] = _clock().subtract(age);
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
}
