import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

// AI-24: when a model has no quota left, or is gone, the assistant tries the
// provider's other models (not only Gemini's), says so, and remembers it.

/// A scripted model that also lists what its provider offers.
class _Models extends FakeLlm {
  _Models(super.script, this.available);
  final List<LlmModel> available;
  @override
  Future<List<LlmModel>> listModels() async => available;
}

LlmReply plan() => calls([
  propose([item('Futás', '2026-05-05T18:00:00', '2026-05-05T19:00:00')]),
]);

List<LlmModel> models(List<String> ids) => [
  for (final i in ids) LlmModel(i, i),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late ProviderContainer c;

  /// An assistant that talks to [provider] with [model] (a key is saved).
  Future<void> use(
    LLMProvider llm, {
    required String provider,
    required String model,
  }) async {
    db = await newDb();
    final keys = MemoryApiKeyStore();
    c = ProviderContainer(
      overrides: [
        ...baseOverrides(db),
        apiKeyStoreProvider.overrideWithValue(keys),
        llmFactoryProvider.overrideWithValue((_) => llm),
        aiClockProvider.overrideWithValue(() => DateTime.utc(2026, 5, 4, 8)),
        handbookStoreProvider.overrideWith(
          (ref) => HandbookStore(
            ref.watch(recordRepoProvider),
            loader: (p) async => 'ALAP[$p]',
          ),
        ),
      ],
    );
    addTearDown(() async {
      c.dispose();
      await db.close();
    });
    await keys.write('key-test', provider: provider);
    final settings = c.read(aiSettingsProvider.notifier);
    await settings.selectProvider(provider);
    final s = await c.read(aiSettingsProvider.future);
    await settings.change(s.copyWith(model: model));
  }

  Future<AssistantState> ask() async {
    await c.read(assistantControllerProvider.notifier).ask('edzés');
    return c.read(assistantControllerProvider);
  }

  Future<String?> savedModel() async =>
      (await c.read(aiSettingsStoreProvider).load()).model;

  const daily = LlmRateLimit('Elfogyott a mai ingyenes keret.', daily: true);
  const gone = LlmModelGone('A modell megszűnt.');

  group('another model of the same provider', () {
    test('Groq: a model with its daily quota used up is replaced', () async {
      final llm = _Models(
        [(_) => daily, (_) => plan()],
        models([
          'llama-3.3-70b-versatile',
          'openai/gpt-oss-20b',
          'whisper-large-v3',
        ]),
      );
      await use(llm, provider: 'groq', model: 'llama-3.3-70b-versatile');
      final st = await ask();
      expect(llm.models, ['llama-3.3-70b-versatile', 'openai/gpt-oss-20b']);
      expect(st.outcome!.items.single.title, 'Futás');
      expect(
        st.notice,
        'Átváltottam a(z) openai/gpt-oss-20b modellre, mert a(z) llama-3.3-70b-versatile-hez nincs szabad keret. A Beállításokban átállíthatod.',
        reason: 'no "ingyenes" where the free tier is not Gemini\'s',
      );
      expect(await savedModel(), 'openai/gpt-oss-20b');
    });

    test('Gemini keeps its words: "ingyenes keret"', () async {
      final llm = _Models([
        (_) => const LlmRateLimit('nincs keret', quotaZero: true),
        (_) => plan(),
      ], models(['gemini-2.5-flash', 'gemini-2.5-flash-lite']));
      await use(llm, provider: 'gemini', model: 'gemini-2.5-flash');
      final st = await ask();
      expect(llm.models, ['gemini-2.5-flash', 'gemini-2.5-flash-lite']);
      expect(st.notice, contains('nincs szabad ingyenes keret'));
    });

    test('a model that is gone is replaced, and the reason is told', () async {
      final llm = _Models([
        (_) => gone,
        (_) => plan(),
      ], models(['llama3-70b-8192', 'llama-3.3-70b-versatile']));
      await use(llm, provider: 'groq', model: 'llama3-70b-8192');
      final st = await ask();
      expect(llm.models, ['llama3-70b-8192', 'llama-3.3-70b-versatile']);
      expect(
        st.notice,
        'Átváltottam a(z) llama-3.3-70b-versatile modellre, mert a(z) llama3-70b-8192 már nem elérhető. A Beállításokban átállíthatod.',
      );
      expect(await savedModel(), 'llama-3.3-70b-versatile');
    });

    test('Gemini: a model that is gone is replaced too', () async {
      final llm = _Models([
        (_) => gone,
        (_) => plan(),
      ], models(['gemini-1.5-flash', 'gemini-2.5-flash']));
      await use(llm, provider: 'gemini', model: 'gemini-1.5-flash');
      final st = await ask();
      expect(llm.models, ['gemini-1.5-flash', 'gemini-2.5-flash']);
      expect(st.notice, contains('gemini-1.5-flash már nem elérhető'));
    });

    test(
      'the next one is tried when a candidate is gone or limited too',
      () async {
        final llm = _Models(
          [(_) => daily, (_) => gone, (_) => daily, (_) => plan()],
          models([
            'llama-3.3-70b-versatile',
            'openai/gpt-oss-20b',
            'openai/gpt-oss-120b',
            'llama-3.1-8b-instant',
          ]),
        );
        await use(llm, provider: 'groq', model: 'llama-3.3-70b-versatile');
        final st = await ask();
        expect(llm.models, [
          'llama-3.3-70b-versatile',
          'openai/gpt-oss-20b',
          'openai/gpt-oss-120b',
          'llama-3.1-8b-instant',
        ]);
        expect(st.notice, contains('modellre'));
        expect(st.notice, contains('llama-3.1-8b-instant'));
        expect(await savedModel(), 'llama-3.1-8b-instant');
      },
    );

    test('when none works, the FIRST reason is the one shown', () async {
      final llm = _Models([
        (_) => const LlmModelGone('Az eredeti modell megszűnt.'),
        (_) => const LlmModelGone('A második is megszűnt.'),
      ], models(['llama3-70b-8192', 'llama-3.3-70b-versatile']));
      await use(llm, provider: 'groq', model: 'llama3-70b-8192');
      final st = await ask();
      expect(llm.models.length, 2);
      expect(st.error, 'Az eredeti modell megszűnt.');
      expect(
        st.errorNeedsSettings,
        isTrue,
        reason: 'the model is changed in the settings',
      );
      expect(await savedModel(), 'llama3-70b-8192', reason: 'nothing changed');
    });

    test(
      'only the failed model is left: the reason and the settings button',
      () async {
        final llm = _Models(
          [(_) => gone],
          models(['llama3-70b-8192', 'whisper-large-v3', 'llama-guard-4-12b']),
        );
        await use(llm, provider: 'groq', model: 'llama3-70b-8192');
        final st = await ask();
        expect(llm.models, ['llama3-70b-8192'], reason: 'guards do not chat');
        expect(st.error, 'A modell megszűnt.');
        expect(st.errorNeedsSettings, isTrue);
      },
    );

    test(
      'an address of the user\'s own has no catalogue: no model is tried',
      () async {
        final llm = _Models([
          (_) => gone,
          (_) => plan(),
        ], models(['mine', 'other']));
        await use(llm, provider: 'custom', model: 'mine');
        final st = await ask();
        expect(llm.models, ['mine']);
        expect(st.error, 'A modell megszűnt.');
      },
    );

    test('a billing problem does not switch models', () async {
      final llm = _Models([
        (_) => const LlmRateLimit(
          'Nincs elég egyenleg.',
          billing: true,
          detail: 'insufficient_quota',
        ),
      ], models(['llama-3.3-70b-versatile', 'openai/gpt-oss-20b']));
      await use(llm, provider: 'groq', model: 'llama-3.3-70b-versatile');
      final st = await ask();
      expect(llm.models, ['llama-3.3-70b-versatile']);
      expect(st.error, contains('Nincs elég egyenleg.'));
      expect(await savedModel(), 'llama-3.3-70b-versatile');
    });

    test('other mistakes are not a reason to switch', () async {
      final llm = _Models([
        (_) => const LlmBadResponse('üres válasz'),
      ], models(['llama-3.3-70b-versatile', 'openai/gpt-oss-20b']));
      await use(llm, provider: 'groq', model: 'llama-3.3-70b-versatile');
      final st = await ask();
      expect(llm.models, ['llama-3.3-70b-versatile']);
      expect(st.error, 'üres válasz');
      expect(st.errorNeedsSettings, isFalse);
    });
  });
}
