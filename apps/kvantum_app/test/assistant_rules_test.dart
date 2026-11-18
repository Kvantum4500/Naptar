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

/// The rules the assistant's proposals are held to (2d): a session is hard from
/// 60 minutes by the code's count, the workouts already booked count against
/// the weekly cap and the 48 hours, a day without a check-in is taken as 3/5.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

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
    handbook: HandbookStore(records, loader: (path) async => 'H[$path]'),
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

  Future<void> booked(
    String id,
    String title,
    DateTime start, {
    int minutes = 50,
  }) =>
      events.saveLocal(evt(id, title, start, len: Duration(minutes: minutes)));

  String told(FakeLlm llm) => jsonEncode(lastResults(llm));

  test('the workouts booked in the same week count against the cap', () async {
    // Mon–Thu evenings: four sessions of 50 minutes (not hard) in the calendar
    for (var d = 4; d <= 7; d++) {
      await booked('g$d', 'Gym', floating(2026, 5, d, 18));
    }
    final llm = FakeLlm([
      // two more on Friday and Saturday make six
      (_) => calls([
        propose([
          item('Futás', '2026-05-08T18:00:00', '2026-05-08T18:50:00'),
          item('Úszás', '2026-05-09T18:00:00', '2026-05-09T18:50:00'),
        ]),
      ]),
      (_) => calls([
        propose([item('Futás', '2026-05-08T18:00:00', '2026-05-08T18:50:00')]),
      ]),
    ]);
    final out = await service(llm)
        .ask('Tervezz edzést a hétre', model: 'm', settings: settings);
    expect(out.items.map((i) => i.title), ['Futás']);
    expect(told(llm), contains('6 edzés'));
    expect(told(llm), contains('ebből 4 már a naptárban van'));
  });

  test('a booked hard session pushes the next hard one 48 hours away', () async {
    await booked('big', 'Gym', floating(2026, 5, 5, 18), minutes: 90);
    final llm = FakeLlm([
      // the model calls it light (hard: false); 90 minutes make it hard anyway
      (_) => calls([
        propose([
          item(
            'Calisthenics',
            '2026-05-06T18:00:00',
            '2026-05-06T19:30:00',
            hard: false,
          ),
        ]),
      ]),
      (_) => calls([
        propose([
          item('Calisthenics', '2026-05-08T18:00:00', '2026-05-08T19:30:00'),
        ]),
      ]),
    ]);
    final out = await service(llm)
        .ask('Tervezz edzést', model: 'm', settings: settings);
    expect(told(llm), contains('Két nehéz edzés között legalább 48 óra'));
    // (the booked one was typed in by hand, so the model only ever knew it as
    // "foglalt": the feedback keeps it that way)
    expect(told(llm), contains('„foglalt” és „Calisthenics”'));
    expect(told(llm).contains('Gym'), isFalse);
    expect(out.items.single.startWall, floating(2026, 5, 8, 18));
  });

  test(
    'a hard session on a day nobody checked in on is fine (3/5 assumed)',
    () async {
      final llm = FakeLlm([
        (_) => calls([
          propose([
            item(
              'Gym',
              '2026-05-06T18:00:00',
              '2026-05-06T19:30:00',
              hard: true,
            ),
          ]),
        ]),
      ]);
      final out = await service(llm)
          .ask('Tervezz edzést', model: 'm', settings: settings);
      expect(out.calls, 1, reason: 'no repair round');
      expect(out.items.single.title, 'Gym');
      expect(out.dropped, isEmpty);
    },
  );

  test('...but a real low check-in still stops it', () async {
    await records.edit(
      kindCheckIn,
      '2026-05-06',
      checkInFields(physical: 2, mood: 3),
    );
    final llm = FakeLlm([
      (_) => calls([
        propose([
          item('Gym', '2026-05-06T18:00:00', '2026-05-06T19:30:00', hard: true),
        ]),
      ]),
      (_) => calls([
        propose([item('Gym', '2026-05-06T18:00:00', '2026-05-06T18:40:00')]),
      ]),
    ]);
    final out = await service(llm)
        .ask('Tervezz edzést', model: 'm', settings: settings);
    expect(told(llm), contains('2/5'));
    expect(out.items.single.endWall, floating(2026, 5, 6, 18, 40));
  });

  test(
    'a typed-in event the model never saw stays "foglalt" in the feedback',
    () async {
      // 16 days away: outside the 7 days of data the model got
      await booked('far', 'Fogorvos', floating(2026, 5, 20, 18), minutes: 60);
      final llm = FakeLlm([
        (_) => calls([
          propose([item('Gym', '2026-05-20T18:00:00', '2026-05-20T18:50:00')]),
        ]),
        (_) => calls([
          propose([item('Gym', '2026-05-20T20:00:00', '2026-05-20T20:50:00')]),
        ]),
      ]);
      final out = await service(llm)
          .ask('Tervezz edzést', model: 'm', settings: settings);
      expect(told(llm), contains('foglalt'));
      expect(told(llm).contains('Fogorvos'), isFalse);
      expect(out.items.single.startWall, floating(2026, 5, 20, 20));
    },
  );

  test('a block over the whole night is sent back (sleep window)', () async {
    final llm = FakeLlm([
      (_) => calls([
        propose([
          item(
            'Éjszakai túra',
            '2026-05-05T22:00:00',
            '2026-05-06T08:00:00',
            kind: 'other',
          ),
        ]),
      ]),
      (_) => calls([
        propose([
          item(
            'Túra',
            '2026-05-05T09:00:00',
            '2026-05-05T12:00:00',
            kind: 'other',
          ),
        ]),
      ]),
    ]);
    final out = await service(llm)
        .ask('Tervezz valamit', model: 'm', settings: settings);
    expect(told(llm), contains('alvási sávba esik'));
    expect(out.items.single.title, 'Túra');
  });

  group('what a request is sent, by what it asks (2d)', () {
    String first(FakeLlm llm) => llm.requests.first.turns.first.parts
        .whereType<LlmText>()
        .map((t) => t.text)
        .join();

    test('deleting and planning in one request carries both', () async {
      await booked('p1', 'Magánügy', floating(2026, 5, 5, 9));
      await records.edit(kindTask, 't1', taskFields(title: 'Beadandó'));
      await records.edit(
        kindCheckIn,
        '2026-05-04',
        checkInFields(physical: 4, mood: 3),
      );
      final llm = FakeLlm([(_) => say('ok')]);
      await service(llm).ask(
        'Töröld a kézzel felvett programokat és tervezz edzést a jövő hétre',
        model: 'm',
        settings: settings,
      );
      final req = llm.requests.first;
      // the events come with references (a deletion needs them) and their names
      expect(first(llm), contains('"r":"e1"'));
      expect(first(llm), contains('Magánügy'));
      // ... and the planning data is there too
      expect(first(llm), contains('<adat tipus="feladatok">'));
      expect(first(llm), contains('<adat tipus="check_in">'));
      expect(first(llm), contains('<adat tipus="szabad_idosavok">'));
      // the instructions: references AND the hard rules AND the user's handbook
      expect(req.system, contains('deletions'));
      expect(req.system, contains('KEMÉNY SZABÁLYOK'));
      expect(req.system, contains('H[assets/handbook/rules.md]'));
      final names = [for (final t in req.tools) t.name];
      expect(
        names,
        containsAll(['get_events', 'get_checkins', 'propose_events']),
      );
      final propose = req.tools.firstWhere((t) => t.name == 'propose_events');
      expect(propose.parameters.toString(), contains('deletions'));
    });

    test(
      'a plain deleting request stays small: events only, a short window',
      () async {
        final llm = FakeLlm([(_) => say('ok')]);
        await service(llm)
            .ask('Töröld a holnapi edzést', model: 'm', settings: settings);
        expect(first(llm), contains('3 nap (2026-05-04 – 2026-05-06)'));
        expect(first(llm).contains('feladatok'), isFalse);
        expect(first(llm).contains('check_in'), isFalse);
        expect(llm.requests.first.system.contains('KEMÉNY SZABÁLYOK'), isFalse);
        final names = [for (final t in llm.requests.first.tools) t.name];
        expect(names.contains('get_checkins'), isFalse);
      },
    );

    test(
      'a question about the calendar gets the events and nothing else',
      () async {
        final llm = FakeLlm([(_) => say('ok')]);
        await service(llm)
            .ask('Mikor szabad a szerda este?', model: 'm', settings: settings);
        expect(first(llm), contains('<adat tipus="esemenyek">'));
        expect(first(llm), contains('<adat tipus="szabad_idosavok">'));
        expect(first(llm).contains('<adat tipus="feladatok">'), isFalse);
        expect(first(llm).contains('<adat tipus="check_in">'), isFalse);
      },
    );
  });
}
