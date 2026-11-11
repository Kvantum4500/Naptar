import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_http.dart';
import 'llm_provider.dart';

/// Any service that speaks the OpenAI "chat completions" protocol with tool
/// calling: Groq, Mistral, OpenRouter, OpenAI itself, or a local server
/// (Ollama, LM Studio...). The key travels only in the Authorization header.
class OpenAiProvider implements LLMProvider {
  OpenAiProvider(
    this._client, {
    required this.apiKey,
    required String baseUrl,
    this.maxOutputTokens = 2048,
    this.defaultTemperature = 0.2,
    this.reasoningEffort,
    this.reasoningModels,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final http.Client _client;
  final String apiKey;
  final String baseUrl;

  /// Upper bound for one reply (thinking + answer). Without an explicit cap
  /// some services (Groq) use a small default that a reasoning model can spend
  /// entirely on thinking, leaving an empty answer. The cap also counts against
  /// per-minute token limits, so it is generous but not huge (the catalog sets
  /// it per provider).
  final int maxOutputTokens;

  /// Used when the request names none; null means it is not sent at all.
  final double? defaultTemperature;

  /// `reasoning_effort` for the models matching [reasoningModels] (for every
  /// model when that is null). Groq's gpt-oss models think a lot by default;
  /// "low" keeps the budget for the actual plan.
  final String? reasoningEffort;
  final RegExp? reasoningModels;

  /// Parameters a model refused, by "baseUrl|model": the next request leaves
  /// them out at once (a refusal costs a round trip).
  static final _refused = <String, Set<String>>{};

  /// Forgets what the models refused (for tests).
  static void forgetRefusals() => _refused.clear();

  /// The parameters that are dropped (or swapped) when a service refuses them.
  static const _refusable = {
    'temperature',
    'reasoning_effort',
    'max_tokens',
    'max_completion_tokens',
    'tool_choice',
  };

  static const _cutMessage =
      'A modell válasza elfogyott a hosszkeretben, mielőtt befejezte volna. Kérj kevesebb napot vagy kevesebb tételt, vagy válassz másik modellt a Beállításokban.';

  Map<String, String> get _headers => {
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    'content-type': 'application/json',
  };

  @override
  void close() => _client.close();

  // ------------------------------------------------------------- generate

  @override
  Future<LlmReply> generate(String model, LlmRequest r) async {
    final key = '$baseUrl|$model';
    final skip = {...?_refused[key]};
    for (var attempt = 0; ; attempt++) {
      try {
        final json = await sendJson(
          () => _client.post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: _headers,
            body: jsonEncode(_body(model, r, skip)),
          ),
          timeout: const Duration(seconds: 90),
          errorFor: _errorFor,
          notJson: 'A szolgáltató válasza nem értelmezhető.',
        );
        return _parseReply(json);
      } on LlmBadRequest catch (e) {
        // The service named a parameter it does not take with this model: one
        // more try without it (twice at most), and remember it.
        final p = e.param;
        if (p == null || attempt >= 2 || !skip.add(p)) rethrow;
        _refused[key] = {...skip};
      }
    }
  }

  Map<String, Object?> _body(String model, LlmRequest r, Set<String> skip) {
    final temp = r.temperature ?? defaultTemperature;
    final cap = _capName(skip);
    final effort = reasoningEffort;
    return {
      'model': model,
      'messages': [
        {'role': 'system', 'content': r.system},
        for (final t in r.turns) ..._messages(t),
      ],
      if (r.tools.isNotEmpty) ...{
        'tools': [
          for (final t in r.tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
        ],
        if (!skip.contains('tool_choice')) 'tool_choice': 'auto',
      },
      if (temp != null && !skip.contains('temperature')) 'temperature': temp,
      ?cap: maxOutputTokens,
      if (effort != null &&
          !skip.contains('reasoning_effort') &&
          (reasoningModels?.hasMatch(model) ?? true))
        'reasoning_effort': effort,
    };
  }

  /// The name of the output cap: OpenAI's newer models want
  /// `max_completion_tokens`, everyone else `max_tokens`; a refusal flips it,
  /// and a service that refuses both gets neither.
  String? _capName(Set<String> skip) {
    final noTokens = skip.contains('max_tokens');
    final noCompletion = skip.contains('max_completion_tokens');
    if (noTokens && noCompletion) return null;
    if (noTokens) return 'max_completion_tokens';
    if (noCompletion) return 'max_tokens';
    return baseUrl.contains('api.openai.com')
        ? 'max_completion_tokens'
        : 'max_tokens';
  }

  List<Map<String, Object?>> _messages(LlmTurn t) {
    if (t.role == 'model') {
      final text = t.parts.whereType<LlmText>().map((p) => p.text).join('\n');
      final calls = t.parts.whereType<LlmToolCall>().toList();
      return [
        {
          'role': 'assistant',
          'content': text.isEmpty ? null : text,
          if (calls.isNotEmpty)
            'tool_calls': [
              for (var i = 0; i < calls.length; i++)
                {
                  'id': calls[i].id ?? 'call_$i',
                  'type': 'function',
                  'function': {
                    'name': calls[i].name,
                    'arguments': jsonEncode(calls[i].args),
                  },
                },
            ],
        },
      ];
    }
    // user turn: plain text and/or tool results (one "tool" message per result)
    final out = <Map<String, Object?>>[];
    final results = t.parts.whereType<LlmToolResult>().toList();
    for (var i = 0; i < results.length; i++) {
      out.add({
        'role': 'tool',
        'tool_call_id': results[i].id ?? 'call_$i',
        'content': jsonEncode(results[i].result),
      });
    }
    final text = t.parts.whereType<LlmText>().map((p) => p.text).join('\n');
    if (text.isNotEmpty) out.add({'role': 'user', 'content': text});
    return out;
  }

  LlmReply _parseReply(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const LlmBadResponse('A modell nem adott választ.');
    }
    final choice = choices.first as Map<String, dynamic>;
    final msg = choice['message'];
    final reason = choice['finish_reason'] as String?;
    final parts = <LlmPart>[];
    var brokenArgs = false;
    if (msg is Map) {
      final content = msg['content'];
      if (content is String && content.trim().isNotEmpty) {
        parts.add(LlmText(content));
      }
      for (final c in (msg['tool_calls'] as List? ?? const [])) {
        if (c is! Map || c['function'] is! Map) continue;
        final f = c['function'] as Map;
        Map<String, Object?> args = {};
        final raw = f['arguments'];
        if (raw is String && raw.trim().isNotEmpty) {
          try {
            final j = jsonDecode(raw);
            if (j is Map) args = Map<String, Object?>.from(j);
          } on FormatException {
            // Cut off by the length cap: reported below. Otherwise a
            // malformed argument string becomes "no arguments" and the
            // proposal check asks the model to try again.
            brokenArgs = true;
          }
        } else if (raw is Map) {
          args = Map<String, Object?>.from(raw);
        }
        parts.add(LlmToolCall('${f['name']}', args, id: c['id'] as String?));
      }
    }
    // A half-written call must not reach the repair loop: the retry would be
    // cut off again, at the price of the whole conversation.
    if (reason == 'length' && brokenArgs) throw const LlmTruncated(_cutMessage);
    if (parts.isEmpty) {
      if (reason == 'length') throw const LlmTruncated(_cutMessage);
      throw LlmBadResponse(
        reason == 'content_filter'
            ? 'A választ a szolgáltató szűrője megállította.'
            : 'A modell üres választ adott${reason == null ? '' : ' ($reason)'}.',
      );
    }
    final usage = json['usage'];
    return LlmReply(
      parts: parts,
      finishReason: reason,
      promptTokens: usage is Map
          ? (usage['prompt_tokens'] as num?)?.toInt()
          : null,
      outputTokens: usage is Map
          ? (usage['completion_tokens'] as num?)?.toInt()
          : null,
    );
  }

  // --------------------------------------------------------------- models

  @override
  Future<List<LlmModel>> listModels() async {
    final json = await sendJson(
      () => _client.get(Uri.parse('$baseUrl/models'), headers: _headers),
      timeout: const Duration(seconds: 90),
      errorFor: _errorFor,
      notJson: 'A szolgáltató válasza nem értelmezhető.',
    );
    final out = <LlmModel>[];
    for (final m in (json['data'] as List? ?? const [])) {
      if (m is! Map || m['id'] is! String) continue;
      final id = m['id'] as String;
      if (RegExp(
        r'(embed|whisper|tts|moderation|guard|dall|image|audio|realtime|transcribe|speech|rerank)',
        caseSensitive: false,
      ).hasMatch(id)) {
        continue;
      }
      if (m['active'] == false) continue;
      out.add(LlmModel(id, '${m['name'] ?? id}'));
    }
    return out;
  }

  // --------------------------------------------------------------- errors

  static final _tooLarge = RegExp(
    r'request too large|maximum context length|context[_ ]length|reduce (the length of )?your (message|prompt)',
    caseSensitive: false,
  );
  static final _refusalWords = RegExp(
    r'unsupported|not supported|does not support|unknown|unrecognized|invalid|only the default|too large|at most|exceed',
    caseSensitive: false,
  );

  /// Which refusable parameter a 400 is about: the service's own `param`
  /// field, or else the first one the message names.
  static String? _refusedParam(String param, String message) {
    if (_refusable.contains(param)) return param;
    if (!_refusalWords.hasMatch(message)) return null;
    return RegExp(
      r'\b(temperature|reasoning_effort|max_completion_tokens|max_tokens|tool_choice)\b',
    ).firstMatch(message)?[1];
  }

  LlmException _errorFor(int status, String body, Map<String, String> headers) {
    var message = '';
    var type = '';
    var code = '';
    var param = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        message = '${err['message'] ?? ''}';
        type = '${err['type'] ?? ''}';
        code = '${err['code'] ?? ''}';
        param = '${err['param'] ?? ''}';
      } else if (err is String) {
        message = err;
      }
    } on FormatException {
      // not JSON
    }
    final safe = redactSecrets(message, key: apiKey);
    var retry = int.tryParse(headers['retry-after'] ?? '');
    final all = '$type $code $message';
    // "Please try again in 18.9s": the service tells the wait in the text.
    final hinted = RegExp(
      r'try again in\s+([\d.]+)\s*(ms|s)\b',
      caseSensitive: false,
    ).firstMatch(message);
    if (retry == null && hinted != null) {
      final v = double.tryParse(hinted[1]!) ?? 0;
      retry = (hinted[2]!.toLowerCase() == 'ms' ? v / 1000 : v).ceil();
    }

