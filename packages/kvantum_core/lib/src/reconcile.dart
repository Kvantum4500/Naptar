import 'event.dart';

/// What the sync engine does with a remote (Google) event.
enum SyncAction { create, update, link, ignoreEcho, delete }

class SyncDecision {
  const SyncDecision(this.action, [this.localId]);
  final SyncAction action;
  final String? localId;
  @override
  String toString() => '$action($localId)';
}

class RemoteEvent {
  const RemoteEvent({
    required this.calendarId,
    required this.googleId,
    required this.etag,
    this.appEventId,
    this.iCalUid,
    this.cancelled = false,
    this.isInstance = false,
    this.originalStart,
  });
  final String calendarId;
  final String googleId;
  final String etag;
  final String? appEventId; // extendedProperties.private.appEventId
  final String? iCalUid;
  final bool cancelled;

  /// One occurrence of a series that was changed or hidden (an "exception").
  /// Google gives such an instance the series' iCalUID and, when the series
  /// was written by this app, a COPY of the series' appEventId: neither says
  /// which local row the instance is.
  final bool isInstance;

  /// Floating start of the occurrence this instance replaces (instances only).
  final DateTime? originalStart;
}

/// Decides how to apply a remote event without ever creating a duplicate.
/// Match order: stored link -> appEventId (our own write coming back) ->
/// iCalUID -> otherwise it is genuinely new.
///
/// A series and its exception instances never stand for each other, except
/// through the stored link: an instance that carries the series' own
/// appEventId / iCalUID must not overwrite the series row (the whole series
/// would turn into that one occurrence). An instance matches an exception
/// row by its own id, or by the iCalUID together with the same original start.
SyncDecision reconcile(RemoteEvent r, Iterable<CalEvent> locals) {
  CalEvent? byLink, byApp, byUid;
  for (final l in locals) {
    if (l.calendarId == r.calendarId && l.googleId == r.googleId) byLink = l;
    if (l.isException != r.isInstance) continue;
    if (r.appEventId != null && l.id == r.appEventId) byApp = l;
    if (r.iCalUid != null &&
        l.iCalUid == r.iCalUid &&
        l.calendarId == r.calendarId &&
        (!r.isInstance || l.originalStart == r.originalStart)) {
      byUid = l;
    }
  }
  final match = byLink ?? byApp ?? byUid;
  if (match == null) {
    return r.cancelled
        ? const SyncDecision(
            SyncAction.ignoreEcho,
          ) // deleted something we never had
        : const SyncDecision(SyncAction.create);
  }
  if (r.cancelled) return SyncDecision(SyncAction.delete, match.id);
  if (match.googleId == null) return SyncDecision(SyncAction.link, match.id);
  if (match.etag == r.etag) {
    return SyncDecision(SyncAction.ignoreEcho, match.id);
  }
  return SyncDecision(SyncAction.update, match.id);
}
