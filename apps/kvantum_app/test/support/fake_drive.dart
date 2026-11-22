import 'dart:convert';
import 'dart:typed_data';

import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_core/kvantum_core.dart' show photoDriveNamePattern;

/// One file of the fake folder: text (a record, a letter, a backup) or, when
/// [bytes] is set, a file of bytes (a picture). [created] is when it was made.
typedef FakeFile = ({
  String name,
  String content,
  int rev,
  Uint8List? bytes,
  DateTime? created,
});

/// In-memory Drive appDataFolder with a change log, duplicates and failures.
class FakeDrive implements DriveRemote {
  /// [clock] says when a file is made (the time [DriveName.created] tells).
  FakeDrive({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, FakeFile> files = {};
  final Map<String, int> _removedAt = {};
  int _clock = 0;
  int _next = 1;

  bool offline = false;

  /// Makes only writing fail (a refused upload).
  Object? failWrite;

  /// Makes only deleting fail (e.g. a refused delete, or the network dropping
  /// at that very call).
  Object? failDelete;

  /// Per-file failures: the error to throw for a file of this name (null: no
  /// failure). Reading, writing and deleting each have their own.
  Object? Function(String name)? failReadOf;
  Object? Function(String name)? failWriteOf;
  Object? Function(String name)? failDeleteOf;

  /// Makes every call fail with this error (e.g. an expired login).
  Object? failWith;
  bool expireToken = false;
  int writes = 0;
  int creates = 0;
  int deletes = 0;

  /// How often a file of bytes (a picture) was written, and read.
  int blobWrites = 0;
  int blobReads = 0;

  /// The media type each file of bytes was written with, by file name.
  final Map<String, String> contentTypes = {};

  /// How often the mailbox listed letters / peer notes.
  int listCalls = 0;

  /// How often a file was looked for by its name.
  int findCalls = 0;

  /// The names of the files whose content was read, in order.
  final List<String> readNames = [];

  /// Overrides what a pull reports about finance mailbox news (null: derive it
  /// from the files, like Drive's change list does).
  bool? forceFinChanged;

  /// Runs inside the next write (simulates an edit made while uploading).
  Future<void> Function()? duringWrite;

  int _bump() => ++_clock;

  /// Another device writes a file (create or overwrite by name).
  String externalWrite(String name, String content, {bool duplicate = false}) {
    final existing = duplicate
        ? null
        : files.entries.where((e) => e.value.name == name).firstOrNull?.key;
    final id = existing ?? 'f${_next++}';
    files[id] = (
      name: name,
      content: content,
      rev: _bump(),
      bytes: null,
      created: existing == null ? _now() : files[existing]?.created,
    );
    return id;
  }

  /// Another device writes a file of bytes (a picture), made at [created]
  /// (now, when not said).
  String externalWriteBytes(String name, Uint8List bytes, {DateTime? created}) {
    final existing = files.entries
        .where((e) => e.value.name == name)
        .firstOrNull
        ?.key;
    final id = existing ?? 'f${_next++}';
    files[id] = (
      name: name,
      content: '',
      rev: _bump(),
      bytes: bytes,
      created: created ?? files[existing]?.created ?? _now(),
    );
    return id;
  }

  /// Says that a file was made at [created] (for a test of what is old).
  void setCreated(String id, DateTime created) {
    final f = files[id]!;
    files[id] = (
      name: f.name,
      content: f.content,
      rev: f.rev,
      bytes: f.bytes,
      created: created,
    );
  }

  void externalDelete(String id) {
    files.remove(id);
    _removedAt[id] = _bump();
  }

  @override
  Future<DrivePull> pull(String? pageToken) async {
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    if (expireToken && pageToken != null) {
      expireToken = false;
      throw DriveTokenExpired();
    }
    final since = pageToken == null ? 0 : int.parse(pageToken);
    final list = [
      for (final e in files.entries)
        // (a picture is no record: the real remote does not hand it over)
        if ((pageToken == null || e.value.rev > since) &&
            !photoDriveNamePattern.hasMatch(e.value.name))
          DriveRecordFile(
            id: e.key,
            name: e.value.name,
            content: e.value.content,
          ),
    ];
    final removed = pageToken == null
        ? <String>[]
        : [
            for (final e in _removedAt.entries)
              if (e.value > since) e.key,
          ];
    final finNews =
        pageToken == null ||
        removed.isNotEmpty ||
        files.values.any((f) => f.rev > since && f.name.startsWith('fin-'));
    return DrivePull(
      files: list,
      removedIds: removed,
      nextToken: '$_clock',
      full: pageToken == null,
      finChanged: forceFinChanged ?? finNews,
    );
  }

  @override
  Future<String?> read(String fileId) async {
    readNames.add(files[fileId]?.name ?? '?');
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    final broken = failReadOf?.call(files[fileId]?.name ?? '');
    if (broken != null) throw broken;
    final f = files[fileId];
    // (a picture is not text: the real remote cannot decode it either)
    if (f?.bytes != null) throw const FormatException('not text');
    return f?.content;
  }

  @override
  Future<Uint8List?> readBytes(String fileId, {required int maxBytes}) async {
    final f = files[fileId];
    readNames.add(f?.name ?? '?');
    blobReads++;
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    final broken = failReadOf?.call(f?.name ?? '');
    if (broken != null) throw broken;
    if (f == null) return null;
    final bytes = f.bytes ?? Uint8List.fromList(utf8.encode(f.content));
    if (bytes.length > maxBytes) throw DriveFileTooBig(bytes.length);
    return bytes;
  }

  @override
  Future<List<String>> findByName(String name) async {
    findCalls++;
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    return [
      for (final e in files.entries)
        if (e.value.name == name) e.key,
    ]..sort();
  }

  @override
  Future<List<DriveName>> listNames(String prefix) async {
    listCalls++;
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    return [
      for (final e in files.entries)
        if (e.value.name.startsWith(prefix))
          DriveName(id: e.key, name: e.value.name, created: e.value.created),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<String> write({
    String? fileId,
    required String name,
    required String content,
  }) async {
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    if (failWrite != null) throw failWrite!;
    final broken = failWriteOf?.call(name);
    if (broken != null) throw broken;
    if (duringWrite != null) {
      final f = duringWrite!;
      duringWrite = null;
      await f();
    }
    writes++;
    if (fileId != null && files.containsKey(fileId)) {
      files[fileId] = (
        name: name,
        content: content,
        rev: _bump(),
        bytes: null,
        created: files[fileId]!.created,
      );
      return fileId;
    }
    creates++;
    final id = 'f${_next++}';
    files[id] = (
      name: name,
      content: content,
      rev: _bump(),
      bytes: null,
      created: _now(),
    );
    return id;
  }

  @override
  Future<String> writeBytes({
    String? fileId,
    required String name,
    required Uint8List bytes,
    required String contentType,
  }) async {
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    if (failWrite != null) throw failWrite!;
    final broken = failWriteOf?.call(name);
    if (broken != null) throw broken;
    if (duringWrite != null) {
      final f = duringWrite!;
      duringWrite = null;
      await f();
    }
    blobWrites++;
    contentTypes[name] = contentType;
    if (fileId != null && files.containsKey(fileId)) {
      files[fileId] = (
        name: name,
        content: '',
        rev: _bump(),
        bytes: bytes,
        created: files[fileId]!.created,
      );
      return fileId;
    }
    final id = 'f${_next++}';
    files[id] = (
      name: name,
      content: '',
      rev: _bump(),
      bytes: bytes,
      created: _now(),
    );
    return id;
  }

  @override
  Future<void> delete(String fileId) async {
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    if (failDelete != null) throw failDelete!;
    final broken = failDeleteOf?.call(files[fileId]?.name ?? '');
    if (broken != null) throw broken;
    deletes++;
    files.remove(fileId);
    _removedAt[fileId] = _bump();
  }
}
