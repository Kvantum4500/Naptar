import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/gemini_provider.dart';
import 'package:kvantum_app/ai/llm_provider.dart';

const secret = 'AIzaSy-SECRET-KEY-123';

http.Response _json(
  Object body, [
  int status = 200,
  Map<String, String> headers = const {},
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...headers},
);

GeminiProvider provider(MockClientHandler h) =>
    GeminiProvider(MockClient(h), apiKey: secret);

LlmRequest request({List<LlmTurn>? turns, List<ToolDecl> tools = const []}) =>
    LlmRequest(
      system: 'Rendszer üzenet',
      turns:
          turns ??
          const [
            LlmTurn('user', [LlmText('Tervezz edzést')]),
          ],
      tools: tools,
    );

Map<String, Object?> okText(String t) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': t},
        ],
      },
      'finishReason': 'STOP',
    },
  ],
  'usageMetadata': {'promptTokenCount': 120, 'candidatesTokenCount': 30},
};

void main() {
  group('generate: request shape', () {
    test('key only in the header, never in the URL; system, contents, tools, mode AUTO', () async {
      late http.Request seen;
      final p = provider((r) async {
        seen = r;
        return _json(okText('Szia'));
      });
      await p.generate(
        'gemini-2.5-flash',
        request(
          tools: const [
            ToolDecl('get_tasks', 'Feladatok', {
              'type': 'object',
              'properties': {},
            }),
          ],
        ),
      );
      expect(seen.method, 'POST');
      expect(seen.url.path, '/v1beta/models/gemini-2.5-flash:generateContent');
      expect(seen.url.toString().contains(secret), isFalse);
      expect(seen.url.queryParameters.containsKey('key'), isFalse);
      expect(seen.headers['x-goog-api-key'], secret);
      final b = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(b['systemInstruction']['parts'][0]['text'], 'Rendszer üzenet');
      expect(b['contents'][0], {
        'role': 'user',
        'parts': [
          {'text': 'Tervezz edzést'},
        ],
      });
      expect(b['tools'][0]['functionDeclarations'][0]['name'], 'get_tasks');
      expect(b['toolConfig']['functionCallingConfig']['mode'], 'AUTO');
      expect(seen.body.contains(secret), isFalse);
    });

    test('no tools: no tool fields at all', () async {
      late Map<String, dynamic> body;
      await provider((r) async {
        body = jsonDecode(r.body) as Map<String, dynamic>;
        return _json(okText('x'));
      }).generate('m', request());
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('toolConfig'), isFalse);
    });

    test('tool calls and results are sent back in Gemini format; raw parts are echoed untouched', () async {
      late Map<String, dynamic> body;
      final p = provider((r) async {
        body = jsonDecode(r.body) as Map<String, dynamic>;
        return _json(okText('kész'));
      });
      await p.generate(
        'm',
        request(
          turns: const [
            LlmTurn('user', [LlmText('kérés')]),
            LlmTurn('model', [
              LlmToolCall(
                'get_tasks',
                {},
                raw: {
                  'functionCall': {'name': 'get_tasks', 'args': {}},
                  'thoughtSignature': 'OPAQUE-SIG',
                },
              ),
            ]),
            LlmTurn('user', [
              LlmToolResult('get_tasks', {'darab': 2}),
            ]),
          ],
        ),
      );
      final contents = body['contents'] as List;
      expect(contents[1]['parts'][0]['thoughtSignature'], 'OPAQUE-SIG');
      expect(contents[2]['role'], 'user');
      expect(contents[2]['parts'][0]['functionResponse'], {
        'name': 'get_tasks',
        'response': {'darab': 2},
      });
    });
  });

  group('generate: reply parsing', () {
    test('text reply with token usage', () async {
      final r = await provider((_) async => _json(okText('Szia!')))
          .generate('m', request());
      expect(r.text, 'Szia!');
      expect(r.toolCalls, isEmpty);
      expect((r.promptTokens, r.outputTokens), (120, 30));
    });

    test(
      'function calls are parsed with name, args and the raw part',
      () async {
        final r = await provider(
          (_) async => _json({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Megnézem.'},
                    {
                      'functionCall': {
                        'name': 'find_free_slots',
                        'args': {'from': '2026-05-04', 'minutes': 60},
                      },
                      'thoughtSignature': 'SIG',
                    },
                  ],
                },
              },
            ],
          }),
        ).generate('m', request());
        expect(r.text, 'Megnézem.');
        final c = r.toolCalls.single;
        expect(c.name, 'find_free_slots');
        expect(c.args['minutes'], 60);
        expect(c.raw!['thoughtSignature'], 'SIG');
      },
    );

    test('hidden "thought" text is not shown to the user', () async {
      final r = await provider(
        (_) async => _json({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'belső gondolat', 'thought': true},
                  {'text': 'Válasz'},
                ],
              },
            },
          ],
        }),
      ).generate('m', request());
      expect(r.text, 'Válasz');
    });

    test(
      'empty, blocked and malformed replies become readable errors',
      () async {
        Future<LlmException> fail(Object body) async {
          try {
            await provider((_) async => _json(body)).generate('m', request());
          } on LlmException catch (e) {
            return e;
          }
          fail('expected an exception');
          throw StateError('unreachable');
        }

        expect(await fail({'candidates': []}), isA<LlmBadResponse>());
        final blocked = await fail({
          'promptFeedback': {'blockReason': 'SAFETY'},
        });
        expect(blocked.message, contains('biztonsági szűrő'));
        expect(
          await fail({
            'candidates': [
              {
                'content': {'parts': []},
                'finishReason': 'MAX_TOKENS',
              },
            ],
          }),
          isA<LlmBadResponse>(),
        );
        await expectLater(
          provider((_) async => http.Response('nem json', 200))
              .generate('m', request()),
          throwsA(isA<LlmBadResponse>()),
        );
      },
    );
  });

  group('error mapping', () {
    Future<LlmException> status(
      int code, [
      Object? body,
      Map<String, String> headers = const {},
    ]) async {
      try {
        await provider((_) async => _json(body ?? {}, code, headers))
            .generate('m', request());
      } on LlmException catch (e) {
        return e;
      }
      throw StateError('no exception');
    }

    test(
      '429 -> rate limit, with the server hint from the body or the header',
      () async {
        final a = await status(429, {
          'error': {
            'status': 'RESOURCE_EXHAUSTED',
            'message': 'quota',
            'details': [
              {'retryDelay': '12s'},
            ],
          },
        });
        expect(a, isA<LlmRateLimit>());
        expect((a as LlmRateLimit).retryAfter, const Duration(seconds: 12));
        final b = await status(429, {}, {'retry-after': '7'});
        expect((b as LlmRateLimit).retryAfter, const Duration(seconds: 7));
      },
    );

    test('bad key, 401, 403 -> auth, without leaking the key', () async {
      final bad = await status(400, {
        'error': {
          'message': 'API key not valid. Please pass a valid API key.',
          'status': 'INVALID_ARGUMENT',
        },
      });
      expect(bad, isA<LlmAuth>());
      expect(await status(401), isA<LlmAuth>());
      expect(
        await status(403, {
          'error': {'status': 'PERMISSION_DENIED', 'message': 'x'},
        }),
        isA<LlmAuth>(),
      );
      for (final e in [bad]) {
        expect(e.message.contains(secret), isFalse);
      }
    });

    test('5xx and network problems are retryable network errors', () async {
      expect(await status(503), isA<LlmNetwork>());
      await expectLater(
        provider((_) async => throw const SocketException('no net'))
            .generate('m', request()),
        throwsA(isA<LlmNetwork>()),
      );
    });

    test('other 4xx shows the API message', () async {
      final e = await status(400, {
        'error': {
          'message': 'Invalid JSON payload',
          'status': 'INVALID_ARGUMENT',
        },
      });
      expect(e, isA<LlmBadResponse>());
      expect(e.message, contains('Invalid JSON payload'));
    });
  });

  group('429 diagnosis', () {
    Future<LlmRateLimit> limit(
      Object body, [
      Map<String, String> headers = const {},
    ]) async {
      try {
        await provider((_) async => _json(body, 429, headers))
            .generate('gemini-2.5-pro', request());
      } on LlmRateLimit catch (e) {
        return e;
      }
      throw StateError('no rate limit');
    }

    test(
      '"limit: 0" means this model has no free quota for this key',
      () async {
        final e = await limit({
          'error': {
            'status': 'RESOURCE_EXHAUSTED',
            'message': 'You exceeded your current quota. * Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 0, model: gemini-2.5-pro',
            'details': [
              {
                '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
                'violations': [
                  {
                    'quotaMetric': 'x/generate_content_free_tier_requests',
                    'quotaId':
                        'GenerateRequestsPerDayPerProjectPerModel-FreeTier',
                    'quotaDimensions': {'model': 'gemini-2.5-pro'},
                  },
                ],
              },
            ],
          },
        });
        expect(e.quotaZero, isTrue);
        expect(e.transient, isFalse);
        expect(e.model, 'gemini-2.5-pro');
        expect(e.message, contains('gemini-2.5-pro'));
        expect(e.message, contains('nincs ingyenes keret'));
        expect(e.detail, contains('limit: 0'));
      },
    );

    test('depleted prepayment credits are billing, not a rate limit', () async {
      final e = await limit({
        'error': {
          'status': 'RESOURCE_EXHAUSTED',
          'message':
              'Your prepayment credits are depleted. Please go to AI Studio to manage your project and billing.',
        },
      });
      expect(e.billing, isTrue);
      expect(e.transient, isFalse);
      expect(e.message, contains('egyenleg'));
      expect(e.detail, contains('prepayment'));
    });

    test('a daily quota is recognised and is not transient', () async {
      final e = await limit({
        'error': {
          'status': 'RESOURCE_EXHAUSTED',
          'message': 'Quota exceeded for metric: generate_content_free_tier_requests, limit: 250, model: gemini-2.5-flash',
          'details': [
            {
              '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
              'violations': [
                {
                  'quotaId':
                      'GenerateRequestsPerDayPerProjectPerModel-FreeTier',
                },
              ],
            },
          ],
        },
      });
      expect(e.daily, isTrue);
      expect(e.quotaZero, isFalse);
      expect(e.transient, isFalse);
      expect(e.message, contains('mai ingyenes keret'));
    });

    test('a per-minute limit is transient and carries the wait hint', () async {
      final e = await limit({
        'error': {
          'status': 'RESOURCE_EXHAUSTED',
          'message': 'Quota exceeded for metric: generate_content_free_tier_requests, limit: 10, model: gemini-2.5-flash',
          'details': [
            {
              '@type': 'type.googleapis.com/google.rpc.QuotaFailure',
              'violations': [
                {
                  'quotaId':
                      'GenerateRequestsPerMinutePerProjectPerModel-FreeTier',
                },
              ],
            },
            {
              '@type': 'type.googleapis.com/google.rpc.RetryInfo',
              'retryDelay': '37s',
            },
          ],
        },
      });
      expect(e.transient, isTrue);
      expect(e.retryAfter, const Duration(seconds: 37));
      expect(e.message, contains('37 mp'));
    });

    test(
      'the detail never contains anything that looks like a key and is bounded',
      () async {
        final e = await limit({
          'error': {
            'status': 'RESOURCE_EXHAUSTED',
            'message': 'bad key AIzaSyA1234567890abcdefghijk ${'x' * 800}',
          },
        });
        expect(e.detail.contains('AIza'), isFalse);
        expect(e.detail.length, lessThanOrEqualTo(401));
      },
    );

    test('fallback models: other stable flash first, then lite, then previews; never the failed one', () {
      LlmModel m(String id) => LlmModel(id, id);
      final list = [
        m('gemini-2.5-pro'),
        m('gemini-2.5-flash'),
        m('gemini-2.5-flash-lite'),
        m('gemini-2.0-flash'),
        m('gemini-3.0-flash-preview'),
        m('gemini-2.5-flash-image'),
        m('gemini-2.0-flash-lite'),
        m('gemini-2.5-flash-tts'),
      ];
      expect(fallbackModels(list, 'gemini-2.5-flash'), [
        'gemini-2.0-flash',
        'gemini-2.5-flash-lite',
        'gemini-2.0-flash-lite',
        'gemini-3.0-flash-preview',
      ]);
      expect(fallbackModels(list, 'gemini-2.5-pro').first, 'gemini-2.5-flash');
      expect(fallbackModels([m('gemini-2.5-pro')], 'gemini-2.5-pro'), isEmpty);
    });
  });

  group('models', () {
    test('lists only models that can generate content, follows paging, strips "models/"', () async {
      var page = 0;
      final seen = <http.Request>[];
      final p = provider((r) async {
        seen.add(r);
        page++;
        return page == 1
            ? _json({
                'nextPageToken': 'P2',
                'models': [
                  {
                    'name': 'models/gemini-2.5-flash',
                    'displayName': 'Gemini 2.5 Flash',
                    'supportedGenerationMethods': ['generateContent'],
                  },
                  {
                    'name': 'models/text-embedding-004',
                    'supportedGenerationMethods': ['embedContent'],
                  },
                ],
              })
            : _json({
                'models': [
                  {
                    'name': 'models/gemini-2.5-pro',
                    'supportedGenerationMethods': [
                      'generateContent',
                      'countTokens',
                    ],
                  },
                ],
              });
      });
      final list = await p.listModels();
      expect(list.map((m) => m.id), ['gemini-2.5-flash', 'gemini-2.5-pro']);
      expect(list.first.displayName, 'Gemini 2.5 Flash');
      expect(seen.last.url.queryParameters['pageToken'], 'P2');
      expect(
        seen.every(
          (r) =>
              r.headers['x-goog-api-key'] == secret &&
              !r.url.toString().contains(secret),
        ),
        isTrue,
      );
    });

    test('a wrong key surfaces as an auth error', () async {
      await expectLater(
        provider(
          (_) async => _json({
            'error': {
              'message': 'API key not valid',
              'status': 'INVALID_ARGUMENT',
            },
          }, 400),
        ).listModels(),
        throwsA(isA<LlmAuth>()),
      );
    });

    LlmModel m(String id) => LlmModel(id, id);

    test('default model: newest stable flash; specials and previews only as fallback', () {
      expect(
        pickDefaultModel([
          m('gemini-2.0-flash'),
          m('gemini-2.5-flash'),
          m('gemini-2.5-pro'),
          m('gemini-2.5-flash-lite'),
        ]),
        'gemini-2.5-flash',
      );
      expect(
        pickDefaultModel([
          m('gemini-2.5-flash'),
          m('gemini-3.0-flash-preview'),
        ]),
        'gemini-2.5-flash',
      );
      expect(
        pickDefaultModel([
          m('gemini-3.0-flash-preview'),
          m('gemini-2.5-flash-lite'),
        ]),
        'gemini-3.0-flash-preview',
      );
      expect(
        pickDefaultModel([m('gemini-2.5-flash-lite'), m('gemini-2.5-pro')]),
        'gemini-2.5-flash-lite',
      );
      expect(pickDefaultModel([m('gemini-2.5-pro')]), 'gemini-2.5-pro');
      expect(pickDefaultModel([m('gemma-3')]), 'gemma-3');
      expect(pickDefaultModel([]), isNull);
    });
  });
}
