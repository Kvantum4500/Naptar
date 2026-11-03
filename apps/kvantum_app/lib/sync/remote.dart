import 'package:kvantum_core/kvantum_core.dart';

/// One change coming from the remote calendar (Google).
class RemoteChange {
  const RemoteChange({required this.ref, this.event, this.masterGoogleId});

  /// Identity + etag, used by `reconcile()` to avoid duplicates.
  final RemoteEvent ref;

  /// Full event data (null when [ref.cancelled]). Its `id` is a placeholder;
  /// the engine assigns the real local id.
  final CalEvent? event;

  /// For exception instances: Google id of the series master.
  final String? masterGoogleId;
}

class PullResult {
  const PullResult(this.changes, this.nextSyncToken);
  final List<RemoteChange> changes;
  final String? nextSyncToken;
}

class PushResult {
  const PushResult(this.googleId, this.etag);
  final String googleId;
  final String etag;
}

/// Abstraction over Google Calendar so the sync engine is testable offline.
abstract class RemoteCalendar {
  /// Incremental when [syncToken] is set, full listing otherwise.
  /// Throws [SyncTokenExpired] (Google HTTP 410) if the token is no longer valid.
  Future<PullResult> pull(String calendarId, String? syncToken);

  /// Create or update. MUST be idempotent per `event.id` (the adapter stores it
  /// as `extendedProperties.private.appEventId`). Throws [ConflictException]
  /// when `event.etag` is stale (HTTP 412).
  Future<PushResult> upsert(CalEvent event);

  Future<void> delete(CalEvent event);
}

class SyncTokenExpired implements Exception {}

class ConflictException implements Exception {}

/// Network down, rate limit, 5xx: stop the run, keep the queue, retry later.
class TransientSyncError implements Exception {
  TransientSyncError([this.message = '']);
  final String message;
}
