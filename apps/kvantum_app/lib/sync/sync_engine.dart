import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import 'remote.dart';

class SyncReport {
  SyncReport();
  int pulled = 0;
  int pushed = 0;
  int failed = 0;
  int deferred = 0; // waiting for something else (e.g. the series master)
  bool fullResync = false;
  bool stoppedEarly = false; // transient error -> retry later
  /// Local edits that were kept over a newer remote version (user may review).
  final List<String> localWonConflicts = [];
  @override
  String toString() =>
      'SyncReport(pulled:$pulled pushed:$pushed failed:$failed full:$fullResync early:$stoppedEarly)';
}

/// Pull -> apply -> push. Local pending edits win over remote edits of the
/// same event (their etag is adopted so the push does not conflict); this is
/// reported in [SyncReport.localWonConflicts].
class SyncEngine {
  SyncEngine(this.repo, this.remote, {Uuid? uuid, this.maxAttempts = 5})
    : _uuid = uuid ?? const Uuid();

  final EventRepository repo;
  final RemoteCalendar remote;
  final Uuid _uuid;
  final int maxAttempts;
  Future<void>? _running;

  /// Serialises runs: a second call while one is active waits for it and then
  /// runs once more (so edits made meanwhile are not missed).
  Future<SyncReport> sync(String calendarId) async {
    while (_running != null) {
      await _running;
    }
    final report = SyncReport();
    final done = _run(calendarId, report);
    _running = done.catchError((_) {});
    try {
      await done;
    } finally {
      _running = null;
    }
    return report;
  }

  Future<void> _run(String calendarId, SyncReport report) async {
    try {
      await _pull(calendarId, report);
      await _push(report);
    } on TransientSyncError {
      report.stoppedEarly = true;
    }
  }

  String _tokenKey(String c) => 'syncToken:$c';

  Future<void> _pull(String calendarId, SyncReport report) async {
    var token = await repo.meta(_tokenKey(calendarId));
    PullResult res;
    try {
      res = await remote.pull(calendarId, token);
    } on SyncTokenExpired {
      await repo.setMeta(_tokenKey(calendarId), null);
      token = null;
      report.fullResync = true;
      res = await remote.pull(calendarId, null);
    }
    final isFull = token == null;
    if (isFull) report.fullResync = true;

    final pendingIds = {for (final p in await repo.pending()) p.event.id};
    // Masters first so exception instances can find their series.
    final ordered = [...res.changes]
      ..sort(
        (a, b) =>
            (a.masterGoogleId == null ? 0 : 1) -
            (b.masterGoogleId == null ? 0 : 1),
      );
    final seenGoogleIds = <String>{};

    for (final ch in ordered) {
      seenGoogleIds.add(ch.ref.googleId);
      await _apply(ch, pendingIds, report);
    }

    if (isFull) {
      // Mirror: anything we had linked to Google that Google no longer lists
      // was deleted remotely (only when we have no pending local change for it).
      for (final l in await repo.all()) {
        if (l.calendarId == calendarId &&
            l.googleId != null &&
            !seenGoogleIds.contains(l.googleId) &&
            !pendingIds.contains(l.id)) {
          await repo.removeFromRemote(l.id);
        }
      }
    }
    await repo.setMeta(_tokenKey(calendarId), res.nextSyncToken);
  }

  Future<void> _apply(
    RemoteChange ch,
    Set<String> pendingIds,
    SyncReport report,
  ) async {
    final locals = await repo.all();
    final d = reconcile(ch.ref, locals);
    report.pulled++;
    switch (d.action) {
      case SyncAction.ignoreEcho:
        return;
      case SyncAction.delete:
        await repo.removeFromRemote(d.localId!);
      case SyncAction.create:
        final e = ch.event!;
        final masterLocal = ch.masterGoogleId == null
            ? null
            : locals
                  .where(
                    (l) =>
                        l.googleId == ch.masterGoogleId &&
                        l.calendarId == e.calendarId,
                  )
                  .firstOrNull;
        // An instance whose series we do not have (e.g. outside the sync
        // window) cannot be placed; skip it instead of storing an orphan.
        if (ch.masterGoogleId != null && masterLocal == null) return;
        await repo.saveFromRemote(
          e.copyWith(
            id: ch.ref.appEventId ?? _uuid.v4(),
            googleId: ch.ref.googleId,
            etag: ch.ref.etag,
            iCalUid: ch.ref.iCalUid,
            recurringEventId: masterLocal?.id,
            bumpVersion: false,
          ),
        );
      case SyncAction.link:
      case SyncAction.update:
        final local = locals.firstWhere((l) => l.id == d.localId);
        if (pendingIds.contains(local.id)) {
          // Keep local content, adopt remote identity/etag so the push is valid.
          await repo.saveFromRemote(
            local.copyWith(
              googleId: ch.ref.googleId,
              etag: ch.ref.etag,
              bumpVersion: false,
            ),
          );
          if (d.action == SyncAction.update) {
            report.localWonConflicts.add(local.id);
          }
        } else if (ch.event != null) {
          await repo.saveFromRemote(
            ch.event!.copyWith(
              id: local.id,
              googleId: ch.ref.googleId,
              etag: ch.ref.etag,
              iCalUid: ch.ref.iCalUid,
              recurringEventId: local.recurringEventId,
              bumpVersion: false,
            ),
          );
        }
    }
  }

  Future<void> _push(SyncReport report) async {
    for (final item in await repo.pending()) {
      if (item.attempts >= maxAttempts) {
        report.failed++;
        continue;
      }
      try {
        if (item.op == 'delete') {
          await remote.delete(item.event);
          await repo.markPushed(item);
        } else {
          String? masterGoogleId;
          if (item.event.isException) {
            final master = await repo.byId(item.event.recurringEventId!);
            masterGoogleId = master?.googleId;
            if (masterGoogleId == null) {
              // The series is not in Google yet; its own queued push comes
              // first, so this instance simply waits for the next run.
              report.deferred++;
              continue;
            }
          }
          final r = await remote.upsert(
            item.event,
            masterGoogleId: masterGoogleId,
          );
          await repo.markPushed(item, googleId: r.googleId, etag: r.etag);
        }
        report.pushed++;
      } on TransientSyncError {
        rethrow; // keep the queue, stop the run
      } on ConflictException {
        // Stale etag: next pull adopts the new etag, then this retries.
        await repo.markFailed(item, 'conflict');
        report.failed++;
      } catch (e) {
        await repo.markFailed(item, e.toString());
        report.failed++;
      }
    }
  }
}
