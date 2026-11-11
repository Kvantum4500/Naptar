import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_page.dart';
import 'package:kvantum_app/ai/handbook_page.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/location_service.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/weather_service.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/backup_ops.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/ui/backup_io.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/fake_wallet.dart';
import 'support/harness.dart';

/// Lists models for the settings page and answers `generate` from a script.
class FakeGemini extends FakeLlm {
  FakeGemini(
    super.script, {
    this.available = const [
      LlmModel('gemini-2.5-flash', 'Flash'),
      LlmModel('gemini-2.5-pro', 'Pro'),
    ],
    this.listError,
  });
  final List<LlmModel> available;
  final LlmException? listError;
  @override
  Future<List<LlmModel>> listModels() async {
    if (listError != null) throw listError!;
    return available;
  }
}

/// A model that answers only when the test lets it.
class GatedGemini extends FakeGemini {
  GatedGemini() : super([]);
  final gate = Completer<LlmReply>();
  @override
  Future<LlmReply> generate(String model, LlmRequest request) {
    requests.add(request);
    return gate.future;
  }
}

/// The list of models is slow; closing the connection (the app's "Mégse")
/// makes the pending call fail, as a real client does.
class SlowModelsGemini extends FakeGemini {
  SlowModelsGemini() : super([]);
  final _models = Completer<List<LlmModel>>();
  @override
  Future<List<LlmModel>> listModels() => _models.future;
  @override
  void close() {
    super.close();
    if (!_models.isCompleted) {
      _models.completeError(
        const LlmNetwork('Nincs kapcsolat: Client is already closed'),
      );
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late MemoryApiKeyStore keys;
  late EventRepository events;

  Future<void> boot(
    WidgetTester tester,
    Widget home, {
    FakeGemini? llm,
    String? key,
    bool stubHandbook = true,
    BackupIo? io,
    LocationProvider? location,
    WeatherService? weatherSvc,
    FakeWallet? wallet,
  }) async {
    useSize(tester);
    db = await newDb();
    events = EventRepository(db);
    keys = MemoryApiKeyStore(key);
    await tester.pumpWidget(
      app(
        home,
        db,
        extra: [
          apiKeyStoreProvider.overrideWithValue(keys),
          if (io != null) backupIoProvider.overrideWithValue(io),
          if (location != null) locationProvider.overrideWithValue(location),
          if (wallet != null) walletBridgeProvider.overrideWithValue(wallet),
          if (weatherSvc != null)
            weatherServiceProvider.overrideWithValue(weatherSvc),
          llmFactoryProvider.overrideWithValue((cfg) => llm ?? FakeGemini([])),
          // Monday 2026-05-04, 10:00 Budapest: the plan fixtures lie after it
          aiClockProvider.overrideWithValue(() => DateTime.utc(2026, 5, 4, 8)),
          currentBuildProvider.overrideWith((ref) async => 7),
          // The bundled assets are covered by the handbook page test; the
          // assistant tests use a stub so they do not depend on the test
          // harness' asset loading.
          if (stubHandbook)
            handbookStoreProvider.overrideWith(
              (ref) => HandbookStore(
                ref.watch(recordRepoProvider),
                loader: (p) async => 'ALAP[$p]',
              ),
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  group('wallet notification settings', () {
    Future<void> show(WidgetTester tester, String text) async {
      final f = find.text(text);
      await tester.scrollUntilVisible(
        f,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    testWidgets('where Wallet cannot be read it says so', (tester) async {
      await boot(
        tester,
        const SettingsPage(),
        wallet: FakeWallet(supported: false),
      );
      await show(tester, 'Google Wallet értesítések');
      expect(find.textContaining('csak Androidon működik'), findsOneWidget);
      expect(find.text('Hozzáférés megadása'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('without access it explains the restricted-settings step', (
      tester,
    ) async {
      final w = FakeWallet(enabled: false);
      await boot(tester, const SettingsPage(), wallet: w);
      await show(tester, 'Hozzáférés megadása');
      expect(
        find.text('Az értesítés-hozzáférés nincs megadva.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Korlátozott beállítások engedélyezése'),
        findsOneWidget,
      );
      await tester.tap(find.text('Hozzáférés megadása'));
      await tester.pump();
      expect(w.listenerOpened, 1);
      await tester.ensureVisible(find.text('Alkalmazás-infó megnyitása'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alkalmazás-infó megnyitása'));
      await tester.pump();
      expect(w.appInfoOpened, 1);
      await shutdown(tester, db);
    });

    testWidgets('with access the hint is gone and the switch persists', (
      tester,
    ) async {
      await boot(tester, const SettingsPage(), wallet: FakeWallet());
      await show(tester, 'Hozzáférés megadása');
      expect(
        find.text('Az értesítés-hozzáférés meg van adva.'),
        findsOneWidget,
      );
      expect(find.textContaining('Korlátozott beállítások'), findsNothing);
      await show(tester, 'Automatikus felvétel');
      await tester.tap(find.text('Automatikus felvétel'));
      await tester.pumpAndSettle();
      final off = await tester.runAsync(
        () => ref0(tester).read(walletIngestProvider).auto,
      );
      expect(off, isFalse);
      await shutdown(tester, db);
    });

    testWidgets('the log shows the received notifications, masked', (
      tester,
    ) async {
      final w = FakeWallet(
        queue: [note('SPAR', 'Mastercard •••• 1234 · 3 490 Ft', 1000)],
      );
      await boot(tester, const SettingsPage(), wallet: w);
      await show(tester, 'Legutóbbi értesítések');
      await tester.tap(find.text('Legutóbbi értesítések'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Még nem érkezett'), findsOneWidget);
      await tester.tap(find.text('Bezár'));
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => ref0(tester).read(walletIngestProvider).run(),
      );
      await tester.tap(find.text('Legutóbbi értesítések'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SPAR'), findsWidgets);
      expect(find.textContaining('felvéve'), findsOneWidget);
      expect(find.textContaining('1234'), findsNothing);
      expect(find.text('Másolás'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('weather and place settings', () {
    Future<void> show(WidgetTester tester, String text) async {
      final f = find.text(text);
      await tester.scrollUntilVisible(
        f,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    Future<Place?> savedPlace(WidgetTester tester) async =>
        (await tester.runAsync(
          () => ref0(tester).read(aiSettingsStoreProvider).load(),
        ))!.place;

    testWidgets('GPS sets the place (rounded) and it can be cleared', (
      tester,
    ) async {
      await boot(
        tester,
        const SettingsPage(),
        location: _FakeLocation(
          LocationResult.ok(Place(name: '', lat: 47.49801, lon: 19.04021)),
        ),
      );
      await show(tester, 'Helyzet meghatározása (GPS)');
      expect(find.textContaining('nincs megadva'), findsOneWidget);
      await tester.tap(find.text('Helyzet meghatározása (GPS)'));
      await tester.pumpAndSettle();
      expect(find.text('Helyszín: 47.50, 19.04'), findsOneWidget);
      expect((await savedPlace(tester))!.lat, 47.5);

      await tester.tap(find.text('Helyszín törlése'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nincs megadva'), findsOneWidget);
      expect(await savedPlace(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets(
      'a refused or unavailable GPS explains itself and sets nothing',
      (tester) async {
        for (final c in [
          (LocationFailure.denied, 'nem engedélyezted'),
          (LocationFailure.deniedForever, 'tiltva van'),
          (LocationFailure.serviceOff, 'ki van kapcsolva'),
          (LocationFailure.unavailable, 'Gépen gyakran nincs GPS'),
        ]) {
          await boot(
            tester,
            const SettingsPage(),
            location: _FakeLocation(LocationResult.fail(c.$1)),
          );
          await show(tester, 'Helyzet meghatározása (GPS)');
          await tester.tap(find.text('Helyzet meghatározása (GPS)'));
          await tester.pumpAndSettle();
          expect(find.textContaining(c.$2), findsOneWidget, reason: '${c.$1}');
          expect(await savedPlace(tester), isNull);
          await shutdown(tester, db);
        }
      },
    );

    testWidgets('a typed city is searched and picked', (tester) async {
      final svc = WeatherService(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'results': [
                {
                  'name': 'Győr',
                  'country': 'Magyarország',
                  'latitude': 47.68333,
                  'longitude': 17.63512,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await boot(tester, const SettingsPage(), weatherSvc: svc);
      await show(tester, 'Vagy keress rá a városodra');
      await tester.enterText(find.byType(TextField).last, 'Győr');
      await tester.tap(find.byTooltip('Keresés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Győr, Magyarország'));
      await tester.pumpAndSettle();
      expect(find.text('Helyszín: Győr, Magyarország'), findsOneWidget);
      final p = (await savedPlace(tester))!;
      expect((p.name, p.lat, p.lon), ('Győr, Magyarország', 47.68, 17.64));
      await shutdown(tester, db);
    });

    testWidgets('the switch turns weather off and hides the place controls', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      await show(tester, 'Időjárás használata a tervezéshez');
      expect(find.text('Helyzet meghatározása (GPS)'), findsOneWidget);
      await tester.tap(find.text('Időjárás használata a tervezéshez'));
      await tester.pumpAndSettle();
      expect(find.text('Helyzet meghatározása (GPS)'), findsNothing);
      expect(
        (await tester.runAsync(
          () => ref0(tester).read(aiSettingsStoreProvider).load(),
        ))!.weather,
        isFalse,
      );
      await shutdown(tester, db);
    });
  });

  group('backup', () {
    testWidgets('export saves an .ics, import restores it without duplicates', (
      tester,
    ) async {
      final io = _MemoryIo();
      await boot(tester, const SettingsPage(), io: io);
      await tester.runAsync(
        () =>
            events.saveLocal(evt('b1', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Mentés fájlba'),
        200,
        scrollable: scroll,
      );
      await tester.ensureVisible(find.text('Mentés fájlba'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentés fájlba'));
      await tester.pumpAndSettle();
      expect(io.saved, contains('SUMMARY:Fogorvos'));
      expect(find.text('A naptár elmentve.'), findsOneWidget);

      // delete, then restore
      await tester.runAsync(() => events.deleteLocal('b1'));
      io.toPick = io.saved;
      await tester.ensureVisible(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Visszaállítva: 1 új, 0 frissítve, 0 változatlan'),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(() => events.byId('b1')))!.start,
        floating(2026, 11, 20, 9),
      );

      // a second restore changes nothing
      await tester.ensureVisible(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('0 új, 0 frissítve, 1 változatlan'),
        findsOneWidget,
      );
      expect((await tester.runAsync(() => events.all()))!.length, 1);
      await shutdown(tester, db);
    });

    testWidgets('finance data can be saved and restored from a file', (
      tester,
    ) async {
      final io = _MemoryIo();
      await boot(tester, const SettingsPage(), io: io);
      final fin = ref0(tester).read(financeRepoProvider);
      await tester.runAsync(
        () => fin.saveTx(
          FinTx(
            id: 'f1',
            date: floating(2026, 11, 8),
            amount: 3490,
            kind: FinKind.expense,
            merchant: 'SPAR',
          ),
        ),
      );
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Pénzügyek mentése'),
        200,
        scrollable: scroll,
      );
      await tester.ensureVisible(find.text('Pénzügyek mentése'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pénzügyek mentése'));
      await tester.pumpAndSettle();
      expect(io.saved, contains('SPAR'));
      expect(find.text('A pénzügyi adatok elmentve.'), findsOneWidget);

      await tester.runAsync(() => fin.deleteTx('f1'));
      io.toPick = io.saved;
      await tester.ensureVisible(find.text('Pénzügyek visszaállítása'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pénzügyek visszaállítása'));
      await tester.pumpAndSettle();
      // the tombstone is newer than the backup, so nothing is resurrected
      expect(find.textContaining('naprakész'), findsOneWidget);
      expect((await tester.runAsync(fin.txs))!, isEmpty);

      io.toPick = 'ez nem pénzügyi adat';
      await tester.tap(find.text('Pénzügyek visszaállítása'));
      await tester.pumpAndSettle();
      expect(find.text('Ez nem pénzügyi mentésfájl.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('restoring a changed event keeps its Google link', (
      tester,
    ) async {
      final io = _MemoryIo();
      await boot(tester, const SettingsPage(), io: io);
      final linked = evt(
        'b2',
        'Edzés',
        floating(2026, 11, 20, 9),
      ).copyWith(googleId: 'g-1', etag: 'e-1');
      await tester.runAsync(() => events.saveLocal(linked));
      final backup = await tester.runAsync(() => exportBackup(events));
      await tester.runAsync(
        () => events.saveLocal(linked.copyWith(title: 'Átírt')),
      );
      io.toPick = backup;
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Visszaállítás fájlból'),
        200,
        scrollable: scroll,
      );
      await tester.ensureVisible(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      // the event changed since the backup: the app asks before overwriting
      expect(find.byKey(const Key('import-choice')), findsOneWidget);
      expect(
        (await tester.runAsync(() => events.byId('b2')))!.title,
        'Átírt',
        reason: 'nothing is written before the answer',
      );
      await tester.tap(find.byKey(const Key('import-all')));
      await tester.pumpAndSettle();
      final e = (await tester.runAsync(() => events.byId('b2')))!;
      expect(e.title, 'Edzés');
      expect(e.googleId, 'g-1');
      expect(e.version, greaterThan(linked.version + 1));
      await shutdown(tester, db);
    });

    testWidgets('a restore never overwrites a changed event unasked', (
      tester,
    ) async {
      final io = _MemoryIo();
      await boot(tester, const SettingsPage(), io: io);
      final changed = evt('c1', 'Edzés', floating(2026, 11, 20, 9));
      final gone = evt('c2', 'Fogorvos', floating(2026, 11, 21, 9));
      await tester.runAsync(() => events.saveAll([changed, gone]));
      final backup = (await tester.runAsync(() => exportBackup(events)))!;
      await tester.runAsync(() async {
        await events.saveLocal(changed.copyWith(title: 'Átírt'));
        await events.deleteLocal('c2');
      });
      io.toPick = backup;
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Visszaállítás fájlból'),
        200,
        scrollable: scroll,
      );
      Future<void> restore() async {
        await tester.ensureVisible(find.text('Visszaállítás fájlból'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Visszaállítás fájlból'));
        await tester.pumpAndSettle();
      }

      // Mégse: nothing at all is written, not even the missing event
      await restore();
      expect(find.byKey(const Key('import-choice')), findsOneWidget);
      expect(find.textContaining('Átírt'), findsOneWidget, reason: 'listed');
      await tester.tap(find.byKey(const Key('import-cancel')));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(() => events.byId('c1')))!.title, 'Átírt');
      expect(await tester.runAsync(() => events.byId('c2')), isNull);

      // Csak az újak: the missing event returns, the changed one stays
      await restore();
      await tester.tap(find.byKey(const Key('import-new')));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(() => events.byId('c1')))!.title, 'Átírt');
      expect(await tester.runAsync(() => events.byId('c2')), isNotNull);
      expect(
        find.textContaining('1 módosult eseményt nem írtam felül'),
        findsOneWidget,
      );

      // the second time there is nothing new: only the overwrite is offered
      await restore();
      expect(find.byKey(const Key('import-new')), findsNothing);
      await tester.tap(find.text('Felülírás'));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(() => events.byId('c1')))!.title, 'Edzés');
      await shutdown(tester, db);
    });

    testWidgets('a cancelled picker or a junk file changes nothing', (
      tester,
    ) async {
      final io = _MemoryIo();
      await boot(tester, const SettingsPage(), io: io);
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Visszaállítás fájlból'),
        200,
        scrollable: scroll,
      );
      await tester.ensureVisible(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Visszaállítás fájlból')); // cancelled
      await tester.pumpAndSettle();
      expect(find.textContaining('Visszaállítva'), findsNothing);
      io.toPick = 'ez nem naptár';
      await tester.ensureVisible(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Visszaállítás fájlból'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nem találtam beolvasható'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('settings page', () {
    testWidgets(
      'a good key is checked against the model list, saved, and a default model is chosen',
      (tester) async {
        await boot(tester, const SettingsPage());
        expect(find.text('Nincs API-kulcs'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, 'AIza-good');
        await tester.tap(find.text('Mentés és ellenőrzés'));
        // (the button spins while the key is checked: pumpAndSettle would wait
        // for it forever) the first key at a provider asks what goes out
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.text('Mi megy ki a(z) Google Gemini felé?'),
          findsOneWidget,
        );
        expect(keys.value, isNull); // nothing is kept before the answer
        await tester.tap(find.text('Rendben, folytatom'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Rendben van, elmentve'), findsOneWidget);
        expect(find.text('API-kulcs megadva'), findsOneWidget);
        expect(keys.value, 'AIza-good');
        final s = await tester.runAsync(
          () => ref0(tester).read(aiSettingsStoreProvider).load(),
        );
        expect(s!.model, 'gemini-2.5-flash');
        // the key never lands in the database
        final dbDump = (await tester.runAsync(
          () => db.select(db.metaRows).get(),
        ))!.map((r) => '${r.key}${r.value}').join();
        expect(dbDump.contains('AIza'), isFalse);
        await shutdown(tester, db);
      },
    );

    // ---- the first key at a provider says what goes out
    Future<void> saveKey(WidgetTester tester, String key) async {
      await tester.enterText(find.byType(TextField).first, key);
      await tester.tap(find.text('Mentés és ellenőrzés'));
      // (the button spins while the key is checked: no pumpAndSettle)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Finder inDialog(String text) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(text),
    );

    testWidgets(
      '"Mégsem használom": the key is not kept, nothing is remembered',
      (tester) async {
        await boot(tester, const SettingsPage());
        await saveKey(tester, 'AIza-good');
        expect(
          find.text('Mi megy ki a(z) Google Gemini felé?'),
          findsOneWidget,
        );
        // what always goes, and the switches for the rest (the handbook too)
        expect(
          inDialog('• a kérésed szövege (legfeljebb 500 karakter)'),
          findsOneWidget,
        );
        for (final t in [
          'Kézikönyv',
          'Naptáresemények',
          'Feladatok',
          'Napi check-in',
          'Pénzügyek',
          'Időjárás',
        ]) {
          expect(inDialog(t), findsOneWidget, reason: t);
        }
        await tester.tap(find.text('Mégsem használom'));
        await tester.pumpAndSettle();
        expect(keys.value, isNull);
        expect(find.textContaining('nem mentettem el'), findsOneWidget);
        expect(
          await tester.runAsync(
            () =>
                ref0(tester)
                    .read(aiSettingsStoreProvider)
                    .consentGiven('gemini'),
          ),
          isFalse,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'the dialog says what is true: titles go with delete/move, the money detail only on request',
      (tester) async {
        await boot(tester, const SettingsPage());
        await saveKey(tester, 'AIza-good');
        Finder said(String part) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(part),
        );
        expect(said('törlésnél és áthelyezésnél igen'), findsOneWidget);
        expect(said('egy hónap részleteit kéri'), findsOneWidget);
        expect(said('a napi előrejelzés megy el'), findsOneWidget);
        expect(said('a nyitott feladataid'), findsOneWidget);
        await tester.tap(find.text('Mégsem használom'));
        await tester.pumpAndSettle();
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'the sharing text on the settings page says that titles go with delete/move too',
      (tester) async {
        await boot(tester, const SettingsPage());
        final part = find.textContaining(
          'törlésnél és áthelyezésnél a címek elmennek',
        );
        await tester.scrollUntilVisible(
          part,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(part, findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'accepted with a switch turned off: the choice is kept, and the dialog does not come back',
      (tester) async {
        await boot(tester, const SettingsPage());
        await saveKey(tester, 'AIza-good');
        // the optional parts start as they are in the settings (all on) ...
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(SwitchListTile, 'Naptáresemények'),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(SwitchListTile, 'Kézikönyv'),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Rendben, folytatom'));
        await tester.pumpAndSettle();

        expect(keys.value, 'AIza-good');
        final store = ref0(tester).read(aiSettingsStoreProvider);
        final s = (await tester.runAsync(store.load))!;
        expect((s.events, s.handbook), (false, false));
        expect(
          (s.tasks, s.checkins, s.finance, s.weather),
          (true, true, true, true),
        );
        expect(
          await tester.runAsync(() => store.consentGiven('gemini')),
          isTrue,
        );

        // a second save at the same provider does not ask again
        await tester.enterText(find.byType(TextField).first, 'AIza-other');
        await tester.tap(find.text('Mentés és ellenőrzés'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(keys.value, 'AIza-other');
        await shutdown(tester, db);
      },
    );

    testWidgets('the question after a workout can be switched off', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      final sw = find.widgetWithText(
        SwitchListTile,
        'Edzés utáni visszajelzés kérése',
      );
      await tester.scrollUntilVisible(
        sw,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isTrue); // on by default
      expect(find.textContaining('Egy edzés után'), findsOneWidget);
      await tester.tap(sw);
      await tester.pumpAndSettle();
      final s = (await tester.runAsync(
        () => ref0(tester).read(aiSettingsStoreProvider).load(),
      ))!;
      expect(s.workoutFeedback, isFalse);
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      await shutdown(tester, db);
    });

    testWidgets('the handbook switch is among the sharing switches', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      final list = find.byType(Scrollable).first;
      final sw = find.widgetWithText(
        SwitchListTile,
        'Kézikönyv (szabályok, profil, tanult szokások)',
      );
      await tester.scrollUntilVisible(sw, 300, scrollable: list);
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      final s = (await tester.runAsync(
        () => ref0(tester).read(aiSettingsStoreProvider).load(),
      ))!;
      expect(s.handbook, isFalse);
      await shutdown(tester, db);
    });

    testWidgets(
      'the settings show today\'s requests and tokens at this provider',
      (tester) async {
        await boot(tester, const SettingsPage());
        final nb = String.fromCharCode(0xA0);
        final store = ref0(tester).read(aiSettingsStoreProvider);
        await tester.runAsync(() async {
          await store.recordCall(
            provider: 'gemini',
            model: 'm',
            usage: const LlmUsage(prompt: 12000, output: 500, thinking: 100),
          );
          await store.recordCall(
            provider: 'groq', // another provider: not in this line
            model: 'm',
            usage: const LlmUsage(prompt: 999999),
          );
        });
        ref0(tester).invalidate(aiUsageProvider);
        await tester.pumpAndSettle();
        final list = find.byType(Scrollable).first;
        final line = find.text(
          'Ma ennél a szolgáltatónál: 1 kérés · 12${nb}600 token (be 12${nb}000 · ki 600)',
        );
        await tester.scrollUntilVisible(line, 300, scrollable: list);
        expect(line, findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('each provider keeps its own key and model', (tester) async {
      await boot(tester, const SettingsPage());
      final c = ref0(tester);
      await tester.runAsync(
        () => c.read(aiSettingsProvider.notifier).selectProvider('groq'),
      );
      await tester.runAsync(
        () => c.read(apiKeyStoreProvider).write('gsk-test', provider: 'groq'),
      );
      await tester.runAsync(() async {
        final st = c.read(aiSettingsStoreProvider);
        await st.save((await st.load()).copyWith(model: 'llama-x'));
      });
      await tester.runAsync(
        () => c.read(aiSettingsProvider.notifier).selectProvider('gemini'),
      );
      final g = (await tester.runAsync(
        () => c.read(aiSettingsStoreProvider).load(),
      ))!;
      expect(g.provider, 'gemini');
      expect(g.model, isNot('llama-x'));
      expect(keys.keyOf('groq'), 'gsk-test');
      expect(keys.keyOf('gemini'), isNull);
      await tester.runAsync(
        () => c.read(aiSettingsProvider.notifier).selectProvider('groq'),
      );
      final r = (await tester.runAsync(
        () => c.read(aiSettingsStoreProvider).load(),
      ))!;
      expect(r.model, 'llama-x');
      await shutdown(tester, db);
    });

    testWidgets('a wrong key shows the reason and is NOT stored', (
      tester,
    ) async {
      await boot(
        tester,
        const SettingsPage(),
        llm: FakeGemini(
          [],
          listError: const LlmAuth('Az API-kulcs érvénytelen.'),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'nem-jó');
      await tester.tap(find.text('Mentés és ellenőrzés'));
      await tester.pumpAndSettle();
      expect(find.text('Az API-kulcs érvénytelen.'), findsOneWidget);
      expect(keys.value, isNull);
      expect(find.text('Nincs API-kulcs'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'an empty field with no key asks for one; the key can be deleted',
      (tester) async {
        await boot(tester, const SettingsPage());
        await tester.tap(find.text('Mentés és ellenőrzés'));
        await tester.pumpAndSettle();
        expect(find.text('Írd be az API-kulcsot.'), findsOneWidget);
        await shutdown(tester, db);

        await boot(tester, const SettingsPage(), key: 'AIza-old');
        expect(find.text('API-kulcs megadva'), findsOneWidget);
        await tester.tap(find.text('Kulcs törlése'));
        await tester.pumpAndSettle();
        expect(keys.value, isNull);
        expect(find.text('Nincs API-kulcs'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('the sleep window is editable and remembered', (tester) async {
      await boot(tester, const SettingsPage());
      await tester.scrollUntilVisible(
        find.text('Alvási sáv'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Alvási sáv'), findsOneWidget);
      final c = ref0(tester);
      var s = (await tester.runAsync(
        () => c.read(aiSettingsStoreProvider).load(),
      ))!;
      expect([s.sleepStartHour, s.sleepEndHour], [23, 7]);

      final dropdowns = find.byType(DropdownButtonFormField<int>);
      await tester.ensureVisible(dropdowns.first);
      await tester.pumpAndSettle();
      await tester.tap(dropdowns.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('08:00').last);
      await tester.pumpAndSettle();
      await tester.tap(dropdowns.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('16:00').last);
      await tester.pumpAndSettle();

      s = (await tester.runAsync(
        () => c.read(aiSettingsStoreProvider).load(),
      ))!;
      expect([s.sleepStartHour, s.sleepEndHour], [8, 16]);
      await shutdown(tester, db);
    });

    testWidgets('the key field hides the text until asked', (tester) async {
      await boot(tester, const SettingsPage());
      expect(
        tester.widget<TextField>(find.byType(TextField).first).obscureText,
        isTrue,
      );
      await tester.tap(find.byTooltip('Mutat'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).obscureText,
        isFalse,
      );
      await shutdown(tester, db);
    });

    testWidgets('sharing switches persist and the version is shown', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Naptáresemények'),
        300,
        scrollable: list,
      );
      await tester.ensureVisible(find.text('Naptáresemények'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Naptáresemények'));
      await tester.pumpAndSettle();
      final s = await tester.runAsync(
        () => ref0(tester).read(aiSettingsStoreProvider).load(),
      );
      expect((s!.events, s.tasks, s.checkins), (false, true, true));
      expect(s.finance, isTrue); // on by default
      expect(s.handbook, isTrue); // on by default

      final fin = find.text('Pénzügyek (csak olvasás)');
      await tester.scrollUntilVisible(fin, 300, scrollable: list);
      await tester.ensureVisible(fin);
      await tester.pumpAndSettle();
      await tester.tap(fin);
      await tester.pumpAndSettle();
      final s2 = await tester.runAsync(
        () => ref0(tester).read(aiSettingsStoreProvider).load(),
      );
      expect(s2!.finance, isFalse);
      await tester.scrollUntilVisible(
        find.text('Verzió: build 7'),
        300,
        scrollable: list,
      );
      expect(find.text('Verzió: build 7'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('handbook', () {
    testWidgets(
      'defaults come from the bundled assets; edit, save, mark modified, reset',
      (tester) async {
        await boot(tester, const HandbookPage(), stubHandbook: false);
        expect(find.text('Kemény szabályok'), findsOneWidget);
        expect(find.text('Alapértelmezett'), findsNWidgets(6));

        await tester.tap(find.text('Kemény szabályok'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Calisthenics, Gym, Street Workout'),
          findsOneWidget,
        ); // real bundled text
        await tester.enterText(
          find.byType(TextField),
          '# Saját szabályok\n- csak reggel edzek',
        );
        await tester.pump();
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        expect(find.text('Módosítva'), findsOneWidget);
        final txt = await tester.runAsync(
          () => ref0(tester).read(handbookStoreProvider).textOf('rules'),
        );
        expect(txt, contains('csak reggel edzek'));

        await tester.tap(find.text('Kemény szabályok'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Alapértelmezett'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Visszaállít'));
        await tester.pumpAndSettle();
        expect(find.text('Alapértelmezett'), findsNWidgets(6));
        await shutdown(tester, db);
      },
    );

    testWidgets('leaving the editor with unsaved text asks first', (
      tester,
    ) async {
      await boot(
        tester,
        const HandbookEditorPage(id: 'profile', title: 'Profil'),
      );
      await tester.enterText(find.byType(TextField), 'félkész');
      await tester.pump();
      await tester.binding.handlePopRoute(); // system "back"
      await tester.pumpAndSettle();
      expect(find.text('Elveted a módosításokat?'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('assistant page', () {
    LlmReply plan(
      List<Map<String, Object?>> items, {
      String summary = 'Heti terv',
    }) => calls([
      tool('propose_events', {'summary': summary, 'proposals': items}),
    ]);

    // ---- deletions need an explicit "Engedélyezem"
    Future<String> refOf(WidgetTester tester, String title) async {
      final occ = (await tester.runAsync(
        () => events.occurrences(
          DateTime.utc(2026, 11, 1),
          DateTime.utc(2026, 12, 31),
        ),
      ))!;
      return occurrenceRef(occ.firstWhere((o) => o.title == title));
    }

    // The same answer again for the repair rounds: a reference the model
    // cannot make right goes back to it (twice at most) before the user is told.
    FakeGemini deleteScript(List<String> refs) => FakeGemini([
      for (var i = 0; i < 3; i++)
        (_) => calls([
          tool('propose_events', {
            'summary': 'Törlés',
            'deletions': [
              for (final r in refs) {'ref': r, 'reason': 'kérted'},
            ],
          }),
        ]),
    ]);

    Future<void> ask(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'töröld a fogorvost');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a deletion waits for "Engedélyezem" and then removes the event',
      (tester) async {
        final refs = <String>[];
        await boot(
          tester,
          const AssistantPage(),
          llm: deleteScript(refs),
          key: 'k',
        );
        await tester.runAsync(
          () => events.saveLocal(
            evt('p1', 'Fogorvos', floating(2026, 11, 20, 9)),
          ),
        );
        refs.add(await refOf(tester, 'Fogorvos'));
        await ask(tester);

        expect(
          find.textContaining('Törlésre javasolt események (1)'),
          findsOneWidget,
        );
        expect(find.text('Fogorvos'), findsOneWidget);
        expect(find.text('Mégse'), findsOneWidget);
        expect(find.text('Engedélyezem'), findsOneWidget);
        // nothing happened yet
        expect((await tester.runAsync(() => events.byId('p1')))!, isNotNull);

        await tester.ensureVisible(find.text('Engedélyezem'));

        await tester.pumpAndSettle();

        await tester.tap(find.text('Engedélyezem'));
        await tester.pumpAndSettle();
        final gone = (await tester.runAsync(() => events.all()))!
            .where((e) => e.id == 'p1')
            .toList();
        // never synced -> removed outright
        expect(gone, isEmpty);
        expect(find.text('1 esemény törölve.'), findsOneWidget);
        expect(find.text('Engedélyezem'), findsNothing);
        await shutdown(tester, db);
      },
    );

    testWidgets('"Mégse" deletes nothing', (tester) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: deleteScript(refs),
        key: 'k',
      );
      await tester.runAsync(
        () =>
            events.saveLocal(evt('p1', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      refs.add(await refOf(tester, 'Fogorvos'));
      await ask(tester);
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(() => events.byId('p1')))!, isNotNull);
      expect(find.text('Engedélyezem'), findsNothing);
      expect(find.textContaining('törölve'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets(
      'a recurring event asks what to remove: only that day by default',
      (tester) async {
        final refs = <String>[];
        await boot(
          tester,
          const AssistantPage(),
          llm: deleteScript(refs),
          key: 'k',
        );
        await tester.runAsync(
          () => events.saveLocal(
            evt(
              's1',
              'Műszak',
              floating(2026, 11, 18, 6),
              rrule: 'FREQ=DAILY;COUNT=5',
            ),
          ),
        );
        refs.add(await refOf(tester, 'Műszak')); // first one: 18 Nov
        await ask(tester);
        expect(find.text('Ismétlődő esemény, mit töröljek?'), findsOneWidget);
        expect(find.text('Csak ezt'), findsOneWidget);
        expect(find.text('Ezt és a következőket'), findsOneWidget);
        expect(find.text('Az összeset'), findsOneWidget);
        await tester.ensureVisible(find.text('Engedélyezem'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Engedélyezem'));
        await tester.pumpAndSettle();
        final m = (await tester.runAsync(() => events.byId('s1')))!;
        expect(m.exdates, [floating(2026, 11, 18, 6)]);
        await shutdown(tester, db);
      },
    );

    testWidgets('a recurring event can be removed completely', (tester) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: deleteScript(refs),
        key: 'k',
      );
      await tester.runAsync(
        () => events.saveLocal(
          evt(
            's1',
            'Műszak',
            floating(2026, 11, 18, 6),
            rrule: 'FREQ=DAILY;COUNT=5',
          ),
        ),
      );
      refs.add(await refOf(tester, 'Műszak'));
      await ask(tester);
      await tester.tap(find.text('Az összeset'));
      await tester.pump();
      await tester.ensureVisible(find.text('Engedélyezem'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Engedélyezem'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => events.byId('s1')), isNull);
      await shutdown(tester, db);
    });

    testWidgets('a made-up reference is never offered for deletion', (
      tester,
    ) async {
      await boot(
        tester,
        const AssistantPage(),
        llm: deleteScript(['nincs-ilyen@2026-11-20T09:00:00.000Z']),
        key: 'k',
      );
      await tester.runAsync(
        () =>
            events.saveLocal(evt('p1', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      await ask(tester);
      expect(find.text('Engedélyezem'), findsNothing);
      await tester.tap(find.textContaining('Nem javasolt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('esemény nem található'), findsOneWidget);
      expect((await tester.runAsync(() => events.byId('p1')))!, isNotNull);
      await shutdown(tester, db);
    });

    // ---- moves need an explicit "Engedélyezem" too
    FakeGemini moveScript(List<String> refs, String start, String end) =>
        FakeGemini([
          for (var i = 0; i < 3; i++)
            (_) => calls([
              tool('propose_events', {
                'summary': 'Áthelyezés',
                'moves': [
                  for (final r in refs)
                    {'ref': r, 'start': start, 'end': end, 'reason': 'kérted'},
                ],
              }),
            ]),
        ]);

    testWidgets('a move waits for "Engedélyezem", then changes the time', (
      tester,
    ) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: moveScript(refs, '2026-11-20T19:00:00', '2026-11-20T20:00:00'),
        key: 'k',
      );
      await tester.runAsync(
        () =>
            events.saveLocal(evt('p1', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      refs.add(await refOf(tester, 'Fogorvos'));
      await ask(tester);

      expect(
        find.textContaining('Áthelyezésre javasolt események (1)'),
        findsOneWidget,
      );
      expect(find.textContaining('Új időpont'), findsOneWidget);
      expect(find.text('Mégse'), findsOneWidget);
      // nothing happened yet
      expect(
        (await tester.runAsync(() => events.byId('p1')))!.start,
        floating(2026, 11, 20, 9),
      );

      await tester.ensureVisible(find.text('Engedélyezem'));

      await tester.pumpAndSettle();

      await tester.tap(find.text('Engedélyezem'));
      await tester.pumpAndSettle();
      final e = (await tester.runAsync(() => events.byId('p1')))!;
      expect(e.start, floating(2026, 11, 20, 19));
      expect(e.end, floating(2026, 11, 20, 20));
      expect(find.text('1 esemény áthelyezve.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('"Mégse" moves nothing', (tester) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: moveScript(refs, '2026-11-20T19:00:00', '2026-11-20T20:00:00'),
        key: 'k',
      );
      await tester.runAsync(
        () =>
            events.saveLocal(evt('p1', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      refs.add(await refOf(tester, 'Fogorvos'));
      await ask(tester);
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => events.byId('p1')))!.start,
        floating(2026, 11, 20, 9),
      );
      expect(find.text('Engedélyezem'), findsNothing);
      expect(find.textContaining('áthelyezve'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('moving one day of a series only overrides that day', (
      tester,
    ) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: moveScript(refs, '2026-11-18T19:00:00', '2026-11-18T20:00:00'),
        key: 'k',
      );
      await tester.runAsync(
        () => events.saveLocal(
          evt(
            's1',
            'Edzés',
            floating(2026, 11, 18, 9),
            rrule: 'FREQ=DAILY;COUNT=3',
          ),
        ),
      );
      refs.add(await refOf(tester, 'Edzés'));
      await ask(tester);
      expect(find.textContaining('csak ez a nap mozdul'), findsOneWidget);
      await tester.ensureVisible(find.text('Engedélyezem'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Engedélyezem'));
      await tester.pumpAndSettle();
      final master = (await tester.runAsync(() => events.byId('s1')))!;
      expect(master.start, floating(2026, 11, 18, 9)); // series unchanged
      final occ = (await tester.runAsync(
        () => events.occurrences(
          DateTime.utc(2026, 11, 18),
          DateTime.utc(2026, 11, 22),
        ),
      ))!;
      expect(occ.length, 3);
      expect(
        occ.where((o) => o.startUtc.hour == 18).length, // 19:00 CET = 18:00Z
        1,
      );
      await shutdown(tester, db);
    });

    testWidgets('a move onto another event is not offered', (tester) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: moveScript(refs, '2026-11-20T13:00:00', '2026-11-20T14:00:00'),
        key: 'k',
      );
      await tester.runAsync(() async {
        await events.saveLocal(
          evt('p1', 'Fogorvos', floating(2026, 11, 20, 9)),
        );
        await events.saveLocal(
          evt('p2', 'Megbeszélés', floating(2026, 11, 20, 13)),
        );
      });
      refs.add(await refOf(tester, 'Fogorvos'));
      await ask(tester);
      expect(find.text('Engedélyezem'), findsNothing);
      await tester.tap(find.textContaining('Nem javasolt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ütközik'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a shift cannot be moved', (tester) async {
      final refs = <String>[];
      await boot(
        tester,
        const AssistantPage(),
        llm: moveScript(refs, '2026-11-20T19:00:00', '2026-11-20T20:00:00'),
        key: 'k',
      );
      await tester.runAsync(
        () => events.saveLocal(
          evt(
            'm1',
            'Nappali műszak',
            floating(2026, 11, 20, 6),
          ).copyWith(notes: kShiftMarker),
        ),
      );
      refs.add(await refOf(tester, 'Nappali műszak'));
      await ask(tester);
      expect(find.text('Engedélyezem'), findsNothing);
      await tester.tap(find.textContaining('Nem javasolt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('műszak, azt nem lehet'), findsOneWidget);
      expect(
        (await tester.runAsync(() => events.byId('m1')))!.start,
        floating(2026, 11, 20, 6),
      );
      await shutdown(tester, db);
    });

    testWidgets('without a key it points to the settings instead of failing', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      await tester.enterText(find.byType(TextField), 'Tervezz edzést');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Még nincs API-kulcs megadva ehhez'),
        findsOneWidget,
      );
      expect(find.text('Beállítások'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('a task block shows its task and carries it into the event', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) => plan([
          {
            ...item(
              'Beadandó munka',
              '2026-05-05T18:00:00',
              '2026-05-05T19:00:00',
              kind: 'task',
            ),
            'taskId': 't1',
          },
        ]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.runAsync(
        () => ref0(tester)
            .read(recordRepoProvider)
            .edit(
              kindTask,
              't1',
              taskFields(title: 'Beadandó', estimateMin: 60),
            ),
      );
      await tester.tap(
        find.text('Ütemezd a nyitott feladataimat a következő napokra'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Feladat: Beadandó'), findsOneWidget);

      await tester.tap(find.text('Elfogadom a kijelölteket (1)'));
      await tester.pumpAndSettle();
      final e = (await tester.runAsync(() => events.all()))!.single;
      expect(e.notes, contains('Feladat: Beadandó'));
      await shutdown(tester, db);
    });

    testWidgets(
      'ask -> review -> accept creates AI-marked events in the Naptar calendar',
      (tester) async {
        final llm = FakeGemini([
          (_) => calls([tool('get_tasks')]),
          (_) => plan([
            item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
            item(
              'Séta',
              '2026-05-06T08:00:00',
              '2026-05-06T08:30:00',
              kind: 'rest',
            ),
          ]),
        ]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(
          find.byType(TextField),
          'Tervezz edzést a jövő hétre',
        );
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();

        expect(find.text('Heti terv'), findsOneWidget);
        expect(find.text('Futás'), findsOneWidget);
        expect(find.text('Séta'), findsOneWidget);
        expect(find.text('Elfogadom a kijelölteket (2)'), findsOneWidget);
        // nothing is in the calendar before approval
        expect((await tester.runAsync(() => events.all()))!, isEmpty);

        await tester.tap(find.text('Séta')); // deselect the walk
        await tester.pump();
        await tester.tap(find.text('Elfogadom a kijelölteket (1)'));
        await tester.pumpAndSettle();

        final saved = (await tester.runAsync(() => events.all()))!;
        expect(saved.length, 1);
        final e = saved.single;
        expect(
          (e.title, e.calendarId, e.aiGenerated, e.colorId, e.tzid),
          ('Futás', kNaptarCalendar, true, aiEventColorId, bp),
        );
        expect(e.start, floating(2026, 5, 5, 18));
        expect(find.textContaining('1 esemény bekerült'), findsOneWidget);
        // queued for the Google sync like any local change
        expect((await tester.runAsync(() => events.pending()))!.length, 1);
        await shutdown(tester, db);
      },
    );

    testWidgets(
      '"Elvetem" throws the plan away without touching the calendar',
      (tester) async {
        final llm = FakeGemini([
          (_) => plan([
            item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
          ]),
        ]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'x');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Elvetem'));
        await tester.pumpAndSettle();
        expect(find.text('Futás'), findsNothing);
        expect((await tester.runAsync(() => events.all()))!, isEmpty);
        await shutdown(tester, db);
      },
    );

    testWidgets('after "Elvetem" the user can have the reason remembered', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) =>
            plan([item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00')]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'x');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elvetem'));
      await tester.pumpAndSettle();
      expect(find.text('Szeretnéd, hogy megjegyezzem, miért?'), findsOneWidget);
      // nothing is written before the button
      expect(
        await tester.runAsync(
          () => ref0(tester).read(handbookStoreProvider).learnedRules(),
        ),
        isEmpty,
      );
      await tester.ensureVisible(
        find.text('Ne tervezz edzést reggel 8 előtt.'),
      );
      await tester.tap(find.text('Ne tervezz edzést reggel 8 előtt.'));
      await tester.pump();
      await tester.ensureVisible(find.text('Megjegyzem'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Megjegyzem'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rögzítve a Tanult szokások'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => ref0(tester).read(handbookStoreProvider).learnedRules(),
        ),
        ['Ne tervezz edzést reggel 8 előtt.'],
      );
      await shutdown(tester, db);
    });

    testWidgets('"Nem most" writes nothing', (tester) async {
      final llm = FakeGemini([
        (_) =>
            plan([item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00')]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'x');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elvetem'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Nem most'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nem most'));
      await tester.pumpAndSettle();
      expect(find.text('Szeretnéd, hogy megjegyezzem, miért?'), findsNothing);
      expect(
        await tester.runAsync(
          () => ref0(tester).read(handbookStoreProvider).learnedRules(),
        ),
        isEmpty,
      );
      await shutdown(tester, db);
    });

    testWidgets(
      'a plan that breaks the rules is never offered; the reasons are listed',
      (tester) async {
        final bad = item(
          'Éjszakai futás',
          '2026-05-05T23:30:00',
          '2026-05-06T00:30:00',
        );
        final llm = FakeGemini([
          (_) => plan([bad]),
          (_) => plan([bad]),
          (_) => plan([bad]),
        ]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'x');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Elfogadom'), findsNothing);
        expect(find.textContaining('Nem javasolt (1)'), findsOneWidget);
        await tester.tap(find.textContaining('Nem javasolt'));
        await tester.pumpAndSettle();
        expect(find.textContaining('alvási sávba esik'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('the model asking a question is shown as a question', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) => calls([
          tool('propose_events', {
            'proposals': [],
            'questions': ['Milyen intenzitást szeretnél?'],
          }),
        ]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'x');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(find.text('Milyen intenzitást szeretnél?'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'a rate limit and a bad key give readable messages, and the failed ask can be retried',
      (tester) async {
        final llm = FakeGemini([
          (_) => const LlmRateLimit('Elfogyott az ingyenes keret.'),
          (_) => plan([
            item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
          ]),
        ]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'edzés');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Elfogyott az ingyenes keret.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Újrapróbál'));
        await tester.pumpAndSettle();
        expect(find.text('Futás'), findsOneWidget);
        await shutdown(tester, db);

        await boot(
          tester,
          const AssistantPage(),
          llm: FakeGemini([(_) => const LlmAuth('Az API-kulcs érvénytelen.')]),
          key: 'k',
        );
        await tester.enterText(find.byType(TextField), 'edzés');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        expect(find.text('Az API-kulcs érvénytelen.'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Beállítások'),
          findsOneWidget,
        );
        await shutdown(tester, db);
      },
    );

    // ---- what the model is sent, and what it cost
    testWidgets(
      '"Mit küldünk a modellnek?" shows the request and sends nothing',
      (tester) async {
        final llm = FakeGemini([]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        expect(find.textContaining('Becsült méret'), findsNothing);
        await tester.enterText(find.byType(TextField), 'Tervezz edzést');
        await tester.tap(find.text('Mit küldünk a modellnek?'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Becsült méret: ≈'), findsOneWidget);
        expect(find.textContaining('esemenyek: ≈'), findsOneWidget);
        expect(find.textContaining('feladatok: ≈'), findsOneWidget);

        // the text itself, ending in the user's own words
        await tester.tap(find.text('A kérés szövege (adatok, idő, kérésed)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Kérés: Tervezz edzést'), findsOneWidget);
        expect(find.textContaining('MOST: 2026-05-04 10:00'), findsOneWidget);

        // refreshed with new words
        await tester.enterText(
          find.byType(TextField),
          'Mikor férne be 45 perc?',
        );
        await tester.ensureVisible(find.text('Frissítés a beírt kéréssel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Frissítés a beírt kéréssel'));
        await tester.pumpAndSettle();
        // (the text tile stays open across a refresh)
        expect(
          find.textContaining('Kérés: Mikor férne be 45 perc?'),
          findsOneWidget,
        );

        // nothing was sent, nothing was counted
        expect(llm.requests, isEmpty);
        expect(
          await tester.runAsync(
            () => ref0(tester).read(aiSettingsStoreProvider).usageToday(),
          ),
          0,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets('the cost of the last request: the provider\'s numbers', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) => LlmReply(
          parts: [
            tool('propose_events', {
              'summary': 'Terv',
              'proposals': [
                item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
              ],
            }),
          ],
          promptTokens: 2700,
          outputTokens: 420,
          thinkingTokens: 80,
        ),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'Tervezz edzést');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      final nb = String.fromCharCode(0xA0);
      expect(
        find.text(
          'Utolsó kérés: 3${nb}200 token (be 2${nb}700 · ki 420 · gondolkodás 80)',
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('no numbers from the provider: the estimate is shown as one', (
      tester,
    ) async {
      final llm = FakeGemini([(_) => say('Rendben, mikor?')]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'Mikor edzek?');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Utolsó kérés: ≈'), findsOneWidget);
      expect(
        find.textContaining('a szolgáltató nem közölt adatot'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('the request is at most 500 characters', (tester) async {
      await boot(tester, const AssistantPage(), llm: FakeGemini([]), key: 'k');
      await tester.enterText(find.byType(TextField), 'a' * 700);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .text
            .length,
        500,
      );
      expect(find.text('500/500'), findsOneWidget);
      await shutdown(tester, db);
    });

    // ---- "Mégse", leaving the page, closing the connection
    Future<void> pumpBriefly(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('"Mégse" stops the request; the late answer is thrown away', (
      tester,
    ) async {
      final llm = GatedGemini();
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'Tervezz edzést');
      await tester.tap(find.byTooltip('Küldés'));
      await pumpBriefly(tester);
      expect(llm.requests.length, 1);
      expect(ref0(tester).read(assistantControllerProvider).busy, isTrue);
      expect(find.text('Mégse'), findsOneWidget);

      await tester.tap(find.text('Mégse'));
      await pumpBriefly(tester);
      expect(ref0(tester).read(assistantControllerProvider).busy, isFalse);
      expect(find.text('Mégse'), findsNothing);
      expect(
        llm.closed,
        greaterThanOrEqualTo(1),
      ); // the call in flight is aborted

      // the model answers anyway, much later: nothing appears
      llm.gate.complete(
        plan([item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00')]),
      );
      await pumpBriefly(tester);
      final st = ref0(tester).read(assistantControllerProvider);
      expect(st.busy, isFalse);
      expect(st.outcome, isNull);
      expect(st.error, isNull);
      expect(find.text('Elfogadom a kijelölteket'), findsNothing);

      // and the page can be used again
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      await shutdown(tester, db);
    });

    testWidgets('leaving the page cancels the request that nobody waits for', (
      tester,
    ) async {
      final llm = GatedGemini();
      await boot(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AssistantPage()),
              ),
              child: const Text('Megnyit'),
            ),
          ),
        ),
        llm: llm,
        key: 'k',
      );
      await tester.tap(find.text('Megnyit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Tervezz edzést');
      await tester.tap(find.byTooltip('Küldés'));
      await pumpBriefly(tester);
      expect(ref0(tester).read(assistantControllerProvider).busy, isTrue);

      await tester.binding.handlePopRoute(); // the system "back"
      // the page leaves with its closing animation; the cancel runs after it
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AssistantPage), findsNothing);
      expect(ref0(tester).read(assistantControllerProvider).busy, isFalse);
      expect(llm.closed, greaterThanOrEqualTo(1));
      await shutdown(tester, db);
    });

    testWidgets(
      '"Mégse" while the models are listed: no bogus error, nothing is sent',
      (tester) async {
        final llm = SlowModelsGemini();
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'Tervezz edzést');
        await tester.tap(find.byTooltip('Küldés'));
        await pumpBriefly(tester);
        expect(ref0(tester).read(assistantControllerProvider).busy, isTrue);

        await tester.tap(find.text('Mégse'));
        await pumpBriefly(tester);
        final st = ref0(tester).read(assistantControllerProvider);
        expect(st.busy, isFalse);
        // the aborted call failed with a network error: the user must not see it
        expect(st.error, isNull);
        expect(find.textContaining('Nincs kapcsolat'), findsNothing);
        expect(llm.requests, isEmpty);
        await shutdown(tester, db);
      },
    );

    testWidgets('"Mégse" right after sending: not a single request goes out', (
      tester,
    ) async {
      final llm = GatedGemini();
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      final ctl = ref0(tester).read(assistantControllerProvider.notifier);
      unawaited(ctl.ask('Tervezz edzést'));
      ctl.cancel(); // before the settings and the key are even read
      await pumpBriefly(tester);
      expect(ref0(tester).read(assistantControllerProvider).busy, isFalse);
      expect(llm.requests, isEmpty);
      expect(llm.closed, greaterThanOrEqualTo(1));
      await shutdown(tester, db);
    });

    testWidgets('every request closes its connection when it is over', (
      tester,
    ) async {
      final llm = FakeGemini([(_) => say('Rendben.')]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'Mikor edzek?');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(find.text('Rendben.'), findsOneWidget);
      expect(llm.closed, 1);
      await shutdown(tester, db);
    });

    testWidgets('a second request while one runs starts nothing', (
      tester,
    ) async {
      final llm = GatedGemini();
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      final ctl = ref0(tester).read(assistantControllerProvider.notifier);
      unawaited(ctl.ask('Tervezz edzést'));
      await pumpBriefly(tester);
      unawaited(ctl.ask('Tervezz mást'));
      await pumpBriefly(tester);
      expect(llm.requests.length, 1);
      llm.gate.complete(say('kész'));
      await pumpBriefly(tester);
      await shutdown(tester, db);
    });

    testWidgets('the notice of a smaller second try is shown with the answer', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) => const LlmTooLarge('túl nagy', limit: 8000, requested: 12000),
        (_) =>
            plan([item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00')]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(
        find.byType(TextField),
        'Tervezz edzést a jövő hétre',
      );
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(llm.requests.length, 2);
      expect(find.textContaining('túl nagynak bizonyult'), findsOneWidget);
      expect(find.textContaining('Futás'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('a quick-prompt chip sends its text', (tester) async {
      final llm = FakeGemini([(_) => say('Rendben, mikor?')]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.tap(find.text('Tervezz edzést a jövő hétre'));
      await tester.pumpAndSettle();
      expect(find.text('Rendben, mikor?'), findsOneWidget);
      expect(
        llm.requests.first.turns.first.parts.whereType<LlmText>().single.text,
        endsWith('Kérés: Tervezz edzést a jövő hétre'),
      );
      await shutdown(tester, db);
    });

    // ---- answers the program gives by itself (2d)
    Future<void> seedBudget(WidgetTester tester) async {
      final fin = ref0(tester).read(financeRepoProvider);
      await tester.runAsync(() async {
        await fin.ensureDefaults();
        await fin.saveTx(
          FinTx(
            id: 't1',
            date: floating(2026, 5, 3),
            amount: 20000,
            kind: FinKind.expense,
            categoryId: 'cat-food',
            merchant: 'SPAR',
          ),
        );
        await fin.saveBudget(
          const FinBudget(categoryId: 'cat-food', limit: 50000),
        );
      });
    }

    String firstMessage(FakeGemini llm) =>
        llm.requests.single.turns.first.parts.whereType<LlmText>().single.text;

    testWidgets(
      'the budget is answered by the program: no key, no model, marked as local',
      (tester) async {
        final llm = FakeGemini([]); // a call would throw
        await boot(tester, const AssistantPage(), llm: llm); // no key at all
        await seedBudget(tester);
        await tester.tap(find.text('Hogy állok a költségkerettel?'));
        await tester.pumpAndSettle();
        expect(find.text('Helyi válasz, modell nélkül'), findsOneWidget);
        expect(
          find.textContaining('Költségkeret – 2026. május'),
          findsOneWidget,
        );
        expect(find.textContaining('Élelmiszer'), findsOneWidget);
        expect(find.textContaining('API-kulcs'), findsNothing);
        expect(find.textContaining('Utolsó kérés'), findsNothing);
        expect(llm.requests, isEmpty);
        await shutdown(tester, db);
      },
    );

    testWidgets('the agenda of tomorrow is answered by the program', (
      tester,
    ) async {
      final llm = FakeGemini([]);
      await boot(tester, const AssistantPage(), llm: llm);
      await tester.runAsync(
        () =>
            events.saveLocal(evt('m', 'Megbeszélés', floating(2026, 5, 5, 12))),
      );
      await tester.tap(find.text('Mi lesz holnap?'));
      await tester.pumpAndSettle();
      expect(find.text('Helyi válasz, modell nélkül'), findsOneWidget);
      expect(find.textContaining('Holnap – kedd (05-05)'), findsOneWidget);
      expect(find.textContaining('12:00–13:00 Megbeszélés'), findsOneWidget);
      expect(llm.requests, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets(
      'a further question goes to the model, with the local answer as data',
      (tester) async {
        final llm = FakeGemini([(_) => say('Kevesebb szórakozás.')]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await seedBudget(tester);
        await tester.tap(find.text('Hogy állok a költségkerettel?'));
        await tester.pumpAndSettle();
        expect(llm.requests, isEmpty);
        await tester.enterText(
          find.byKey(const Key('local-more')),
          'Miből spórolhatnék?',
        );
        await tester.tap(find.byKey(const Key('local-more-send')));
        await tester.pumpAndSettle();
        expect(llm.requests, hasLength(1));
        final first = firstMessage(llm);
        expect(first, contains('<adat tipus="helyi_valasz">'));
        expect(first, contains('Élelmiszer'));
        expect(first, endsWith('Kérés: Miből spórolhatnék?'));
        expect(find.textContaining('Kevesebb szórakozás.'), findsOneWidget);
        expect(find.text('Helyi válasz, modell nélkül'), findsNothing);
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'with the money data not shared the local answer still comes, but goes to no model',
      (tester) async {
        final llm = FakeGemini([(_) => say('Ok.')]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await seedBudget(tester);
        await tester.runAsync(
          () =>
              ref0(tester)
                  .read(aiSettingsStoreProvider)
                  .save(const AiSettings(finance: false)),
        );
        await tester.tap(find.text('Hogy állok a költségkerettel?'));
        await tester.pumpAndSettle();
        // the data is on the device: the answer is there whatever the switch says
        expect(find.textContaining('Élelmiszer'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('local-more')),
          'Miből spórolhatnék?',
        );
        await tester.tap(find.byKey(const Key('local-more-send')));
        await tester.pumpAndSettle();
        final first = firstMessage(llm);
        expect(first.contains('helyi_valasz'), isFalse);
        expect(first.contains('Élelmiszer'), isFalse);
        expect(first, contains('"kikapcsolva":true'));
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'a request that needs a switched-off source gets a notice at once, not a model call',
      (tester) async {
        final llm = FakeGemini([]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.runAsync(
          () =>
              ref0(tester)
                  .read(aiSettingsStoreProvider)
                  .save(const AiSettings(finance: false)),
        );
        await tester.enterText(
          find.byType(TextField).first,
          'Miből spórolhatnék a legtöbbet?',
        );
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('A pénzügyi adatok megosztása ki van kapcsolva'),
          findsOneWidget,
        );
        expect(find.text('Helyi válasz, modell nélkül'), findsOneWidget);
        // nothing to build on: no further question to the model
        expect(find.byKey(const Key('local-more')), findsNothing);
        expect(llm.requests, isEmpty);
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'a model without free quota is replaced by another one, the switch is remembered and explained',
      (tester) async {
        final llm = FakeGemini(
          [
            (_) => const LlmRateLimit(
              'nincs keret',
              quotaZero: true,
              model: 'gemini-2.5-flash',
            ),
            (_) => plan([
              item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
            ]),
          ],
          available: const [
            LlmModel('gemini-2.5-flash', 'Flash'),
            LlmModel('gemini-2.5-flash-lite', 'Lite'),
          ],
        );
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'edzés');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();

        expect(llm.models, ['gemini-2.5-flash', 'gemini-2.5-flash-lite']);
        expect(find.text('Futás'), findsOneWidget);
        expect(
          find.textContaining(
            'Átváltottam a(z) gemini-2.5-flash-lite modellre',
          ),
          findsOneWidget,
        );
        final s = await tester.runAsync(
          () => ref0(tester).read(aiSettingsStoreProvider).load(),
        );
        expect(s!.model, 'gemini-2.5-flash-lite');
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'when no other model works, the precise reason and the service detail are shown',
      (tester) async {
        final limit = const LlmRateLimit(
          'A(z) gemini-2.5-flash modellhez ennél a kulcsnál nincs ingyenes keret (limit: 0).',
          quotaZero: true,
          detail: 'Quota exceeded for metric ..., limit: 0, model: gemini-2.5-flash',
        );
        final llm = FakeGemini(
          [(_) => limit, (_) => limit],
          available: const [
            LlmModel('gemini-2.5-flash', 'Flash'),
            LlmModel('gemini-2.0-flash', 'Flash 2'),
          ],
        );
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'edzés');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('nincs ingyenes keret (limit: 0)'),
          findsOneWidget,
        );
        expect(find.textContaining('engedélyezd a számlázást'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Beállítások'),
          findsOneWidget,
        );
        await tester.tap(find.text('Részletek'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Quota exceeded for metric'),
          findsOneWidget,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets('a billing problem advises another provider, not waiting', (
      tester,
    ) async {
      final llm = FakeGemini([
        (_) => const LlmRateLimit(
          'A Google-fiók előre fizetett egyenlege elfogyott.',
          billing: true,
          detail: 'prepayment credits are depleted',
        ),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.enterText(find.byType(TextField), 'edzés');
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
      expect(find.textContaining('válassz másik szolgáltatót'), findsOneWidget);
      expect(find.textContaining('Várj egy percet'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Beállítások'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'a short per-minute limit gives a "wait and retry" message without a settings button',
      (tester) async {
        final llm = FakeGemini([
          for (var i = 0; i < 3; i++)
            (_) => const LlmRateLimit(
              'Túl sok kérés rövid idő alatt.',
              retryAfter: Duration(seconds: 1),
            ),
        ]);
        await boot(tester, const AssistantPage(), llm: llm, key: 'k');
        await tester.enterText(find.byType(TextField), 'edzés');
        await tester.tap(find.byTooltip('Küldés'));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle(
          const Duration(seconds: 1),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 30),
        );
        expect(
          find.textContaining('Túl sok kérés rövid idő alatt.'),
          findsOneWidget,
        );
        expect(find.textContaining('Várj egy percet'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Beállítások'), findsNothing);
        await shutdown(tester, db);
      },
    );
  });
}

ProviderContainer ref0(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

class _MemoryIo implements BackupIo {
  String? saved;
  String? toPick;

  @override
  Future<bool> save(String fileName, String text) async {
    saved = text;
    return true;
  }

  @override
  Future<String?> pick() async => toPick;
}

class _FakeLocation implements LocationProvider {
  _FakeLocation(this.result);
  final LocationResult result;

  @override
  Future<LocationResult> current() async => result;
}
