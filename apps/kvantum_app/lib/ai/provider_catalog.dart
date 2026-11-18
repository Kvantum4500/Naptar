import 'package:http/http.dart' as http;

import 'endpoint_policy.dart';
import 'gemini_provider.dart';
import 'llm_provider.dart';
import 'openai_provider.dart';

/// Which AI services the app can talk to.
class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.label,
    required this.keyUrl,
    required this.note,
    this.baseUrl,
    this.keyOptional = false,
    this.modelPrefs = const [],
    this.temperature = 0.2,
    this.maxOutput = 4096,
    this.reasoningEffort,
    this.reasoningModels,
    this.tokenBudget = 20000,
  });

  final String id;
  final String label;

  /// Where the user creates a key (shown as a link).
  final String keyUrl;
  final String note;

  /// null for Gemini (own protocol) and for the custom entry (user supplies it).
  final String? baseUrl;
  final bool keyOptional;

  /// Patterns for the default model, best first.
  final List<RegExp> modelPrefs;

  /// Sampling temperature for planning (low: the same request should give
  /// nearly the same plan). null = not sent, the service's own default.
  final double? temperature;

  /// Upper bound for one reply, thinking included. Groq counts it against the
  /// per-minute token limit (8 000 on the free tier), so it is lower there.
  final int maxOutput;

  /// `reasoning_effort` sent to the models matching [reasoningModels].
  final String? reasoningEffort;
  final RegExp? reasoningModels;

  /// How many tokens a request (instructions + tools + data) may have, by the
  /// program's own estimate. A bigger one is made smaller before it is sent.
  /// Groq's free tier allows 8 000 tokens a minute, and the reply cap counts
  /// against it too (8 000 − 2 048, with some room for the estimate's error).
  final int tokenBudget;
}

final kProviders = <ProviderInfo>[
  ProviderInfo(
    id: 'gemini',
    label: 'Google Gemini',
    keyUrl: 'https://aistudio.google.com/apikey',
    note: 'Az EU-ban az ingyenes szint sok fióknál nem érhető el; ilyenkor előre fizetett egyenleg kell.',
  ),
  ProviderInfo(
    id: 'groq',
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    keyUrl: 'https://console.groq.com/keys',
    note: 'Ingyenes szint van, bankkártya nélkül. A limitet a Groq konzolján nézheted meg.',
    modelPrefs: [
      RegExp(r'llama-3\.3-70b'),
      RegExp(r'llama-3\.1-70b'),
      RegExp(r'gpt-oss'),
      RegExp(r'llama'),
    ],
    maxOutput: 2048,
    tokenBudget: 5500,
    // gpt-oss thinks a lot by default; "low" keeps the budget for the plan
    reasoningEffort: 'low',
    reasoningModels: RegExp(r'gpt-oss'),
  ),
  ProviderInfo(
    id: 'mistral',
    label: 'Mistral',
    baseUrl: 'https://api.mistral.ai/v1',
    keyUrl: 'https://console.mistral.ai/api-keys',
    note: 'Francia szolgáltató, ingyenes kísérleti csomaggal (telefonos megerősítés kell). Az ingyenes csomag adatait a Mistral fejleszthet vele.',
    modelPrefs: [
      RegExp(r'mistral-small-latest'),
      RegExp(r'mistral-medium-latest'),
      RegExp(r'mistral-large-latest'),
      RegExp(r'mistral'),
    ],
  ),
  ProviderInfo(
    id: 'openrouter',
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    keyUrl: 'https://openrouter.ai/keys',
    note: 'Sok modell egy kulccsal; a „:free” végű modellek ingyenesek, de szigorúbb limittel.',
    modelPrefs: [RegExp(r'llama-3\.3-70b-instruct:free'), RegExp(r':free$')],
  ),
  ProviderInfo(
    id: 'openai',
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    keyUrl: 'https://platform.openai.com/api-keys',
    note: 'Fizetős (előre feltöltött egyenleggel).',
    modelPrefs: [
      RegExp(r'^gpt-4o-mini$'),
      RegExp(r'gpt-4\.1-mini'),
      RegExp(r'gpt-5-mini'),
      RegExp(r'^gpt-'),
    ],
  ),
  ProviderInfo(
    id: 'custom',
    label: 'Egyéni (OpenAI-kompatibilis)',
    keyUrl: 'https://ollama.com',
    note: 'Bármilyen OpenAI-kompatibilis cím, pl. helyi Ollama: http://localhost:11434/v1 (kulcs nem kell).',
    keyOptional: true,
  ),
];

ProviderInfo providerById(String id) =>
    kProviders.firstWhere((p) => p.id == id, orElse: () => kProviders.first);

/// What it takes to talk to one provider.
class LlmConfig {
  const LlmConfig({required this.provider, required this.apiKey, this.baseUrl});
  final String provider;
  final String apiKey;
  final String? baseUrl;
}

LLMProvider buildProvider(LlmConfig c, http.Client client) {
  final info = providerById(c.provider);
  if (c.provider == 'gemini') {
    return GeminiProvider(
      client,
      apiKey: c.apiKey,
      maxOutputTokens: info.maxOutput,
      defaultTemperature: info.temperature,
    );
  }
  // Only the "custom" provider has an address chosen by the user. A leftover
  // custom address must never redirect the key and the data of Groq, Mistral…
  final String? base;
  if (c.provider == 'custom') {
    final text = c.baseUrl?.trim() ?? '';
    if (text.isNotEmpty) {
      final check = checkCustomEndpoint(text);
      if (!check.ok) throw LlmBadResponse(check.error!);
    }
    base = text;
  } else {
    base = info.baseUrl;
  }
  if (base == null || base.trim().isEmpty) {
    throw const LlmBadResponse('Add meg a szolgáltató címét a Beállításokban.');
  }
  return OpenAiProvider(
    client,
    apiKey: c.apiKey,
    baseUrl: base.trim(),
    maxOutputTokens: info.maxOutput,
    defaultTemperature: info.temperature,
    reasoningEffort: info.reasoningEffort,
    reasoningModels: info.reasoningModels,
  );
}

/// Models that do not chat (guards, speech, embeddings, images…): never a
/// fallback.
final _notForChat = RegExp(
  r'guard|whisper|tts|embed|moderat|transcri|audio|image|realtime|dall-e|rerank|orpheus',
  caseSensitive: false,
);

/// Other models of [providerId] worth trying when [failed] has no quota left
/// or is gone: the ones the provider's own preferences name, best first, never
/// the failed one, nothing that cannot chat, at most three. Gemini has its own,
/// subtler list; an address of the user's own has no preferences (no catalogue
/// to choose from), so it gets none.
List<String> fallbackModelsFor(
  String providerId,
  List<LlmModel> models,
  String failed,
) {
  if (providerId == 'gemini') return fallbackModels(models, failed);
  final out = <String>[];
  for (final re in providerById(providerId).modelPrefs) {
    final hit = [
      for (final m in models)
        if (m.id != failed &&
            re.hasMatch(m.id) &&
            !_notForChat.hasMatch(m.id) &&
            !out.contains(m.id))
          m.id,
    ]..sort((a, b) => b.compareTo(a));
    out.addAll(hit);
  }
  return out.take(3).toList();
}

/// The default model from the list a provider returned.
String? pickModelFor(String providerId, List<LlmModel> models) {
  if (models.isEmpty) return null;
  if (providerId == 'gemini') return pickDefaultModel(models);
  for (final re in providerById(providerId).modelPrefs) {
    final hit = models.where((m) => re.hasMatch(m.id)).toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    if (hit.isNotEmpty) return hit.first.id;
  }
  return models.first.id;
}