    // The request itself is too big (Groq: HTTP 413 "Request too large ... on
    // tokens per minute", OpenAI: context length): waiting does not help.
    if (status == 413 ||
        code == 'context_length_exceeded' ||
        _tooLarge.hasMatch(message)) {
      final lim = RegExp(r'Limit\s+(\d+),\s*Requested\s+(\d+)')
          .firstMatch(message);
      final ctx = RegExp(
        r'(\d+)\s*tokens\.?\s*However.*?(\d+)\s*tokens',
        caseSensitive: false,
      ).firstMatch(message);
      final limit = int.tryParse(lim?[1] ?? ctx?[1] ?? '');
      final requested = int.tryParse(lim?[2] ?? ctx?[2] ?? '');
      return LlmTooLarge(
        'A kérés túl nagy ehhez a modellhez${limit != null && requested != null ? ' (kb. $requested token, a korlát $limit)' : ''}. Kérj kevesebb napot, rövidítsd a Kézikönyvet a Beállításokban, vagy válassz másik modellt.',
        limit: limit,
        requested: requested,
      );
    }
    // The model could not write its function call (Groq): nothing to do with
    // the request, another go (with less to chew on) often works.
    if (code == 'tool_use_failed' ||
        message.contains('Failed to call a function')) {
      return const LlmToolFailed(
        'A modell nem tudta összeállítani a tervet (hibás eszközhívás). Próbáld újra, vagy válassz másik modellt a Beállításokban.',
      );
    }
    // A short per-minute limit is NOT a billing problem, even when the message
    // advertises a paid tier ("Upgrade ... /settings/billing").
    final perMinute = RegExp(
      r'per minute|\bTPM\b|\bRPM\b|try again in',
      caseSensitive: false,
    ).hasMatch(all);
    if (status == 402 ||
        type.toLowerCase().contains('insufficient_quota') ||
        code.toLowerCase().contains('insufficient_quota') ||
        (!perMinute &&
            status != 401 &&
            RegExp(
              r'insufficient_quota|billing|credit|payment',
              caseSensitive: false,
            ).hasMatch(all))) {
      return LlmRateLimit(
        'A szolgáltatónál nincs elég egyenleg vagy a számlázás nincs beállítva.',
        detail: safe,
        billing: true,
      );
    }
    if (status == 429) {
      final daily = RegExp(
        r'per day|daily|\bTPD\b|\bRPD\b',
        caseSensitive: false,
      ).hasMatch(all);
      return LlmRateLimit(
        daily
            ? 'Elfogyott a mai ingyenes keret.'
            : 'Túl sok kérés rövid idő alatt${retry == null ? '' : ' (kb. $retry mp várakozás kell)'}.',
        retryAfter: retry == null ? null : Duration(seconds: retry),
        detail: safe,
        daily: daily,
      );
    }
    if (status == 401 || status == 403) {
      return const LlmAuth(
        'Az API-kulcs érvénytelen, lejárt vagy nincs jogosultsága. Ellenőrizd a Beállításokban.',
      );
    }
    if (status >= 500) {
      return LlmNetwork(
        'A szolgáltatás átmenetileg nem elérhető ($status).',
        status: status,
      );
    }
    final text =
        'A szolgáltató hibát jelzett ($status${message.isEmpty ? '' : ': $safe'}).';
    if (status == 400) {
      final p = _refusedParam(param, message);
      if (p != null) return LlmBadRequest(text, param: p);
    }
    return LlmBadResponse(text);
  }
}
