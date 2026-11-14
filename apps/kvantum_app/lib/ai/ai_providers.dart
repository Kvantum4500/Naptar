import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import '../ui/event_editor.dart' show Scope;
import '../ui/undo_service.dart';
import 'ai_settings.dart';
import 'approval.dart';
import 'assistant_service.dart';
import 'gemini_provider.dart';
import 'handbook_store.dart';
import 'llm_provider.dart';
import 'location_service.dart';
import 'provider_catalog.dart';
import 'weather_service.dart';

final apiKeyStoreProvider = Provider<ApiKeyStore>((_) => SecureApiKeyStore());

final llmFactoryProvider = Provider<LLMProvider Function(LlmConfig config)>(
  (_) =>
      (cfg) => buildProvider(cfg, http.Client()),
);

final aiSettingsStoreProvider = Provider<AiSettingsStore>((ref) {
  final r = ref.watch(recordRepoProvider);
  return AiSettingsStore(read: r.meta, write: r.setMeta);
});

final weatherServiceProvider = Provider<WeatherService>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return WeatherService(c, log: ref.read(diagLogProvider));
});

final locationProvider = Provider<LocationProvider>(
  (ref) => const GeolocatorLocationProvider(),
);

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

  /// Switches the provider; each provider remembers its own model.
  Future<void> selectProvider(String id) async {
    final store = ref.read(aiSettingsStoreProvider);
    await store.write('ai.provider', id == 'gemini' ? null : id);
    state = AsyncData(await store.load()); // brings that provider's own model
  }
}

final aiSettingsProvider =
    AsyncNotifierProvider<AiSettingsNotifier, AiSettings>(
      AiSettingsNotifier.new,
    );

/// What the assistant used today at the CURRENT provider (answered requests and
/// their tokens); invalidate after each assistant run.
final aiUsageProvider = FutureProvider.autoDispose<AiUsageDay>((ref) async {
  final settings = await ref.watch(aiSettingsProvider.future);
  return ref
      .watch(aiSettingsStoreProvider)
      .usageOf(provider: settings.provider);
});

/// The clock the assistant plans with (proposals must lie ahead of it).
/// Tests replace it so their fixed dates stay valid.
final aiClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

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
    this.deleteScopes = const {},
    this.deletedCount,
    this.movedCount,
    this.askWhy = false,
    this.habitSaved = false,
  });

  /// Per proposed deletion of a recurring event: what to remove (default: only that day).
  final Map<int, Scope> deleteScopes;

  /// How many events were deleted after the user confirmed.
  final int? deletedCount;

  /// How many events were moved after the user confirmed.
  final int? movedCount;

  /// After a discarded plan: offer to remember why.
  final bool askWhy;

  /// A habit was just written to "Tanult szokások".
  final bool habitSaved;

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
    Map<int, Scope>? deleteScopes,
    int? deletedCount,
    bool clearDeleted = false,
    int? movedCount,
    bool clearMoved = false,
    String? notice,
    bool clearNotice = false,
    bool? askWhy,
    bool? habitSaved,
  }) => AssistantState(
    deleteScopes: deleteScopes ?? this.deleteScopes,
    deletedCount: clearDeleted ? null : (deletedCount ?? this.deletedCount),
    movedCount: clearMoved ? null : (movedCount ?? this.movedCount),
    notice: clearNotice ? null : (notice ?? this.notice),
    errorDetail: errorDetail,
    askWhy: askWhy ?? this.askWhy,
    habitSaved: habitSaved ?? this.habitSaved,
    busy: busy ?? this.busy,
    outcome: clearOutcome ? null : (outcome ?? this.outcome),
    error: clearError ? null : (error ?? this.error),
    errorNeedsSettings: errorNeedsSettings ?? this.errorNeedsSettings,
    selected: selected ?? this.selected,
    acceptedCount: clearAccepted ? null : (acceptedCount ?? this.acceptedCount),
    prompt: prompt ?? this.prompt,
    // the progress line ("waiting for the rate limit…") used to be dropped here
    status: clearStatus ? null : (status ?? this.status),
  );
}

/// The preview builds the request but never sends it.
class _NoProvider implements LLMProvider {
  @override
  Future<LlmReply> generate(String model, LlmRequest request) =>
      throw StateError('the preview sends nothing');

