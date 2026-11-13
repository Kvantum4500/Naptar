import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/event_repository.dart';
import '../diag/diag_log.dart';
import '../diag/newer_format.dart';
import '../diag/request_stats.dart';
import '../drive/drive_remote.dart';
import '../drive/drive_sync_engine.dart';
import '../drive/finance_mailbox.dart';
import '../drive/google_drive_remote.dart';
import '../google/google_auth_service.dart';
import '../google/google_calendar_remote.dart';
import '../providers.dart';
import 'api_errors.dart';
import 'channel_status.dart';
import 'error_catalog.dart';
import 'remote.dart';
import 'retry_after_client.dart';
import 'sync_engine.dart';
import 'sync_hold.dart';
import 'sync_pacer.dart';
import 'sync_reset.dart';

const syncCalendarId = kNaptarCalendar;

final googleConfiguredProvider = Provider<bool>(
  (_) => GoogleConfig.isConfigured,
);
final authGatewayProvider = Provider<AuthGateway>(
  (ref) => GoogleAuthService(
    SecureCredentialStore(),
    log: ref.read(diagLogProvider),
  ),
);
final driveFactoryProvider = Provider<DriveRemote Function(http.Client)>(
  (_) =>
      (c) => GoogleDriveRemote(c),
);
final remoteFactoryProvider = Provider<RemoteCalendar Function(http.Client)>(
  (_) =>
      (c) => GoogleCalendarRemote(c),
);

/// Starts the one-shot timer of the next automatic run (replaceable in tests).
typedef SyncScheduler = Timer Function(Duration delay, void Function() action);
final syncSchedulerProvider = Provider<SyncScheduler>(
  (_) =>
      (delay, action) => Timer(delay, action),
);

/// "Now" for the scheduling decisions (replaceable in tests).
final syncClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Pause between two uploads of one run.
final syncPaceProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 200),
);

final syncPacerProvider = Provider<SyncPacer>((_) => SyncPacer());

const _unset = Object();

class SyncState {
  const SyncState({
    this.configured = false,
    this.signedIn = false,
    this.syncing = false,
    this.lastSync,
    this.pending = 0,
    this.error,
    this.financeNote,
    this.nextAttempt,
    this.mismatch,
    this.parked = 0,
    this.channels = const {},
    this.upload,
  });
  final bool configured, signedIn, syncing;

  /// How far the uploads of the run that is going on are (null: not uploading
  /// now). Only the calendar's events report it.
  final ({int done, int total})? upload;

  /// What the last finance mail run did (null when nothing happened).
  final String? financeNote;
  final DateTime? lastSync;
  final int pending;
  final String? error;

  /// When the next automatic run is planned (null: none, e.g. in the
  /// background).
  final DateTime? nextAttempt;

  /// Calendar sync is paused: this is not the account / calendar the device
  /// was linked to. The user decides what to do (see the controller).
  final SyncBindingMismatch? mismatch;

  /// Uploads the Google refused repeatedly: they wait for a manual retry or an
  /// edit of the event.
  final int parked;

  /// What the last run found on each channel ([syncChannels]); a channel the
  /// last run did not look at keeps what it had.
  final Map<String, ChannelStatus> channels;

  SyncState copyWith({
    bool? signedIn,
    bool? syncing,
    DateTime? lastSync,
    int? pending,
    String? error,
    bool clearError = false,
    String? financeNote,
    Object? nextAttempt = _unset,
    Object? mismatch = _unset,
    int? parked,
    Map<String, ChannelStatus>? channels,
    Object? upload = _unset,
  }) => SyncState(
    configured: configured,
    signedIn: signedIn ?? this.signedIn,
    syncing: syncing ?? this.syncing,
    lastSync: lastSync ?? this.lastSync,
    pending: pending ?? this.pending,
    error: clearError ? null : (error ?? this.error),
    financeNote: financeNote ?? this.financeNote,
    nextAttempt: identical(nextAttempt, _unset)
        ? this.nextAttempt
        : nextAttempt as DateTime?,
    mismatch: identical(mismatch, _unset)
        ? this.mismatch
        : mismatch as SyncBindingMismatch?,
    parked: parked ?? this.parked,
    channels: channels ?? this.channels,
    // a run that is over has no upload going on, whichever way it ended
    upload: identical(upload, _unset)
        ? (syncing == false ? null : this.upload)
        : upload as ({int done, int total})?,
  );
}

