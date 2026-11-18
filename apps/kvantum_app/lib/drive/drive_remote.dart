import 'package:flutter/foundation.dart';

import '../sync/api_errors.dart' show RetryHint;

/// A record file as stored in Drive's hidden app folder.
class DriveRecordFile {
  const DriveRecordFile({
    required this.id,
    required this.name,
    required this.content,
  });
  final String id;
  final String name;
  final String content;
}

/// Id and name of a file in the app folder (no content).
class DriveName {
  const DriveName({required this.id, required this.name});
  final String id;
  final String name;
}

class DrivePull {
  const DrivePull({
    required this.files,
    required this.removedIds,
    required this.nextToken,
    this.full = false,
    this.finChanged = true,
  });

  /// Changed (or, on a full pull, all) record files with their content.
  final List<DriveRecordFile> files;
  final List<String> removedIds;

  /// Token to continue from next time.
  final String nextToken;
  final bool full;

  /// Whether files of the finance mailbox (`fin-…`) were touched since the
  /// last pull (always true for a full listing): when not, the mailbox has no
  /// news and need not be listed again.
  final bool finChanged;
}

/// Abstraction over Google Drive's appDataFolder, so the sync logic is
/// testable without a network.
abstract class DriveRemote {
  /// Incremental when [pageToken] is set, a full listing otherwise.
  /// Throws [DriveTokenExpired] when the token is no longer valid.
  Future<DrivePull> pull(String? pageToken);

  /// Content of a file, or null when it no longer exists. Throws
  /// [DriveFileTooBig] for a file larger than [driveMaxReadBytes].
  Future<String?> read(String fileId);

  /// Ids of record files with this exact name (oldest first when duplicated).
  Future<List<String>> findByName(String name);

  /// Creates (fileId null) or overwrites a file; returns its id.
  Future<String> write({
    String? fileId,
    required String name,
    required String content,
  });

  /// Files whose name starts with [prefix] (names only, oldest name first).
  Future<List<DriveName>> listNames(String prefix);

  /// Deletes a duplicate file after its content has been merged elsewhere.
  Future<void> delete(String fileId);
}

class DriveTokenExpired implements Exception {}

/// The most bytes the app takes from one Drive file. Everything it writes
/// there is far smaller (the biggest, a backup copy, is about 4 MB): a larger
/// file is not the app's own, and is not read into memory.
const driveMaxReadBytes = 8 * 1024 * 1024;

/// A Drive file bigger than [driveMaxReadBytes] (or than the limit a remote
/// was made with): [DriveRemote.read] refuses it. [bytes] is what was seen
/// when it was given up on (not necessarily the whole size).
class DriveFileTooBig implements Exception {
  const DriveFileTooBig(this.bytes);
  final int bytes;

  @override
  String toString() => 'DriveFileTooBig($bytes)';
}

/// Network down, rate limit, 5xx: stop, keep everything queued, retry later.
class DriveTransientError implements Exception, RetryHint {
  DriveTransientError([this.message = '', this.retryAfter])
    : throttled = false,
      dailyLimit = false;

  /// A usage limit: back off, honouring [retryAfter].
  DriveTransientError.throttled(
    this.message, {
    this.retryAfter,
    this.dailyLimit = false,
  }) : throttled = true;

  final String message;
  @override
  final Duration? retryAfter;
  @override
  final bool throttled;
  @override
  final bool dailyLimit;

  @override
  String toString() => 'DriveTransientError($message)';
}

@immutable
class DriveReport {
  const DriveReport({
    this.pulled = 0,
    this.pushed = 0,
    this.skippedCorrupt = 0,
    this.mergedDuplicates = 0,
    this.failed = 0,
    this.full = false,
    this.stoppedEarly = false,
    this.finChanged = true,
    this.newerFormat = 0,
    this.purged = 0,
    this.hint,
  });
  final int pulled;
  final int pushed;
  final int skippedCorrupt;
  final int mergedDuplicates;
  final int failed;
  final bool full;
  final bool stoppedEarly;

  /// See [DrivePull.finChanged].
  final bool finChanged;

  /// Files a newer version of the app wrote: left exactly as they are.
  final int newerFormat;

  /// Old markers of deleted records forgotten in this run.
  final int purged;

  /// Why the run stopped early (when it did).
  final RetryHint? hint;

  @override
  String toString() =>
      'DriveReport(pulled:$pulled pushed:$pushed corrupt:$skippedCorrupt dups:$mergedDuplicates failed:$failed full:$full early:$stoppedEarly)';
}
