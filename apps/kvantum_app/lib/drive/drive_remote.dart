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

  /// Content of a file, or null when it no longer exists.
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

  /// Why the run stopped early (when it did).
  final RetryHint? hint;

  @override
  String toString() =>
      'DriveReport(pulled:$pulled pushed:$pushed corrupt:$skippedCorrupt dups:$mergedDuplicates failed:$failed full:$full early:$stoppedEarly)';
}
