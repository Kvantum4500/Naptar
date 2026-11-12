import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import '../diag/diag_log.dart';
import 'api_errors.dart';
import 'error_catalog.dart' show uploadErrorCode;
import 'remote.dart';

class SyncReport {
  SyncReport();
  int pulled = 0;
  int pushed = 0;

  /// Items refused this run plus items that were given up on earlier.
  int failed = 0;
  int deferred = 0; // waiting for something else (e.g. the series master)

  /// Items given up on after [SyncEngine.maxAttempts] refusals: they wait for
  /// a manual retry (or for the next edit of the event).
  int parked = 0;

  /// Remote events the adapter could not read (skipped, the rest applied).
  int skippedRemote = 0;
  bool fullResync = false;
  bool stoppedEarly = false; // transient error -> retry later

  /// The per-run limit of uploads was reached: more are waiting, run again.
  bool more = false;

  /// The Google calendar of the app does not exist (any more).
  bool calendarGone = false;

  /// This device is linked to another account / calendar: nothing was done.
  SyncBindingMismatch? mismatch;

  /// Why the run stopped early (carries the server's `Retry-After`).
  RetryHint? hint;

  /// Local edits that were kept over a newer remote version (user may review).
  final List<String> localWonConflicts = [];
  @override
  String toString() =>
      'SyncReport(pulled:$pulled pushed:$pushed failed:$failed parked:$parked full:$fullResync early:$stoppedEarly)';
}

/// The meta key that remembers which account / calendar this device syncs
/// with.
const syncBindingKey = 'sync.binding';

/// How many times Google may refuse one upload before it is given up on (it
/// then waits for a manual retry or an edit).
const maxUploadAttempts = 5;

/// Pull -> apply -> push. Local pending edits win over remote edits of the
/// same event (their etag is adopted so the push does not conflict); this is
/// reported in [SyncReport.localWonConflicts].
///
/// What happens to a failed upload depends on WHY it failed: a network
/// problem or a usage limit stops the run and leaves the item untouched (it
/// is fine, the moment is not); only a refusal of the item itself counts as
/// an attempt, and after [maxAttempts] the item is parked until somebody
/// retries it.
class SyncEngine {
  SyncEngine(
    this.repo,
    this.remote, {
    Uuid? uuid,
    this.maxAttempts = maxUploadAttempts,
    this.maxPushPerRun = 150,
    this.pace = Duration.zero,
    this._log,
  }) : _uuid = uuid ?? const Uuid();

  final EventRepository repo;
  final RemoteCalendar remote;
  final Uuid _uuid;
  final DiagLog? _log;
  final int maxAttempts;

  /// At most this many uploads in one run; the rest waits for the next one
  /// (a long run would hold everything else up and hit usage limits).
  final int maxPushPerRun;

  /// Pause between two consecutive uploads. Google throttles quick bursts of
  /// writes (tens of events in a few seconds) with a "usage limits" error.
  final Duration pace;
  Future<void>? _running;

  /// Serialises runs: a second call while one is active waits for it and then
  /// runs once more (so edits made meanwhile are not missed).
  ///
  /// A [manual] run (the user asked for it) first gives the items that were
  /// given up on a fresh start.
  Future<SyncReport> sync(String calendarId, {bool manual = false}) async {
    while (_running != null) {
      await _running;
    }
    final report = SyncReport();
    final done = _run(calendarId, report, manual);
    _running = done.catchError((_) {});
    try {
      await done;
    } finally {
      _running = null;
    }
    return report;
  }

  Future<void> _run(String calendarId, SyncReport report, bool manual) async {
    try {
      report.mismatch = await _checkBinding(calendarId);
      if (report.mismatch != null) return;
      if (manual) await repo.resetAttempts();
      await _pull(calendarId, report);
      await _push(report);
    } on CalendarGoneError {
      report.calendarGone = true;
      report.stoppedEarly = true;
    } on TransientSyncError catch (e) {
      report.stoppedEarly = true;
      report.hint = e;
    }
  }

  /// A device syncs with exactly one account / calendar. The first run only
  /// notes which; if it later turns out to be another one (another login, a
  /// calendar that was deleted and created again), nothing is mixed in.
  Future<SyncBindingMismatch?> _checkBinding(String calendarId) async {
    final current = await remote.identity(calendarId);
    final stored = RemoteIdentity.tryParse(await repo.meta(syncBindingKey));
    if (stored == null) {
      await repo.setMeta(syncBindingKey, current.key);
      return null;
    }
    if (stored.matches(current)) {
      if (stored.account.isEmpty && current.account.isNotEmpty) {
        // the account became known: remember it
        await repo.setMeta(syncBindingKey, current.key);
      }
      return null;
    }
    return SyncBindingMismatch(stored: stored, current: current);
  }

  String _tokenKey(String c) => 'syncToken:$c';

