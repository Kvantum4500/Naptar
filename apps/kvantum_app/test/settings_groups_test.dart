import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings/account_card.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/diagnostics_page.dart';
import 'package:kvantum_app/ui/sync_status.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// A controller that only records what the screen asks of it.
class _Ctl extends SyncController {
  _Ctl(this.initial);
  final SyncState initial;
  final calls = <String>[];

  @override
  SyncState build() => initial;
  @override
  Future<int> localEventCount() async => 4;
  @override
  Future<void> signIn() async => calls.add('in');
  @override
  Future<void> signOut() async => calls.add('out');
  @override
  Future<void> syncNow({bool manual = false}) async =>
      calls.add(manual ? 'now-manual' : 'now');
  @override
  Future<void> resetSync() async => calls.add('reset');
  @override
  Future<void> keepLocalAfterMismatch() async => calls.add('keep');
}

SyncState signedIn({
  bool syncing = false,
  int pending = 0,
  int parked = 0,
  String? error,
  DateTime? next,
  DateTime? last,
  SyncBindingMismatch? mismatch,
  ({int done, int total})? upload,
}) => SyncState(
  configured: true,
  signedIn: true,
  syncing: syncing,
  pending: pending,
  parked: parked,
  error: error,
  nextAttempt: next,
  lastSync: last ?? DateTime(2026, 11, 12, 9, 30),
  mismatch: mismatch,
  upload: upload,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  _Ctl? ctl;

  Future<void> boot(
    WidgetTester tester, {
    SyncState? state,
    bool settle = true,
  }) async {
    // tall, so that the whole list is built at once
    useSize(tester, size: const Size(900, 6400));
    db = await newDb();
    ctl = state == null ? null : _Ctl(state);
    await tester.pumpWidget(
      app(
        const SettingsPage(),
        db,
        extra: [
          apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null)),
          currentBuildProvider.overrideWith((ref) async => 7),
          // five minutes after the last run of the fixtures
          syncClockProvider.overrideWithValue(
            () => DateTime(2026, 11, 12, 9, 35),
          ),
          if (ctl != null) syncControllerProvider.overrideWith(() => ctl!),
        ],
      ),
    );
    // (a spinner never lets the frames settle)
    settle
        ? await tester.pumpAndSettle()
        : await tester.pump(const Duration(milliseconds: 100));
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  group('the groups', () {
    testWidgets('the page is divided into five, in this order', (tester) async {
      await boot(tester);
      final titles = [
        for (final h in tester.widgetList<SettingsGroupHeader>(
          find.byType(SettingsGroupHeader),
        ))
          h.title,
      ];
      expect(titles, [
        'Fiók és szinkron',
        'Asszisztens',
        'Értesítések',
        'Adatok',
        'Névjegy',
      ]);
      // and they run down the page in that order
      final ys = [
        for (final t in titles)
          top(tester, find.widgetWithText(SettingsGroupHeader, t)),
      ];
      expect([...ys]..sort(), ys);
      await shutdown(tester, db);
    });

    testWidgets('every card is under its own group', (tester) async {
      await boot(tester);
      final y = <String, double>{
        for (final t in [
          'Fiók és szinkron',
          'Google-fiók',
          'Asszisztens',
          'AI-asszisztens',
          'Mit láthat az asszisztens?',
          'Időjárás és helyszín',
          'Alvási sáv',
          'Edzés utáni visszajelzés',
          'Kézikönyv',
          'Értesítések',
          'Emlékeztetők',
          'Google Wallet értesítések',
          'Adatok',
          'Mentés és visszaállítás',
          'Névjegy',
          'A program',
        ])
          t: top(tester, find.text(t)),
      };
      final order = y.keys.toList();
      for (var i = 1; i < order.length; i++) {
        expect(
          y[order[i]]!,
          greaterThan(y[order[i - 1]]!),
          reason: '${order[i]} should be below ${order[i - 1]}',
        );
      }
      await shutdown(tester, db);
    });

    testWidgets('a heading is marked as a heading for a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      expect(
        tester.getSemantics(find.text('Asszisztens')),
        matchesSemantics(label: 'Asszisztens', isHeader: true),
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the first text field is still the API key', (tester) async {
      await boot(tester);
      final first = tester.widget<TextField>(find.byType(TextField).first);
      expect(first.decoration?.labelText, 'API-kulcs');
      await shutdown(tester, db);
    });

    testWidgets(
      'the Diagnostics and the shortcuts buttons are where they were',
      (tester) async {
        await boot(tester);
        expect(find.byKey(const Key('open-diagnostics')), findsOneWidget);
        expect(find.byKey(const Key('open-shortcuts')), findsOneWidget);
        await shutdown(tester, db);
      },
    );
  });

  group('the account card', () {
    testWidgets('a build without Google says so, with no buttons', (
      tester,
    ) async {
      await boot(tester);
      expect(find.byKey(const Key('account-not-configured')), findsOneWidget);
      expect(
        find.textContaining('nincs beállítva a Google-bejelentkezés'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('account-sign-in')), findsNothing);
      expect(find.byKey(const Key('account-sync-now')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('signed out: says so and signs in', (tester) async {
      await boot(
        tester,
        state: const SyncState(configured: true, signedIn: false),
      );
      expect(find.byKey(const Key('account-signed-out')), findsOneWidget);
      expect(find.text('Belépés Google-lal'), findsOneWidget);
      expect(find.byKey(const Key('account-sync-now')), findsNothing);
      await tester.tap(find.byKey(const Key('account-sign-in')));
      expect(ctl!.calls, ['in']);
      await shutdown(tester, db);
    });

    testWidgets('an expired login shows the reason and one tap signs in', (
      tester,
    ) async {
      await boot(
        tester,
        state: const SyncState(
          configured: true,
          signedIn: false,
          error: 'A Google-bejelentkezés lejárt.',
        ),
      );
      expect(find.text('A Google-bejelentkezés lejárt.'), findsOneWidget);
      expect(find.text('Belépés szükséges'), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-sign-in')));
      expect(ctl!.calls, ['in']);
      await shutdown(tester, db);
    });

    testWidgets('signed in: the state, the last run and the buttons', (
      tester,
    ) async {
      await boot(tester, state: signedIn());
      expect(find.byKey(const Key('account-status')), findsOneWidget);
      expect(find.text('Szinkronban 09:30'), findsOneWidget);
      expect(
        find.text('Utolsó sikeres szinkron: 2026. november 12. 09:30'),
        findsOneWidget,
      );
      expect(find.text('Szinkron most'), findsOneWidget);
      expect(find.byKey(const Key('account-diagnostics')), findsOneWidget);
      expect(find.byKey(const Key('account-reset')), findsOneWidget);
      expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
      expect(find.byKey(const Key('account-decide')), findsNothing);
      expect(find.byKey(const Key('account-error')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('"Szinkron most" runs a manual sync', (tester) async {
      await boot(tester, state: signedIn());
      await tester.tap(find.byKey(const Key('account-sync-now')));
      expect(ctl!.calls, ['now-manual']);
      await shutdown(tester, db);
    });

    testWidgets('a failed or given-up sync offers "Újrapróbálás most"', (
      tester,
    ) async {
      await boot(tester, state: signedIn(error: 'Nincs kapcsolat.'));
      expect(find.text('Újrapróbálás most'), findsOneWidget);
      expect(find.text('Szinkron most'), findsNothing);
      expect(find.text('Nincs kapcsolat.'), findsOneWidget);
      await shutdown(tester, db);
      await boot(tester, state: signedIn(pending: 3, parked: 2));
      expect(find.text('Újrapróbálás most'), findsOneWidget);
      expect(
        find.text('3 módosítás vár feltöltésre (2 elakadt)'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('pending changes without trouble keep "Szinkron most"', (
      tester,
    ) async {
      await boot(tester, state: signedIn(pending: 3));
      expect(find.text('Szinkron most'), findsOneWidget);
      expect(find.text('3 módosítás vár feltöltésre'), findsOneWidget);
      expect(find.text('3 függőben'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the next automatic try is named when there is one', (
      tester,
    ) async {
      await boot(tester, state: signedIn(next: DateTime(2026, 11, 12, 9, 45)));
      expect(find.text('Következő automatikus próba: 09:45'), findsOneWidget);
      await shutdown(tester, db);
      await boot(tester, state: signedIn());
      expect(find.textContaining('Következő automatikus próba'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('while it uploads, how far it is', (tester) async {
      await boot(
        tester,
        state: signedIn(syncing: true, upload: (done: 3, total: 9)),
        settle: false,
      );
      expect(find.text('Feltöltés 3/9'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a decision needed (another account) has its own button', (
      tester,
    ) async {
      await boot(
        tester,
        state: signedIn(
          mismatch: const SyncBindingMismatch(
            stored: RemoteIdentity(account: 'anna@gmail.com', calendar: 'c1'),
            current: RemoteIdentity(account: 'bela@gmail.com', calendar: 'c2'),
          ),
        ),
      );
      expect(find.text('Döntés kell'), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-decide')));
      await tester.pumpAndSettle();
      expect(find.text(bindingTitleAccount), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('"Szinkron alaphelyzetbe…" asks first, then resets', (
      tester,
    ) async {
      await boot(tester, state: signedIn());
      await tester.tap(find.byKey(const Key('account-reset')));
      await tester.pumpAndSettle();
      expect(find.text(resetTitle), findsOneWidget);
      expect(ctl!.calls, isEmpty);
      await tester.tap(find.byKey(const Key('reset-go')));
      await tester.pumpAndSettle();
      expect(ctl!.calls, ['reset']);
      await shutdown(tester, db);
    });

    testWidgets('"Kilépés" signs out', (tester) async {
      await boot(tester, state: signedIn());
      await tester.tap(find.byKey(const Key('account-sign-out')));
      expect(ctl!.calls, ['out']);
      await shutdown(tester, db);
    });

    testWidgets('"Diagnosztika" opens the diagnostics page', (tester) async {
      await boot(tester, state: signedIn());
      await tester.tap(find.byKey(const Key('account-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('syncSummary, the words the button and the card share', () {
    final now = DateTime(2026, 11, 12, 12);

    ({IconData icon, String label, SyncTone tone}) of(SyncState s) =>
        syncSummary(s, now: now);

    test('in sync: the time of the last run', () {
      final s = of(signedIn(last: DateTime(2026, 11, 12, 11, 58)));
      expect(s.label, 'Szinkronban 11:58');
      expect(s.tone, SyncTone.ok);
      expect(s.icon, Icons.cloud_done_outlined);
    });

    test('in sync before the first run has a time', () {
      final s = of(const SyncState(configured: true, signedIn: true));
      expect(s.label, 'Szinkronban');
      expect(s.tone, SyncTone.ok);
    });

    test('the data is old after ten minutes', () {
      expect(
        of(signedIn(last: DateTime(2026, 11, 12, 11, 50))).label,
        'Szinkronban 11:50',
      );
      final s = of(signedIn(last: DateTime(2026, 11, 12, 11, 49)));
      expect(s.label, 'Régi adat');
      expect(s.tone, SyncTone.wait);
      expect(s.icon, Icons.schedule);
    });

    test('changes waiting to go up', () {
      final s = of(signedIn(pending: 4, last: now));
      expect(s.label, '4 függőben');
      expect(s.tone, SyncTone.wait);
      expect(s.icon, Icons.cloud_upload_outlined);
    });

    test('an error', () {
      final s = of(signedIn(error: 'x', last: now));
      expect(s.label, 'Hiba');
      expect(s.tone, SyncTone.bad);
      expect(s.icon, Icons.error_outline);
    });

    test('a decision needed is louder than an error', () {
      final s = of(
        signedIn(
          error: 'x',
          last: now,
          mismatch: const SyncBindingMismatch(
            stored: RemoteIdentity(account: 'a', calendar: 'c'),
            current: RemoteIdentity(account: 'b', calendar: 'c'),
          ),
        ),
      );
      expect(s.label, 'Döntés kell');
      expect(s.tone, SyncTone.bad);
      expect(s.icon, Icons.sync_problem);
    });

    test(
      'a run in progress comes first, with the upload when there is one',
      () {
        expect(
          of(signedIn(syncing: true, error: 'x', pending: 2)).label,
          'Szinkronizál…',
        );
        expect(
          of(signedIn(syncing: true, upload: (done: 2, total: 5))).label,
          'Feltöltés 2/5',
        );
        expect(of(signedIn(syncing: true)).tone, SyncTone.ok);
      },
    );

    test('an error is louder than changes waiting', () {
      expect(of(signedIn(error: 'x', pending: 2, last: now)).label, 'Hiba');
    });

    test('the tones have the colours of the theme', () {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
      expect(syncToneColor(SyncTone.ok, scheme), scheme.primary);
      expect(syncToneColor(SyncTone.wait, scheme), scheme.tertiary);
      expect(syncToneColor(SyncTone.bad, scheme), scheme.error);
    });
  });
}