/// What one pass over the three channels found, for the scheduling.
class _Outcome {
  const _Outcome({
    this.failed = false,
    this.busy = false,
    this.more = false,
    this.retryAfter,
    this.throttled = false,
    this.dailyLimit = false,
    this.expired = false,
  });

  /// A channel stopped because of the moment (network, server, a limit).
  final bool failed;

  /// Something was pulled / pushed: keep the lively beat.
  final bool busy;

  /// More is waiting to be uploaded than one run does.
  final bool more;
  final Duration? retryAfter;
  final bool throttled, dailyLimit;

  /// The login is gone; nothing more to schedule.
  final bool expired;
}

/// Syncs the calendar, the Drive records and the finance mail.
///
/// The beat adapts: a minute while things happen, slower and slower while
/// nothing does, backing off after failures (never sooner than the server
/// asked), and no timer at all while the app is in the background. Local edits
/// start a run after a short pause (except while backing off), coming back to
/// the app starts one if the last is older than half a minute, and "Szinkron
/// most" always runs at once and starts the beat over.
class SyncController extends Notifier<SyncState> with WidgetsBindingObserver {
  SyncEngine? _engine;
  DriveSyncEngine? _drive;
  FinanceMailbox? _mail;
  SyncResetOps? _reset;
  Timer? _timer, _debounce;

  int _quiet = 0, _failures = 0, _ticks = 0;
  DateTime? _notBefore, _lastRun;
  bool _foreground = true;

  DateTime _now() => ref.read(syncClockProvider)();

  DiagLog get _log => ref.read(diagLogProvider);

