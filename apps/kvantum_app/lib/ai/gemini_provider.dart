import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// Google Gemini over the public REST API (`generateContent`, function calling).
///
/// The API key travels only in the `x-goog-api-key` header, never in the URL
/// (URLs end up in logs).
class GeminiProvider implements LLMProvider {
  GeminiProvider(
    this._client, {
    required this.apiKey,
    this.baseUrl = 'https://generativelanguage.googleapis.com',
  });

  final http.Client _client;
  final String apiKey;
  final String baseUrl;

  Map<String, String> get _headers => {
    'x-goog-api-key': apiKey,
    'content-type': 'application/json',
  };

  // ------------------------------------------------------------- generate

  @override
  Future<LlmReply> generate(String model, LlmRequest r) async {
    final body = <String, Object?>{
      'systemInstruction': {
        'parts': [
          {'text': r.system},
        ],
      },
      'contents': [for (final t in r.turns) _turn(t)],
      if (r.tools.isNotEmpty) ...{
        'tools': [
          {
            'functionDeclarations': [
              for (final t in r.tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
            ],
          },
        ],
        'toolConfig': {
          'functionCallingConfig': {'mode': 'AUTO'},
        },
      },
      'generationConfig': {'temperature': r.temperature},
    };
    final json = await _post(
      Uri.parse('$baseUrl/v1beta/models/$model:generateContent'),
      body,
    );
    return _parseReply(json);
  }

  Map<String, Object?> _turn(LlmTurn t) => {
    'role': t.role,
    'parts': [
      for (final p in t.parts)
        switch (p) {
          LlmText() => {'text': p.text},
          LlmToolCall() =>
            p.raw ??
                {
                  'functionCall': {'name': p.name, 'args': p.args},
                },
          LlmToolResult() => {
            'functionResponse': {'name': p.name, 'response': p.result},
          },
        },
    ],
  };

  LlmReply _parseReply(Map<String, dynamic> json) {
    final block = (json['promptFeedback'] as Map?)?['blockReason'];
    final cands = json['candidates'];
    if (cands is! List || cands.isEmpty) {
      throw LlmBadResponse(
        block != null
            ? 'A kérést a modell biztonsági szűrője elutasította ($block).'
            : 'A modell nem adott választ.',
      );
    }
    final cand = cands.first as Map<String, dynamic>;
    final rawParts = (cand['content'] as Map?)?['parts'];
    final parts = <LlmPart>[];
    if (rawParts is List) {
      for (final p in rawParts) {
        if (p is! Map) continue;
        final fc = p['functionCall'];
        if (fc is Map) {
          final args = fc['args'];
          parts.add(
            LlmToolCall(
              '${fc['name']}',
              args is Map
                  ? Map<String, Object?>.from(args)
                  : <String, Object?>{},
              raw: Map<String, Object?>.from(p),
            ),
          );
        } else if (p['text'] is String && p['thought'] != true) {
          parts.add(LlmText(p['text'] as String));
        }
      }
    }
    final reason = cand['finishReason'] as String?;
    if (parts.isEmpty) {
      throw LlmBadResponse(
        reason == 'SAFETY' || reason == 'PROHIBITED_CONTENT'
            ? 'A választ a modell biztonsági szűrője megállította.'
            : 'A modell üres választ adott${reason == null ? '' : ' ($reason)'}.',
      );
    }
    final usage = json['usageMetadata'];
    return LlmReply(
      parts: parts,
      finishReason: reason,
      promptTokens: usage is Map
          ? (usage['promptTokenCount'] as num?)?.toInt()
          : null,
      outputTokens: usage is Map
          ? (usage['candidatesTokenCount'] as num?)?.toInt()
          : null,
    );
  }

  // --------------------------------------------------------------- models

  @override
  Future<List<LlmModel>> listModels() async {
    final out = <LlmModel>[];
    String? page;
    do {
      final uri = Uri.parse('$baseUrl/v1beta/models')
          .replace(queryParameters: {'pageSize': '100', 'pageToken': ?page});
      final json = await _get(uri);
      for (final m in (json['models'] as List? ?? const [])) {
        if (m is! Map) continue;
        final methods = (m['supportedGenerationMethods'] as List? ?? const [])
            .cast<Object?>();
        final name = '${m['name']}';
        if (!methods.contains('generateContent') ||
            !name.startsWith('models/')) {
          continue;
        }
        out.add(
          LlmModel(
            name.substring(7),
            '${m['displayName'] ?? name.substring(7)}',
          ),
        );
      }
      page = json['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return out;
  }

  // ----------------------------------------------------------------- http

  Future<Map<String, dynamic>> _post(Uri url, Object body) =>
      _send(() => _client.post(url, headers: _headers, body: jsonEncode(body)));
  Future<Map<String, dynamic>> _get(Uri url) =>
      _send(() => _client.get(url, headers: _headers));

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() call,
  ) async {
    final http.Response res;
    try {
      res = await call().timeout(const Duration(seconds: 60));
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
      throw const LlmBadResponse('A modell válasza nem értelmezhető.');
    }
    throw _errorFor(res.statusCode, text, res.headers);
  }

  LlmException _errorFor(int status, String body, Map<String, String> headers) {
    String message = '';
    String apiStatus = '';
    Duration? retry;
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        message = '${err['message'] ?? ''}';
        apiStatus = '${err['status'] ?? ''}';
        for (final d in (err['details'] as List? ?? const [])) {
          final rd = d is Map ? d['retryDelay'] : null;
          if (rd is String) {
            final m = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(rd);
            if (m != null) {
              retry = Duration(
                milliseconds: (double.parse(m[1]!) * 1000).round(),
              );
            }
          }
        }
      }
    } on FormatException {
      // body is not JSON
    }
    final header = int.tryParse(headers['retry-after'] ?? '');
    if (header != null) retry = Duration(seconds: header);

    if (status == 429 || apiStatus == 'RESOURCE_EXHAUSTED') {
      return LlmRateLimit(
        'Elfogyott az ingyenes keret vagy túl sok a kérés. Próbáld később.',
        retryAfter: retry,
      );
    }
    if (status == 401 ||
        status == 403 ||
        apiStatus == 'UNAUTHENTICATED' ||
        apiStatus == 'PERMISSION_DENIED' ||
        (status == 400 && message.toLowerCase().contains('api key'))) {
      return const LlmAuth(
        'Az API-kulcs érvénytelen, lejárt vagy nincs jogosultsága. Ellenőrizd a Beállításokban.',
      );
    }
    if (status >= 500) {
      return LlmNetwork(
        'A Gemini szolgáltatás átmenetileg nem elérhető ($status).',
      );
    }
    return LlmBadResponse(
      'A Gemini hibát jelzett ($status${message.isEmpty ? '' : ': $message'}).',
    );
  }
}

