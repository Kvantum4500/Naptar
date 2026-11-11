import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis/drive/v3.dart' as d;
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart' show safeRecordFileNamePattern;

import 'drive_remote.dart';

const _space = 'appDataFolder';
final _recordName = safeRecordFileNamePattern;

/// [DriveRemote] on top of Drive API v3, limited to the hidden appDataFolder
/// (scope `drive.appdata`: the app can see nothing else in the user's Drive).
class GoogleDriveRemote implements DriveRemote {
  GoogleDriveRemote(this._client);

  final http.Client _client;
  d.DriveApi get _api => d.DriveApi(_client);

  // ---------------------------------------------------------------- pull

  @override
  Future<DrivePull> pull(String? pageToken) async {
    if (pageToken == null) return _full();
    final files = <DriveRecordFile>[];
    final removed = <String>[];
    var token = pageToken;
    String? next;
    do {
      final d.ChangeList res;
      try {
        res = await _guard(
          () => _api.changes.list(
            token,
            spaces: _space,
            includeRemoved: true,
            pageSize: 100,
            $fields: 'nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,trashed))',
          ),
        );
      } on _BadToken {
        throw DriveTokenExpired();
      }
      for (final c in res.changes ?? const <d.Change>[]) {
        final f = c.file;
        if (c.removed == true || f == null || f.trashed == true) {
          if (c.fileId != null) removed.add(c.fileId!);
          continue;
        }
        if (f.id == null || f.name == null || !_recordName.hasMatch(f.name!)) {
          continue;
        }
        final content = await read(f.id!);
        if (content != null) {
          files.add(
            DriveRecordFile(id: f.id!, name: f.name!, content: content),
          );
        }
      }
      if (res.nextPageToken != null) token = res.nextPageToken!;
      next = res.newStartPageToken;
      if (res.nextPageToken == null) break;
    } while (true);
    return DrivePull(
      files: files,
      removedIds: removed,
      nextToken: next ?? token,
    );
  }

  Future<DrivePull> _full() async {
    // The start token is taken BEFORE listing so changes made during the
    // listing are not missed.
    final start = await _guard(
      () => _api.changes.getStartPageToken($fields: 'startPageToken'),
    );
    final files = <DriveRecordFile>[];
    String? page;
    do {
      final res = await _guard(
        () => _api.files.list(
          spaces: _space,
          q: 'trashed = false',
          pageSize: 100,
          pageToken: page,
          $fields: 'nextPageToken,files(id,name)',
        ),
      );
      for (final f in res.files ?? const <d.File>[]) {
        if (f.id == null || f.name == null || !_recordName.hasMatch(f.name!)) {
          continue;
        }
        final content = await read(f.id!);
        if (content != null) {
          files.add(
            DriveRecordFile(id: f.id!, name: f.name!, content: content),
          );
        }
      }
      page = res.nextPageToken;
    } while (page != null);
    return DrivePull(
      files: files,
      removedIds: const [],
      nextToken: start.startPageToken!,
      full: true,
    );
  }

  // -------------------------------------------------------------- files

  @override
  Future<String?> read(String fileId) async {
    try {
      final media = await _guard(
        () => _api.files.get(
          fileId,
          downloadOptions: d.DownloadOptions.fullMedia,
        ),
      ) as d.Media;
      return await utf8.decoder.bind(media.stream).join();
    } on _Gone {
      return null;
    }
  }

  @override
  Future<List<String>> findByName(String name) async {
    final safe = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final res = await _guard(
      () => _api.files.list(
        spaces: _space,
        q: "name = '$safe' and trashed = false",
        orderBy: 'createdTime',
        pageSize: 10,
        $fields: 'files(id)',
      ),
    );
    return [for (final f in res.files ?? const <d.File>[]) ?f.id];
  }

  @override
  Future<List<DriveName>> listNames(String prefix) async {
    final out = <DriveName>[];
    String? page;
    do {
      final res = await _guard(
        () => _api.files.list(
          spaces: _space,
          q: 'trashed = false',
          pageSize: 200,
          pageToken: page,
          $fields: 'nextPageToken,files(id,name)',
        ),
      );
      for (final f in res.files ?? const <d.File>[]) {
        if (f.id != null && f.name != null && f.name!.startsWith(prefix)) {
          out.add(DriveName(id: f.id!, name: f.name!));
        }
      }
      page = res.nextPageToken;
    } while (page != null);
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Future<String> write({
    String? fileId,
    required String name,
    required String content,
  }) async {
    final bytes = utf8.encode(content);
    d.Media media() => d.Media(
      Stream.value(bytes),
      bytes.length,
      contentType: 'application/json',
    );
    if (fileId == null) {
      final created = await _guard(
        () => _api.files.create(
          d.File(name: name, parents: [_space], mimeType: 'application/json'),
          uploadMedia: media(),
          $fields: 'id',
        ),
      );
      return created.id!;
    }
    try {
      final updated = await _guard(
        () => _api.files.update(
          d.File(),
          fileId,
          uploadMedia: media(),
          $fields: 'id',
        ),
      );
      return updated.id!;
    } on _Gone {
      // the file was removed meanwhile: create it again
      return write(name: name, content: content);
    }
  }

  @override
  Future<void> delete(String fileId) async {
    try {
      await _guard(() => _api.files.delete(fileId));
    } on _Gone {
      // already gone
    }
  }
}

class _Gone implements Exception {}

class _BadToken implements Exception {}

/// Maps API/network failures to the engine's error vocabulary.
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on d.DetailedApiRequestError catch (e) {
    final s = e.status ?? 0;
    final reason = e.errors.firstOrNull?.reason ?? '';
    if (s == 404) throw _Gone();
    if (s == 400 && (e.message ?? '').toLowerCase().contains('page')) {
      throw _BadToken();
    }
    if (s == 410) throw _BadToken();
    if (s == 401) throw DriveTransientError('auth');
    if (s == 429 ||
        s >= 500 ||
        (s == 403 && reason.toLowerCase().contains('ratelimit'))) {
      throw DriveTransientError('http $s $reason');
    }
    rethrow;
  } on SocketException catch (e) {
    throw DriveTransientError(e.message);
  } on http.ClientException catch (e) {
    throw DriveTransientError(e.message);
  } on TimeoutException {
    throw DriveTransientError('timeout');
  }
}
