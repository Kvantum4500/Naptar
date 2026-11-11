import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_http.dart';
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
    this.maxOutputTokens = 4096,
    this.defaultTemperature = 0.2,
  });

  final http.Client _client;
  final String apiKey;
  final String baseUrl;

  /// Upper bound for one reply. The model's hidden "thinking" counts into it,
  /// so it is not as small as the visible answer alone would need.
  final int maxOutputTokens;

  /// Used when the request names none; null means it is not sent at all.
  final double? defaultTemperature;

  static const _cutMessage =
      'A modell válasza elfogyott a hosszkeretben, mielőtt befejezte volna. Kérj kevesebb napot vagy kevesebb tételt, vagy válassz másik modellt a Beállításokban.';

  @override
  void close() => _client.close();

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
      'generationConfig': {
        if ((r.temperature ?? defaultTemperature) != null)
          'temperature': r.temperature ?? defaultTemperature,
        'maxOutputTokens': maxOutputTokens,
      },
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
      // the cap was spent (on hidden thinking, mostly) before any answer
      if (reason == 'MAX_TOKENS') throw const LlmTruncated(_cutMessage);
      // the model could not write its function call; another go often works
      if (reason == 'MALFORMED_FUNCTION_CALL') {
        throw const LlmToolFailed(
          'A modell nem tudta összeállítani a tervet (hibás eszközhívás). Próbáld újra, vagy válassz másik modellt a Beállításokban.',
        );
      }
      throw LlmBadResponse(
        reason == 'SAFETY' || reason == 'PROHIBITED_CONTENT'
            ? 'A választ a modell biztonsági szűrője megállította.'
            : 'A modell üres választ adott${reason == null ? '' : ' ($reason)'}.',
      );
    }
    final usage = json['usageMetadata'];
    int? n(String key) =>
        usage is Map && usage[key] is num ? (usage[key] as num).toInt() : null;
    return LlmReply(
      parts: parts,
      finishReason: reason,
      promptTokens: n('promptTokenCount'),
      outputTokens: n('candidatesTokenCount'),
      // hidden thinking is billed as output but not part of candidatesTokenCount
      thinkingTokens: n('thoughtsTokenCount'),
      cachedTokens: n('cachedContentTokenCount'),
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

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call) =>
      sendJson(
        call,
        timeout: const Duration(seconds: 60),
        errorFor: _errorFor,
        notJson: 'A modell válasza nem értelmezhető.',
      );

  LlmException _errorFor(int status, String body, Map<String, String> headers) {
    String message = '';
    String apiStatus = '';
    Duration? retry;
    String? quotaModel;
    var quotaIds = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        message = '${err['message'] ?? ''}';
        apiStatus = '${err['status'] ?? ''}';
        for (final d in (err['details'] as List? ?? const [])) {
          if (d is Map && '${d['@type']}'.contains('QuotaFailure')) {
            for (final v in (d['violations'] as List? ?? const [])) {
              if (v is! Map) continue;
              quotaIds += ' ${v['quotaId'] ?? ''} ${v['quotaMetric'] ?? ''}';
              final dims = v['quotaDimensions'];
              if (dims is Map && dims['model'] != null) {
                quotaModel = '${dims['model']}';
              }
            }
          }
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
      final all = '$message $quotaIds';
      quotaModel ??= RegExp(r'model:\s*([\w.\-]+)').firstMatch(message)?[1];
      final billing = RegExp(
        r'prepayment|billing|credits are depleted|insufficient_quota',
        caseSensitive: false,
      ).hasMatch(all);
      final zero = !billing && RegExp(r'limit:\s*0\b').hasMatch(all);
      final daily =
          !billing &&
          !zero &&
          RegExp(r'PerDay|per day|daily', caseSensitive: false).hasMatch(all);
      final name = quotaModel ?? 'ez a modell';
      final text = billing
          ? 'A Google-fiók előre fizetett egyenlege elfogyott vagy nincs feltöltve, ezért a kérés nem engedélyezett.'
          : zero
          ? 'A(z) $name modellhez ennél a kulcsnál nincs ingyenes keret (limit: 0).'
          : daily
          ? 'Elfogyott a mai ingyenes keret ehhez a modellhez ($name).'
          : 'Túl sok kérés rövid idő alatt${retry == null ? '' : ' (kb. ${retry.inSeconds} mp várakozás kell)'}.';
      return LlmRateLimit(
        text,
        retryAfter: retry,
        detail: redactSecrets(message, key: apiKey),
        quotaZero: zero,
        daily: daily,
        billing: billing,
        model: quotaModel,
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
        status: status,
      );
    }
    return LlmBadResponse(
      'A Gemini hibát jelzett ($status${message.isEmpty ? '' : ': ${redactSecrets(message, key: apiKey)}'}).',
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

/// Other models worth trying when one has no quota: stable flash first, then
/// flash-lite (usually the most generous free tier), then previews.
List<String> fallbackModels(List<LlmModel> models, String failed) {
  double version(String id) {
    final m = RegExp(r'gemini-(\d+(?:\.\d+)?)').firstMatch(id);
    return m == null ? 0 : double.parse(m[1]!);
  }

  bool special(String id) => RegExp(
    r'(image|tts|live|audio|embed|thinking|exp|vision|robotics|computer)',
  ).hasMatch(id);
  List<String> pick(bool Function(String) f) => [
    for (final m in models)
      if (m.id != failed && m.id.contains('flash') && !special(m.id) && f(m.id))
        m.id,
  ]..sort((a, b) => version(b).compareTo(version(a)));

  final stableFlash = pick(
    (id) => !id.contains('lite') && !id.contains('preview'),
  );
  final stableLite = pick(
    (id) => id.contains('lite') && !id.contains('preview'),
  );
  final previews = pick((id) => id.contains('preview'));
  return [...stableFlash, ...stableLite, ...previews].take(4).toList();
}
