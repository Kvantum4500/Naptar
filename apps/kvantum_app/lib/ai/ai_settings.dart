import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the API keys live (one per provider). The real implementation uses
/// the OS secure store (Windows DPAPI / Android Keystore); a key is never
/// written to the database, to Drive, to logs or to the repository.
abstract class ApiKeyStore {
  Future<String?> read({String provider = 'gemini'});
  Future<void> write(String? key, {String provider = 'gemini'});
}

class SecureApiKeyStore implements ApiKeyStore {
  SecureApiKeyStore([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  // The Gemini key keeps its original name so existing installs find it.
  static String _name(String provider) =>
      provider == 'gemini' ? 'gemini_api_key_v1' : 'llm_key_v1_$provider';

  @override
  Future<String?> read({String provider = 'gemini'}) async {
    final v = await _s.read(key: _name(provider));
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  @override
  Future<void> write(String? key, {String provider = 'gemini'}) =>
      (key == null || key.trim().isEmpty)
      ? _s.delete(key: _name(provider))
      : _s.write(key: _name(provider), value: key.trim());
}

class MemoryApiKeyStore implements ApiKeyStore {
  MemoryApiKeyStore([String? gemini]) {
    if (gemini != null) _keys['gemini'] = gemini;
  }
  final Map<String, String> _keys = {};

  /// The Gemini key (kept for the existing tests' convenience).
  String? get value => _keys['gemini'];

  String? keyOf(String provider) => _keys[provider];

  @override
  Future<String?> read({String provider = 'gemini'}) async => _keys[provider];

  @override
  Future<void> write(String? key, {String provider = 'gemini'}) async {
    if (key == null || key.trim().isEmpty) {
      _keys.remove(provider);
    } else {
      _keys[provider] = key.trim();
    }
  }
}

/// What the assistant may see, and which model it uses.
class AiSettings {
  const AiSettings({
    this.provider = 'gemini',
    this.model,
    this.customBaseUrl,
    this.events = true,
    this.tasks = true,
    this.checkins = true,
  });

  /// Provider id from the catalog (gemini, groq, mistral, openrouter, openai, custom).
  final String provider;

  /// The model of the CURRENT provider (each provider remembers its own).
  final String? model;

  /// Address for the "custom" provider.
  final String? customBaseUrl;
  final bool events;
  final bool tasks;
  final bool checkins;

  AiSettings copyWith({
    String? provider,
    String? model,
    bool clearModel = false,
    String? customBaseUrl,
    bool? events,
    bool? tasks,
    bool? checkins,
  }) => AiSettings(
    provider: provider ?? this.provider,
    model: clearModel ? null : (model ?? this.model),
    customBaseUrl: customBaseUrl ?? this.customBaseUrl,
    events: events ?? this.events,
    tasks: tasks ?? this.tasks,
    checkins: checkins ?? this.checkins,
  );
}

/// Persists [AiSettings] and the daily request counter in a key/value store.
class AiSettingsStore {
  AiSettingsStore({
    required this.read,
    required this.write,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String? value) write;
  final DateTime Function() _now;

  Future<AiSettings> load() async {
    final provider = (await read('ai.provider')) ?? 'gemini';
    return AiSettings(
      provider: provider,
      // older versions stored a single model name (it was always Gemini's)
      model:
          await read('ai.model.$provider') ??
          (provider == 'gemini' ? await read('ai.model') : null),
      customBaseUrl: await read('ai.customBase'),
      events: (await read('ai.events')) != 'off',
      tasks: (await read('ai.tasks')) != 'off',
      checkins: (await read('ai.checkins')) != 'off',
    );
  }

  Future<void> save(AiSettings s) async {
    await write('ai.provider', s.provider == 'gemini' ? null : s.provider);
    await write('ai.model.${s.provider}', s.model);
    await write('ai.customBase', s.customBaseUrl);
    await write('ai.events', s.events ? null : 'off');
    await write('ai.tasks', s.tasks ? null : 'off');
    await write('ai.checkins', s.checkins ? null : 'off');
  }

  String get _usageKey {
    final n = _now();
    return 'ai.usage.${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// Requests sent today (the free tier has a daily limit).
  Future<int> usageToday() async =>
      int.tryParse(await read(_usageKey) ?? '') ?? 0;

  Future<int> bumpUsage() async {
    final n = await usageToday() + 1;
    await write(_usageKey, '$n');
    return n;
  }
}
