import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// Any service that speaks the OpenAI "chat completions" protocol with tool
/// calling: Groq, Mistral, OpenRouter, OpenAI itself, or a local server
/// (Ollama, LM Studio...). The key travels only in the Authorization header.
class OpenAiProvider implements LLMProvider {
  OpenAiProvider(this._client, {required this.apiKey, required String baseUrl})
    : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final http.Client _client;
  final String apiKey;
  final String baseUrl;

  Map<String, String> get _headers => {
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    'content-type': 'application/json',
  };

  // ------------------------------------------------------------- generate

  @override
  Future<LlmReply> generate(String model, LlmRequest r) async {
    final body = <String, Object?>{
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
        'tool_choice': 'auto',
      },
      'temperature': r.temperature,
    };
    final json = await _send(
      () => _client.post(
        Uri.parse('$baseUrl/chat/completions'),
        headers: _headers,
        body: jsonEncode(body),
      ),
    );
    return _parseReply(json);
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
    final parts = <LlmPart>[];
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
            // a malformed argument string becomes "no arguments"; the
            // proposal check then asks the model to try again
          }
        } else if (raw is Map) {
          args = Map<String, Object?>.from(raw);
        }
        parts.add(LlmToolCall('${f['name']}', args, id: c['id'] as String?));
      }
    }
    final reason = choice['finish_reason'] as String?;
    if (parts.isEmpty) {
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
    final json = await _send(
      () => _client.get(Uri.parse('$baseUrl/models'), headers: _headers),
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

  // ----------------------------------------------------------------- http

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() call,
  ) async {
    final http.Response res;
    try {
      res = await call().timeout(const Duration(seconds: 90));
    } on SocketException catch (e) {
      throw LlmNetwork('Nincs kapcsolat: ${e.message}');
    } on http.ClientException catch (e) {
      throw LlmNetwork('Nincs kapcsolat: ${e.message}');
    } on TimeoutException {
      throw const LlmNetwork('A modell nem válaszolt időben.');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final j = jsonDecode(text);
        if (j is Map<String, dynamic>) return j;
      } on FormatException {
        // falls through
      }
      throw const LlmBadResponse('A szolgáltató válasza nem értelmezhető.');
    }
    throw _errorFor(res.statusCode, text, res.headers);
  }

  LlmException _errorFor(int status, String body, Map<String, String> headers) {
    var message = '';
    var type = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        message = '${err['message'] ?? ''}';
        type = '${err['type'] ?? err['code'] ?? ''}';
      } else if (err is String) {
        message = err;
      }
    } on FormatException {
      // not JSON
    }
    var retry = int.tryParse(headers['retry-after'] ?? '');
    final all = '$type $message';
    // "Please try again in 18.9s": the service tells the wait in the text.
    final hinted = RegExp(
      r'try again in\s+([\d.]+)\s*(ms|s)\b',
      caseSensitive: false,
    ).firstMatch(message);
    if (retry == null && hinted != null) {
      final v = double.tryParse(hinted[1]!) ?? 0;
      retry = (hinted[2]!.toLowerCase() == 'ms' ? v / 1000 : v).ceil();
    }
    // A short per-minute limit is NOT a billing problem, even when the message
    // advertises a paid tier ("Upgrade ... /settings/billing").
    final perMinute = RegExp(
      r'per minute|\bTPM\b|\bRPM\b|try again in',
      caseSensitive: false,
    ).hasMatch(all);
    if (status == 402 ||
        type.toLowerCase().contains('insufficient_quota') ||
        (!perMinute &&
            status != 401 &&
            RegExp(
              r'insufficient_quota|billing|credit|payment',
              caseSensitive: false,
            ).hasMatch(all))) {
      return LlmRateLimit(
        'A szolgáltatónál nincs elég egyenleg vagy a számlázás nincs beállítva.',
        detail: _safe(message),
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
        detail: _safe(message),
        daily: daily,
      );
    }
    if (status == 401 || status == 403) {
      return const LlmAuth(
        'Az API-kulcs érvénytelen, lejárt vagy nincs jogosultsága. Ellenőrizd a Beállításokban.',
      );
    }
    if (status >= 500) {
      return LlmNetwork('A szolgáltatás átmenetileg nem elérhető ($status).');
    }
    return LlmBadResponse(
      'A szolgáltató hibát jelzett ($status${message.isEmpty ? '' : ': ${_safe(message)}'}).',
    );
  }
}

String _safe(String m) {
  final clean = m
      .replaceAll(RegExp(r'(sk-|gsk_|AIza)[0-9A-Za-z_\-]{10,}'), '[kulcs]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.length > 400 ? '${clean.substring(0, 400)}…' : clean;
}
