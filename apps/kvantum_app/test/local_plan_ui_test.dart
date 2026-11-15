import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart' show MemoryApiKeyStore;
import 'package:kvantum_app/ai/approval.dart' show assistantApplyingProvider;
import 'package:kvantum_app/ai/assistant_page.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/local_plan_prefs.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

/// A model that lists one model, as the settings need.
class _Llm extends FakeLlm {
  _Llm(super.script);
  @override
  Future<List<LlmModel>> listModels() async => const [
    LlmModel('gemini-2.5-flash', 'Flash'),
  ];
}

/// The wishes cannot be read: the plan fails, and the error card must offer
/// the plan again, not a question to the model.
class _BrokenPrefs extends LocalPlanPrefsNotifier {
  static int built = 0;
  @override
  Future<LocalPlanPrefs> build() async {
    built++;
    throw StateError('unreadable');
  }
}

/// The wishes load only when the test lets them (the plan is "working").
class _SlowPrefs extends LocalPlanPrefsNotifier {
  static Completer<void> gate = Completer<void>();
  @override
  Future<LocalPlanPrefs> build() async {
    await gate.future;
    return const LocalPlanPrefs();
  }
}

/// H: the plan the program makes by itself, on the screen: the button beside
/// the quick prompts, the button of the error card, what the card says, the
/// way the plan is accepted and discarded, and the settings of the planner.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late EventRepository events;
  late MemoryApiKeyStore keys;

  Future<void> boot(
    WidgetTester tester,
    Widget home, {
    LLMProvider? llm,
    String? key,
    double? textScale,
    List<Override> extra = const [],
  }) async {
    // tall: a list that is built lazily shows all the cards
    useSize(tester, size: const Size(1280, 2600));
    db = await newDb();
    events = EventRepository(db);
    keys = MemoryApiKeyStore(key);
    await tester.pumpWidget(
      app(
        home,
        db,
        textScale: textScale,
        extra: [
          apiKeyStoreProvider.overrideWithValue(keys),
          llmFactoryProvider.overrideWithValue((cfg) => llm ?? _Llm([])),
          // Monday 2026-05-04, 10:00 Budapest: the plan starts on the Tuesday
          aiClockProvider.overrideWithValue(() => DateTime.utc(2026, 5, 4, 8)),
          handbookStoreProvider.overrideWith(
            (ref) => HandbookStore(
              ref.watch(recordRepoProvider),
              loader: (p) async => 'ALAP[$p]',
            ),
          ),
          ...extra,
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer ref0(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  Future<void> planWith(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('plan-local-chip')));
    await tester.pumpAndSettle();
  }

  Future<void> ask(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.tap(find.byTooltip('Küldés'));
    await tester.pumpAndSettle();
  }

  group('the button beside the quick prompts', () {
    testWidgets('it is there, and the plan comes with no key and no model', (
      tester,
    ) async {
      final llm = _Llm([]); // a call would throw
      await boot(tester, const AssistantPage(), llm: llm); // no key at all
      expect(find.text('Terv AI nélkül'), findsOneWidget);
      await planWith(tester);
      // the card says where it came from
      expect(find.text('Helyi terv, modell nélkül'), findsOneWidget);
      expect(
        find.textContaining(
          'Helyi terv, modell nélkül: 3 edzés a következő 7 napra',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Semmi nem hagyta el az eszközt'),
        findsOneWidget,
      );
      // the three sessions, selected, with their reasons
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      expect(find.text('Calisthenics 45 perc'), findsNWidgets(2));
      expect(find.text('Gym 60 perc'), findsOneWidget);
      expect(find.textContaining('Helyi terv: '), findsNWidgets(3));
      expect(find.text('Elfogadom a kijelölteket (3)'), findsOneWidget);
      // nothing to ask a model about a plan, nothing about a key
      expect(find.byKey(const Key('local-more')), findsNothing);
      expect(find.textContaining('API-kulcs'), findsNothing);
      expect(find.textContaining('Utolsó kérés'), findsNothing);
      expect(llm.requests, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('the hard session is marked, the light ones are not', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      await planWith(tester);
      expect(find.byTooltip('Nehéz edzés'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('accepting puts the sessions into the calendar, once', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      await planWith(tester);
      final button = find.text('Elfogadom a kijelölteket (3)');
      await tester.tap(button);
      // the second tap lands before the page has been rebuilt
      await tester.tap(button, warnIfMissed: false);
      await tester.pumpAndSettle();
      final all = (await tester.runAsync(() => events.all()))!;
      expect([for (final e in all) e.title]..sort(), [
        'Calisthenics 45 perc',
        'Calisthenics 45 perc',
        'Gym 60 perc',
      ]);
      expect(all.every((e) => e.aiGenerated), isTrue);
      expect(find.textContaining('3 esemény bekerült'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('one session can be left out', (tester) async {
      await boot(tester, const AssistantPage());
      await planWith(tester);
      await tester.tap(find.byType(CheckboxListTile).at(1)); // the gym
      await tester.pumpAndSettle();
      expect(find.text('Elfogadom a kijelölteket (2)'), findsOneWidget);
      await tester.tap(find.text('Elfogadom a kijelölteket (2)'));
      await tester.pumpAndSettle();
      final all = (await tester.runAsync(() => events.all()))!;
      expect(all.map((e) => e.title), everyElement('Calisthenics 45 perc'));
      expect(all, hasLength(2));
      await shutdown(tester, db);
    });

    testWidgets('"Elvetem" asks no "why": the program learns nothing from it', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      await planWith(tester);
      await tester.tap(find.text('Elvetem'));
      await tester.pumpAndSettle();
      expect(find.text('Szeretnéd, hogy megjegyezzem, miért?'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect((await tester.runAsync(() => events.all()))!, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('a plan for the model still asks "why" (that is unchanged)', (
      tester,
    ) async {
      final llm = _Llm([
        (_) => calls([
          tool('propose_events', {
            'summary': 'Terv',
            'proposals': [
              item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00'),
            ],
          }),
        ]),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await ask(tester, 'Tervezz edzést a jövő hétre');
      await tester.tap(find.text('Elvetem'));
      await tester.pumpAndSettle();
      expect(find.text('Szeretnéd, hogy megjegyezzem, miért?'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the wishes of the user decide what is planned', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      // (saved earlier, as the settings page does: the plan reads it from the
      // store)
      await tester.runAsync(
        () => ref0(tester)
            .read(recordRepoProvider)
            .setMeta(
              localPlanKey,
              const LocalPlanPrefs(
                sports: [PlanSport(name: 'Úszás', minutes: 30)],
                perWeek: 2,
              ).encode(),
            ),
      );
      await planWith(tester);
      expect(find.text('Úszás 30 perc'), findsNWidgets(2));
      expect(find.text('Gym 60 perc'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('with a full calendar it says that nothing fits', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      // a conference on every day of the window
      await tester.runAsync(() async {
        for (var d = 5; d <= 11; d++) {
          await events.saveLocal(
            evt(
              'k$d',
              'Konferencia',
              floating(2026, 5, d, 6),
              len: const Duration(hours: 17),
            ),
          );
        }
      });
      await planWith(tester);
      expect(find.textContaining('nem fért be új edzés'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      // the reasons are listed, as for any plan
      expect(find.textContaining('Nem javasolt (2)'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('while it works there is a status and the "Mégse" works', (
      tester,
    ) async {
      _SlowPrefs.gate = Completer<void>();
      await boot(
        tester,
        const AssistantPage(),
        extra: [localPlanPrefsProvider.overrideWith(_SlowPrefs.new)],
      );
      await tester.tap(find.byKey(const Key('plan-local-chip')));
      await tester.pump();
      expect(find.text('A program tervez, modell nélkül…'), findsOneWidget);
      // (one plan at a time: the chip waits)
      expect(
        tester
            .widget<ActionChip>(find.byKey(const Key('plan-local-chip')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Mégse'));
      await tester.pump();
      expect(find.text('A program tervez, modell nélkül…'), findsNothing);
      // the plan arrives late: it is dropped, the page stays empty
      _SlowPrefs.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Helyi terv, modell nélkül'), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the button of the error card', () {
    testWidgets('no key, a plan wanted: "Helyi terv" makes the plan itself', (
      tester,
    ) async {
      final llm = _Llm([]);
      await boot(tester, const AssistantPage(), llm: llm);
      await ask(tester, 'Tervezz edzést a jövő hétre');
      expect(
        find.textContaining('Még nincs API-kulcs megadva'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('plan-local-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-local-error')));
      await tester.pumpAndSettle();
      // the error card is gone, the plan is there
      expect(find.textContaining('Még nincs API-kulcs megadva'), findsNothing);
      expect(find.text('Helyi terv, modell nélkül'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      expect(llm.requests, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('a refused key', (tester) async {
      final llm = _Llm([
        (_) => const LlmAuth('A kulcs érvénytelen.'),
        (_) => const LlmAuth('A kulcs érvénytelen.'),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'rossz');
      await ask(tester, 'Tervezz edzést a jövő hétre');
      expect(find.textContaining('A kulcs érvénytelen.'), findsOneWidget);
      expect(find.byKey(const Key('plan-local-error')), findsOneWidget);
      // (a request to delete is no plan: the program has no plan to offer)
      await ask(tester, 'Töröld a holnapi edzést');
      expect(find.textContaining('A kulcs érvénytelen.'), findsOneWidget);
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('no quota left: yes; a limit that clears in a minute: no', (
      tester,
    ) async {
      final llm = _Llm([
        (_) => const LlmRateLimit('Elfogyott a napi keret.', daily: true),
        (_) => const LlmRateLimit('Túl sok kérés.'),
        (_) => const LlmRateLimit('Nincs egyenleg.', billing: true),
        (_) => const LlmRateLimit('Nincs ingyenes keret.', quotaZero: true),
        (_) => const LlmRateLimit('Elfogyott a napi keret.', daily: true),
      ]);
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      Future<void> again() async {
        await tester.tap(find.text('Újrapróbál'));
        await tester.pumpAndSettle();
      }

      await ask(tester, 'Tervezz edzést a jövő hétre');
      expect(find.byKey(const Key('plan-local-error')), findsOneWidget);
      await again(); // the transient one
      expect(find.textContaining('Túl sok kérés.'), findsOneWidget);
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      await again(); // billing
      expect(find.byKey(const Key('plan-local-error')), findsOneWidget);
      await again(); // no free quota
      expect(find.byKey(const Key('plan-local-error')), findsOneWidget);
      // the quota is gone, but this is no plan request: nothing to offer
      await ask(tester, 'Töröld a holnapi edzést');
      expect(find.textContaining('Elfogyott a napi keret.'), findsOneWidget);
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a question about money has no plan to offer instead', (
      tester,
    ) async {
      await boot(tester, const AssistantPage()); // no key
      await ask(tester, 'Miből spórolhatnék a legtöbbet?');
      expect(
        find.textContaining('Még nincs API-kulcs megadva'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('neither does a request to delete something', (tester) async {
      await boot(tester, const AssistantPage());
      await ask(tester, 'Töröld a holnapi edzést');
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a plan that failed is tried again, not asked of the model', (
      tester,
    ) async {
      _BrokenPrefs.built = 0;
      final llm = _Llm([]);
      final sink = MemoryDiagSink();
      await boot(
        tester,
        const AssistantPage(),
        llm: llm,
        key: 'k',
        extra: [
          localPlanPrefsProvider.overrideWith(_BrokenPrefs.new),
          diagLogProvider.overrideWithValue(DiagLog()..attach(sink)),
        ],
      );
      await planWith(tester);
      // (the failure is written down, in codes)
      await tester.runAsync(() => ref0(tester).read(diagLogProvider).flush());
      expect(sink.lines.join('\n'), contains('plan.local_failed'));
      expect(find.text('Újrapróbál'), findsOneWidget);
      expect(find.byKey(const Key('plan-local-error')), findsNothing);
      final first = _BrokenPrefs.built;
      await tester.tap(find.text('Újrapróbál'));
      await tester.pumpAndSettle();
      // the plan was attempted again (the wishes were read again), and the
      // text "Terv AI nélkül" went nowhere
      expect(_BrokenPrefs.built, greaterThan(first));
      expect(llm.requests, isEmpty);
      expect(find.text('Újrapróbál'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('the plan and the rest of the page', () {
    testWidgets('no plan starts while an approval is being carried out', (
      tester,
    ) async {
      await boot(tester, const AssistantPage());
      final c = ref0(tester);
      expect(c.read(assistantApplyingProvider.notifier).begin(), isTrue);
      await c.read(assistantControllerProvider.notifier).planLocally();
      await tester.pumpAndSettle();
      expect(c.read(assistantControllerProvider).busy, isFalse);
      expect(c.read(assistantControllerProvider).outcome, isNull);
      expect(find.byType(CheckboxListTile), findsNothing);
      c.read(assistantApplyingProvider.notifier).end();
      await shutdown(tester, db);
    });

    testWidgets('a local plan is not taken further to the model', (
      tester,
    ) async {
      final llm = _Llm([]); // a call would throw
      await boot(tester, const AssistantPage(), llm: llm, key: 'k');
      await planWith(tester);
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      await ref0(tester)
          .read(assistantControllerProvider.notifier)
          .askMore('Mikor férne be még egy?');
      await tester.pumpAndSettle();
      expect(llm.requests, isEmpty);
      expect(ref0(tester).read(assistantControllerProvider).error, isNull);
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      await shutdown(tester, db);
    });
  });

  group('the settings of the planner', () {
    Future<void> show(WidgetTester tester, Finder f) async {
      await tester.scrollUntilVisible(
        f,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, Key key) async {
      final f = find.byKey(key);
      await show(tester, f);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<String?> saved(WidgetTester tester) async {
      final text = await tester.runAsync<String?>(
        () => ref0(tester).read(recordRepoProvider).meta(localPlanKey),
      );
      return text;
    }

    testWidgets(
      'the first start shows the two sports, three a week, any time',
      (tester) async {
        await boot(tester, const SettingsPage());
        await show(tester, find.text('Helyi terv (AI nélkül)'));
        expect(find.text('Calisthenics'), findsOneWidget);
        expect(find.text('45 perc'), findsOneWidget);
        expect(find.text('Gym'), findsOneWidget);
        expect(find.text('60 perc'), findsOneWidget);
        expect(find.text('3 edzés hetente'), findsOneWidget);
        expect(
          find.textContaining('Bármikor (inkább 10–19 óra között)'),
          findsOneWidget,
        );
        // nothing is saved until the user changes something; no "reset" either
        expect(await saved(tester), isNull);
        expect(find.byKey(const Key('plan-reset')), findsNothing);
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'the weekly goal and the time of day are saved on this device',
      (tester) async {
        await boot(tester, const SettingsPage());
        await show(tester, find.byKey(const ValueKey('plan-perweek-3')));
        await tester.tap(find.byKey(const ValueKey('plan-perweek-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('5 edzés hetente').last);
        await tester.pumpAndSettle();
        await show(tester, find.byKey(const ValueKey('plan-band-any')));
        await tester.tap(find.byKey(const ValueKey('plan-band-any')));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Este (17–21 óra)').last);
        await tester.pumpAndSettle();
        final p = LocalPlanPrefs.decode(await saved(tester));
        expect(p.perWeek, 5);
        expect(p.band, PlanBand.evening);
        expect(p.sports, defaultPlanSports);
        await shutdown(tester, db);
      },
    );

    testWidgets('a sport is added, with its length and the outdoor mark', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      await show(tester, find.byKey(const Key('plan-sport-add')));
      await tester.tap(find.byKey(const Key('plan-sport-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('plan-sport-name')), 'Kajak');
      await tester.enterText(find.byKey(const Key('plan-sport-minutes')), '90');
      await tester.tap(find.byKey(const Key('plan-sport-outdoor')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan-sport-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Kajak'), findsOneWidget);
      expect(find.text('90 perc · szabadtéri'), findsOneWidget);
      final p = LocalPlanPrefs.decode(await saved(tester));
      expect(
        p.sports.last,
        const PlanSport(name: 'Kajak', minutes: 90, outdoor: true),
      );
      expect(p.sports, hasLength(3));
      await shutdown(tester, db);
    });

    testWidgets('a wrong entry is explained and nothing is saved', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      await show(tester, find.byKey(const Key('plan-sport-add')));
      await tester.tap(find.byKey(const Key('plan-sport-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('plan-sport-name')), 'Úszás');
      await tester.enterText(find.byKey(const Key('plan-sport-minutes')), '5');
      await tester.tap(find.byKey(const Key('plan-sport-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-sport-bad')), findsOneWidget);
      // too long is wrong too
      await tester.enterText(
        find.byKey(const Key('plan-sport-minutes')),
        '181',
      );
      await tester.tap(find.byKey(const Key('plan-sport-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-sport-bad')), findsOneWidget);
      // no name
      await tester.enterText(find.byKey(const Key('plan-sport-name')), '  ');
      await tester.enterText(find.byKey(const Key('plan-sport-minutes')), '30');
      await tester.tap(find.byKey(const Key('plan-sport-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-sport-bad')), findsOneWidget);
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(await saved(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('a sport is edited by tapping it, and deleted', (tester) async {
      await boot(tester, const SettingsPage());
      await show(tester, find.byKey(const Key('plan-sport-1')));
      await tester.tap(find.byKey(const Key('plan-sport-1'))); // the gym
      await tester.pumpAndSettle();
      expect(find.text('Sport szerkesztése'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('plan-sport-minutes')), '75');
      await tester.tap(find.byKey(const Key('plan-sport-ok')));
      await tester.pumpAndSettle();
      expect(find.text('75 perc'), findsOneWidget);
      await tapKey(tester, const Key('plan-sport-del-0'));
      expect(find.text('Calisthenics'), findsNothing);
      final p = LocalPlanPrefs.decode(await saved(tester));
      expect(p.sports, [const PlanSport(name: 'Gym', minutes: 75)]);
      await shutdown(tester, db);
    });

    testWidgets('with no sport left it says the plan has nothing to plan', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      await tapKey(tester, const Key('plan-sport-del-1'));
      await tapKey(tester, const Key('plan-sport-del-0'));
      expect(find.textContaining('Nincs sport megadva'), findsOneWidget);
      expect(LocalPlanPrefs.decode(await saved(tester)).sports, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('the defaults come back after a question', (tester) async {
      await boot(tester, const SettingsPage());
      await tester.runAsync(
        () => ref0(tester)
            .read(localPlanPrefsProvider.notifier)
            .save(
              const LocalPlanPrefs(
                sports: [PlanSport(name: 'Úszás', minutes: 30)],
                perWeek: 6,
                band: PlanBand.morning,
              ),
            ),
      );
      await tester.pumpAndSettle();
      await show(tester, find.byKey(const Key('plan-reset')));
      await tester.tap(find.byKey(const Key('plan-reset')));
      await tester.pumpAndSettle();
      expect(find.text('Alapértékek visszaállítása?'), findsOneWidget);
      // "Mégse" changes nothing
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(LocalPlanPrefs.decode(await saved(tester)).perWeek, 6);
      await tester.tap(find.byKey(const Key('plan-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan-reset-yes')));
      await tester.pumpAndSettle();
      final p = LocalPlanPrefs.decode(await saved(tester));
      expect(p.sports, defaultPlanSports);
      expect(p.perWeek, 3);
      expect(p.band, PlanBand.any);
      expect(find.byKey(const Key('plan-reset')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('any change of the wishes offers the way back', (tester) async {
      await boot(tester, const SettingsPage());
      Future<void> saveOnly(LocalPlanPrefs p) async {
        await tester.runAsync(
          () => ref0(tester).read(localPlanPrefsProvider.notifier).save(p),
        );
        await tester.pumpAndSettle();
      }

      // (each wish alone: the weekly goal, the time of day, the sports)
      await saveOnly(const LocalPlanPrefs(perWeek: 4));
      await show(tester, find.text('Helyi terv (AI nélkül)'));
      expect(find.byKey(const Key('plan-reset')), findsOneWidget);
      await saveOnly(const LocalPlanPrefs(band: PlanBand.evening));
      expect(find.byKey(const Key('plan-reset')), findsOneWidget);
      await saveOnly(
        const LocalPlanPrefs(sports: [PlanSport(name: 'Gym', minutes: 60)]),
      );
      expect(find.byKey(const Key('plan-reset')), findsOneWidget);
      await saveOnly(const LocalPlanPrefs());
      expect(find.byKey(const Key('plan-reset')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the sport that is tapped is the one that goes', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      await tapKey(tester, const Key('plan-sport-del-1')); // the Gym
      expect(find.text('Gym'), findsNothing);
      expect(find.text('Calisthenics'), findsOneWidget);
      final p = LocalPlanPrefs.decode(await saved(tester));
      expect(p.sports, [const PlanSport(name: 'Calisthenics', minutes: 45)]);
      await shutdown(tester, db);
    });

    testWidgets('twelve sports are the most: the add button goes', (
      tester,
    ) async {
      await boot(tester, const SettingsPage());
      Future<void> saveSports(int n) async {
        await tester.runAsync(
          () => ref0(tester)
              .read(localPlanPrefsProvider.notifier)
              .save(
                LocalPlanPrefs(
                  sports: [
                    for (var i = 0; i < n; i++)
                      PlanSport(name: 'Sport $i', minutes: 30),
                  ],
                ),
              ),
        );
        await tester.pumpAndSettle();
      }

      // eleven: there is still room for one more
      await saveSports(11);
      await show(tester, find.byKey(const Key('plan-sport-10')));
      expect(find.byKey(const Key('plan-sport-add')), findsOneWidget);
      // twelve: the most
      await saveSports(12);
      await show(tester, find.byKey(const Key('plan-sport-11')));
      expect(find.byKey(const Key('plan-sport-add')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('at twice the text size nothing overflows', (tester) async {
      await boot(tester, const SettingsPage(), textScale: 2);
      await show(tester, find.text('Helyi terv (AI nélkül)'));
      await tester.scrollUntilVisible(
        find.byKey(const Key('plan-sport-add')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });
}
