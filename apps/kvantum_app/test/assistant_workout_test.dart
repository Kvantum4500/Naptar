import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_service.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/harness.dart';

/// What the assistant gets of the feedback after workouts (2e): the short
/// lines, the legend, the limits the user's own workouts have taught, and the
/// verdict the screen shows.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late AiSettingsStore store;
  late HandbookStore handbook;

  // Monday 2026-05-04, 10:00 Budapest
  final now = DateTime.utc(2026, 5, 4, 8);

  AssistantService service(FakeLlm llm, {int? budget}) => AssistantService(
    provider: llm,
    events: events,
    records: records,
    handbook: handbook,
    settingsStore: store,
    now: () => now,
    delay: (d) async {},
    tokenBudget: budget,
  );

  setUp(() async {
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db, deviceId: 'T', clock: () => 1000);
    handbook = HandbookStore(records, loader: (path) async => 'H[$path]');
    store = AiSettingsStore(
      read: records.meta,
      write: records.setMeta,
      now: () => DateTime(2026, 5, 4),
    );
  });
  tearDown(() => db.close());

  const settings = AiSettings();
  var seq = 0;

  /// A feedback [daysAgo] days before the 4th of May.
  Future<void> feedback(
    String sport,
    int minutes,
    int? body, {
    int daysAgo = 1,
    int? mind,
    int? start,
    int? end,
    int? exp,
    String note = '',
    String title = 'Edzés',
    bool done = true,
  }) => records.edit(
    kindWorkoutLog,
    'l${seq++}',
    workoutLogFields(
      title: title,
      date: DateTime.utc(2026, 5, 4).subtract(Duration(days: daysAgo)),
      minutes: minutes,
      sport: sport,
      done: done,
      bodyLoad: body,
      mindLoad: mind,
      energyStart: start,
      energyEnd: end,
      experience: exp,
      note: note,
    ),
  );

  Future<void> manyFeedback(
    String sport,
    int minutes,
    List<int> loads, {
    int firstDaysAgo = 1,
  }) async {
    for (var i = 0; i < loads.length; i++) {
      await feedback(sport, minutes, loads[i], daysAgo: firstDaysAgo + i);
    }
  }

  String firstOf(FakeLlm llm) =>
      (llm.requests.first.turns.first.parts.single as LlmText).text;
  String everythingOf(FakeLlm llm) =>
      '${llm.requests.first.system}\n${firstOf(llm)}';
  String told(FakeLlm llm) => jsonEncode(lastResults(llm));

  Future<FakeLlm> ask(String q, {AiSettings s = settings}) async {
    final llm = FakeLlm([(_) => say('ok')]);
    await service(llm).ask(q, model: 'm', settings: s);
    return llm;
  }

  group('what the model gets of the feedback', () {
    test('the latest ones as short lines, after the check-in block', () async {
      await feedback(
        'gym',
        60,
        4,
        daysAgo: 3,
        mind: 2,
        start: 3,
        end: 2,
        exp: 4,
      );
      await feedback(
        'calisthenics',
        45,
        2,
        daysAgo: 1,
        mind: 1,
        start: 4,
        end: 4,
        exp: 5,
      );
      await feedback('gym', 60, null, daysAgo: 5, done: false);
      final llm = await ask('Tervezz edzést a jövő hétre');
      final first = firstOf(llm);
      expect(first, contains('<adat tipus="edzes_naplo">'));
      expect(
        first,
        contains(
          '"edzesek":["05-03 calisthenics 45p nf2 nm1 e4/4 k5","05-01 gym 60p nf4 nm2 e3/2 k4","04-29 gym 60p kihagyta"]',
        ),
      );
      expect(
        first.indexOf('<adat tipus="check_in">'),
        lessThan(first.indexOf('<adat tipus="edzes_naplo">')),
      );
      // the legend and how to use it are in the instructions
      final system = llm.requests.first.system;
      expect(system, contains('edzes_naplo: d=nap, s=sport, p=perc'));
      expect(system, contains('Az edzes_naplo az észlelt terhelés'));
    });

    test('no title and no note: only the generic name of the sport', () async {
      await feedback(
        'gym',
        60,
        3,
        title: 'Gym Pistivel a titkos edzőteremben',
        note: 'sérült a térdem, az orvos mondta',
      );
      final all = everythingOf(await ask('Tervezz edzést'));
      expect(all, contains('gym 60p nf3'));
      expect(all.contains('Pisti'), isFalse);
      expect(all.contains('titkos'), isFalse);
      expect(all.contains('térd'), isFalse);
      expect(all.contains('orvos'), isFalse);
    });

    test('nothing without feedback: no block, no legend', () async {
      final all = everythingOf(await ask('Tervezz edzést'));
      expect(all.contains('edzes_naplo'), isFalse);
      expect(all.contains('Egyedi nehéz-küszöb'), isFalse);
    });

    test('nothing with the check-in data switched off', () async {
      await feedback('gym', 60, 4);
      await manyFeedback('gym', 50, [5, 5, 5], firstDaysAgo: 4);
      final llm = await ask(
        'Tervezz edzést',
        s: const AiSettings(checkins: false),
      );
      final all = everythingOf(llm);
      expect(all.contains('edzes_naplo'), isFalse);
      expect(all.contains('Egyedi nehéz-küszöb'), isFalse);
      expect(firstOf(llm), contains('"kikapcsolva":true'));
    });

    test('a deleting request and a money question do not carry it', () async {
      await feedback('gym', 60, 4);
      for (final q in ['Töröld a holnapi edzést', 'Mennyit költöttem?']) {
        final all = everythingOf(await ask(q));
        expect(all.contains('edzes_naplo'), isFalse, reason: q);
      }
    });

    test('a deleting-and-planning request does', () async {
      await feedback('gym', 60, 4);
      final llm = await ask('Töröld a holnapi edzést és tervezz újat');
      expect(firstOf(llm), contains('<adat tipus="edzes_naplo">'));
      expect(llm.requests.first.system, contains('edzes_naplo: d=nap'));
    });

    test('at most ten lines, within 60 days', () async {
      await manyFeedback('gym', 60, List.filled(14, 3));
      await feedback('gym', 60, 3, daysAgo: 70);
      final first = firstOf(await ask('Tervezz edzést'));
      final lines = RegExp(r'"(\d\d-\d\d) gym 60p nf3"').allMatches(first);
      expect(lines.length, 10);
    });

    test('the preview shows the block and its size', () async {
      await feedback('gym', 60, 4);
      final pre = await service(FakeLlm([]))
          .preview('Tervezz edzést', settings: settings);
      expect(pre.blocks.map((b) => b.name), contains('edzes_naplo'));
      expect(pre.firstMessage, contains('gym 60p nf4'));
    });
  });

  group('the size', () {
    test('ten lines cost about 150 tokens', () async {
      final without = await service(FakeLlm([]))
          .preview('Tervezz edzést a jövő hétre', settings: settings);
      await manyFeedback('gym', 60, List.filled(10, 3));
      await manyFeedback(
        'calisthenics',
        45,
        List.filled(2, 2),
        firstDaysAgo: 11,
      );
      final withLog = await service(FakeLlm([]))
          .preview('Tervezz edzést a jövő hétre', settings: settings);
      final extra = withLog.estimatedTokens - without.estimatedTokens;
      expect(extra, greaterThan(100));
      expect(extra, lessThan(320), reason: '$extra tokens');
    });

    test('the budget guard drops it before the learned habits', () async {
      await feedback('gym', 60, 4);
      final pre = await service(
        FakeLlm([]),
        budget: 300,
      ).preview('Tervezz edzést a jövő hétre', settings: settings);
      final steps = pre.reductions.join(' | ');
      expect(pre.reductions, contains('edzésnapló'));
      expect(
        steps.indexOf('edzésnapló'),
        greaterThan(steps.indexOf('időablak')),
        reason: steps,
      );
      expect(
        steps.indexOf('Tanult szokások'),
        greaterThan(steps.indexOf('edzésnapló')),
        reason: steps,
      );
      expect(pre.firstMessage.contains('edzes_naplo'), isFalse);
    });
  });

  group('the limits the user\'s own workouts have taught', () {
    // check-in energy 2 on the 6th: a hard session is refused that day
    Future<void> lowEnergyOn6th() => records.edit(
      kindCheckIn,
      '2026-05-06',
      checkInFields(physical: 2, mood: 3),
    );

    FakeLlm planOf(
      String title,
      String start,
      String end, {
      bool hard = false,
    }) => FakeLlm([
      (_) => calls([
        propose([item(title, start, end, hard: hard)]),
      ]),
      // the repair: the same session on a day without a check-in
      (_) => calls([
        propose([
          item(
            title,
            start.replaceFirst('05-06', '05-07'),
            end.replaceFirst('05-06', '05-07'),
          ),
        ]),
      ]),
    ]);

    test(
      'without a lesson a 60-minute session is hard: refused on a low day',
      () async {
        await lowEnergyOn6th();
        final llm = planOf(
          'Calisthenics',
          '2026-05-06T18:00:00',
          '2026-05-06T19:00:00',
        );
        final out = await service(llm)
            .ask('Tervezz edzést', model: 'm', settings: settings);
        expect(told(llm), contains('fizikai energia'));
        expect(out.items.single.startWall, floating(2026, 5, 7, 18));
      },
    );

    test(
      'three hard sessions of 50 minutes make the sport hard from 45',
      () async {
        await lowEnergyOn6th();
        await manyFeedback('gym', 50, [4, 5, 4]);
        final llm = planOf('Gym', '2026-05-06T18:00:00', '2026-05-06T18:45:00');
        final out = await service(llm)
            .ask('Tervezz edzést', model: 'm', settings: settings);
        // refused as a hard session (energy 2/5) ...
        expect(told(llm), contains('fizikai energia'));
        expect(out.items.single.startWall, floating(2026, 5, 7, 18));
        // ... and the model was told the limit
        expect(
          llm.requests.first.system,
          contains('Egyedi nehéz-küszöb a naplód szerint (perc): gym 45.'),
        );
      },
    );

    test('...but the same 45 minutes pass when nothing was learned', () async {
      await lowEnergyOn6th();
      final llm = FakeLlm([
        (_) => calls([
          propose([item('Gym', '2026-05-06T18:00:00', '2026-05-06T18:45:00')]),
        ]),
      ]);
      final out = await service(llm)
          .ask('Tervezz edzést', model: 'm', settings: settings);
      expect(out.calls, 1);
      expect(out.items.single.startWall, floating(2026, 5, 6, 18));
      expect(
        llm.requests.first.system.contains('Egyedi nehéz-küszöb'),
        isFalse,
      );
    });

    test('easy sessions alone loosen nothing: only a yes does', () async {
      await lowEnergyOn6th();
      await manyFeedback('calisthenics', 60, [1, 2, 1, 2, 1]);
      final llm = planOf(
        'Calisthenics',
        '2026-05-06T18:00:00',
        '2026-05-06T19:00:00',
      );
      final out = await service(llm)
          .ask('Tervezz edzést', model: 'm', settings: settings);
      expect(told(llm), contains('fizikai energia')); // still hard
      expect(out.items.single.startWall, floating(2026, 5, 7, 18));
      expect(
        llm.requests.first.system.contains('Egyedi nehéz-küszöb'),
        isFalse,
      );
    });

    test(
      'after a yes the 60-minute session is not held to the energy rule',
      () async {
        await lowEnergyOn6th();
        await manyFeedback('calisthenics', 60, [1, 2, 1, 2, 1]);
        await handbook.agreeLight('calisthenics');
        final llm = FakeLlm([
          (_) => calls([
            propose([
              item(
                'Calisthenics',
                '2026-05-06T18:00:00',
                '2026-05-06T19:00:00',
              ),
            ]),
          ]),
        ]);
        final out = await service(llm)
            .ask('Tervezz edzést', model: 'm', settings: settings);
        expect(out.calls, 1, reason: 'no repair round');
        expect(out.items.single.startWall, floating(2026, 5, 6, 18));
        expect(
          llm.requests.first.system,
          contains(
            'Egyedi nehéz-küszöb a naplód szerint (perc): calisthenics 90.',
          ),
        );
        // the user's own words reach the model through the learned habits too
        expect(llm.requests.first.system, contains('[könnyű: calisthenics]'));
        // what the screen shows is the code's verdict: not hard
        expect(out.items.single.hard, isFalse);
      },
    );

    test(
      '...but 90 minutes are hard again, and so is the model\'s "hard"',
      () async {
        await lowEnergyOn6th();
        await manyFeedback('calisthenics', 60, [1, 2, 1, 2, 1]);
        await handbook.agreeLight('calisthenics');
        for (final (end, hard) in [('20:30:00', false), ('19:00:00', true)]) {
          final llm = planOf(
            'Calisthenics',
            '2026-05-06T18:00:00',
            '2026-05-06T$end',
            hard: hard,
          );
          final out = await service(llm)
              .ask('Tervezz edzést', model: 'm', settings: settings);
          expect(told(llm), contains('fizikai energia'), reason: end);
          expect(
            out.items.single.startWall,
            floating(2026, 5, 7, 18),
            reason: end,
          );
        }
      },
    );

    test('new hard sessions take the yes back', () async {
      await lowEnergyOn6th();
      await manyFeedback('calisthenics', 70, [5, 4, 5]); // the newest three
      await manyFeedback('calisthenics', 60, [1, 1, 1, 1, 1], firstDaysAgo: 10);
      await handbook.agreeLight('calisthenics');
      final llm = planOf(
        'Calisthenics',
        '2026-05-06T18:00:00',
        '2026-05-06T19:00:00',
      );
      final out = await service(llm)
          .ask('Tervezz edzést', model: 'm', settings: settings);
      expect(told(llm), contains('fizikai energia'));
      expect(out.items.single.startWall, floating(2026, 5, 7, 18));
    });

    test(
      'the limits apply in code even when the feedback is not shared',
      () async {
        await lowEnergyOn6th();
        await manyFeedback('gym', 50, [4, 5, 4]);
        final llm = planOf('Gym', '2026-05-06T18:00:00', '2026-05-06T18:45:00');
        final out = await service(llm).ask(
          'Tervezz edzést',
          model: 'm',
          settings: const AiSettings(checkins: false),
        );
        // refused as hard, and the refusal does not give the energy away
        expect(
          told(llm),
          contains('Erre a napra nehéz edzés nem javasolható.'),
        );
        expect(told(llm).contains('fizikai energia'), isFalse);
        expect(out.items.single.startWall, floating(2026, 5, 7, 18));
        // ... but the model is not told how they came about
        expect(
          llm.requests.first.system.contains('Egyedi nehéz-küszöb'),
          isFalse,
        );
      },
    );

    test(
      'a booked workout is told apart by the same limit (48 hours)',
      () async {
        await manyFeedback('calisthenics', 60, [1, 2, 1, 2, 1]);
        await handbook.agreeLight('calisthenics');
        // a typed-in 70-minute calisthenics: not hard for this user
        await events.saveLocal(
          evt(
            'c',
            'Calisthenics',
            floating(2026, 5, 5, 18),
            len: const Duration(minutes: 70),
          ),
        );
        final llm = FakeLlm([
          (_) => calls([
            propose([
              item(
                'Gym',
                '2026-05-06T18:00:00',
                '2026-05-06T19:00:00',
                hard: true,
              ),
            ]),
          ]),
        ]);
        final out = await service(llm)
            .ask('Tervezz edzést', model: 'm', settings: settings);
        expect(out.calls, 1, reason: 'the day after an easy one is fine');
        expect(out.items, hasLength(1));
      },
    );
  });
}
