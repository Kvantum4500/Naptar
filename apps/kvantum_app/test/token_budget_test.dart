import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_service.dart';
import 'package:kvantum_app/ai/handbook_legacy.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/weather_service.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

/// The size of what the assistant sends, measured on a fixed sample calendar
/// with the REAL bundled handbook. The free tiers allow few tokens per minute
/// (Groq: 8 000), so a request that grows back is a bug. The estimate is
/// deliberately pessimistic: 3 characters per token for everything (Hungarian
/// text is about 3.0, JSON about 3.4).
const _charsPerToken = 3.0;

int _tokens(int chars) => (chars / _charsPerToken).ceil();

/// What one model call carries: system prompt + tool declarations + messages.
class _Size {
  _Size(LlmRequest r)
    : system = _tokens(r.system.length),
      tools = _tokens(
        jsonEncode([
          for (final t in r.tools)
            {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
        ]).length,
      ),
      messages = _tokens(
        r.turns
            .expand((t) => t.parts)
            .map(
              (p) => switch (p) {
                LlmText(:final text) => text.length,
                LlmToolResult(:final result) => jsonEncode(result).length,
                _ => 0,
              },
            )
            .fold(0, (a, b) => a + b),
      );
  final int system;
  final int tools;
  final int messages;

  /// The part that is the same for every request of a kind.
  int get fixed => system + tools;
  int get total => system + tools + messages;

  @override
  String toString() =>
      'összesen ≈ $total token (rendszerprompt $system, eszközök $tools, üzenet $messages)';
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late FinanceRepository fin;
  late AiSettingsStore store;

  // Monday 2026-05-04, 10:00 Budapest
  final now = DateTime.utc(2026, 5, 4, 8);
  final budapest = Place(name: 'Budapest', lat: 47.5, lon: 19.04);

  Map<String, Object?> forecast() => {
    'daily': {
      'time': [
        for (var i = 0; i < 14; i++)
          DateTime.utc(2026, 5, 4 + i).toIso8601String().substring(0, 10),
      ],
      'temperature_2m_max': [for (var i = 0; i < 14; i++) 17.0 + i % 4],
      'temperature_2m_min': [for (var i = 0; i < 14; i++) 8.0 + i % 3],
      'precipitation_sum': [
        for (var i = 0; i < 14; i++) i % 5 == 1 ? 7.0 : 0.0,
      ],
      'precipitation_probability_max': [
        for (var i = 0; i < 14; i++) i % 5 == 1 ? 85 : 10,
      ],
      'wind_speed_10m_max': [for (var i = 0; i < 14; i++) 10.0 + i % 6],
      'weather_code': [for (var i = 0; i < 14; i++) i % 5 == 1 ? 63 : 1],
    },
  };

  AssistantService service(FakeLlm llm, {DateTime? at}) => AssistantService(
    provider: llm,
    events: events,
    records: records,
    handbook: HandbookStore(
      records,
      loader: (path) => File(path).readAsString(),
    ),
    settingsStore: store,
    now: () => at ?? now,
    delay: (d) async {},
    finance: fin,
    weather: WeatherService(
      MockClient(
        (_) async => http.Response(
          jsonEncode(forecast()),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    ),
  );

  Future<CalEvent> shift(
    String id,
    String title,
    DateTime s,
    DateTime e,
  ) async {
    final ev = evt(
      id,
      title,
      s,
      len: e.difference(s),
    ).copyWith(notes: kShiftMarker);
    await events.saveLocal(ev);
    return ev;
  }

  /// A busy but ordinary fortnight: 14 events (3 shifts, 4 earlier assistant
  /// suggestions, 6 typed in, 1 all-day), 6 open tasks, 5 check-ins, a place.
  setUp(() async {
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db, deviceId: 'T', clock: () => 1000);
    fin = FinanceRepository(db, clock: () => 1000);
    await fin.ensureDefaults();
    store = AiSettingsStore(
      read: records.meta,
      write: records.setMeta,
      now: () => DateTime(2026, 5, 4),
    );

    await shift(
      's1',
      'Éjszakás műszak',
      floating(2026, 5, 7, 18),
      floating(2026, 5, 8, 6),
    );
    await shift(
      's2',
      'Éjszakás műszak',
      floating(2026, 5, 8, 18),
      floating(2026, 5, 9, 6),
    );
    await shift(
      's3',
      'Nappali műszak',
      floating(2026, 5, 13, 6),
      floating(2026, 5, 13, 18),
    );
    for (final (id, title, start, mins) in [
      ('h1', 'Fogorvos', floating(2026, 5, 5, 12), 60),
      ('h2', 'Megbeszélés a főnökkel', floating(2026, 5, 6, 9), 60),
      ('h3', 'Vacsora a szülőkkel', floating(2026, 5, 9, 18), 120),
      ('h4', 'Autószerviz', floating(2026, 5, 12, 8), 120),
      ('h5', 'Bevásárlás', floating(2026, 5, 10, 10), 60),
      ('h6', 'Haverokkal kajak', floating(2026, 5, 16, 9), 180),
    ]) {
      await events.saveLocal(
        evt(id, title, start, len: Duration(minutes: mins)),
      );
    }
    for (final (id, title, start) in [
      ('a1', 'Calisthenics 45 perc', floating(2026, 5, 4, 18)),
      ('a2', 'Gym 60 perc', floating(2026, 5, 6, 18)),
      ('a3', 'Street Workout 45 perc', floating(2026, 5, 11, 17)),
      ('a4', 'Könnyű nyújtás', floating(2026, 5, 12, 19)),
    ]) {
      await events.saveLocal(evt(id, title, start).copyWith(aiGenerated: true));
    }
    await events.saveLocal(
      evt(
        'd1',
        'Munkaszüneti nap',
        floating(2026, 5, 14),
        len: const Duration(days: 1),
        allDay: true,
      ),
    );

    for (final (id, title, due, est) in [
      ('k1', 'Adóbevallás beadása', floating(2026, 5, 10), 90),
      ('k2', 'Szakdolgozat 2. fejezet', floating(2026, 5, 15), 180),
      ('k3', 'Lakásbiztosítás megújítása', floating(2026, 5, 12), 30),
      ('k4', 'Autó műszaki vizsga időpont', null, 15),
      ('k5', 'Szekrény összeszerelése', floating(2026, 5, 17), 120),
      ('k6', 'Könyvtári könyvek visszavitele', floating(2026, 5, 8), 45),
    ]) {
      await records.edit(
        kindTask,
        id,
        taskFields(title: title, due: due, estimateMin: est),
      );
    }
    for (final (day, p, m, h, a) in [
      (28, 3, 3, 4, 4),
      (29, 4, 3, 3, 3),
      (30, 2, 2, 2, 2),
      (1, 3, 4, 4, 4),
      (3, 4, 4, 5, 4),
    ]) {
      final d = day > 20 ? DateTime(2026, 4, day) : DateTime(2026, 5, day);
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      await records.edit(
        kindCheckIn,
        key,
        checkInFields(
          physical: p,
          mental: m,
          mood: h,
          sleep: a,
          note: day == 30 ? 'Rossz éjszaka volt' : '',
        ),
      );
    }
    await fin.saveTx(
      FinTx(
        id: 'f1',
        date: floating(2026, 5, 3),
        amount: 21500,
        kind: FinKind.expense,
        categoryId: 'cat-food',
        merchant: 'SPAR',
      ),
    );
    await fin.saveBudget(const FinBudget(categoryId: 'cat-food', limit: 60000));
  });
  tearDown(() => db.close());

  Future<(LlmRequest, String)> sent(
    String prompt, {
    DateTime? at,
    AiSettings? settings,
  }) async {
    final llm = FakeLlm([(_) => say('ok')]);
    await service(llm, at: at).ask(
      prompt,
      model: 'm',
      settings: settings ?? AiSettings(place: budapest),
    );
    final r = llm.requests.single;
    return (r, (r.turns.first.parts.single as LlmText).text);
  }

  group('how big a request is (sample fortnight, real bundled handbook)', () {
    test('"Tervezz edzést a jövő hétre" fits in about 3 200 tokens', () async {
      final (r, _) = await sent('Tervezz edzést a jövő hétre');
      final size = _Size(r);
      expect(size.total, lessThanOrEqualTo(3200), reason: '$size');
    });

    test('a deletion request fits in about 2 200 tokens', () async {
      final (r, _) = await sent('Töröld a kézzel felvett programokat holnapra');
      final size = _Size(r);
      expect(size.total, lessThanOrEqualTo(2200), reason: '$size');
    });

    test('the fixed part (system prompt + tools) stays under 2 300', () async {
      final (r, _) = await sent('Tervezz edzést a jövő hétre');
      final size = _Size(r);
      expect(size.fixed, lessThanOrEqualTo(2300), reason: '$size');
    });

    test('a money question carries only the money data', () async {
      final (r, first) = await sent('Hogy állok a költségkerettel?');
      final size = _Size(r);
      expect(first, contains('<adat tipus="penzugy">'));
      expect(first.contains('<adat tipus="esemenyek">'), isFalse);
      // a money question needs no handbook and no calendar: well under 1 000
      expect(size.total, lessThanOrEqualTo(1000), reason: '$size');
    });
  });

  group('what stays the same from one request to the next', () {
    test('system prompt and tool list do not depend on the clock', () async {
      final (a, _) = await sent('Tervezz edzést a jövő hétre');
      final (b, _) = await sent(
        'Tervezz edzést a jövő hétre',
        at: now.add(const Duration(days: 1, minutes: 7)),
      );
      expect(b.system, a.system);
      expect(
        [for (final t in b.tools) jsonEncode(t.parameters) + t.description],
        [for (final t in a.tools) jsonEncode(t.parameters) + t.description],
      );
      // no minute-precise clock in either (it would defeat prefix caching)
      expect(a.system.contains('MOST'), isFalse);
      expect(
        RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}').hasMatch(a.system),
        isFalse,
      );
    });

    test('the clock and the request come last in the first message', () async {
      final (_, first) = await sent('Tervezz edzést a jövő hétre');
      expect(first, endsWith('Kérés: Tervezz edzést a jövő hétre'));
      expect(
        first.indexOf('MOST: 2026-05-04 10:00'),
        greaterThan(first.lastIndexOf('</adat>')),
      );
    });

    test(
      'another wording of the same kind keeps the same system prompt',
      () async {
        final (a, _) = await sent('Tervezz edzést a jövő hétre');
        final (b, _) = await sent('Mikor edzek két hétre előre?');
        expect(b.system, a.system);
        expect(
          [for (final t in b.tools) t.name],
          [for (final t in a.tools) t.name],
        );
      },
    );

    test('each kind of request gets its own, smaller prompt', () async {
      final (plan, _) = await sent('Tervezz edzést a jövő hétre');
      final (edit, _) = await sent('Töröld a holnapi edzést');
      final (money, _) = await sent('Hogy állok a költségkerettel?');
      expect(money.system.length, lessThan(edit.system.length));
      expect(edit.system.length, lessThan(plan.system.length));
      // the training rules are not sent with a deletion or a money question
      expect(plan.system, contains('Calisthenics'));
      expect(edit.system.contains('Calisthenics'), isFalse);
      expect(money.system.contains('Calisthenics'), isFalse);
      // but what is fixed and what is movable in the calendar is
      expect(edit.system, contains('Rögzített'));
    });
  });

  group('what a request leaves out', () {
    test(
      'a plan carries no event references, a deletion request does',
      () async {
        final (_, plan) = await sent('Tervezz edzést a jövő hétre');
        expect(plan.contains('"r":'), isFalse);
        final (_, del) = await sent('Töröld a holnapi edzést');
        expect(del, contains('"r":"e1"'));
      },
    );

    test(
      'a plan is told about money only when the request is about money',
      () async {
        final (plain, _) = await sent('Tervezz edzést a jövő hétre');
        expect(plain.system.contains('get_finance'), isFalse);
        expect(plain.tools.map((t) => t.name), isNot(contains('get_finance')));
        final (mixed, _) = await sent('Tervezz edzést, de figyelj a pénzemre');
        expect(mixed.system, contains('get_finance'));
        expect(mixed.tools.map((t) => t.name), contains('get_finance'));
      },
    );

    test(
      'a plan is not offered deleting or moving, a deletion request is',
      () async {
        final (plan, _) = await sent('Tervezz edzést a jövő hétre');
        final (del, _) = await sent('Töröld a holnapi edzést');
        String schemaOf(LlmRequest r) => jsonEncode(
          r.tools.firstWhere((t) => t.name == 'propose_events').parameters,
        );
        expect(schemaOf(plan).contains('deletions'), isFalse);
        expect(schemaOf(plan).contains('moves'), isFalse);
        expect(schemaOf(del), contains('deletions'));
        expect(schemaOf(del), contains('moves'));
      },
    );
  });

  group('tools by scope', () {
    Set<String> names(String prompt) =>
        assistantToolsFor(scopeFor(prompt, floating(2026, 5, 4)))
            .map((t) => t.name)
            .toSet();

    test('planning gets the data tools and the proposal tool', () {
      expect(names('Tervezz edzést a jövő hétre'), {
        'get_events',
        'get_checkins',
        'find_free_slots',
        'propose_events',
      });
    });

    test('there is no task tool: the first message already has every task', () {
      expect(
        names('Tervezz edzést a jövő hétre'),
        isNot(contains('get_tasks')),
      );
    });

    test('deleting or moving gets the events, the free slots and the proposal tool', () {
      expect(names('Töröld a holnapi edzést'), {
        'get_events',
        'find_free_slots',
        'propose_events',
      });
    });

    test('a pure money question gets only the money tool', () {
      expect(names('Hogy állok a költségkerettel?'), {'get_finance'});
    });

    test('a plan that also mentions money gets the money tool too', () {
      expect(
        names('Tervezz edzést, de figyelj a pénzemre'),
        contains('get_finance'),
      );
      expect(
        names('Tervezz edzést, de figyelj a pénzemre'),
        contains('propose_events'),
      );
    });

    test(
      'propose_events lets the model name a task and keeps replies short',
      () {
        final t = assistantToolsFor(
          scopeFor('Tervezz edzést', floating(2026, 5, 4)),
        ).firstWhere((t) => t.name == 'propose_events');
        final item =
            ((t.parameters['properties'] as Map)['proposals'] as Map)['items']
                as Map;
        final props = (item['properties'] as Map).keys;
        expect(
          props,
          containsAll(['title', 'start', 'end', 'kind', 'hard', 'taskId']),
        );
        // the zone is the default one; the model is not asked for it each time
        expect(props.contains('tzid'), isFalse);
      },
    );
  });

  group('the bundled handbook', () {
    test('no default file grows back (characters)', () {
      const limits = {
        'rules': 1400,
        'profile': 700,
        'relations': 800,
        'calendar-semantics': 450,
        'output-format': 400,
        'learned': 200,
      };
      var sum = 0;
      for (final e in limits.entries) {
        final n = File('assets/handbook/${e.key}.md').readAsStringSync().length;
        sum += n;
        expect(n, lessThanOrEqualTo(e.value), reason: e.key);
      }
      expect(sum, lessThanOrEqualTo(3900));
    });

    test('the rules still hold every sport and weather rule of the user', () {
      final rules = File('assets/handbook/rules.md').readAsStringSync();
      for (final must in [
        'Calisthenics',
        'Gym',
        'Street Workout',
        'kajak',
        'falmászás',
        'kerékpár',
        'séta',
        'outdoor',
        '60%',
        'szél',
        'fagy',
      ]) {
        expect(rules, contains(must), reason: must);
      }
    });

    test('numbers that the live rules know are not repeated in the files', () {
      // the limits (sleep window, buffer, 48 h, weekly cap) live once, in the
      // system prompt built from PlanRules
      for (final id in ['rules', 'relations', 'output-format']) {
        final t = File('assets/handbook/$id.md').readAsStringSync();
        expect(t.contains('23:00'), isFalse, reason: '$id: sleep window');
        expect(
          t.contains('heti legfeljebb'),
          isFalse,
          reason: '$id: weekly cap',
        );
      }
    });

    test(
      'the profile knows the 12-day shift cycle and the rest after nights',
      () {
        final p = File('assets/handbook/profile.md').readAsStringSync();
        expect(p, contains('12 napos'));
        expect(p, contains('18–06'));
        expect(p, contains('Éjszakás műszak (18–06) után'));
      },
    );

    test('the calendar meanings do not refer to data that is never sent', () {
      final t = File('assets/handbook/calendar-semantics.md')
          .readAsStringSync();
      for (final gone in [
        'résztvev',
        'appEventId',
        'extended property',
        'ai=1',
      ]) {
        expect(t.contains(gone), isFalse, reason: gone);
      }
      // what the data really carries: the flags of the legend
      expect(t, contains('f: a'));
    });
  });

  group('older default texts are not the user\'s own', () {
    // The previous default of calendar-semantics.md (Build 37 and before).
    const oldSemantics = '''# Naptár-jelentések
- Rögzített (nem mozgatható): munka, megbeszélés, orvos, utazás, minden, ami meghívott résztvevővel van.
- Mozgatható: az AI által létrehozott edzés- és tanulásblokkok (jelölés: `appEventId` + `ai=1` a privát extended property-ben).
- Egész napos esemény (ünnep, szabadság) nem blokkol, de jelzi, hogy az a nap szabadnap/utazás lehet — nézd meg a címét.
- Naptárak/színek jelentése: (töltsd ki, pl. Munka = kék, Magán = zöld)
''';

    HandbookStore handbook() =>
        HandbookStore(records, loader: (p) => File(p).readAsString());

    test(
      'an unedited copy of the old default gives way to the new one',
      () async {
        expect(
          isLegacyHandbookDefault('calendar-semantics', oldSemantics),
          isTrue,
        );
        // windows line ends do not make it "edited"
        expect(
          isLegacyHandbookDefault(
            'calendar-semantics',
            oldSemantics.replaceAll('\n', '\r\n'),
          ),
          isTrue,
        );
        final hb = handbook();
        await hb.save('calendar-semantics', oldSemantics);
        expect(await hb.isCustomized('calendar-semantics'), isFalse);
        final text = await hb.textOf('calendar-semantics');
        expect(text, isNot(contains('appEventId')));
        expect(text, contains('Rögzített'));
      },
    );

    // The default of calendar-semantics.md in Build 38 (before the attendee
    // remark went), a text a device may have saved unedited.
    const build38Semantics = '''# Naptár-jelentések
- Rögzített (nem mozgatható): munka, megbeszélés, orvos, utazás, meghívott résztvevős esemény, és a műszak.
- Mozgatható: az AI korábbi edzés- és tanulásblokkjai (f: a).
- Egész napos esemény (ünnep, szabadság) nem blokkol, de jelzi, hogy szabadnap vagy utazás lehet: nézd meg a címét.
- Naptárak/színek jelentése: (töltsd ki, pl. Munka = kék, Magán = zöld)
''';

    test('the default of the previous build is recognised too', () async {
      expect(
        isLegacyHandbookDefault('calendar-semantics', build38Semantics),
        isTrue,
      );
      final hb = handbook();
      await hb.save('calendar-semantics', build38Semantics);
      expect(await hb.isCustomized('calendar-semantics'), isFalse);
      expect(
        (await hb.textOf('calendar-semantics')).contains('résztvev'),
        isFalse,
      );
    });

    test('a copy the user really changed is never replaced', () async {
      final hb = handbook();
      final mine = oldSemantics.replaceFirst('Munka = kék', 'Munka = piros');
      expect(isLegacyHandbookDefault('calendar-semantics', mine), isFalse);
      await hb.save('calendar-semantics', mine);
      expect(await hb.isCustomized('calendar-semantics'), isTrue);
      expect(await hb.textOf('calendar-semantics'), contains('Munka = piros'));
    });

    test(
      'the same text under another file name is still the user\'s own',
      () async {
        expect(isLegacyHandbookDefault('rules', oldSemantics), isFalse);
        expect(
          isLegacyHandbookDefault('nincs-ilyen-fajl', oldSemantics),
          isFalse,
        );
      },
    );

    test('the current defaults are not counted as old ones', () {
      for (final id in [
        'rules',
        'profile',
        'relations',
        'calendar-semantics',
        'output-format',
      ]) {
        final t = File('assets/handbook/$id.md').readAsStringSync();
        expect(isLegacyHandbookDefault(id, t), isFalse, reason: id);
      }
    });

    test('template lines and titles do not reach the model', () async {
      final hb = handbook();
      final all = await hb.combined();
      // one heading per file, not twice (the file's own `# ` title is dropped)
      expect(
        RegExp(
          r'^#{1,2} Kemény szabályok',
          multiLine: true,
        ).allMatches(all).length,
        1,
      );
      // unfilled template lines of the profile
      expect(all.contains('Sérülések, korlátok'), isFalse);
      expect(all.contains('(pl. állóképesség'), isFalse);
      // an empty "learned" file is left out altogether
      expect(all.contains('## Tanult szokások'), isFalse);
      // filled-in content stays
      expect(all, contains('Calisthenics'));
      expect(all, contains('12 napos'));
    });
  });
}
