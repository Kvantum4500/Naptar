import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/openai_provider.dart';
import 'package:kvantum_app/ai/provider_catalog.dart';

const secret = 'gsk_SECRET1234567890abcdef';

http.Response _json(
  Object body, [
  int status = 200,
  Map<String, String> headers = const {},
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...headers},
);

OpenAiProvider provider(
  MockClientHandler h, {
  String base = 'https://api.example.com/v1/',
}) => OpenAiProvider(MockClient(h), apiKey: secret, baseUrl: base);

LlmRequest request({List<LlmTurn>? turns, List<ToolDecl> tools = const []}) =>
    LlmRequest(
      system: 'Rendszer',
      turns:
          turns ??
          const [
            LlmTurn('user', [LlmText('Tervezz')]),
          ],
      tools: tools,
    );

Map<String, Object?> okText(String t) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': t},
      'finish_reason': 'stop',
    },
  ],
  'usage': {'prompt_tokens': 50, 'completion_tokens': 9},
};

void main() {
  group('request shape', () {
    test('endpoint, bearer header (never in the URL), system + user messages, tools in function format', () async {
      late http.Request seen;
      await provider((r) async {
        seen = r;
        return _json(okText('Szia'));
      }).generate(
        'llama-x',
        request(
          tools: const [
            ToolDecl('get_tasks', 'Feladatok', {
              'type': 'object',
              'properties': {},
            }),
          ],
        ),
      );
      expect(
        seen.url.toString(),
        'https://api.example.com/v1/chat/completions',
      ); // trailing slash handled
      expect(seen.headers['Authorization'], 'Bearer $secret');
      expect(seen.url.toString().contains(secret), isFalse);
      expect(seen.body.contains(secret), isFalse);
      final b = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(b['model'], 'llama-x');
      expect(b['messages'][0], {'role': 'system', 'content': 'Rendszer'});
      expect(b['messages'][1], {'role': 'user', 'content': 'Tervezz'});
      expect(b['tools'][0], {
        'type': 'function',
        'function': {
          'name': 'get_tasks',
          'description': 'Feladatok',
          'parameters': {'type': 'object', 'properties': {}},
        },
      });
      expect(b['tool_choice'], 'auto');
    });

    test('no key (local server) sends no Authorization header; no tools -> no tool fields', () async {
      late http.Request seen;
      await OpenAiProvider(
        MockClient((r) async {
          seen = r;
          return _json(okText('x'));
        }),
        apiKey: '',
        baseUrl: 'http://localhost:11434/v1',
      ).generate('m', request());
      expect(seen.headers.containsKey('Authorization'), isFalse);
      final b = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(b.containsKey('tools'), isFalse);
    });

    test('tool calls and results: assistant tool_calls with ids, one tool message per result', () async {
      late Map<String, dynamic> b;
      await provider((r) async {
        b = jsonDecode(r.body) as Map<String, dynamic>;
        return _json(okText('kész'));
      }).generate(
        'm',
        request(
          turns: const [
            LlmTurn('user', [LlmText('kérés')]),
            LlmTurn('model', [
              LlmToolCall('get_tasks', {}, id: 'call_a'),
              LlmToolCall('find_free_slots', {'minutes': 60}, id: 'call_b'),
            ]),
            LlmTurn('user', [
              LlmToolResult('get_tasks', {'darab': 1}, id: 'call_a'),
              LlmToolResult('find_free_slots', {'darab': 2}, id: 'call_b'),
            ]),
          ],
        ),
      );
      final msgs = b['messages'] as List;
      expect(msgs[2]['role'], 'assistant');
      expect(msgs[2]['content'], isNull);
      expect(msgs[2]['tool_calls'][0]['id'], 'call_a');
      expect(msgs[2]['tool_calls'][1]['function']['name'], 'find_free_slots');
      expect(jsonDecode(msgs[2]['tool_calls'][1]['function']['arguments']), {
        'minutes': 60,
      });
      expect(msgs[3], {
        'role': 'tool',
        'tool_call_id': 'call_a',
        'content': '{"darab":1}',
      });
      expect(msgs[4]['tool_call_id'], 'call_b');
    });
  });

  group('reply parsing', () {
    test('text with usage', () async {
      final r = await provider((_) async => _json(okText('Szia!')))
          .generate('m', request());
      expect(r.text, 'Szia!');
      expect((r.promptTokens, r.outputTokens), (50, 9));
    });

    test('tool calls: ids, name, JSON-string arguments', () async {
      final r = await provider(
        (_) async => _json({
          'choices': [
            {
              'message': {
                'content': null,
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'propose_events',
                      'arguments': '{"proposals":[{"title":"Futás"}]}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      ).generate('m', request());
      final c = r.toolCalls.single;
      expect((c.name, c.id), ('propose_events', 'call_1'));
      expect((c.args['proposals'] as List).single['title'], 'Futás');
    });

    test(
      'malformed argument strings become empty arguments instead of crashing',
      () async {
        final r = await provider(
          (_) async => _json({
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    {
                      'id': 'c',
                      'function': {
                        'name': 'get_tasks',
                        'arguments': '{nem json',
                      },
                    },
                  ],
                },
              },
            ],
          }),
        ).generate('m', request());
        expect(r.toolCalls.single.args, isEmpty);
      },
    );

    test(
      'empty, filtered and malformed replies become readable errors',
      () async {
        for (final body in <Object>[
          {'choices': []},
          {
            'choices': [
              {
                'message': {'content': ''},
                'finish_reason': 'length',
              },
            ],
          },
          {
            'choices': [
              {'message': {}, 'finish_reason': 'content_filter'},
            ],
          },
        ]) {
          await expectLater(
            provider((_) async => _json(body)).generate('m', request()),
            throwsA(isA<LlmBadResponse>()),
          );
        }
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

    test('401/403 -> auth', () async {
      expect(
        await status(401, {
          'error': {'message': 'Invalid API Key'},
        }),
        isA<LlmAuth>(),
      );
      expect(await status(403), isA<LlmAuth>());
    });

    test('429 per-minute: transient with the retry-after hint', () async {
      final e = await status(
        429,
        {
          'error': {'message': 'Rate limit reached for requests per minute'},
        },
        {'retry-after': '12'},
      ) as LlmRateLimit;
      expect(e.transient, isTrue);
      expect(e.retryAfter, const Duration(seconds: 12));
    });

    test(
      'a per-minute token limit that mentions billing is still just a wait',
      () async {
        final e = await status(429, {
          'error': {
            'message': 'Rate limit reached for model `openai/gpt-oss-20b` on tokens per minute (TPM): Limit 8000, Used 5206, Requested 5313. Please try again in 18.8925s. Need more tokens? Upgrade to Dev Tier today at https://console.groq.com/settings/billing',
          },
        }) as LlmRateLimit;
        expect(e.billing, isFalse);
        expect(e.transient, isTrue);
        expect(e.retryAfter, const Duration(seconds: 19));
      },
    );

    test('millisecond hints are read too', () async {
      final e = await status(429, {
        'error': {
          'message':
              'Rate limit on requests per minute. Please try again in 250ms.',
        },
      }) as LlmRateLimit;
      expect(e.retryAfter, const Duration(seconds: 1));
    });

    test('429 daily quota is recognised and not transient', () async {
      final e = await status(429, {
        'error': {
          'message':
              'Rate limit reached for tokens per day (TPD): Limit 100000',
        },
      }) as LlmRateLimit;
      expect(e.daily, isTrue);
      expect(e.transient, isFalse);
    });

    test('no balance / billing (402 or insufficient_quota) is a billing problem, not a rate problem', () async {
      final a = await status(402, {
        'error': {'message': 'Payment required'},
      }) as LlmRateLimit;
      expect(a.billing, isTrue);
      final b = await status(429, {
        'error': {
          'type': 'insufficient_quota',
          'message': 'You exceeded your current quota, please check your plan and billing details.',
        },
      }) as LlmRateLimit;
      expect(b.billing, isTrue);
      expect(b.transient, isFalse);
    });

    test('5xx -> network; 400 shows the service message; keys never leak into messages', () async {
      expect(await status(503), isA<LlmNetwork>());
      final e = await status(400, {
        'error': {'message': 'model does not support tools. key $secret'},
      });
      expect(e, isA<LlmBadResponse>());
      expect(e.message, contains('does not support tools'));
      expect(e.message.contains('gsk_'), isFalse);
      await expectLater(
        provider((_) async => throw const SocketException('no net'))
            .generate('m', request()),
        throwsA(isA<LlmNetwork>()),
      );
    });
  });

  group('models', () {
    test('lists chat models only; drops embeddings/audio/moderation and inactive ones', () async {
      late http.Request seen;
      final list = await provider((r) async {
        seen = r;
        return _json({
          'data': [
            {'id': 'llama-3.3-70b-versatile', 'active': true},
            {'id': 'whisper-large-v3'},
            {'id': 'text-embedding-3-small'},
            {'id': 'old-model', 'active': false},
            {'id': 'mistral-small-latest'},
            {'id': 'omni-moderation-latest'},
          ],
        });
      }).listModels();
      expect(list.map((m) => m.id), [
        'llama-3.3-70b-versatile',
        'mistral-small-latest',
      ]);
      expect(seen.url.path, '/v1/models');
      expect(seen.headers['Authorization'], 'Bearer $secret');
    });

    test('a wrong key surfaces as an auth error', () async {
      await expectLater(
        provider(
          (_) async => _json({
            'error': {'message': 'Invalid API Key'},
          }, 401),
        ).listModels(),
        throwsA(isA<LlmAuth>()),
      );
    });
  });

  group('catalog', () {
    LlmModel m(String id) => LlmModel(id, id);

    test('every provider is selectable; ids are unique; known base URLs', () {
      expect(kProviders.map((p) => p.id).toSet().length, kProviders.length);
      expect(providerById('groq').baseUrl, 'https://api.groq.com/openai/v1');
      expect(providerById('mistral').baseUrl, 'https://api.mistral.ai/v1');
      expect(
        providerById('nincs-ilyen').id,
        'gemini',
      ); // unknown ids fall back safely
    });

    test(
      'default model per provider follows the preferences, else the first one',
      () {
        expect(
          pickModelFor('groq', [
            m('gemma2-9b-it'),
            m('llama-3.1-8b-instant'),
            m('llama-3.3-70b-versatile'),
          ]),
          'llama-3.3-70b-versatile',
        );
        expect(
          pickModelFor('mistral', [
            m('mistral-large-latest'),
            m('mistral-small-latest'),
          ]),
          'mistral-small-latest',
        );
        expect(
          pickModelFor('openai', [m('gpt-4o'), m('gpt-4o-mini')]),
          'gpt-4o-mini',
        );
        expect(
          pickModelFor('openrouter', [m('a/b'), m('x/y:free')]),
          'x/y:free',
        );
        expect(pickModelFor('custom', [m('qwen3'), m('llama3')]), 'qwen3');
        expect(
          pickModelFor('gemini', [m('gemini-2.5-flash'), m('gemini-2.5-pro')]),
          'gemini-2.5-flash',
        );
        expect(pickModelFor('groq', []), isNull);
      },
    );

    test(
      'buildProvider: right class per provider; custom needs an address',
      () {
        final c = http.Client();
        expect(
          buildProvider(const LlmConfig(provider: 'groq', apiKey: 'k'), c),
          isA<OpenAiProvider>(),
        );
        expect(
          buildProvider(
            const LlmConfig(
              provider: 'custom',
              apiKey: '',
              baseUrl: 'http://localhost:11434/v1',
            ),
            c,
          ),
          isA<OpenAiProvider>(),
        );
        expect(
          () =>
              buildProvider(const LlmConfig(provider: 'custom', apiKey: ''), c),
          throwsA(isA<LlmBadResponse>()),
        );
      },
    );
  });
}