  Future<void> _pull(String calendarId, SyncReport report) async {
    var token = await repo.meta(_tokenKey(calendarId));
    PullResult res;
    try {
      res = await remote.pull(calendarId, token);
    } on SyncTokenExpired {
      _log?.info('sync', 'calendar.token_expired');
      await repo.setMeta(_tokenKey(calendarId), null);
      token = null;
      report.fullResync = true;
      res = await remote.pull(calendarId, null);
    }
    final isFull = token == null;
    if (isFull) report.fullResync = true;
    report.skippedRemote += res.skipped.length;
    for (final s in res.skipped) {
      _log?.infoOnce(
        'skipped:${s.googleId}',
        'sync',
        'calendar.skipped',
        data: {'id': s.googleId, 'why': s.reason},
      );
    }

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
      await _apply(ch, report);
    }

    if (isFull) {
      // Mirror: anything we had linked to Google that Google no longer lists
      // was deleted remotely (only when we have no pending local change for it).
      // A windowed listing never contained what started before the window, so
      // the older history is kept instead of being mistaken for deletions.
      final since = res.windowStartUtc;
      await repo.atomically(() async {
        final pending = await repo.pendingOps();
        for (final l in await repo.all()) {
          if (l.calendarId == calendarId &&
              l.googleId != null &&
              !seenGoogleIds.contains(l.googleId) &&
              !pending.containsKey(l.id)) {
            if (since != null && _startsBefore(l, since)) continue;
            await repo.removeFromRemote(l.id);
          }
        }
      });
    }
    await repo.setMeta(_tokenKey(calendarId), res.nextSyncToken);
  }

  static bool _startsBefore(CalEvent e, DateTime t) {
    try {
      return e.startUtc.isBefore(t);
    } catch (_) {
      return false; // an event we cannot place in time is judged like any other
    }
  }

  /// Applies one remote change. Reading the local state and writing the result
  /// happen as one unit, so an edit made while the pull runs is either seen
  /// (and kept) or comes entirely after.
  Future<void> _apply(RemoteChange ch, SyncReport report) =>
      repo.atomically(() async {
        final locals = await repo.all();
        final pending = await repo.pendingOps();
        final d = reconcile(ch.ref, locals);
        report.pulled++;
        switch (d.action) {
          case SyncAction.ignoreEcho:
            return;
          case SyncAction.delete:
            final id = d.localId!;
            if (pending[id] == 'upsert') {
              // Deleted there, edited here and not uploaded yet: the edit wins.
              // Cutting the link makes the waiting upload create the event
              // again instead of the deletion swallowing the edit.
              await repo.unlink(id);
              report.localWonConflicts.add(id);
            } else {
              await repo.removeFromRemote(id);
            }
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
            // Google may hand back the appEventId we wrote; it names the row
            // only if no other row (a series an instance copied it from, or a
            // deletion still waiting to be uploaded) already has that id.
            final wanted = ch.ref.appEventId;
            if (wanted != null && await repo.isTombstone(wanted)) return;
            final taken = wanted == null || locals.any((l) => l.id == wanted);
            await repo.saveFromRemote(
              e.copyWith(
                id: taken ? _uuid.v4() : wanted,
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
            if (pending.containsKey(local.id)) {
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
      });

  Future<void> _push(SyncReport report) async {
    var uploads = 0;
    for (final item in await repo.pending()) {
      if (item.attempts >= maxAttempts) {
        report.failed++;
        report.parked++;
        continue;
      }
      String? masterGoogleId;
      if (item.op != 'delete' && item.event.isException) {
        final master = await repo.byId(item.event.recurringEventId!);
        masterGoogleId = master?.googleId;
        if (masterGoogleId == null) {
          // The series is not in Google yet; its own queued push comes
          // first, so this instance simply waits for the next run.
          report.deferred++;
          continue;
        }
      }
      if (uploads >= maxPushPerRun) {
        report.more = true;
        break;
      }
      if (uploads > 0 && pace > Duration.zero) await Future.delayed(pace);
      try {
        if (item.op == 'delete') {
          await remote.delete(item.event);
          await repo.markPushed(item);
        } else {
          final r = await remote.upsert(
            item.event,
            masterGoogleId: masterGoogleId,
          );
          await repo.markPushed(item, googleId: r.googleId, etag: r.etag);
        }
        uploads++;
        report.pushed++;
      } on TransientSyncError catch (e) {
        // keep the queue, stop the run; the item is fine, the moment is not
        final code = uploadErrorCode(e);
        await repo.noteError(item, code);
        _log?.info(
          'sync',
          'push.transient',
          data: {'op': item.op, 'err': code},
        );
        rethrow;
      } on ConflictException {
        // Stale etag: next pull adopts the new etag, then this retries.
        await repo.markFailed(item, 'conflict');
        report.failed++;
        final parkedNow = item.attempts + 1 >= maxAttempts;
        if (parkedNow) report.parked++;
        _log?.info(
          'sync',
          'push.conflict',
          data: {'op': item.op, 'try': item.attempts + 1, 'parked': parkedNow},
        );
      } catch (e, st) {
        final code = uploadErrorCode(e);
        await repo.markFailed(item, code);
        report.failed++;
        final parkedNow = item.attempts + 1 >= maxAttempts;
        if (parkedNow) report.parked++;
        final data = {
          'op': item.op,
          'err': code,
          'try': item.attempts + 1,
          'parked': parkedNow,
        };
        if (e is ItemRejectedError) {
          _log?.info('sync', 'push.rejected', data: data);
        } else {
          _log?.error('sync', 'push.unexpected', e, st, data);
        }
      }
    }
  }
}
