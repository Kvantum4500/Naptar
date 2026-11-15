import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/gemini_provider.dart';
import 'package:kvantum_app/ai/llm_http.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/openai_provider.dart';
import 'package:kvantum_app/ai/provider_catalog.dart';

/// How the providers cope with what goes wrong: replies cut off by the length
/// cap, requests that are too big, parameters a model refuses, server hiccups,
/// keys in error messages, and closing the connection.

const secret = 'gsk_SECRET1234567890abcdef';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

OpenAiProvider openai(
  MockClientHandler h, {
  String base = 'https://api.example.com/v1',
  double? temperature = 0.2,
  String? effort,
  http.Client? client,
}) => OpenAiProvider(
  client ?? MockClient(h),
  apiKey: secret,
  baseUrl: base,
  defaultTemperature: temperature,
  reasoningEffort: effort,
);

LlmRequest req({double? temperature}) => LlmRequest(
  system: 'Rendszer',
  turns: const [
    LlmTurn('user', [LlmText('Tervezz')]),
  ],
  tools: const [
    ToolDecl('propose_events', 'Terv', {'type': 'object', 'properties': {}}),
  ],
  temperature: temperature,
);

Map<String, Object?> ok([String t = 'ok']) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': t},
      'finish_reason': 'stop',
    },
  ],
};

Map<String, Object?> toolReply(String args, String finish) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'propose_events', 'arguments': args},
          },
        ],
      },
      'finish_reason': finish,
    },
  ],
};

Map<String, Object?> err(
  String message, {
  String type = 'invalid_request_error',
  String? code,
  String? param,
}) => {
  'error': {'message': message, 'type': type, 'code': ?code, 'param': ?param},
};

/// A client that counts how often it was closed.
class SpyClient extends MockClient {
  SpyClient(super.fn);
  int closed = 0;
  @override
  void close() {
    closed++;
    super.close();
  }
}

