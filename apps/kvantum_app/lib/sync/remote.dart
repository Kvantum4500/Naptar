import 'package:kvantum_core/kvantum_core.dart';

import 'api_errors.dart' show RetryHint;

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

/// A remote event the adapter could not turn into an event (unknown time
/// zone, broken date, ...). It is left out; the rest of the listing applies.
class SkippedRemote {
  const SkippedRemote(this.googleId, this.reason);
  final String googleId;
  final String reason;
}

class PullResult {
  const PullResult(
    this.changes,
    this.nextSyncToken, {
    this.windowStartUtc,
    this.skipped = const [],
  });
  final List<RemoteChange> changes;
  final String? nextSyncToken;

  /// Set when a FULL listing only covered events ending after this instant
  /// (the remote is asked for a window to save data). Events that started
  /// before it were never listed, so their absence says nothing about them.
  final DateTime? windowStartUtc;

  /// Events that could not be read (see [SkippedRemote]).
  final List<SkippedRemote> skipped;
}

class PushResult {
  const PushResult(this.googleId, this.etag);
  final String googleId;
  final String etag;
}

/// Whose calendar this is: the Google account (the address of its primary
/// calendar) and the real id of the app's own calendar. A device is linked to
/// exactly one such pair; anything else is a different calendar and must not
/// be mixed into the local data silently.
class RemoteIdentity {
  const RemoteIdentity({required this.account, required this.calendar});
  final String account;
  final String calendar;

  /// What is stored in the database.
  String get key => '$account|$calendar';

  static RemoteIdentity? tryParse(String? key) {
    if (key == null) return null;
    final i = key.lastIndexOf('|');
    if (i < 0) return null;
    return RemoteIdentity(
      account: key.substring(0, i),
      calendar: key.substring(i + 1),
    );
  }

  /// An unknown (empty) account never counts as a difference.
  bool matches(RemoteIdentity other) =>
      calendar == other.calendar &&
      (account.isEmpty || other.account.isEmpty || account == other.account);

  /// The address with most of its name hidden (shown in the UI, never logged).
  String get maskedAccount {
    final at = account.indexOf('@');
    if (account.isEmpty) return '(ismeretlen fiók)';
    if (at <= 1) return account;
    final stars = '*' * (at - 1).clamp(1, 6).toInt();
    return '${account[0]}$stars${account.substring(at)}';
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteIdentity &&
      other.account == account &&
      other.calendar == calendar;
  @override
  int get hashCode => Object.hash(account, calendar);
}

/// Abstraction over Google Calendar so the sync engine is testable offline.
abstract class RemoteCalendar {
  /// Which account / calendar [calendarId] really is (cached by the adapter).
  Future<RemoteIdentity> identity(String calendarId);

  /// Incremental when [syncToken] is set, full listing otherwise.
  /// Throws [SyncTokenExpired] (Google HTTP 410) if the token is no longer valid
  /// and [CalendarGoneError] when the calendar itself does not exist any more.
  Future<PullResult> pull(String calendarId, String? syncToken);

  /// Create or update. MUST be idempotent per `event.id` (the adapter stores it
  /// as `extendedProperties.private.appEventId`). Throws [ConflictException]
  /// when `event.etag` is stale (HTTP 412).
  ///
  /// For exception instances [masterGoogleId] is the Google id of the series.
  Future<PushResult> upsert(CalEvent event, {String? masterGoogleId});

  Future<void> delete(CalEvent event);
}

class SyncTokenExpired implements Exception {
  @override
  String toString() => 'SyncTokenExpired';
}

class ConflictException implements Exception {
  @override
  String toString() => 'ConflictException';
}

/// Network down, rate limit, 5xx: stop the run, keep the queue, retry later.
/// It never uses up an item's attempts: the item is fine, the moment is not.
class TransientSyncError implements Exception, RetryHint {
  TransientSyncError([this.message = '', this.retryAfter])
    : throttled = false,
      dailyLimit = false;

  /// A usage limit: back off, honouring [retryAfter].
  TransientSyncError.throttled(
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
  String toString() => 'TransientSyncError($message)';
}

/// The app's Google calendar does not exist (any more). The next run looks it
/// up again; if it is a different one, the linking question follows.
class CalendarGoneError implements Exception {
  @override
  String toString() => 'CalendarGoneError';
}

/// The Google account or calendar differs from the one this device was linked
/// to: nothing is pulled or pushed until the user decides what to do.
class SyncBindingMismatch implements Exception {
  const SyncBindingMismatch({required this.stored, required this.current});
  final RemoteIdentity stored;
  final RemoteIdentity current;

  bool get accountChanged =>
      stored.account.isNotEmpty &&
      current.account.isNotEmpty &&
      stored.account != current.account;

  @override
  String toString() => 'SyncBindingMismatch';
}
