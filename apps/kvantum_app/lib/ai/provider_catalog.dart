import 'package:http/http.dart' as http;

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
  if (c.provider == 'gemini') return GeminiProvider(client, apiKey: c.apiKey);
  final base = c.baseUrl ?? providerById(c.provider).baseUrl;
  if (base == null || base.trim().isEmpty) {
    throw const LlmBadResponse('Add meg a szolgáltató címét a Beállításokban.');
  }
  return OpenAiProvider(client, apiKey: c.apiKey, baseUrl: base.trim());
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