void main() {
  setUp(OpenAiProvider.forgetRefusals);

  group('a reply cut off by the length cap', () {
    test('LlmReply.truncated knows both providers\' words for it', () {
      expect(
        const LlmReply(parts: [], finishReason: 'length').truncated,
        isTrue,
      );
      expect(
        const LlmReply(parts: [], finishReason: 'MAX_TOKENS').truncated,
        isTrue,
      );
      expect(
        const LlmReply(parts: [], finishReason: 'stop').truncated,
        isFalse,
      );
      expect(const LlmReply(parts: []).truncated, isFalse);
    });

    test(
      'a half-written tool call is reported, never handed on as "no arguments"',
      () async {
        final p = openai(
          (_) async => _json(
            toolReply(
              '{"summary":"Terv","proposals":[{"title":"Gym 60 per',
              'length',
            ),
          ),
        );
        await expectLater(
          p.generate('m', req()),
          throwsA(
            isA<LlmTruncated>().having(
              (e) => e.message,
              'message',
              contains('hosszkeret'),
            ),
          ),
        );
      },
    );

    test(
      'a complete call that stopped at the cap is kept and flagged',
      () async {
        final p = openai(
          (_) async => _json(toolReply('{"summary":"Terv"}', 'length')),
        );
        final r = await p.generate('m', req());
        expect(r.truncated, isTrue);
        expect(r.toolCalls.single.args['summary'], 'Terv');
      },
    );

    test(
      'an unrelated broken argument string is still "no arguments"',
      () async {
        final p = openai(
          (_) async => _json(toolReply('{"summary":', 'tool_calls')),
        );
        final r = await p.generate('m', req());
        expect(r.truncated, isFalse);
        expect(r.toolCalls.single.args, isEmpty);
      },
    );

    test('Gemini: the cap spent before any answer is explained', () async {
      final p = GeminiProvider(
        MockClient(
          (_) async => _json({
            'candidates': [
              {
                'content': {'parts': <Object>[]},
                'finishReason': 'MAX_TOKENS',
              },
            ],
          }),
        ),
        apiKey: 'AIzaSy-SECRET-KEY-123',
      );
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmTruncated>().having(
            (e) => e.message,
            'message',
            contains('hosszkeret'),
          ),
        ),
      );
    });

    test(
      'Gemini: a call that stopped at the cap is kept and flagged',
      () async {
        final p = GeminiProvider(
          MockClient(
            (_) async => _json({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'propose_events',
                          'args': {'summary': 'Terv'},
                        },
                      },
                    ],
                  },
                  'finishReason': 'MAX_TOKENS',
                },
              ],
            }),
          ),
          apiKey: 'AIzaSy-SECRET-KEY-123',
        );
        final r = await p.generate('m', req());
        expect(r.truncated, isTrue);
        expect(r.toolCalls.single.name, 'propose_events');
      },
    );

    test('Gemini: a malformed function call is a tool failure', () async {
      final p = GeminiProvider(
        MockClient(
          (_) async => _json({
            'candidates': [
              {
                'content': {'parts': <Object>[]},
                'finishReason': 'MALFORMED_FUNCTION_CALL',
              },
            ],
          }),
        ),
        apiKey: 'AIzaSy-SECRET-KEY-123',
      );
      await expectLater(p.generate('m', req()), throwsA(isA<LlmToolFailed>()));
    });
  });

  group('a request that is too big, a model that fails its call', () {
    test('Groq 413 carries the numbers and is not a rate limit', () async {
      final p = openai(
        (_) async => _json(
          err(
            'Request too large for model `openai/gpt-oss-20b` in organization `org_x` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 12039, please reduce your message size and try again.',
            type: 'tokens',
            code: 'rate_limit_exceeded',
          ),
          413,
        ),
      );
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmTooLarge>()
              .having((e) => e.limit, 'limit', 8000)
              .having((e) => e.requested, 'requested', 12039)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('12039'), contains('8000')),
              ),
        ),
      );
    });

    test('a context-length 400 is "too large" as well', () async {
      final p = openai(
        (_) async => _json(
          err(
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9500 tokens. Please reduce the length of the messages.",
            code: 'context_length_exceeded',
          ),
          400,
        ),
      );
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmTooLarge>()
              .having((e) => e.limit, 'limit', 8192)
              .having((e) => e.requested, 'requested', 9500),
        ),
      );
    });

    test('a per-minute 429 stays a rate limit that clears by itself', () async {
      final p = openai(
        (_) async => _json(
          err(
            'Rate limit reached for model `x` on tokens per minute (TPM): Limit 8000, Used 6500, Requested 2500. Please try again in 5.5s.',
            type: 'tokens',
            code: 'rate_limit_exceeded',
          ),
          429,
        ),
      );
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmRateLimit>()
              .having((e) => e.transient, 'transient', isTrue)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 6),
              ),
        ),
      );
    });

    test('Groq tool_use_failed is its own error', () async {
      final p = openai(
        (_) async => _json(
          err(
            "Failed to call a function. Please adjust your prompt. See 'failed_generation' for more details.",
            code: 'tool_use_failed',
          ),
          400,
        ),
      );
      await expectLater(p.generate('m', req()), throwsA(isA<LlmToolFailed>()));
    });
  });

  group('parameters a model does not take', () {
    test('temperature refused: one more request without it, and the next one starts without it', () async {
      final bodies = <Map<String, Object?>>[];
      final p = openai((r) async {
        final b = jsonDecode(r.body) as Map<String, Object?>;
        bodies.add(b);
        if (b.containsKey('temperature')) {
          return _json(
            err(
              "Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.",
              code: 'unsupported_value',
              param: 'temperature',
            ),
            400,
          );
        }
        return _json(ok());
      });
      expect((await p.generate('m1', req())).text, 'ok');
      expect(bodies.length, 2);
      expect(bodies[0]['temperature'], 0.2);
      expect(bodies[1].containsKey('temperature'), isFalse);

      // remembered for this model: no wasted round trip the next time ...
      await p.generate('m1', req());
      expect(bodies.length, 3);
      expect(bodies[2].containsKey('temperature'), isFalse);

      // ... but another model is asked with it first (and refuses it too)
      await p.generate('other-model', req());
      expect(bodies[3]['temperature'], 0.2);
      expect(bodies[4].containsKey('temperature'), isFalse);
      expect(bodies.length, 5);
    });

    test(
      'max_tokens refused: the same cap goes out as max_completion_tokens',
      () async {
        final bodies = <Map<String, Object?>>[];
        final p = openai((r) async {
          final b = jsonDecode(r.body) as Map<String, Object?>;
          bodies.add(b);
          if (b.containsKey('max_tokens')) {
            return _json(
              err(
                "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
                code: 'unsupported_parameter',
                param: 'max_tokens',
              ),
              400,
            );
          }
          return _json(ok());
        });
        await p.generate('m', req());
        expect(bodies[0]['max_tokens'], 2048);
        expect(bodies[1].containsKey('max_tokens'), isFalse);
        expect(bodies[1]['max_completion_tokens'], 2048);
      },
    );

    test(
      'a parameter named only in the message is found too (Groq style)',
      () async {
        final bodies = <Map<String, Object?>>[];
        final p = openai((r) async {
          final b = jsonDecode(r.body) as Map<String, Object?>;
          bodies.add(b);
          return b.containsKey('reasoning_effort')
              ? _json(
                  err('`reasoning_effort` is not supported with this model'),
                  400,
                )
              : _json(ok());
        }, effort: 'low');
        await p.generate('m', req());
        expect(bodies.length, 2);
        expect(bodies[0]['reasoning_effort'], 'low');
        expect(bodies[1].containsKey('reasoning_effort'), isFalse);
      },
    );

    test(
      'the retry is bounded: a service that refuses everything gets 3 requests',
      () async {
        var n = 0;
        const names = [
          'temperature',
          'tool_choice',
          'max_tokens',
          'reasoning_effort',
        ];
        final p = openai((r) async {
          final name = names[n++ % names.length];
          return _json(err("Unsupported parameter: '$name'", param: name), 400);
        }, effort: 'low');
        await expectLater(
          p.generate('m', req()),
          throwsA(isA<LlmBadRequest>()),
        );
        expect(n, 3);
      },
    );

    test('a 400 that names no refusable parameter is not retried', () async {
      var n = 0;
      final p = openai((_) async {
        n++;
        return _json(err('messages: unknown role', param: 'messages'), 400);
      });
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmBadResponse>().having(
            (e) => e is LlmBadRequest,
            'bad request',
            isFalse,
          ),
        ),
      );
      expect(n, 1);
    });

    test(
      'a request-level temperature beats the preset; null preset sends none',
      () async {
        final bodies = <Map<String, Object?>>[];
        Future<void> run(OpenAiProvider p, LlmRequest r) async {
          await p.generate('m', r);
        }

        final p = openai((r) async {
          bodies.add(jsonDecode(r.body) as Map<String, Object?>);
          return _json(ok());
        });
        await run(p, req());
        await run(p, req(temperature: 0.7));
        final none = openai((r) async {
          bodies.add(jsonDecode(r.body) as Map<String, Object?>);
          return _json(ok());
        }, temperature: null);
        await run(none, req());
        expect(bodies[0]['temperature'], 0.2);
        expect(bodies[1]['temperature'], 0.7);
        expect(bodies[2].containsKey('temperature'), isFalse);
      },
    );
  });

  group('what the wire can do', () {
    test(
      '5xx carries its status; only the transient ones are worth a retry',
      () async {
        Future<LlmNetwork> failWith(int status) async {
          try {
            await openai((_) async => _json(err('x'), status))
                .generate('m', req());
          } on LlmNetwork catch (e) {
            return e;
          }
          throw StateError('no error for $status');
        }

        for (final s in [500, 502, 503, 504, 529]) {
          final e = await failWith(s);
          expect(e.status, s);
          expect(e.retryable, isTrue, reason: '$s');
        }
        for (final s in [501, 505]) {
          expect((await failWith(s)).retryable, isFalse, reason: '$s');
        }
      },
    );

    test(
      'no answer in time is a retryable timeout; no connection is not',
      () async {
        final slow = await openai((_) async => throw TimeoutException('x'))
            .generate('m', req())
            .then<LlmNetwork?>((_) => null)
            .catchError((Object e) => e as LlmNetwork);
        expect(slow!.timeout, isTrue);
        expect(slow.retryable, isTrue);

        final off =
            await openai(
                  (_) async =>
                      throw const SocketException('Failed host lookup'),
                )
                .generate('m', req())
                .then<LlmNetwork?>((_) => null)
                .catchError((Object e) => e as LlmNetwork);
        expect(off!.retryable, isFalse);
        expect(off.message, contains('Nincs kapcsolat'));
      },
    );

    test(
      'a closed client (a cancelled request) is a plain network error',
      () async {
        final e =
            await openai(
                  (_) async =>
                      throw http.ClientException('Client is already closed'),
                )
                .generate('m', req())
                .then<LlmNetwork?>((_) => null)
                .catchError((Object e) => e as LlmNetwork);
        expect(e, isNotNull);
        expect(e!.retryable, isFalse);
      },
    );

    test('the whole-request timeout is not retryable', () {
      expect(const LlmTimeout('x').retryable, isFalse);
    });

    test('close() closes the HTTP client, both providers, twice is fine', () {
      final a = SpyClient((_) async => _json(ok()));
      final b = SpyClient((_) async => _json(ok()));
      openai((_) async => _json(ok()), client: a)
        ..close()
        ..close();
      GeminiProvider(b, apiKey: 'AIzaSy-SECRET-KEY-123')
        ..close()
        ..close();
      expect(a.closed, 2);
      expect(b.closed, 2);
    });
  });

  group('keys never end up in messages', () {
    test('redactSecrets: the key in use, prefixed keys, bearer tokens, long tokens', () {
      const key = 'abcd-EFGH-1234'; // no known prefix at all
      final out = redactSecrets(
        'bad key $key / sk-or-v1-0123456789abcdef / gsk_AAAAAAAAAAAA / '
        'AIzaSyAAAAAAAAAAAA / Authorization: Bearer abc.def-ghi_jkl123456 / '
        'mistral 0123456789abcdef0123456789abcdef end',
        key: key,
      );
      expect(out, isNot(contains(key)));
      for (final leaked in [
        'sk-or-v1',
        'gsk_AAAA',
        'AIzaSyAAAA',
        'abc.def-ghi',
        '0123456789abcdef0123456789abcdef',
      ]) {
        expect(out.contains(leaked), isFalse, reason: leaked);
      }
      expect(out, contains('[kulcs]'));
      expect(out, contains('end'));
    });

    test(
      'redactSecrets: GitHub and Google tokens go too (not only AI keys)',
      () {
        // (made-up values of the real shapes; the second part has dashes,
        // underscores and dots, which the 32-letter rule alone would not catch)
        const samples = {
          'github_pat_11ABCDEFG0abcdefghijkl_MNOPQRSTUVWXYZ': 'fine-grained',
          'ghp_abcdefghijklmnopqrstuvwxyz0123456789': 'personal',
          'gho_abcdefghijkl': 'OAuth',
          'ghu_abcdefghijkl': 'user',
          'ghs_abcdefghijkl': 'server',
          'ghr_abcdefghijkl': 'refresh',
          'GOCSPX-abc_DEF-ghi123': 'Google client secret',
          'ya29.a0AfH6SMB_x-y.z1234': 'Google access token',
          '1//0gAbCdEf-GhIjKl_MnOp': 'Google refresh token',
        };
        for (final e in samples.entries) {
          final out = redactSecrets('hiba ${e.key} vége');
          expect(out, 'hiba [kulcs] vége', reason: e.value);
        }
      },
    );

    test('redactSecrets: ordinary text with the same letters stays', () {
      for (final text in [
        'ghost_town and ghp_ alone',
        'ya29 is a number, 1//0 a fraction',
        'GOCSPX- without more',
        'a/1//path',
      ]) {
        expect(redactSecrets(text), text, reason: text);
      }
    });

    test('redactSecrets: bounded and on one line', () {
      final out = redactSecrets('a\n\n   b ${'x ' * 400}');
      expect(out.length, lessThanOrEqualTo(401));
      expect(out.contains('\n'), isFalse);
      expect(out, endsWith('…'));
    });

    test('OpenAI-style: a key quoted by the service is removed from the shown message', () async {
      const key = 'abcd1234efgh5678ijkl9012mnop3456'; // a Mistral-looking key
      final p = OpenAiProvider(
        MockClient(
          (_) async => _json(err('Rejected body for key $key at gateway'), 400),
        ),
        apiKey: key,
        baseUrl: 'https://api.example.com/v1',
      );
      try {
        await p.generate('m', req());
        fail('should have thrown');
      } on LlmBadResponse catch (e) {
        expect(e.message, isNot(contains(key)));
        expect(e.message, contains('gateway'));
      }
    });

    test('Gemini: the fall-through 4xx message is cleaned as well', () async {
      const key = 'AIzaSyREALKEY0123456789abcdef';
      final p = GeminiProvider(
        MockClient(
          (_) async => _json({
            'error': {
              'message': 'Bad value near $key in request',
              'status': 'INVALID_ARGUMENT',
            },
          }, 400),
        ),
        apiKey: key,
      );
      try {
        await p.generate('m', req());
        fail('should have thrown');
      } on LlmBadResponse catch (e) {
        expect(e.message, isNot(contains(key)));
        expect(e.message, contains('Bad value'));
      }
    });

    test(
      'Gemini: a 503 is a retryable network error with its status',
      () async {
        final p = GeminiProvider(
          MockClient(
            (_) async => _json({
              'error': {'message': 'overloaded'},
            }, 503),
          ),
          apiKey: 'AIzaSy-SECRET-KEY-123',
        );
        try {
          await p.generate('m', req());
          fail('should have thrown');
        } on LlmNetwork catch (e) {
          expect(e.status, 503);
          expect(e.retryable, isTrue);
        }
      },
    );
  });

  group('presets of the catalog', () {
    Future<Map<String, Object?>> bodyOf(String id, {String model = 'm'}) async {
      late Map<String, Object?> body;
      await buildProvider(
        LlmConfig(
          provider: id,
          apiKey: 'k',
          baseUrl: id == 'custom' ? 'https://api.example.com/v1' : null,
        ),
        MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, Object?>;
          return id == 'gemini'
              ? _json({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'ok'},
                        ],
                      },
                      'finishReason': 'STOP',
                    },
                  ],
                })
              : _json(ok());
        }),
      ).generate(model, req());
      return body;
    }

    test('Groq keeps the small cap (8 000 tokens a minute), the others are roomier', () async {
      expect((await bodyOf('groq'))['max_tokens'], 2048);
      expect((await bodyOf('mistral'))['max_tokens'], 4096);
      expect((await bodyOf('openrouter'))['max_tokens'], 4096);
      expect((await bodyOf('custom'))['max_tokens'], 4096);
      final openai = await bodyOf('openai');
      expect(openai['max_completion_tokens'], 4096);
      expect(openai.containsKey('max_tokens'), isFalse);
    });

    test('planning runs cold: low temperature everywhere', () async {
      for (final id in ['groq', 'mistral', 'openrouter', 'openai', 'custom']) {
        expect((await bodyOf(id))['temperature'], 0.2, reason: id);
      }
      final g = (await bodyOf('gemini'))['generationConfig'] as Map;
      expect(g['temperature'], 0.2);
      expect(g['maxOutputTokens'], 4096);
    });

    test('presets are data of the catalog, one place', () {
      expect(providerById('groq').maxOutput, 2048);
      expect(providerById('groq').reasoningEffort, 'low');
      expect(
        providerById('groq').reasoningModels!.hasMatch('openai/gpt-oss-20b'),
        isTrue,
      );
      expect(
        providerById('groq').reasoningModels!.hasMatch('llama-3.3-70b'),
        isFalse,
      );
      expect(providerById('mistral').reasoningEffort, isNull);
    });
  });

  group('a model that is gone (AI-24)', () {
    Future<Object?> failure(Future<Object?> call) async {
      try {
        await call;
        return null;
      } on LlmException catch (e) {
        return e;
      }
    }

    test('model_not_found (OpenAI, Groq) is "gone", not a bad request', () async {
      final p = openai(
        (_) async => _json(
          err(
            'The model `gpt-9` does not exist or you do not have access to it.',
            code: 'model_not_found',
          ),
          404,
        ),
      );
      await expectLater(
        p.generate('m', req()),
        throwsA(
          isA<LlmModelGone>().having(
            (e) => e.message,
            'message',
            allOf(contains('Válassz másik modellt'), contains('gpt-9')),
          ),
        ),
      );
    });

    test('a decommissioned model (Groq) is gone', () async {
      final p = openai(
        (_) async => _json(
          err(
            'The model `llama3-70b-8192` has been decommissioned and is no longer supported. Please refer to https://console.groq.com/docs/deprecations for a recommendation on which model to use instead.',
            code: 'model_decommissioned',
          ),
          400,
        ),
      );
      await expectLater(p.generate('m', req()), throwsA(isA<LlmModelGone>()));
    });

    test(
      'the words are enough when the service sends no code (OpenRouter)',
      () async {
        final p = openai(
          (_) async => _json(
            err(
              'No endpoints found for meta-llama/llama-3.3-70b-instruct:free.',
            ),
            404,
          ),
        );
        await expectLater(p.generate('m', req()), throwsA(isA<LlmModelGone>()));
      },
    );

    // every sign of a model that is gone, one by one: a mutant that drops one
    // of them must show
    for (final c in <(String, int, String, String?)>[
      ('does not exist (404)', 404, 'The model `gpt-9` does not exist.', null),
      ('does not exist (400)', 400, 'The model `gpt-9` does not exist.', null),
      ('does not exist (410)', 410, 'The model `gpt-9` does not exist.', null),
      ('not found', 404, 'Model gpt-9 not found.', null),
      ('deprecated', 404, 'The model `gpt-9` is deprecated.', null),
      (
        'decommissioned',
        400,
        'The model `gpt-9` has been decommissioned.',
        null,
      ),
      ('no longer available', 404, 'This model is no longer available.', null),
      ('no longer supported', 404, 'The model is no longer supported.', null),
      ('no endpoints found', 404, 'No endpoints found for x/y:free.', null),
      ('the code model_not_found alone', 404, 'Nope.', 'model_not_found'),
      (
        'the code model_decommissioned alone',
        400,
        'Nope.',
        'model_decommissioned',
      ),
    ]) {
      test('a sign of a model that is gone: ${c.$1}', () async {
        final p = openai((_) async => _json(err(c.$3, code: c.$4), c.$2));
        await expectLater(p.generate('m', req()), throwsA(isA<LlmModelGone>()));
      });
    }

    for (final c in <(String, int, String)>[
      (
        'the words, but not at the usual statuses',
        422,
        'The model `gpt-9` does not exist.',
      ),
      (
        'a tool that was not found in what the model wrote',
        400,
        'The function `get_weather` was not found in the model output.',
      ),
    ]) {
      test('not a model that is gone: ${c.$1}', () async {
        final p = openai((_) async => _json(err(c.$3), c.$2));
        final e = await failure(p.generate('m', req()));
        expect(e, isA<LlmBadResponse>());
        expect(e, isNot(isA<LlmModelGone>()));
      });
    }

    test('a 404 about something else stays a plain bad response', () async {
      final p = openai((_) async => http.Response('Not Found', 404));
      final e = await failure(p.generate('m', req()));
      expect(e, isA<LlmBadResponse>());
      expect(e, isNot(isA<LlmModelGone>()));
    });

    test('a rate limit that names the model stays a rate limit', () async {
      final p = openai(
        (_) async => _json(
          err(
            'Rate limit reached for model `llama-3.3-70b-versatile` on tokens per day (TPD): Limit 100000, Used 99000, Requested 2000. Please try again in 14m.',
            type: 'tokens',
            code: 'rate_limit_exceeded',
          ),
          429,
        ),
      );
      final e = await failure(p.generate('m', req()));
      expect(e, isA<LlmRateLimit>().having((r) => r.daily, 'daily', isTrue));
    });

    test('the key is not in the message', () async {
      final p = openai(
        (_) async => _json(
          err('The model `$secret` does not exist.', code: 'model_not_found'),
          404,
        ),
      );
      final e = await failure(p.generate('m', req())) as LlmModelGone;
      expect(e.message, isNot(contains(secret)));
    });

    test('Gemini: 404 for the model is gone, another 400 is not', () async {
      GeminiProvider gemini(int status, Map<String, Object?> body) =>
          GeminiProvider(
            MockClient((_) async => _json(body, status)),
            apiKey: 'AIzaSy-SECRET-KEY-123',
          );
      final gone = await failure(
        gemini(404, {
          'error': {
            'code': 404,
            'message': 'models/gemini-1.5-flash is not found for API version v1beta, or is not supported for generateContent.',
            'status': 'NOT_FOUND',
          },
        }).generate('m', req()),
      );
      expect(gone, isA<LlmModelGone>());
      final other = await failure(
        gemini(400, {
          'error': {
            'code': 400,
            'message': 'Request contains an invalid argument.',
            'status': 'INVALID_ARGUMENT',
          },
        }).generate('m', req()),
      );
      expect(other, isA<LlmBadResponse>());
      expect(other, isNot(isA<LlmModelGone>()));
    });
  });

  group('a Gemini model that is gone: the status and the words each do', () {
    Future<Object?> failureOf(http.Response r) async {
      try {
        await GeminiProvider(
          MockClient((_) async => r),
          apiKey: 'AIzaSy-SECRET-KEY-123',
        ).generate('m', req());
        return null;
      } on LlmException catch (e) {
        return e;
      }
    }

    test('a 404 that says nothing else', () async {
      expect(
        await failureOf(http.Response('Not Found', 404)),
        isA<LlmModelGone>(),
      );
    });

    test('NOT_FOUND in the body of another status', () async {
      expect(
        await failureOf(
          _json({
            'error': {'code': 400, 'message': 'x', 'status': 'NOT_FOUND'},
          }, 400),
        ),
        isA<LlmModelGone>(),
      );
    });
  });

  group('fallbackModelsFor: another model of the same provider', () {
    List<LlmModel> ms(List<String> ids) => [
      for (final i in ids) LlmModel(i, i),
    ];

    test('Groq: the preferences in order, never the failed one, no guards or speech', () {
      final r = fallbackModelsFor(
        'groq',
        ms([
          'llama-3.3-70b-versatile',
          'llama-3.1-8b-instant',
          'openai/gpt-oss-120b',
          'openai/gpt-oss-20b',
          'whisper-large-v3',
          'llama-guard-4-12b',
          'openai/gpt-oss-safeguard-20b',
        ]),
        'llama-3.3-70b-versatile',
      );
      expect(r, [
        'openai/gpt-oss-20b',
        'openai/gpt-oss-120b',
        'llama-3.1-8b-instant',
      ]);
    });

    test('at most three, without duplicates', () {
      final r = fallbackModelsFor(
        'groq',
        ms([
          'a-llama-1',
          'b-llama-2',
          'c-llama-3',
          'd-llama-4',
          'llama-3.3-70b-x',
        ]),
        'zzz',
      );
      expect(r, ['llama-3.3-70b-x', 'd-llama-4', 'c-llama-3']);
    });

    test('nothing when the failed model is the only one', () {
      expect(
        fallbackModelsFor(
          'groq',
          ms(['llama-3.3-70b-versatile']),
          'llama-3.3-70b-versatile',
        ),
        isEmpty,
      );
      expect(fallbackModelsFor('groq', const [], 'x'), isEmpty);
    });

    test(
      'OpenRouter: the free ones the preferences name, not the paid ones',
      () {
        final r = fallbackModelsFor(
          'openrouter',
          ms([
            'meta-llama/llama-3.3-70b-instruct:free',
            'google/gemma-2-9b-it:free',
            'openai/gpt-4o-mini',
            'mistralai/mistral-7b-instruct:free',
          ]),
          'google/gemma-2-9b-it:free',
        );
        expect(r, [
          'meta-llama/llama-3.3-70b-instruct:free',
          'mistralai/mistral-7b-instruct:free',
        ]);
      },
    );

    test(
      'Gemini keeps its own list, an address of the user\'s own has none',
      () {
        expect(
          fallbackModelsFor(
            'gemini',
            ms(['gemini-2.5-flash', 'gemini-2.5-flash-lite']),
            'gemini-2.5-flash',
          ),
          ['gemini-2.5-flash-lite'],
        );
        expect(fallbackModelsFor('custom', ms(['a', 'b']), 'a'), isEmpty);
      },
    );
  });
}
