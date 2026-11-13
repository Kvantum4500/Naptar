import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/notify/reminders.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/month_view.dart';
import 'package:kvantum_app/ui/setup_guide.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// A scheduler that can remind, and counts being asked for anything.
class _Scheduler extends NoopReminderScheduler {
  int asked = 0;

  @override
  bool get supported => true;

  @override
  Future<bool> ensurePermission() async {
    asked++;
    return true;
  }
}

/// A controller that only records what the card asks of it.
class _Ctl extends SyncController {
  _Ctl(this.initial);
  final SyncState initial;
  int signIns = 0;

  @override
  SyncState build() => initial;

  @override
  Future<void> signIn() async {
    signIns++;
  }

  void signedInNow() => state = state.copyWith(signedIn: true);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('which step comes next', () {
    const all = SetupFacts(
      googleConfigured: true,
      remindersSupported: true,
      walletSupported: true,
    );

    test('the first one that is not done, in the order they are offered', () {
      final next = nextSetupStep(all, {})!;
      expect(next.step, SetupStep.signIn);
      expect((next.number, next.total), (1, 5));
    });

    test('a step that is done is passed over and counted', () {
      final facts = SetupFacts(
        googleConfigured: true,
        signedIn: true,
        aiKey: true,
        remindersSupported: true,
        walletSupported: true,
      );
      final next = nextSetupStep(facts, {})!;
      expect(next.step, SetupStep.place);
      expect((next.number, next.total), (3, 5));
    });

    test('a step set aside is passed over and counted as well', () {
      final next = nextSetupStep(all, {SetupStep.signIn, SetupStep.aiKey})!;
      expect(next.step, SetupStep.place);
      expect((next.number, next.total), (3, 5));
    });

    test('what the device cannot do is never offered, nor counted', () {
      // no Google keys in this build, no reminders and no Wallet here
      final next = nextSetupStep(const SetupFacts(), {})!;
      expect(next.step, SetupStep.aiKey);
      expect((next.number, next.total), (1, 2));
      expect(
        nextSetupStep(const SetupFacts(aiKey: true), {})!.step,
        SetupStep.place,
      );
    });

    test('nothing is left when every step is done or set aside', () {
      expect(
        nextSetupStep(const SetupFacts(aiKey: true, place: true), {}),
        isNull,
      );
      expect(
        nextSetupStep(const SetupFacts(), {SetupStep.aiKey, SetupStep.place}),
        isNull,
      );
      expect(
        nextSetupStep(const SetupFacts(aiKey: true), {SetupStep.place}),
        isNull,
      );
    });

    test('a step done later than a skipped one does not reorder', () {
      final next = nextSetupStep(
        const SetupFacts(place: true, remindersSupported: true),
        {SetupStep.aiKey},
      )!;
      expect(next.step, SetupStep.reminders);
      expect((next.number, next.total), (3, 3));
    });
  });