  @override
  SyncState build() {
    final configured = ref.watch(googleConfiguredProvider);
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _timer?.cancel();
      _debounce?.cancel();
    });
    if (configured) Future.microtask(_restore);
    return SyncState(configured: configured);
  }

  Future<void> _restore() async {
    try {
      final client = await ref.read(authGatewayProvider).restore();
      if (client != null) await _start(client);
    } catch (e, st) {
      _log.error('auth', 'restore.failed', e, st);
      state = state.copyWith(error: signInFailedText(e, restore: true));
    }
  }

  Future<void> signIn() async {
    if (!state.configured) return;
    try {
      state = state.copyWith(clearError: true);
      final client = await ref.read(authGatewayProvider).signIn();
      await _start(client);
    } catch (e, st) {
      _log.error('auth', 'signin.failed', e, st);
      state = state.copyWith(error: signInFailedText(e));
    }
  }

  void _stopEverything() {
    _timer?.cancel();
    _timer = null;
    _debounce?.cancel();
    _engine = null;
    _drive = null;
    _mail = null;
    _reset = null;
  }

  Future<void> signOut() async {
    _stopEverything();
    await ref.read(authGatewayProvider).signOut();
    state = state.copyWith(
      signedIn: false,
      syncing: false,
      clearError: true,
      nextAttempt: null,
      mismatch: null,
    );
  }

  Future<void> _start(http.Client client) async {
    // one wrapper for both services: it keeps the server's Retry-After and
    // counts the calls
    final tapped = RetryAfterClient(
      client,
      stats: ref.read(requestStatsProvider),
    );
    final events = ref.read(repoProvider);
    final records = ref.read(recordRepoProvider);
    final hold = ref.read(syncHoldProvider);
    _engine = SyncEngine(
      events,
      ref.read(remoteFactoryProvider)(tapped),
      pace: ref.read(syncPaceProvider),
      isHeld: hold.holdsEvent,
      onProgress: (done, total) {
        if (ref.mounted && state.syncing) {
          state = state.copyWith(upload: (done: done, total: total));
        }
      },
      log: _log,
    );
    final driveRemote = ref.read(driveFactoryProvider)(tapped);
    _drive = DriveSyncEngine(records, driveRemote, log: _log);
    final mail = FinanceMailbox(
      ref.read(financeRepoProvider),
      driveRemote,
      deviceId: await records.deviceId(),
      log: _log,
    );
    _mail = mail;
    _reset = SyncResetOps(
      events: events,
      records: records,
      resetMailbox: mail.resetPeers,
    );
    state = state.copyWith(signedIn: true, clearError: true);
    _quiet = 0;
    _failures = 0;
    _ticks = 0;
    _notBefore = null;
    await syncNow(manual: true);
  }

  /// The saved Google login no longer works: the token endpoint answered
  /// `invalid_grant` (refresh token expired or revoked; with an OAuth app in
  /// "Testing" mode this happens after 7 days). Deliberately NOT matched: the
  /// generic "Failed to obtain access credentials", which the auth library
  /// also uses for a Google 5xx/429, a problem that goes away by itself and
  /// must not sign the user out.
  static bool isAuthExpired(Object e) {
    final t = '$e'.toLowerCase();
    return t.contains('invalid_grant') ||
        t.contains('token has been expired or revoked');
  }

  /// Drops the dead session once and asks for a new sign-in. Local data and
  /// the queue of unsent changes are untouched; they upload after signing in.
  Future<void> _expireLogin() async {
    _log.info('auth', 'expired');
    _stopEverything();
    try {
      await ref.read(authGatewayProvider).signOut();
    } catch (e, st) {
      _log.error('auth', 'signout.failed', e, st); // nothing more to clean up
    }
    state = state.copyWith(
      signedIn: false,
      syncing: false,
      nextAttempt: null,
      error: 'A Google-bejelentkezés lejárt. Jelentkezz be újra, az adataid megvannak, a függő módosítások utána feltöltődnek.',
    );
  }

  /// Call after any local change; coalesces bursts of edits into one run. While
  /// the sync is backing off after a failure the planned run carries the edit.
  void requestSync() {
    if (!state.signedIn) return;
    final blocked = _notBefore;
    if (blocked != null && blocked.isAfter(_now())) return;
    _debounce?.cancel();
    _debounce = ref.read(syncSchedulerProvider)(
      const Duration(seconds: 2),
      () => syncNow(),
    );
  }

  bool _running = false, _again = false, _manualAgain = false;

  /// One run at a time: calls that arrive meanwhile (the timer, coming back to
  /// the app, a saved edit) are folded into ONE follow-up run instead of
  /// piling up behind a slow request.
  ///
  /// [manual]: the user asked for it. It does not wait for a backoff, gives
  /// the uploads that were given up on a fresh start, and restarts the beat.
  Future<void> syncNow({bool manual = false}) async {
    if (_engine == null) return;
    if (manual) {
      _failures = 0;
      _quiet = 0;
      _notBefore = null;
    }
    if (_running) {
      _again = true;
      _manualAgain = _manualAgain || manual;
      return;
    }
    _running = true;
    var last = const _Outcome();
    try {
      var asked = manual;
      do {
        _again = false;
        try {
          last = await _syncOnce(manual: asked);
        } catch (e, st) {
          last = await _crashed(e, st);
        }
        asked = _manualAgain;
        _manualAgain = false;
      } while (_again && _engine != null);
    } finally {
      _running = false;
    }
    if (!last.expired && _engine != null) _scheduleAfter(last);
  }

  /// A failure outside the three channel guards (the database, a bug). It must
  /// neither leave "syncing" on for good nor stop the beat: the run counts as
  /// failed and the next one is planned as usual.
  Future<_Outcome> _crashed(Object e, StackTrace st) async {
    _log.error('sync', 'run.crashed', e, st);
    if (isAuthExpired(e)) {
      await _expireLogin();
      return const _Outcome(expired: true);
    }
    state = state.copyWith(syncing: false, error: unexpectedText('Szinkron'));
    return const _Outcome(failed: true);
  }

  /// Plans the next automatic run from what the last one found.
  void _scheduleAfter(_Outcome o) {
    final Duration wait;
    if (o.failed) {
      _failures++;
      _quiet = 0;
      wait = ref
          .read(syncPacerProvider)
          .afterFailure(
            failures: _failures,
            retryAfter: o.retryAfter,
            throttled: o.throttled,
            dailyLimit: o.dailyLimit,
          );
    } else {
      _failures = 0;
      if (o.more) {
        wait = SyncPacer.followUp;
      } else {
        _quiet = o.busy ? 0 : _quiet + 1;
        wait = ref.read(syncPacerProvider).afterSuccess(quietRuns: _quiet);
      }
    }
    _arm(wait);
  }

  void _arm(Duration wait) {
    _timer?.cancel();
    _timer = null;
    final next = _now().add(wait);
    _notBefore = _failures > 0 ? next : null;
    state = state.copyWith(nextAttempt: next);
    if (!_foreground) return; // coming back to the app looks at it again
    _timer = ref.read(syncSchedulerProvider)(wait, () {
      _timer = null;
      syncNow();
    });
  }

  /// Calendar, Drive and the finance mail sync independently: a problem with
  /// one never blocks the others.
  Future<_Outcome> _syncOnce({required bool manual}) async {
    final engine = _engine;
    if (engine == null) return const _Outcome();
    state = state.copyWith(syncing: true);
    final started = _now();
    final errors = <String>[];
    var ok = true, failed = false, busy = false, more = false;
    Duration? retryAfter;
    var throttled = false, daily = false;
    SyncBindingMismatch? mismatch;
    var parked = 0;

    void noteHint(RetryHint? h) {
      if (h == null) return;
      throttled |= h.throttled;
      daily |= h.dailyLimit;
      final r = h.retryAfter;
      if (r != null && (retryAfter == null || r > retryAfter!)) retryAfter = r;
    }

    // what each channel found, for the Diagnostics page (a channel this run
    // did not look at keeps what it had)
    final found = <String, ChannelStatus>{};
    void channel(
      String name, {
      String? code,
      List<String> lines = const [],
      int pulled = 0,
      int pushed = 0,
      int refused = 0,
    }) {
      found[name] = ChannelStatus(
        lastTry: started,
        lastOk: code == null ? started : state.channels[name]?.lastOk,
        code: code,
        text: lines.isEmpty ? null : lines.join(' '),
        pulled: pulled,
        pushed: pushed,
        failed: refused,
      );
    }

    try {
      final r = await engine.sync(syncCalendarId, manual: manual);
      final lines = <String>[];
      String? code;
      if (r.mismatch != null) {
        mismatch = r.mismatch;
        ok = false;
        code = 'mismatch';
      } else if (r.calendarGone) {
        ok = false;
        failed = true;
        code = 'gone';
        lines.add(calendarGoneText);
      } else if (r.stoppedEarly) {
        ok = false;
        failed = true;
        noteHint(r.hint);
        code = 'transient';
        lines.add(transientText('Naptár', r.hint));
      } else {
        parked = r.parked;
        if (r.parked > 0) {
          code = 'parked';
          lines.add(parkedText('Naptár', r.parked));
        }
        final refused = r.failed - r.parked;
        if (refused > 0) {
          code ??= 'refused';
          lines.add(refusedText('Naptár', refused));
        }
        if (r.skippedRemote > 0) {
          code ??= 'skipped';
          lines.add(skippedText('Naptár', r.skippedRemote));
        }
      }
      errors.addAll(lines);
      channel(
        channelCalendar,
        code: code,
        lines: lines,
        pulled: r.pulled,
        pushed: r.pushed,
        refused: r.failed,
      );
      if (code != null) {
        _log.info(
          'sync',
          'calendar.$code',
          data: {
            'pulled': r.pulled,
            'pushed': r.pushed,
            'failed': r.failed,
            'parked': r.parked,
            'skipped': r.skippedRemote,
            if (r.hint?.throttled ?? false) 'limit': true,
            if (r.hint?.dailyLimit ?? false) 'daily': true,
          },
        );
      }
      busy |= r.pulled > 0 || r.pushed > 0 || r.deferred > 0;
      more |= r.more;
    } catch (e, st) {
      if (isAuthExpired(e)) {
        await _expireLogin();
        return const _Outcome(expired: true);
      }
      ok = false;
      failed = true;
      final line = unexpectedText('Naptár');
      errors.add(line);
      channel(channelCalendar, code: 'unexpected', lines: [line]);
      _log.error('sync', 'calendar.unexpected', e, st);
    }

    DriveReport? driveReport;
    int? driveNewer;
    final drive = _drive;
    if (drive != null) {
      try {
        final r = await drive.sync();
        driveReport = r;
        final lines = <String>[];
        String? code;
        if (r.stoppedEarly) {
          ok = false;
          failed = true;
          noteHint(r.hint);
          code = 'transient';
          lines.add(transientText('Drive', r.hint));
        } else if (r.failed > 0) {
          code = 'push_failed';
          lines.add('Drive: ${r.failed} elemet nem sikerült feltölteni.');
        } else if (r.skippedCorrupt > 0) {
          code = 'corrupt';
          lines.add('Drive: ${r.skippedCorrupt} sérült fájlt kihagytam.');
        }
        if (!r.stoppedEarly) {
          driveNewer = r.newerFormat;
          if (r.newerFormat > 0) {
            code ??= 'newer';
            lines.add(newerFormatText('Drive', r.newerFormat));
          }
        }
        errors.addAll(lines);
        channel(
          channelDrive,
          code: code,
          lines: lines,
          pulled: r.pulled,
          pushed: r.pushed,
          refused: r.failed,
        );
        if (code != null) {
          _log.info(
            'sync',
            'drive.$code',
            data: {
              'pulled': r.pulled,
              'pushed': r.pushed,
              'failed': r.failed,
              'corrupt': r.skippedCorrupt,
              'newer': r.newerFormat,
            },
          );
        }
        busy |= r.pulled > 0 || r.pushed > 0;
      } catch (e, st) {
        if (isAuthExpired(e)) {
          await _expireLogin();
          return const _Outcome(expired: true);
        }
        ok = false;
        failed = true;
        final line = unexpectedText('Drive');
        errors.add(line);
        channel(channelDrive, code: 'unexpected', lines: [line]);
        _log.error('sync', 'drive.unexpected', e, st);
      }
    }

    // The mailbox is listed when Drive reported news about it, when there is
    // something to send, now and then as a safety net, and on request.
    final mail = _mail;
    String? note;
    int? financeNewer;
    if (mail != null) {
      final tick = _ticks++;
      final dirty = await ref.read(financeRepoProvider).dirtyCount();
      final look =
          manual ||
          driveReport == null ||
          driveReport.finChanged ||
          dirty > 0 ||
          tick % 5 == 0;
      if (look) {
        try {
          final r = await mail.sync();
          final lines = <String>[];
          String? code;
          if (r.stoppedEarly) {
            ok = false;
            failed = true;
            noteHint(r.hint);
            code = 'transient';
            lines.add(transientText('Pénzügy', r.hint));
          } else {
            if (r.corrupt > 0) {
              code = 'corrupt';
              lines.add('Pénzügy: ${r.corrupt} sérült levelet eldobtam.');
            }
            financeNewer = r.newerLetters;
            if (r.newerLetters > 0) {
              code ??= 'newer';
              lines.add(newerFormatText('Pénzügy', r.newerLetters));
            }
            if (r.sentLetters + r.receivedLetters > 0) {
              note =
                  'Pénzügy: ${r.sentLetters} levél elküldve, ${r.receivedLetters} megérkezett'
                  '${r.applied > 0 ? ' (${r.applied} tétel frissült)' : ''}.';
              busy = true;
            }
          }
          errors.addAll(lines);
          channel(
            channelFinance,
            code: code,
            lines: lines,
            pulled: r.receivedLetters,
            pushed: r.sentLetters,
          );
          if (code != null) {
            _log.info(
              'sync',
              'finance.$code',
              data: {
                'sent': r.sentLetters,
                'received': r.receivedLetters,
                'corrupt': r.corrupt,
                'newer': r.newerLetters,
              },
            );
          }
        } catch (e, st) {
          if (isAuthExpired(e)) {
            await _expireLogin();
            return const _Outcome(expired: true);
          }
          ok = false;
          failed = true;
          final line = unexpectedText('Pénzügy');
          errors.add(line);
          channel(channelFinance, code: 'unexpected', lines: [line]);
          _log.error('sync', 'finance.unexpected', e, st);
        }
      }
    }

    await _keepDiagnostics(driveNewer: driveNewer, financeNewer: financeNewer);

    final pending =
        (await ref.read(repoProvider).pending()).length +
        await ref.read(recordRepoProvider).dirtyCount();
    _lastRun = _now();
    state = state.copyWith(
      syncing: false,
      pending: pending,
      lastSync: ok ? _now() : null,
      financeNote: note,
      parked: parked,
      mismatch: mismatch,
      error: errors.isEmpty ? null : errors.join(' · '),
      clearError: errors.isEmpty,
      channels: {...state.channels, ...found},
    );
    return _Outcome(
      failed: failed,
      busy: busy,
      more: more,
      retryAfter: retryAfter,
      throttled: throttled,
      dailyLimit: daily,
    );
  }

  /// After a run: adds the counted requests to the stored table, and notes
  /// whether items of a newer version of the app were seen ([updateSightings]).
  /// Diagnostics must never break the sync, so nothing here throws.
  Future<void> _keepDiagnostics({int? driveNewer, int? financeNewer}) async {
    final events = ref.read(repoProvider);
    try {
      await ref.read(requestStatsProvider).flush(events.meta, events.setMeta);
    } catch (e, st) {
      _log.error('diag', 'stats.flush_failed', e, st);
    }
    if (driveNewer == null && financeNewer == null) return;
    try {
      final old = decodeNewerFormat(await events.meta(newerFormatKey));
      final now = updateSightings(
        old,
        now: _now(),
        drive: driveNewer,
        finance: financeNewer,
      );
      final before = encodeNewerFormat(old), after = encodeNewerFormat(now);
      if (before != after) {
        await events.setMeta(newerFormatKey, now.isEmpty ? null : after);
        if (now.isNotEmpty) {
          _log.info(
            'sync',
            'newer_format',
            data: {for (final e in now.entries) e.key: e.value.count},
          );
        }
      }
    } catch (e, st) {
      _log.error('diag', 'newer_format.save_failed', e, st);
    }
  }

  // ---------------------------------------------------------------- reset

  /// How many calendar events a fresh start would remove from this device.
  Future<int> localEventCount() =>
      ref.read(repoProvider).countLive(syncCalendarId);

  /// "Szinkron alaphelyzetbe": same account, everything linked again.
  Future<void> resetSync() async {
    final reset = _reset;
    if (reset == null) return;
    await reset.resetAll(syncCalendarId);
    await syncNow(manual: true);
  }

  /// Another account / calendar: keep the local events and upload them.
  Future<void> keepLocalAfterMismatch() async {
    final m = state.mismatch, reset = _reset;
    if (m == null || reset == null) return;
    await reset.rebindKeepLocal(syncCalendarId, m.current);
    state = state.copyWith(mismatch: null);
    await syncNow(manual: true);
  }

  /// Another account / calendar: remove the local events, take the new ones.
  Future<void> startFreshAfterMismatch() async {
    final m = state.mismatch, reset = _reset;
    if (m == null || reset == null) return;
    await reset.rebindFresh(syncCalendarId, m.current);
    state = state.copyWith(mismatch: null);
    await syncNow(manual: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        if (_engine == null) return;
        final last = _lastRun;
        if (last == null ||
            _now().difference(last) > const Duration(seconds: 30)) {
          syncNow();
        } else {
          final next = this.state.nextAttempt;
          final left = next == null ? SyncPacer.base : next.difference(_now());
          _arm(
            left < const Duration(seconds: 1)
                ? const Duration(seconds: 1)
                : left,
          );
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _foreground = false;
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break;
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