  @override
  Future<List<LlmModel>> listModels() async => const [];

  @override
  void close() {}
}

class AssistantController extends Notifier<AssistantState> {
  @override
  AssistantState build() => const AssistantState();

  AssistantService _newService(
    AiSettings settings,
    ProviderInfo info,
    LLMProvider provider,
  ) => AssistantService(
    now: ref.read(aiClockProvider),
    provider: provider,
    providerId: info.id,
    // the request is made smaller before it is sent if it would not fit
    tokenBudget: info.tokenBudget,
    events: ref.read(repoProvider),
    records: ref.read(recordRepoProvider),
    handbook: ref.read(handbookStoreProvider),
    settingsStore: ref.read(aiSettingsStoreProvider),
    weather: ref.read(weatherServiceProvider),
    finance: ref.read(financeRepoProvider),
    rules: PlanRules(
      sleepStartHour: settings.sleepStartHour,
      sleepEndHour: settings.sleepEndHour,
    ),
  );

  /// What the request for [prompt] would carry, built by the same code as the
  /// real one but never sent: for the "Mit küldünk?" panel.
  Future<PreparedRequest> preview(String prompt) async {
    final settings = await ref.read(aiSettingsProvider.future);
    final info = providerById(settings.provider);
    return _newService(
      settings,
      info,
      _NoProvider(),
    ).preview(prompt.trim(), settings: settings);
  }

  // The running request. A new number per request: a result that arrives for an
  // older number (the user pressed "Mégse" meanwhile) is thrown away.
  int _run = 0;
  AssistantService? _service;
  LLMProvider? _provider;

  /// "Mégse" (also when the page is left): stops the running request. The
  /// connection is closed, so the call in flight is aborted, and the late
  /// answer, if any, is dropped.
  void cancel() {
    // (a page that is left after the whole app is gone has nothing to cancel)
    if (!ref.mounted || !state.busy) return;
    _run++;
    _service?.cancel();
    _provider?.close();
    state = AssistantState(prompt: state.prompt);
  }

  /// A further question to the model about a local answer the program has
  /// just given ("Kérdezd a modellt is"): the answer goes with it as data,
  /// where the user's sharing switches allow it.
  Future<void> askMore(String followUp) async {
    final answer = state.outcome?.localAnswer;
    if (answer == null || answer.kind == LocalKind.switchedOff) return;
    await ask(followUp, context: answer);
  }

