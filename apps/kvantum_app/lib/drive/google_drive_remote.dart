import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:googleapis/drive/v3.dart' as d;
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart' show safeRecordFileNamePattern;

import '../sync/api_errors.dart';
import '../sync/retry_after_client.dart';
import 'drive_remote.dart';

const _space = 'appDataFolder';
final _recordName = safeRecordFileNamePattern;

/// [DriveRemote] on top of Drive API v3, limited to the hidden appDataFolder
/// (scope `drive.appdata`: the app can see nothing else in the user's Drive).
class GoogleDriveRemote implements DriveRemote {
  GoogleDriveRemote(this._client, {this.maxReadBytes = driveMaxReadBytes});

  final http.Client _client;

  /// The most bytes taken from one file (a parameter for the tests).
  final int maxReadBytes;
  d.DriveApi get _api => d.DriveApi(_client);

  /// Runs an API call and maps its failures to the sync vocabulary, with the
  /// server's `Retry-After` when the client in use records it.
  Future<T> _g<T>(Future<T> Function() call) =>
      _guard(call, retryAfter: () => retryAfterOf(_client));

  // ---------------------------------------------------------------- pull

  @override
  Future<DrivePull> pull(String? pageToken) async {
    if (pageToken == null) return _full();
    final files = <DriveRecordFile>[];
    final removed = <String>[];
    var token = pageToken;
    String? next;
    var finTouched = false;
    do {
      final d.ChangeList res;
      try {
        res = await _g(
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
        if (f.name != null && f.name!.startsWith('fin-')) finTouched = true;
        if (f.id == null || f.name == null || !_recordName.hasMatch(f.name!)) {
          continue;
        }
        final String? content;
        try {
          content = await read(f.id!);
        } on DriveFileTooBig {
          continue; // not the app's own file: nothing to take from it
        }
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
      // a removed file may be a letter somebody collected: look at the mail
      finChanged: finTouched || removed.isNotEmpty,
    );
  }

  Future<DrivePull> _full() async {
    // The start token is taken BEFORE listing so changes made during the
    // listing are not missed.
    final start = await _g(
      () => _api.changes.getStartPageToken($fields: 'startPageToken'),
    );
    final files = <DriveRecordFile>[];
    String? page;
    do {
      final res = await _g(
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
        final String? content;
        try {
          content = await read(f.id!);
        } on DriveFileTooBig {
          continue; // not the app's own file: nothing to take from it
        }
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
    final bytes = await _download(fileId, maxReadBytes);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<Uint8List?> readBytes(String fileId, {required int maxBytes}) =>
      _download(fileId, maxBytes);

  /// The bytes of a file, null when it is gone. [max] is the most that is
  /// taken: what the server announces is looked at first, then what really
  /// arrives (a file that is bigger than what the app writes is not read).
  Future<Uint8List?> _download(String fileId, int max) async {
    try {
      final media = await _g(
        () => _api.files.get(
          fileId,
          downloadOptions: d.DownloadOptions.fullMedia,
        ),
      ) as d.Media;
      final announced = media.length;
      if (announced != null && announced > max) {
        await media.stream.listen((_) {}).cancel();
        throw DriveFileTooBig(announced);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in media.stream) {
        bytes.add(chunk);
        if (bytes.length > max) throw DriveFileTooBig(bytes.length);
      }
      return bytes.takeBytes();
    } on _Gone {
      return null;
    }
  }

  @override
  Future<List<String>> findByName(String name) async {
    final safe = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final res = await _g(
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
      final res = await _g(
        () => _api.files.list(
          spaces: _space,
          q: 'trashed = false',
          pageSize: 200,
          pageToken: page,
          $fields: 'nextPageToken,files(id,name,createdTime)',
        ),
      );
      for (final f in res.files ?? const <d.File>[]) {
        if (f.id != null && f.name != null && f.name!.startsWith(prefix)) {
          out.add(DriveName(id: f.id!, name: f.name!, created: f.createdTime));
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
  }) => writeBytes(
    fileId: fileId,
    name: name,
    bytes: Uint8List.fromList(utf8.encode(content)),
    contentType: 'application/json',
  );

  @override
  Future<String> writeBytes({
    String? fileId,
    required String name,
    required Uint8List bytes,
    required String contentType,
  }) async {
    d.Media media() =>
        d.Media(Stream.value(bytes), bytes.length, contentType: contentType);
    if (fileId == null) {
      final created = await _g(
        () => _api.files.create(
          d.File(name: name, parents: [_space], mimeType: contentType),
          uploadMedia: media(),
          $fields: 'id',
        ),
      );
      return created.id!;
    }
    try {
      final updated = await _g(
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
      return writeBytes(name: name, bytes: bytes, contentType: contentType);
    }
  }

  @override
  Future<void> delete(String fileId) async {
    try {
      await _g(() => _api.files.delete(fileId));
    } on _Gone {
      // already gone
    }
  }
}

class _Gone implements Exception {}

class _BadToken implements Exception {}

/// Maps API/network failures to the engine's error vocabulary (see
/// [classifyApiError]). [retryAfter] supplies the server's `Retry-After`.
Future<T> _guard<T>(
  Future<T> Function() call, {
  Duration? Function()? retryAfter,
}) async {
  try {
    return await call();
  } on d.DetailedApiRequestError catch (e) {
    final status = e.status ?? 0;
    final detail = e.errors.firstOrNull;
    final kind = classifyApiError(
      status: status,
      reason: detail?.reason,
      domain: detail?.domain,
      message: e.message,
      location: detail?.location,
    );
    final wait = retryAfter?.call();
    final what = 'http $status ${detail?.reason ?? ''}'.trim();
    switch (kind) {
      case ApiFailure.gone:
        // a gone change token is "start over"; a gone file is just gone
        if (status == 410) throw _BadToken();
        throw _Gone();
      case ApiFailure.tokenInvalid:
        throw _BadToken();
      case ApiFailure.conflict:
        throw DriveTransientError(what, wait);
      case ApiFailure.auth:
        throw DriveTransientError('auth', wait);
      case ApiFailure.throttled:
        throw DriveTransientError.throttled(what, retryAfter: wait);
      case ApiFailure.dailyLimit:
        throw DriveTransientError.throttled(
          what,
          retryAfter: wait,
          dailyLimit: true,
        );
      case ApiFailure.server:
        throw DriveTransientError(what, wait);
      case ApiFailure.itemRejected:
        throw ItemRejectedError(status, detail?.reason, e.message);
    }
  } on SocketException catch (e) {
    throw DriveTransientError(e.message);
  } on http.ClientException catch (e) {
    throw DriveTransientError(e.message);
  } on TimeoutException {
    throw DriveTransientError('timeout');
  }
}
