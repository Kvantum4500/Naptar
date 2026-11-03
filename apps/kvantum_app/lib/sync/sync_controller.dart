import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/event_repository.dart';
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
  });
  final bool configured, signedIn, syncing;
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
  }) => SyncState(
    configured: configured,
    signedIn: signedIn ?? this.signedIn,
    syncing: syncing ?? this.syncing,
    lastSync: lastSync ?? this.lastSync,
    pending: pending ?? this.pending,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Adaptive sync: right after local edits (debounced), when the app returns to
/// the foreground, and every minute while it runs. Android background runs and
/// push (turbo mode) come later.
class SyncController extends Notifier<SyncState> with WidgetsBindingObserver {
  SyncEngine? _engine;
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
    await ref.read(authGatewayProvider).signOut();
    state = state.copyWith(signedIn: false, syncing: false, clearError: true);
  }

  Future<void> _start(http.Client client) async {
    _engine = SyncEngine(
      ref.read(repoProvider),
      ref.read(remoteFactoryProvider)(client),
    );
    state = state.copyWith(signedIn: true, clearError: true);
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
    await syncNow();
  }

  /// Call after any local change; coalesces bursts of edits into one run.
  void requestSync() {
    if (!state.signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), syncNow);
  }

  Future<void> syncNow() async {
    final engine = _engine;
    if (engine == null) return;
    state = state.copyWith(syncing: true);
    try {
      final r = await engine.sync(syncCalendarId);
      final pending = (await ref.read(repoProvider).pending()).length;
      state = state.copyWith(
        syncing: false,
        pending: pending,
        lastSync: r.stoppedEarly ? null : DateTime.now(),
        error: r.stoppedEarly
            ? 'Nincs kapcsolat vagy limit, később újrapróbálja.'
            : (r.failed > 0
                  ? '${r.failed} módosítást nem sikerült elküldeni.'
                  : null),
        clearError: !r.stoppedEarly && r.failed == 0,
      );
    } catch (e) {
      state = state.copyWith(syncing: false, error: 'Szinkron hiba: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) syncNow();
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
