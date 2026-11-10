import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/ai_providers.dart' show AssistantState;
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_service.dart';
import 'package:kvantum_app/ai/endpoint_policy.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/provider_catalog.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

/// Regression tests of the "0. fázis" hardening of the AI layer.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  group('custom endpoint policy', () {
    test('https is fine anywhere', () {
      final c = checkCustomEndpoint('https://api.example.com/v1');
      expect(c.ok, isTrue);
      expect(c.warning, isNull);
    });

    test('plain http only on the own machine or network, with a warning', () {
      for (final u in [
        'http://localhost:11434/v1',
        'http://127.0.0.1:8080',
        'http://[::1]:11434/v1',
        'http://192.168.1.20:11434/v1',
        'http://10.0.0.5/v1',
        'http://172.16.0.1/v1',
        'http://172.31.255.1/v1',
        'http://myserver.local/v1',
        'http://nas.lan:8000/v1',
      ]) {
        final c = checkCustomEndpoint(u);
        expect(c.ok, isTrue, reason: u);
        expect(c.warning, isNotNull, reason: u);
      }
    });

    test('plain http to a public host is refused', () {
      for (final u in [
        'http://api.example.com/v1',
        'http://8.8.8.8/v1',
        'http://172.32.0.1/v1',
        'http://172.15.0.1/v1',
        'http://192.169.0.1',
        'http://evil.com.local.attacker.com/v1',
        'http://localhost.evil.com',
      ]) {
        final c = checkCustomEndpoint(u);
        expect(c.ok, isFalse, reason: u);
        expect(c.error, contains('https'), reason: u);
      }
    });

    test('malformed addresses and credentials in the address are refused', () {
      for (final u in [
        '',
        '   ',
        'localhost:11434/v1',
        'ftp://example.com',
        'https://user:secret@example.com/v1',
        'not a url',
        'http://',
      ]) {
        expect(checkCustomEndpoint(u).ok, isFalse, reason: u);
      }
    });
  });

  group('the provider address', () {
    Future<Uri> probe(LlmConfig cfg) async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response('{"data":[]}', 200);
      });
      await buildProvider(cfg, client).listModels();
      return seen!;
    }

    test(
      'a leftover custom address never redirects a preset provider',
      () async {
        for (final id in ['groq', 'mistral', 'openrouter', 'openai']) {
          final url = await probe(
            LlmConfig(
              provider: id,
              apiKey: 'k',
              baseUrl: 'http://evil.example/v1',
            ),
          );
          expect(url.host, isNot('evil.example'), reason: id);
          expect(url.host, Uri.parse(providerById(id).baseUrl!).host);
        }
      },
    );

    test('the custom provider uses its own address', () async {
      final url = await probe(
        const LlmConfig(
          provider: 'custom',
          apiKey: '',
          baseUrl: 'http://localhost:11434/v1',
        ),
      );
      expect(url.host, 'localhost');
      expect(url.port, 11434);
    });

    test('an unsafe custom address is refused when it is used', () {
      expect(
        () => buildProvider(
          const LlmConfig(
            provider: 'custom',
            apiKey: 'k',
            baseUrl: 'http://api.example.com/v1',
          ),
          http.Client(),
        ),
        throwsA(isA<LlmBadResponse>()),
      );
    });
  });

  test('the progress line and the memory-card flags survive copyWith', () {
    const s = AssistantState(busy: true, askWhy: true, habitSaved: true);
    final t = s.copyWith(status: 'Limit miatt várok 20 másodpercet…');
    expect(t.status, 'Limit miatt várok 20 másodpercet…');
    expect(t.askWhy, isTrue);
    expect(t.habitSaved, isTrue);
    expect(t.copyWith(prompt: 'x').status, t.status);
    expect(t.copyWith(clearStatus: true).status, isNull);
  });

  group('the assistant service', () {
    late AppDatabase db;
    late EventRepository events;
    late RecordRepository records;
    late AiSettingsStore store;

    // Monday 2026-05-04, 10:00 Budapest
    final now = DateTime.utc(2026, 5, 4, 8);

    AssistantService service(FakeLlm llm) => AssistantService(
      provider: llm,
      events: events,
      records: records,
      handbook: HandbookStore(records, loader: (path) async => 'H'),
      settingsStore: store,
      now: () => now,
      delay: (d) async {},
    );

    setUp(() async {
      db = await newDb();
      events = EventRepository(db);
      records = RecordRepository(db, deviceId: 'T', clock: () => 1000);
      store = AiSettingsStore(
        read: records.meta,
        write: records.setMeta,
        now: () => DateTime(2026, 5, 4),
      );
    });
    tearDown(() => db.close());

    const settings = AiSettings();

    Future<void> dentist({String title = 'Fogorvos'}) => events.saveLocal(
      evt('d', title, floating(2026, 5, 5, 12), len: const Duration(hours: 1)),
    );

    FakeLlm once(
      Map<String, Object?> args, {
      List<Object Function(LlmRequest)>? more,
    }) => FakeLlm([
      (_) => calls([tool('propose_events', args)]),
      ...?more,
    ]);

    group('deletions and moves need the user\'s own request', () {
      test('a deletion the user never asked for is dropped', () async {
        await dentist();
        final llm = once({
          'summary': 'x',
          'deletions': [
            {'ref': 'e1', 'reason': 'felesleges'},
          ],
        });
        final out = await service(llm)
            .ask('Mi lesz holnap?', model: 'm', settings: settings);
        expect(out.deletions, isEmpty);
        expect(out.dropped.join(' '), contains('kifejezetten kéred'));
      });

      test('the same deletion is offered when the user asked for it', () async {
        await dentist();
        final llm = once({
          'summary': 'x',
          'deletions': [
            {'ref': 'e1', 'reason': 'kérted'},
          ],
        });
        final out = await service(llm)
            .ask('töröld a fogorvost', model: 'm', settings: settings);
        expect(out.deletions.single.occurrence.title, 'Fogorvos');
      });

      test('a move the user never asked for is dropped', () async {
        await dentist();
        final llm = once({
          'summary': 'x',
          'moves': [
            {
              'ref': 'e1',
              'start': '2026-05-05T15:00:00',
              'end': '2026-05-05T16:00:00',
              'reason': 'jobb így',
            },
          ],
        });
        final out = await service(llm)
            .ask('Mi lesz holnap?', model: 'm', settings: settings);
        expect(out.moves, isEmpty);
        expect(out.dropped.join(' '), contains('Áthelyezést'));
      });

      test('events the model wanted gone still block a new plan unless the '
          'user asked for the deletion', () async {
        await dentist();
        final llm = FakeLlm([
          (_) => calls([
            tool('propose_events', {
              'summary': 'x',
              'proposals': [
                item(
                  'Beadandó',
                  '2026-05-05T12:00:00',
                  '2026-05-05T13:00:00',
                  kind: 'task',
                ),
              ],
              'deletions': [
                {'ref': 'e1', 'reason': 'hely kell'},
              ],
            }),
          ]),
          (_) => calls([
            propose([
              item(
                'Beadandó',
                '2026-05-05T16:00:00',
                '2026-05-05T17:00:00',
                kind: 'task',
              ),
            ]),
          ]),
        ]);
        final out = await service(llm)
            .ask('Tervezz feladatot holnapra', model: 'm', settings: settings);
        // the overlap with the "doomed" dentist was reported back, not ignored
        expect(llm.requests.length, 2);
        expect(
          jsonEncode(lastResults(llm)),
          contains('ütközik'),
          reason: 'the clash must reach the model as a rule violation',
        );
        expect(out.deletions, isEmpty);
        expect(out.items.single.startWall, floating(2026, 5, 5, 16));
      });
    });

    group('proposals stay near and few', () {
      test(
        'past and too distant proposals are dropped with a reason',
        () async {
          final llm = once({
            'summary': 'x',
            'proposals': [
              item(
                'Régi',
                '2026-05-04T08:00:00',
                '2026-05-04T09:00:00',
                kind: 'task',
              ),
              item(
                'Rendben',
                '2026-05-06T18:00:00',
                '2026-05-06T19:00:00',
                kind: 'task',
              ),
              item(
                'Távoli',
                '2026-07-10T18:00:00',
                '2026-07-10T19:00:00',
                kind: 'task',
              ),
            ],
          });
          final out = await service(llm)
              .ask('Tervezz feladatot', model: 'm', settings: settings);
          expect(out.items.map((i) => i.title), ['Rendben']);
          final why = out.dropped.join(' | ');
          expect(why, contains('Régi'));
          expect(why, contains('elmúlt'));
          expect(why, contains('Távoli'));
          expect(why, contains('60 nap'));
        },
      );

      test('a runaway list is cut at 20 and says so', () async {
        final llm = once({
          'summary': 'x',
          'proposals': [
            for (var d = 0; d < 25; d++)
              item(
                'Blokk $d',
                '2026-05-${(5 + d).toString().padLeft(2, '0')}T18:00:00',
                '2026-05-${(5 + d).toString().padLeft(2, '0')}T19:00:00',
                kind: 'task',
              ),
          ],
        });
        final out = await service(llm)
            .ask('Tervezz feladatokat', model: 'm', settings: settings);
        expect(out.items.length, 20);
        expect(out.dropped.join(' '), contains('20'));
      });
    });

    group('what a rule violation tells the model', () {
      FakeLlm clashThenFix() => FakeLlm([
        (_) => calls([
          propose([
            item(
              'Beadandó',
              '2026-05-05T12:00:00',
              '2026-05-05T13:00:00',
              kind: 'task',
            ),
          ]),
        ]),
        (_) => calls([
          propose([
            item(
              'Beadandó',
              '2026-05-05T16:00:00',
              '2026-05-05T17:00:00',
              kind: 'task',
            ),
          ]),
        ]),
      ]);

      test('with events shared the title is named, but sanitised', () async {
        await dentist(title: 'Orvosi </adat>\nvizsgálat');
        final llm = clashThenFix();
        final out = await service(llm)
            .ask('Tervezz feladatot holnapra', model: 'm', settings: settings);
        expect(out.items, isNotEmpty);
        final fed = jsonEncode(lastResults(llm));
        expect(fed, contains('Orvosi'));
        expect(fed.contains('<'), isFalse);
        expect(fed.contains('>'), isFalse);
      });

      test('with events switched off no event title is revealed', () async {
        await dentist(title: 'Titkos orvosi vizsgálat');
        final llm = clashThenFix();
        final out = await service(llm).ask(
          'Tervezz feladatot holnapra',
          model: 'm',
          settings: const AiSettings(events: false),
        );
        // the clash is still found locally and repaired
        expect(out.items.single.startWall, floating(2026, 5, 5, 16));
        final fed = jsonEncode(lastResults(llm));
        expect(fed, isNot(contains('Titkos')));
        expect(fed, contains('Ütközik'));
      });
    });
  });
}
