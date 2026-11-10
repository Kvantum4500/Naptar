import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/event_repository.dart';
import '../drive/drive_remote.dart';
import '../drive/drive_sync_engine.dart';
import '../drive/finance_mailbox.dart';
import '../drive/google_drive_remote.dart';
import '../google/google_auth_service.dart';
import '../google/google_calendar_remote.dart';
import '../providers.dart';
import 'remote.dart';
import 'sync_engine.dart';

const syncCalendarId = kNaptarCalendar;

final googleConfiguredProvider = Provider<bool>(
  (_) => GoogleConfig.isConfigured,
);
final authGatewayProvider = Provider<AuthGateway>(
  (_) => GoogleAuthService(SecureCredentialStore()),
);
final driveFactoryProvider = Provider<DriveRemote Function(http.Client)>(
  (_) =>
      (c) => GoogleDriveRemote(c),
);
final remoteFactoryProvider = Provider<RemoteCalendar Function(http.Client)>(
  (_) =>
      (c) => GoogleCalendarRemote(c),
);

class SyncState {
  const SyncState({
    this.configured = false,
    this.signedIn = false,
    this.syncing = false,
    this.lastSync,
    this.pending = 0,
    this.error,
    this.financeNote,
  });
  final bool configured, signedIn, syncing;

  /// What the last finance mail run did (null when nothing happened).
  final String? financeNote;
  final DateTime? lastSync;
  final int pending;
  final String? error;

  SyncState copyWith({
    bool? signedIn,
    bool? syncing,
    DateTime? lastSync,
    int? pending,
    String? error,
    bool clearError = false,
    String? financeNote,
  }) => SyncState(
    configured: configured,
    signedIn: signedIn ?? this.signedIn,
    syncing: syncing ?? this.syncing,
    lastSync: lastSync ?? this.lastSync,
    pending: pending ?? this.pending,
    error: clearError ? null : (error ?? this.error),
    financeNote: financeNote ?? this.financeNote,
  );
}

/// Adaptive sync: right after local edits (debounced), when the app returns to
/// the foreground, and every minute while it runs. Android background runs and
/// push (turbo mode) come later.
class SyncController extends Notifier<SyncState> with WidgetsBindingObserver {
  SyncEngine? _engine;
  DriveSyncEngine? _drive;
  FinanceMailbox? _mail;
  Timer? _periodic, _debounce;