  group('the card', () {
    late AppDatabase db;
    late MemoryApiKeyStore keys;
    late _Ctl ctl;
    late ProviderContainer c;

    Future<void> mount(
      WidgetTester tester, {
      bool guide = true,
      bool configured = false,
      bool signedIn = false,
      FakeWallet? wallet,
      _Scheduler? scheduler,
      double? textScale,
      Size size = const Size(900, 900),
    }) async {
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          textScale: textScale,
          theme: appTheme(Brightness.light),
          extra: [
            setupGuideProvider.overrideWithValue(guide),
            apiKeyStoreProvider.overrideWithValue(keys),
            if (configured) syncControllerProvider.overrideWith(() => ctl),
            if (wallet != null) walletBridgeProvider.overrideWithValue(wallet),
            if (scheduler != null)
              reminderSchedulerProvider.overrideWithValue(scheduler),
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
    }

    Future<void> boot(
      WidgetTester tester, {
      String? apiKey,
      bool configured = false,
      bool signedIn = false,
      FakeWallet? wallet,
      _Scheduler? scheduler,
      bool guide = true,
      double? textScale,
      Size size = const Size(900, 900),
      Future<void> Function()? seed,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      keys = MemoryApiKeyStore(apiKey);
      ctl = _Ctl(SyncState(configured: configured, signedIn: signedIn));
      if (seed != null) await tester.runAsync(seed);
      await mount(
        tester,
        guide: guide,
        configured: configured,
        signedIn: signedIn,
        wallet: wallet,
        scheduler: scheduler,
        textScale: textScale,
      );
    }

    /// Closes the app and opens it again on the same database (a new start).
    Future<void> restart(
      WidgetTester tester, {
      FakeWallet? wallet,
      _Scheduler? scheduler,
    }) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
      await mount(tester, wallet: wallet, scheduler: scheduler);
    }

    Future<void> done(WidgetTester tester) => shutdown(tester, db);

    Finder card() => find.byKey(const Key('setup-card'));
    Finder step(String title) =>
        find.descendant(of: card(), matching: find.text(title));
    Future<String?> meta(WidgetTester tester, String key) =>
        tester.runAsync(() => EventRepository(db).meta(key)).then((v) => v);

    testWidgets('a fresh installation is offered the first step', (
      tester,
    ) async {
      await boot(tester);
      expect(card(), findsOneWidget);
      expect(step('Első lépések · 1/2'), findsOneWidget);
      expect(step('AI-kulcs megadása'), findsOneWidget);
      expect(find.text('Elrejtés'), findsOneWidget);
      expect(find.text('Nem kell'), findsOneWidget);
      expect(find.text('Megnyitás'), findsOneWidget);
      await done(tester);
    });

    testWidgets('the guide is off unless the app switches it on', (
      tester,
    ) async {
      await boot(tester, guide: false);
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('with a key, the next step is the place', (tester) async {
      await boot(tester, apiKey: 'k');
      expect(step('Első lépések · 2/2'), findsOneWidget);
      expect(step('Hely megadása (nem kötelező)'), findsOneWidget);
      await done(tester);
    });

    testWidgets('it is gone when everything is done', (tester) async {
      await boot(tester, apiKey: 'k');
      final ai = c.read(aiSettingsProvider.notifier);
      await tester.runAsync(
        () => ai.change(
          const AiSettings().copyWith(
            place: Place(name: 'Budapest', lat: 47.5, lon: 19.05),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('"Nem kell" sets a step aside, also after a new start', (
      tester,
    ) async {
      await boot(tester);
      await tester.tap(find.text('Nem kell'));
      await tester.pumpAndSettle();
      expect(step('Hely megadása (nem kötelező)'), findsOneWidget);
      expect(await meta(tester, 'setup.skip.aiKey'), '1');
      expect(await meta(tester, 'setup.skip.place'), isNull);

      await restart(tester);
      expect(step('Hely megadása (nem kötelező)'), findsOneWidget);
      expect(step('AI-kulcs megadása'), findsNothing);
      await done(tester);
    });

    testWidgets('the card goes when the last step is set aside', (
      tester,
    ) async {
      await boot(tester, apiKey: 'k');
      await tester.tap(find.text('Nem kell'));
      await tester.pumpAndSettle();
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('"Elrejtés" hides it for good, also after a new start', (
      tester,
    ) async {
      await boot(tester);
      await tester.tap(find.text('Elrejtés'));
      await tester.pumpAndSettle();
      expect(card(), findsNothing);
      expect(await meta(tester, 'setup.dismissed'), '1');

      await restart(tester);
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('"Megnyitás" opens Settings; a key saved there moves it on', (
      tester,
    ) async {
      await boot(tester);
      await tester.tap(find.text('Megnyitás'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // a key is saved there (the card looks again when the page is closed)
      await tester.runAsync(() => keys.write('k', provider: 'gemini'));
      Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(step('Hely megadása (nem kötelező)'), findsOneWidget);
      await done(tester);
    });

    testWidgets('it looks at the device and asks for nothing', (tester) async {
      final scheduler = _Scheduler();
      final wallet = FakeWallet(enabled: false);
      await boot(tester, wallet: wallet, scheduler: scheduler);
      expect(card(), findsOneWidget);
      expect(scheduler.asked, 0); // no notification permission asked for
      expect(wallet.listenerOpened, 0); // no system page opened
      expect(wallet.appInfoOpened, 0);
      expect(wallet.drains, 0); // nothing read from Wallet
      await done(tester);
    });

    testWidgets('on a phone the reminders and the Wallet come after', (
      tester,
    ) async {
      final scheduler = _Scheduler();
      final wallet = FakeWallet(enabled: false);
      await boot(tester, apiKey: 'k', wallet: wallet, scheduler: scheduler);
      // (the place first)
      expect(step('Első lépések · 2/4'), findsOneWidget);
      await tester.tap(find.text('Nem kell'));
      await tester.pumpAndSettle();
      expect(step('Első lépések · 3/4'), findsOneWidget);
      expect(step('Emlékeztetők bekapcsolása'), findsOneWidget);
      await tester.tap(find.text('Nem kell'));
      await tester.pumpAndSettle();
      expect(step('Első lépések · 4/4'), findsOneWidget);
      expect(step('Wallet-fizetések átvétele (nem kötelező)'), findsOneWidget);
      await done(tester);
    });

    testWidgets('reminders that are on, and Wallet access that is given, '
        'count as done', (tester) async {
      await boot(
        tester,
        apiKey: 'k',
        wallet: FakeWallet(), // access given, booking on by default
        scheduler: _Scheduler(),
        seed: () async {
          final repo = EventRepository(db);
          await repo.setMeta('rem.checkin', 'on');
          await repo.setMeta(
            'setup.skip.place',
            '1',
          ); // (the place was set aside)
        },
      );
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('Wallet access without the booking switched on is not done', (
      tester,
    ) async {
      await boot(
        tester,
        apiKey: 'k',
        wallet: FakeWallet(),
        seed: () async {
          final repo = EventRepository(db);
          await repo.setMeta('setup.skip.place', '1');
          await repo.setMeta('fin.walletAuto', 'off');
        },
      );
      expect(step('Wallet-fizetések átvétele (nem kötelező)'), findsOneWidget);
      await done(tester);
    });

    testWidgets('coming back to the app looks again (Wallet access given)', (
      tester,
    ) async {
      final wallet = FakeWallet(enabled: false);
      await boot(
        tester,
        apiKey: 'k',
        wallet: wallet,
        seed: () => EventRepository(db).setMeta('setup.skip.place', '1'),
      );
      expect(step('Wallet-fizetések átvétele (nem kötelező)'), findsOneWidget);

      // the user gave the access in the system's settings and came back
      wallet.enabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(card(), findsNothing);
      await done(tester);
    });

    testWidgets('with Google keys the login comes first, and signs in', (
      tester,
    ) async {
      await boot(tester, configured: true);
      expect(step('Első lépések · 1/3'), findsOneWidget);
      expect(step('Belépés a Google-fiókkal'), findsOneWidget);
      await tester.tap(find.text('Belépés'));
      await tester.pumpAndSettle();
      expect(ctl.signIns, 1);

      // signed in: the next step
      ctl.signedInNow();
      await tester.pumpAndSettle();
      expect(step('AI-kulcs megadása'), findsOneWidget);
      expect(step('Első lépések · 2/3'), findsOneWidget);
      await done(tester);
    });

    testWidgets('Settings can bring the guide back', (tester) async {
      await boot(tester);
      await tester.tap(find.text('Elrejtés'));
      await tester.pumpAndSettle();
      expect(card(), findsNothing);

      // (Settings is a long page: a tall window shows it all)
      tester.view.physicalSize = const Size(900, 4200);
      Navigator.of(tester.element(find.byType(HomePage)))
          .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reset-setup')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Az első lépések újra megjelennek'), findsOne);
      expect(await meta(tester, 'setup.dismissed'), isNull);

      Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      await tester.pumpAndSettle();
      expect(step('AI-kulcs megadása'), findsOneWidget);
      await done(tester);
    });

    testWidgets('it is read out as a heading with its step', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      expect(
        tester.getSemantics(find.text('Első lépések · 1/2')),
        containsSemantics(label: 'Első lépések · 1/2', isHeader: true),
      );
      handle.dispose();
      await done(tester);
    });

    testWidgets('the banners never take more than a third of the screen', (
      tester,
    ) async {
      // a phone, at the largest text size: the guide and the check-in are two
      // tall banners
      await boot(tester, textScale: 2.0, size: const Size(360, 640));
      expect(card(), findsOneWidget);
      final banners = tester.getSize(find.byKey(const Key('home-banners')));
      expect(banners.height, lessThanOrEqualTo(640 / 3 + 0.01));
      // and the calendar still has the room
      expect(
        tester.getSize(find.byType(MonthView)).height,
        greaterThan(640 / 3),
      );
      await done(tester);
    });
  });
}