/// The model to use by default from the list the API returned: the newest
/// stable "flash" model; previews, lite/image/audio variants only as a fallback.
String? pickDefaultModel(List<LlmModel> models) {
  double version(String id) {
    final m = RegExp(r'gemini-(\d+(?:\.\d+)?)').firstMatch(id);
    return m == null ? 0 : double.parse(m[1]!);
  }

  bool special(String id) => RegExp(
    r'(lite|image|tts|live|audio|embed|thinking|exp|vision|robotics|computer)',
  ).hasMatch(id);
  bool preview(String id) => id.contains('preview');

  List<LlmModel> flash(bool Function(String) f) => [
    for (final m in models)
      if (m.id.contains('flash') && f(m.id)) m,
  ]..sort((a, b) => version(b.id).compareTo(version(a.id)));

  final stable = flash((id) => !special(id) && !preview(id));
  if (stable.isNotEmpty) return stable.first.id;
  final prev = flash((id) => !special(id));
  if (prev.isNotEmpty) return prev.first.id;
  final any = flash((_) => true);
  if (any.isNotEmpty) return any.first.id;
  final gemini = [
    for (final m in models)
      if (m.id.startsWith('gemini')) m,
  ];
  return gemini.isEmpty
      ? (models.isEmpty ? null : models.first.id)
      : gemini.first.id;
}