  @override
  SyncState build() {
    final configured = ref.watch(googleConfiguredProvider);
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _periodic?.cancel();
      _debounce?.cancel();
    });
    if (configured) Future.microtask(_restore);
    return SyncState(configured: configured);
  }

  Future<void> _restore() async {
    try {
      final client = await ref.read(authGatewayProvider).restore();
      if (client != null) await _start(client);
    } catch (e) {
      state = state.copyWith(error: 'Belépés visszaállítása sikertelen: $e');
    }
  }

  Future<void> signIn() async {
    if (!state.configured) return;
    try {
      state = state.copyWith(clearError: true);
      final client = await ref.read(authGatewayProvider).signIn();
      await _start(client);
    } catch (e) {
      state = state.copyWith(error: 'Belépés sikertelen: $e');
    }
  }

  Future<void> signOut() async {
    _periodic?.cancel();
    _engine = null;
    _drive = null;
    _mail = null;
    await ref.read(authGatewayProvider).signOut();
    state = state.copyWith(signedIn: false, syncing: false, clearError: true);
  }

  Future<void> _start(http.Client client) async {
    _engine = SyncEngine(
      ref.read(repoProvider),
      ref.read(remoteFactoryProvider)(client),
    );
    final driveRemote = ref.read(driveFactoryProvider)(client);
    _drive = DriveSyncEngine(ref.read(recordRepoProvider), driveRemote);
    _mail = FinanceMailbox(
      ref.read(financeRepoProvider),
      driveRemote,
      deviceId: await ref.read(recordRepoProvider).deviceId(),
    );
    state = state.copyWith(signedIn: true, clearError: true);
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
    await syncNow();
  }

  /// The saved Google login no longer works (refresh token expired or
  /// revoked; with an OAuth app in "Testing" mode this happens after 7 days).
  static bool isAuthExpired(Object e) {
    final t = '$e'.toLowerCase();
    return t.contains('invalid_grant') ||
        t.contains('expired or revoked') ||
        t.contains('failed to obtain access credentials');
  }

  /// Drops the dead session once and asks for a new sign-in. Local data and
  /// the queue of unsent changes are untouched; they upload after signing in.
  Future<void> _expireLogin() async {
    _periodic?.cancel();
    _debounce?.cancel();
    _engine = null;
    _drive = null;
    _mail = null;
    try {
      await ref.read(authGatewayProvider).signOut();
    } catch (_) {
      // nothing more to clean up
    }
    state = state.copyWith(
      signedIn: false,
      syncing: false,
      error: 'A Google-bejelentkezés lejárt. Jelentkezz be újra, az adataid megvannak, a függő módosítások utána feltöltődnek.',
    );
  }

  /// Call after any local change; coalesces bursts of edits into one run.
  void requestSync() {
    if (!state.signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), syncNow);
  }

  /// Calendar and Drive data sync independently: a problem with one never
  /// blocks the other.
  Future<void> syncNow() async {
    final engine = _engine;
    if (engine == null) return;
    state = state.copyWith(syncing: true);
    final errors = <String>[];
    var ok = true;
    try {
      final r = await engine.sync(syncCalendarId);
      if (r.stoppedEarly) {
        ok = false;
        errors.add('Naptár: nincs kapcsolat vagy limit, később újrapróbálja.');
      } else if (r.failed > 0) {
        errors.add('Naptár: ${r.failed} módosítást nem sikerült elküldeni.');
      }
    } catch (e) {
      if (isAuthExpired(e)) return _expireLogin();
      ok = false;
      errors.add('Naptár: $e');
    }
    final drive = _drive;
    if (drive != null) {
      try {
        final r = await drive.sync();
        if (r.stoppedEarly) {
          ok = false;
          errors.add('Drive: nincs kapcsolat vagy limit, később újrapróbálja.');
        } else if (r.failed > 0) {
          errors.add('Drive: ${r.failed} elemet nem sikerült feltölteni.');
        } else if (r.skippedCorrupt > 0) {
          errors.add('Drive: ${r.skippedCorrupt} sérült fájlt kihagytam.');
        }
      } catch (e) {
        if (isAuthExpired(e)) return _expireLogin();
        ok = false;
        errors.add('Drive: $e');
      }
    }
    final mail = _mail;
    String? note;
    if (mail != null) {
      try {
        final r = await mail.sync();
        if (r.stoppedEarly) {
          ok = false;
          errors.add(
            'Pénzügy: nincs kapcsolat vagy limit, később újrapróbálja.',
          );
        } else {
          if (r.corrupt > 0) {
            errors.add('Pénzügy: ${r.corrupt} sérült levelet eldobtam.');
          }
          if (r.sentLetters + r.receivedLetters > 0) {
            note =
                'Pénzügy: ${r.sentLetters} levél elküldve, ${r.receivedLetters} megérkezett'
                '${r.applied > 0 ? ' (${r.applied} tétel frissült)' : ''}.';
          }
        }
      } catch (e) {
        if (isAuthExpired(e)) return _expireLogin();
        ok = false;
        errors.add('Pénzügy: $e');
      }
    }
    final pending =
        (await ref.read(repoProvider).pending()).length +
        await ref.read(recordRepoProvider).dirtyCount();
    state = state.copyWith(
      syncing: false,
      pending: pending,
      lastSync: ok ? DateTime.now() : null,
      financeNote: note,
      error: errors.isEmpty ? null : errors.join(' · '),
      clearError: errors.isEmpty,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) syncNow();
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
