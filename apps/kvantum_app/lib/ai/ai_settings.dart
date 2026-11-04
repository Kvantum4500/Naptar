import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the Gemini API key lives. The real implementation uses the OS
/// secure store (Windows DPAPI / Android Keystore); the key is never written
/// to the database, to Drive, to logs or to the repository.
abstract class ApiKeyStore {
  Future<String?> read();
  Future<void> write(String? key);
}

class SecureApiKeyStore implements ApiKeyStore {
  SecureApiKeyStore([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _k = 'gemini_api_key_v1';

  @override
  Future<String?> read() async {
    final v = await _s.read(key: _k);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  @override
  Future<void> write(String? key) => (key == null || key.trim().isEmpty)
      ? _s.delete(key: _k)
      : _s.write(key: _k, value: key.trim());
}

class MemoryApiKeyStore implements ApiKeyStore {
  MemoryApiKeyStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? key) async =>
      value = (key == null || key.trim().isEmpty) ? null : key.trim();
}

/// What the assistant may see, and which model it uses.
class AiSettings {
  const AiSettings({
    this.model,
    this.events = true,
    this.tasks = true,
    this.checkins = true,
  });
  final String? model;
  final bool events;
  final bool tasks;
  final bool checkins;

  AiSettings copyWith({
    String? model,
    bool clearModel = false,
    bool? events,
    bool? tasks,
    bool? checkins,
  }) => AiSettings(
    model: clearModel ? null : (model ?? this.model),
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

  Future<AiSettings> load() async => AiSettings(
    model: await read('ai.model'),
    events: (await read('ai.events')) != 'off',
    tasks: (await read('ai.tasks')) != 'off',
    checkins: (await read('ai.checkins')) != 'off',
  );

  Future<void> save(AiSettings s) async {
    await write('ai.model', s.model);
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
