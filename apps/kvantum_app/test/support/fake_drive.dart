import 'package:kvantum_app/drive/drive_remote.dart';

/// In-memory Drive appDataFolder with a change log, duplicates and failures.
class FakeDrive implements DriveRemote {
  final Map<String, ({String name, String content, int rev})> files = {};
  final Map<String, int> _removedAt = {};
  int _clock = 0;
  int _next = 1;

  bool offline = false;

  /// Makes every call fail with this error (e.g. an expired login).
  Object? failWith;
  bool expireToken = false;
  int writes = 0;
  int creates = 0;
  int deletes = 0;

  /// How often the mailbox listed letters / peer notes.
  int listCalls = 0;

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
    files[id] = (name: name, content: content, rev: _bump());
    return id;
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
        if (pageToken == null || e.value.rev > since)
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
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    return files[fileId]?.content;
  }

  @override
  Future<List<String>> findByName(String name) async {
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
          DriveName(id: e.key, name: e.value.name),
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
    if (duringWrite != null) {
      final f = duringWrite!;
      duringWrite = null;
      await f();
    }
    writes++;
    if (fileId != null && files.containsKey(fileId)) {
      files[fileId] = (name: name, content: content, rev: _bump());
      return fileId;
    }
    creates++;
    final id = 'f${_next++}';
    files[id] = (name: name, content: content, rev: _bump());
    return id;
  }

  @override
  Future<void> delete(String fileId) async {
    if (failWith != null) throw failWith!;
    if (offline) throw DriveTransientError('offline');
    deletes++;
    files.remove(fileId);
    _removedAt[fileId] = _bump();
  }
}
