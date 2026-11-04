import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_page.dart';
import 'package:kvantum_app/ai/handbook_page.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
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
