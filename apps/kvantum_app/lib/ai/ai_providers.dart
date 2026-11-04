import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import 'ai_settings.dart';
import 'assistant_service.dart';
import 'gemini_provider.dart';
import 'handbook_store.dart';
import 'llm_provider.dart';

final apiKeyStoreProvider = Provider<ApiKeyStore>((_) => SecureApiKeyStore());

final llmFactoryProvider = Provider<LLMProvider Function(String apiKey)>(
  (_) =>
      (key) => GeminiProvider(http.Client(), apiKey: key),
);

final aiSettingsStoreProvider = Provider<AiSettingsStore>((ref) {
  final r = ref.watch(recordRepoProvider);
  return AiSettingsStore(read: r.meta, write: r.setMeta);
});

final handbookStoreProvider = Provider<HandbookStore>(
  (ref) => HandbookStore(ref.watch(recordRepoProvider)),
);

class AiSettingsNotifier extends AsyncNotifier<AiSettings> {
  @override
  Future<AiSettings> build() => ref.watch(aiSettingsStoreProvider).load();

  Future<void> change(AiSettings s) async {
    await ref.read(aiSettingsStoreProvider).save(s);
    state = AsyncData(s);
  }
}

final aiSettingsProvider =
    AsyncNotifierProvider<AiSettingsNotifier, AiSettings>(
      AiSettingsNotifier.new,
    );

/// Requests sent today; invalidate after each assistant run.
final aiUsageProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(aiSettingsStoreProvider).usageToday(),
);

/// Colour of events the assistant creates (Google "Sage"): easy to tell apart.
const aiEventColorId = '2';

class AssistantState {
  const AssistantState({
    this.busy = false,
    this.outcome,
    this.error,
    this.errorNeedsSettings = false,
    this.selected = const {},
    this.acceptedCount,
    this.prompt = '',
    this.status,
    this.notice,
    this.errorDetail,
  });

  final bool busy;
  final AssistantOutcome? outcome;
  final String? error;

  /// True when the fix is in the settings (no / wrong key).
  final bool errorNeedsSettings;
  final Set<int> selected;
  final int? acceptedCount;
  final String prompt;

  /// Progress line while busy (e.g. waiting for a rate limit to clear).
  final String? status;

  /// Something worth telling after a successful run (e.g. model switched).
  final String? notice;

  /// The service's own explanation of an error, for diagnosis.
  final String? errorDetail;

  AssistantState copyWith({
    bool? busy,
    AssistantOutcome? outcome,
    bool clearOutcome = false,
    String? error,
    bool clearError = false,
    bool? errorNeedsSettings,
    Set<int>? selected,
    int? acceptedCount,
    bool clearAccepted = false,
    String? prompt,
    String? status,
    bool clearStatus = false,
  }) => AssistantState(
    busy: busy ?? this.busy,
    outcome: clearOutcome ? null : (outcome ?? this.outcome),
    error: clearError ? null : (error ?? this.error),
    errorNeedsSettings: errorNeedsSettings ?? this.errorNeedsSettings,
    selected: selected ?? this.selected,
    acceptedCount: clearAccepted ? null : (acceptedCount ?? this.acceptedCount),
    prompt: prompt ?? this.prompt,
  );
}

class AssistantController extends Notifier<AssistantState> {
  @override
  AssistantState build() => const AssistantState();

