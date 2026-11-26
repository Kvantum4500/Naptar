import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'llm_provider.dart' show LlmUsage;
import 'place.dart';

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
    this.finance = true,
    this.sleepStartHour = 23,
    this.sleepEndHour = 7,
    this.weather = true,
    this.place,
    this.handbook = true,
    this.workoutFeedback = true,
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

  /// The assistant may read the finance data (it never writes it).
  final bool finance;

  /// Sleep window (wall-clock hours): the assistant plans nothing inside it.
  final int sleepStartHour;
  final int sleepEndHour;

  /// Use the forecast of [place] when planning (needs a place to do anything).
  final bool weather;

  /// Where the weather is looked up (set from GPS or a typed city).
  final Place? place;

  /// The user's own handbook (rules, profile, learned habits) goes to the
  /// model. Off: only the built-in rules go.
  final bool handbook;

  /// Ask how a workout went after it (the answers teach the assistant how
  /// hard the user's workouts really are).
  final bool workoutFeedback;

  AiSettings copyWith({
    String? provider,
    String? model,
    bool clearModel = false,
    String? customBaseUrl,
    bool? events,
    bool? tasks,
    bool? checkins,
    bool? finance,
    int? sleepStartHour,
    int? sleepEndHour,
    bool? weather,
    Place? place,
    bool clearPlace = false,
    bool? handbook,
    bool? workoutFeedback,
  }) => AiSettings(
    provider: provider ?? this.provider,
    model: clearModel ? null : (model ?? this.model),
    customBaseUrl: customBaseUrl ?? this.customBaseUrl,
    events: events ?? this.events,
    tasks: tasks ?? this.tasks,
    checkins: checkins ?? this.checkins,
    finance: finance ?? this.finance,
    sleepStartHour: sleepStartHour ?? this.sleepStartHour,
    sleepEndHour: sleepEndHour ?? this.sleepEndHour,
    weather: weather ?? this.weather,
    place: clearPlace ? null : (place ?? this.place),
    handbook: handbook ?? this.handbook,
    workoutFeedback: workoutFeedback ?? this.workoutFeedback,
  );
}

/// What the assistant used on one day: answered requests and their tokens.
class AiUsageDay {
  const AiUsageDay({this.requests = 0, this.tokens = LlmUsage.zero});
  final int requests;
  final LlmUsage tokens;

  AiUsageDay operator +(AiUsageDay o) =>
      AiUsageDay(requests: requests + o.requests, tokens: tokens + o.tokens);
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
      finance: (await read('ai.finance')) != 'off',
      sleepStartHour: _hour(await read('ai.sleepStart'), 23),
      sleepEndHour: _hour(await read('ai.sleepEnd'), 7),
      weather: (await read('ai.weather')) != 'off',
      place: Place.decode(await read('ai.place')),
      handbook: (await read('ai.handbook')) != 'off',
      workoutFeedback: (await read('ai.workoutFeedback')) != 'off',
    );
  }

  Future<void> save(AiSettings s) async {
    await write('ai.provider', s.provider == 'gemini' ? null : s.provider);
    await write('ai.model.${s.provider}', s.model);
    await write('ai.customBase', s.customBaseUrl);
    await write('ai.events', s.events ? null : 'off');
    await write('ai.tasks', s.tasks ? null : 'off');
    await write('ai.checkins', s.checkins ? null : 'off');
    await write('ai.finance', s.finance ? null : 'off');
    await write(
      'ai.sleepStart',
      s.sleepStartHour == 23 ? null : '${s.sleepStartHour}',
    );
    await write(
      'ai.sleepEnd',
      s.sleepEndHour == 7 ? null : '${s.sleepEndHour}',
    );
    await write('ai.weather', s.weather ? null : 'off');
    await write('ai.place', s.place?.encode());
    await write('ai.handbook', s.handbook ? null : 'off');
    await write('ai.workoutFeedback', s.workoutFeedback ? null : 'off');
  }

  static int _hour(String? v, int fallback) {
    final n = int.tryParse(v ?? '');
    return n != null && n >= 0 && n <= 23 ? n : fallback;
  }

  String get _day {
    final n = _now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // The first version only counted requests, in one number.
  String get _usageKey => 'ai.usage.$_day';

  // Today's requests and tokens: {"provider|model": {"r": 3, "p": .., "o": ..,
  // "t": .., "c": ..}}.
  String get _tokenKey => 'ai.use.$_day';

  Future<Map<String, Object?>> _readDay() async {
    try {
      final j = jsonDecode(await read(_tokenKey) ?? '{}');
      return j is Map ? Map<String, Object?>.from(j) : {};
    } on FormatException {
      return {};
    }
  }

  /// A model call that was ANSWERED, with what it cost ([usage] null: the
  /// service did not say). Attempts that failed (a rate limit, a server error)
  /// are not counted: they used nothing.
  Future<void> recordCall({
    required String provider,
    required String model,
    LlmUsage? usage,
  }) async {
    final day = await _readDay();
    final key = '$provider|$model';
    final old = day[key] is Map ? day[key] as Map : const {};
    final sum = LlmUsage.fromJson(old) + (usage ?? LlmUsage.zero);
    day[key] = {'r': ((old['r'] as num?)?.toInt() ?? 0) + 1, ...sum.toJson()};
    await write(_tokenKey, jsonEncode(day));
  }

  /// What was used today at [provider] (all its models), or at every provider.
  Future<AiUsageDay> usageOf({String? provider}) async {
    var sum = const AiUsageDay();
    (await _readDay()).forEach((k, v) {
      if (provider != null && !k.startsWith('$provider|')) return;
      sum =
          sum +
          AiUsageDay(
            requests: v is Map && v['r'] is num ? (v['r'] as num).toInt() : 0,
            tokens: LlmUsage.fromJson(v),
          );
    });
    return sum;
  }

  /// Requests answered today (every provider; the old counter included).
  Future<int> usageToday() async =>
      (int.tryParse(await read(_usageKey) ?? '') ?? 0) +
      (await usageOf()).requests;

  /// Counts one request without tokens (the first version's counter).
  Future<int> bumpUsage() async {
    final n = (int.tryParse(await read(_usageKey) ?? '') ?? 0) + 1;
    await write(_usageKey, '$n');
    return await usageToday();
  }

  /// The user accepted what goes to [provider] (the first key save asks).
  Future<bool> consentGiven(String provider) async =>
      (await read('ai.consent.$provider')) == '1';

  Future<void> giveConsent(String provider) =>
      write('ai.consent.$provider', '1');
}