  Future<void> ask(String prompt, {LocalAnswer? context}) async {
    final text = prompt.trim();
    // (a question does not start while an approval is being carried out: the
    // page would be rebuilt under it)
    if (text.isEmpty || state.busy || ref.read(assistantApplyingProvider)) {
      return;
    }
    final run = ++_run;
    bool live() => run == _run;
    state = AssistantState(busy: true, prompt: text);
    void status(String s) {
      if (live()) state = state.copyWith(status: s);
    }

    LLMProvider? provider;
    try {
      var settings = await ref.read(aiSettingsProvider.future);
      final info = providerById(settings.provider);
      // Some questions the program answers itself, from the data on the device:
      // no key, no model, no tokens (and nothing leaves the device).
      if (context == null) {
        final local = await _newService(
          settings,
          info,
          _NoProvider(),
        ).localOutcome(text, settings: settings);
        if (local != null) {
          if (live()) state = AssistantState(prompt: text, outcome: local);
          return;
        }
      }
      final key = await ref.read(apiKeyStoreProvider).read(provider: info.id);
      if (key == null && !info.keyOptional) {
        if (live()) {
          state = AssistantState(
            prompt: text,
            error:
                'Még nincs API-kulcs megadva ehhez: ${info.label}. Add meg a Beállításokban.',
            errorNeedsSettings: true,
          );
        }
        return;
      }
      provider = ref.read(llmFactoryProvider)(
        LlmConfig(
          provider: info.id,
          apiKey: key ?? '',
          // only the custom provider has an address of its own
          baseUrl: info.id == 'custom' ? settings.customBaseUrl : null,
        ),
      );
      _provider = provider;
      final settingsNotifier = ref.read(aiSettingsProvider.notifier);
      var model = settings.model;
      if (model == null || model.trim().isEmpty) {
        model = pickModelFor(info.id, await provider.listModels());
        if (model == null) {
          throw const LlmBadResponse(
            'Nem találtam használható modellt ehhez a kulcshoz.',
          );
        }
        settings = settings.copyWith(model: model);
        await settingsNotifier.change(settings);
      }
      // "Mégse" during the preparations: nothing is sent at all
      if (!live()) return;
      final service = _newService(settings, info, provider);
      _service = service;
      Future<AssistantOutcome> go(String m) => service.ask(
        text,
        model: m,
        settings: settings,
        onStatus: status,
        context: context,
      );

      AssistantOutcome outcome;
      String? notice;
      try {
        outcome = await go(model);
      } on LlmRateLimit catch (first) {
        // Switching models only makes sense where one provider has several free
        // ones (Gemini); billing problems affect every model alike.
        if (info.id != 'gemini' || !(first.quotaZero || first.daily)) rethrow;
        // This model has no (more) free quota: try the other flash models once.
        AssistantOutcome? alt;
        String? used;
        for (final cand in fallbackModels(await provider.listModels(), model)) {
          status('A(z) $model-hez nincs szabad keret, próbálom ezt: $cand…');
          try {
            alt = await go(cand);
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
      if (!live()) return;
      final notes = [?notice, ?outcome.notice];
      state = AssistantState(
        prompt: text,
        outcome: outcome,
        selected: {for (var i = 0; i < outcome.items.length; i++) i},
        notice: notes.isEmpty ? null : notes.join(' '),
      );
    } on LlmCancelled {
      // cancel() has already put the page back
    } on LlmAuth catch (e) {
      if (live()) {
        state = AssistantState(
          prompt: text,
          error: e.message,
          errorNeedsSettings: true,
        );
      }
    } on LlmRateLimit catch (e) {
      final advice = e.billing
          ? ' Tölts fel egyenleget a szolgáltatónál, vagy válassz másik szolgáltatót a Beállításokban (pl. Groq vagy Mistral).'
          : e.quotaZero
          ? ' Válassz másik modellt a Beállításokban, vagy engedélyezd a számlázást a Google AI Studióban (az ingyenes szint nem minden fióknál és országban érhető el).'
          : e.daily
          ? ' Holnap újra működik, vagy válassz másik modellt a Beállításokban.'
          : ' Várj egy percet, és próbáld újra.';
      if (live()) {
        state = AssistantState(
          prompt: text,
          error: '${e.message}$advice',
          errorNeedsSettings: !e.transient,
          errorDetail: e.detail.isEmpty ? null : e.detail,
        );
      }
    } on LlmException catch (e) {
      if (live()) state = AssistantState(prompt: text, error: e.message);
    } catch (e, st) {
      ref.read(diagLogProvider).error('ai', 'ask.failed', e, st);
      if (live()) {
        state = AssistantState(prompt: text, error: errorInfoFor(e).text);
      }
    } finally {
      // one connection per request, closed when it is over
      provider?.close();
      if (identical(_provider, provider)) {
        _provider = null;
        _service = null;
      }
      ref.invalidate(aiUsageProvider);
    }
  }

  void toggle(int index) {
    final s = {...state.selected};
    s.contains(index) ? s.remove(index) : s.add(index);
    state = state.copyWith(selected: s);
  }

  /// Creates the selected proposals as real events in the app's own calendar:
  /// all in one transaction, with "Visszavonás" on offer afterwards. What went
  /// stale while the card was waiting (its time is over, it clashes with
  /// something added meanwhile) is left out and named in the notice.
  Future<int> acceptSelected(UndoSite site) async {
    final turn = ref.read(assistantApplyingProvider.notifier);
    if (!turn.begin()) return 0;
    try {
      final o = state.outcome;
      if (o == null) return 0;
      // (taken before the first await: the indices belong to THIS list)
      final chosen = [
        for (var i = 0; i < o.items.length; i++)
          if (state.selected.contains(i)) o.items[i],
      ];
      if (chosen.isEmpty) return 0;
      final ids = [for (final _ in chosen) const Uuid().v4()];
      final doomed = {for (final d in o.deletions) occurrenceRef(d.occurrence)};
      final now = ref.read(aiClockProvider)();
      ApplyResult? done;
      await ref
          .read(undoServiceProvider)
          .run(
            site,
            newIds: ids,
            change: () async {
              done = await applyNew(
                ref.read(repoProvider),
                chosen,
                ids,
                now: now,
                doomed: doomed,
                build: _newEvent,
              );
              return done!.changes;
            },
            // (not the words of the card on the page: both are on the screen)
            message: (_) => '${done?.applied ?? 0} esemény hozzáadva',
            onUndone: () async => _undone(accepted: true),
          );
      final r = done ?? const ApplyResult();
      if (!ref.mounted) return r.applied;
      ref.read(syncControllerProvider.notifier).requestSync();
      // built from the LIVE state: whatever the user did meanwhile stays
      final rest = state.outcome?.withoutItems();
      final keep =
          rest != null && (rest.deletions.isNotEmpty || rest.moves.isNotEmpty);
      state = state.copyWith(
        outcome: keep ? rest : null,
        clearOutcome: !keep,
        selected: const {},
        acceptedCount: r.applied,
        clearAccepted: r.applied == 0,
        notice: _noticeWith(r.skipped),
      );
      return r.applied;
    } catch (e, st) {
      _failed(e, st, 'assistant.accept_failed');
      return 0;
    } finally {
      turn.end();
    }
  }

  CalEvent _newEvent(ProposalItem it, String id) => CalEvent(
    id: id,
    calendarId: kNaptarCalendar,
    title: it.title,
    notes: [
      if (it.taskTitle != null) 'Feladat: ${it.taskTitle}',
      if (it.reason.isNotEmpty) it.reason,
    ].join('\n'),
    start: it.startWall,
    end: it.endWall,
    tzid: it.tzid,
    colorId: aiEventColorId,
    aiGenerated: true,
  );

  void setDeleteScope(int index, Scope scope) => state = state.copyWith(
    deleteScopes: {...state.deleteScopes, index: scope},
  );

  /// "Engedélyezem": deletes exactly the events listed on the confirmation
  /// card, each as the calendar has it now, in one transaction, with
  /// "Visszavonás" on offer afterwards.
  Future<int> confirmDeletions(UndoSite site) async {
    final turn = ref.read(assistantApplyingProvider.notifier);
    if (!turn.begin()) return 0;
    try {
      final o = state.outcome;
      if (o == null || o.deletions.isEmpty) return 0;
      // (taken before the first await: the indices belong to THIS list)
      final deletions = o.deletions;
      final scopes = {...state.deleteScopes};
      ApplyResult? done;
      await ref
          .read(undoServiceProvider)
          .run(
            site,
            holdIds: [for (final d in deletions) d.occurrence.eventId],
            change: () async {
              done = await applyDeletions(
                ref.read(repoProvider),
                deletions,
                scopes,
              );
              return done!.changes;
            },
            message: (_) => '${done?.applied ?? 0} esemény törölve',
            onUndone: () async => _undone(deleted: true),
          );
      final r = done ?? const ApplyResult();
      if (!ref.mounted) return r.applied;
      ref.read(syncControllerProvider.notifier).requestSync();
      // built from the LIVE state: whatever the user did meanwhile stays
      state = state.copyWith(
        outcome: state.outcome?.withoutDeletions(),
        deleteScopes: const {},
        deletedCount: r.applied,
        clearDeleted: r.applied == 0,
        notice: _noticeWith(r.skipped),
      );
      return r.applied;
    } catch (e, st) {
      _failed(e, st, 'assistant.delete_failed');
      return 0;
    } finally {
      turn.end();
    }
  }

  /// "Mégse": nothing is deleted; the rest of the answer stays.
  void declineDeletions() {
    final o = state.outcome;
    if (o == null) return;
    state = state.copyWith(
      outcome: o.withoutDeletions(),
      deleteScopes: const {},
    );
  }

  /// "Engedélyezem": moves exactly the events listed on the confirmation
  /// card, each as the calendar has it now, in one transaction, with
  /// "Visszavonás" on offer afterwards.
  Future<int> confirmMoves(UndoSite site) async {
    final turn = ref.read(assistantApplyingProvider.notifier);
    if (!turn.begin()) return 0;
    try {
      final o = state.outcome;
      if (o == null || o.moves.isEmpty) return 0;
      final moves = o.moves;
      final doomed = {for (final d in o.deletions) occurrenceRef(d.occurrence)};
      ApplyResult? done;
      await ref
          .read(undoServiceProvider)
          .run(
            site,
            holdIds: [for (final m in moves) m.occurrence.eventId],
            change: () async {
              done = await applyMoves(
                ref.read(repoProvider),
                moves,
                doomed: doomed,
              );
              return done!.changes;
            },
            message: (_) => '${done?.applied ?? 0} esemény áthelyezve',
            onUndone: () async => _undone(moved: true),
          );
      final r = done ?? const ApplyResult();
      if (!ref.mounted) return r.applied;
      ref.read(syncControllerProvider.notifier).requestSync();
      // built from the LIVE state: whatever the user did meanwhile stays
      state = state.copyWith(
        outcome: state.outcome?.withoutMoves(),
        movedCount: r.applied,
        clearMoved: r.applied == 0,
        notice: _noticeWith(r.skipped),
      );
      return r.applied;
    } catch (e, st) {
      _failed(e, st, 'assistant.move_failed');
      return 0;
    } finally {
      turn.end();
    }
  }

  /// "Mégse": nothing is moved; the rest of the answer stays.
  void declineMoves() {
    final o = state.outcome;
    if (o == null) return;
    state = state.copyWith(outcome: o.withoutMoves());
  }

  // The "Rendben" of a result card closes THAT card; the others stay.
  void dismissAccepted() => _settle(state.copyWith(clearAccepted: true));
  void dismissMoved() => _settle(state.copyWith(clearMoved: true));
  void dismissDeleted() => _settle(state.copyWith(clearDeleted: true));
  void dismissHabit() => _settle(state.copyWith(habitSaved: false));

  /// "Elvetem": a discarded plan offers to remember why (the user's own
  /// words; nothing is written without the button). A deletion or move card
  /// that came with it stays.
  void discardPlan() {
    final o = state.outcome;
    final had = o?.items.isNotEmpty ?? false;
    final rest = o?.withoutItems();
    final keep =
        rest != null && (rest.deletions.isNotEmpty || rest.moves.isNotEmpty);
    state = state.copyWith(
      outcome: keep ? rest : null,
      clearOutcome: !keep,
      selected: const {},
      askWhy: had,
    );
  }

  /// "Megjegyzem": writes the user's sentence to the handbook.
  Future<bool> rememberHabit(String text) async {
    final ok = await ref.read(handbookStoreProvider).appendLearned(text);
    if (ref.mounted) state = state.copyWith(askWhy: false, habitSaved: ok);
    return ok;
  }

  /// "Nem most".
  void skipHabit() => _settle(state.copyWith(askWhy: false));

  /// Shows [s], or the empty page when the card that was just closed was the
  /// last thing on it (as before, when "Rendben" cleared the page). Anything
  /// that still asks for a decision, or tells a result, stays.
  void _settle(AssistantState s) {
    final o = s.outcome;
    final pending =
        o != null &&
        (o.items.isNotEmpty || o.deletions.isNotEmpty || o.moves.isNotEmpty);
    final shown =
        s.acceptedCount != null ||
        s.movedCount != null ||
        s.deletedCount != null ||
        s.habitSaved ||
        s.askWhy ||
        s.error != null;
    state = (s.busy || pending || shown) ? s : AssistantState(prompt: s.prompt);
  }

  /// "Visszavonás" took an approval back: the card that told its result goes
  /// (the page is empty again when it was the last thing on it).
  void _undone({
    bool accepted = false,
    bool deleted = false,
    bool moved = false,
  }) {
    if (!ref.mounted) return;
    _settle(
      state.copyWith(
        clearAccepted: accepted,
        clearDeleted: deleted,
        clearMoved: moved,
      ),
    );
  }

  /// The notice with what an approval had to leave out added to it.
  String? _noticeWith(List<Skipped> skipped) {
    final extra = skippedNotice(skipped);
    if (extra == null) return state.notice;
    return state.notice == null ? extra : '${state.notice} $extra';
  }

  /// An approval failed. It is one transaction, so nothing was half done.
  void _failed(Object e, StackTrace st, String code) {
    ref.read(diagLogProvider).error('ui', code, e, st);
    if (ref.mounted) {
      state = state.copyWith(
        notice: 'A művelet nem sikerült, semmi nem változott. Próbáld újra.',
      );
    }
  }
}

final assistantControllerProvider =
    NotifierProvider<AssistantController, AssistantState>(
      AssistantController.new,
    );