  Future<void> ask(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty || state.busy) return;
    state = AssistantState(busy: true, prompt: text);
    void status(String s) => state = state.copyWith(status: s);
    try {
      final key = await ref.read(apiKeyStoreProvider).read();
      if (key == null) {
        state = AssistantState(
          prompt: text,
          error:
              'Még nincs Gemini API-kulcs megadva. Add meg a Beállításokban.',
          errorNeedsSettings: true,
        );
        return;
      }
      final provider = ref.read(llmFactoryProvider)(key);
      final settingsNotifier = ref.read(aiSettingsProvider.notifier);
      var settings = await ref.read(aiSettingsProvider.future);
      var model = settings.model;
      if (model == null || model.trim().isEmpty) {
        model = pickDefaultModel(await provider.listModels());
        if (model == null) {
          throw const LlmBadResponse(
            'Nem találtam használható modellt ehhez a kulcshoz.',
          );
        }
        settings = settings.copyWith(model: model);
        await settingsNotifier.change(settings);
      }
      final service = AssistantService(
        provider: provider,
        events: ref.read(repoProvider),
        records: ref.read(recordRepoProvider),
        handbook: ref.read(handbookStoreProvider),
        settingsStore: ref.read(aiSettingsStoreProvider),
      );
      Future<AssistantOutcome> run(String m) =>
          service.ask(text, model: m, settings: settings, onStatus: status);

      AssistantOutcome outcome;
      String? notice;
      try {
        outcome = await run(model);
      } on LlmRateLimit catch (first) {
        if (!(first.quotaZero || first.daily)) rethrow;
        // This model has no (more) free quota: try the other flash models once.
        AssistantOutcome? alt;
        String? used;
        for (final cand in fallbackModels(await provider.listModels(), model)) {
          status('A(z) $model-hez nincs szabad keret, próbálom ezt: $cand…');
          try {
            alt = await run(cand);
            used = cand;
            break;
          } on LlmRateLimit {
            continue;
          }
        }
        if (alt == null) rethrow; // keep the precise first error
        outcome = alt;
        settings = settings.copyWith(model: used);
        await settingsNotifier.change(settings);
        notice =
            'Átváltottam a(z) $used modellre, mert a(z) $model-hez nincs szabad ingyenes keret. A Beállításokban átállíthatod.';
      }
      state = AssistantState(
        prompt: text,
        outcome: outcome,
        selected: {for (var i = 0; i < outcome.items.length; i++) i},
        notice: notice,
      );
    } on LlmAuth catch (e) {
      state = AssistantState(
        prompt: text,
        error: e.message,
        errorNeedsSettings: true,
      );
    } on LlmRateLimit catch (e) {
      final advice = e.quotaZero
          ? ' Válassz másik modellt a Beállításokban, vagy engedélyezd a számlázást a Google AI Studióban (az ingyenes szint nem minden fióknál és országban érhető el).'
          : e.daily
          ? ' Holnap újra működik, vagy válassz másik modellt a Beállításokban.'
          : ' Várj egy percet, és próbáld újra.';
      state = AssistantState(
        prompt: text,
        error: '${e.message}$advice',
        errorNeedsSettings: !e.transient,
        errorDetail: e.detail.isEmpty ? null : e.detail,
      );
    } on LlmException catch (e) {
      state = AssistantState(prompt: text, error: e.message);
    } catch (e) {
      state = AssistantState(prompt: text, error: 'Váratlan hiba: $e');
    } finally {
      ref.invalidate(aiUsageProvider);
    }
  }

  void toggle(int index) {
    final s = {...state.selected};
    s.contains(index) ? s.remove(index) : s.add(index);
    state = state.copyWith(selected: s);
  }

  /// Creates the selected proposals as real events in the app's own calendar.
  Future<int> acceptSelected() async {
    final o = state.outcome;
    if (o == null) return 0;
    final repo = ref.read(repoProvider);
    var n = 0;
    for (var i = 0; i < o.items.length; i++) {
      if (!state.selected.contains(i)) continue;
      final it = o.items[i];
      await repo.saveLocal(
        CalEvent(
          id: const Uuid().v4(),
          calendarId: kNaptarCalendar,
          title: it.title,
          notes: it.reason,
          start: it.startWall,
          end: it.endWall,
          tzid: it.tzid,
          colorId: aiEventColorId,
          aiGenerated: true,
        ),
      );
      n++;
    }
    ref.read(syncControllerProvider.notifier).requestSync();
    state = AssistantState(prompt: state.prompt, acceptedCount: n);
    return n;
  }

  void dismiss() => state = const AssistantState();
}

final assistantControllerProvider =
    NotifierProvider<AssistantController, AssistantState>(
      AssistantController.new,
    );
