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
          if (weatherSvc != null)
            weatherServiceProvider.overrideWithValue(weatherSvc),
          llmFactoryProvider.overrideWithValue((cfg) => llm ?? FakeGemini([])),
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
      final e = (await tester.runAsync(() => events.byId('b2')))!;
      expect(e.title, 'Edzés');
      expect(e.googleId, 'g-1');
      expect(e.version, greaterThan(linked.version + 1));
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
      await tester.tap(find.text('Naptáresemények'));
      await tester.pumpAndSettle();
      final s = await tester.runAsync(
        () => ref0(tester).read(aiSettingsStoreProvider).load(),
      );
      expect((s!.events, s.tasks, s.checkins), (false, true, true));
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
          find.textContaining('Alvási sáv'),
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

    FakeGemini deleteScript(List<String> refs) => FakeGemini([
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
      await tester.tap(find.text('Ne tervezz edzést reggel 8 előtt.'));
      await tester.pump();
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

    testWidgets('a quick-prompt chip sends its text', (tester) async {
      final llm = FakeGemini([(_) => say('Rendben, mikor?')]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await tester.tap(find.text('Tervezz edzést a jövő hétre'));
      await tester.pumpAndSettle();
      expect(find.text('Rendben, mikor?'), findsOneWidget);
      expect(
        llm.requests.first.turns.first.parts.whereType<LlmText>().single.text,
        startsWith('Tervezz edzést a jövő hétre'),
      );
      await shutdown(tester, db);
    });

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
