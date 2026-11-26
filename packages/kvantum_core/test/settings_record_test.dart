import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The settings that live on every device (8th round): the pay estimate, the
/// goals of the food and fluid log and the wishes of the local planner are
/// three small synced records, each setting a field of its own. What they
/// read as, what is written into them, and what two devices make of them.
void main() {
  /// A record of [id] with [fields] written at [ts] by [dev] (on top of [base]).
  SyncRecord rec(
    String id,
    Map<String, Object?> fields, {
    int ts = 1000,
    String dev = 'aaaa',
    SyncRecord? base,
  }) => (base ?? SyncRecord(id: id, kind: kindSettings)).edit(
    fields,
    ts: ts,
    dev: dev,
  );

  group('the kind', () {
    test('settings is a synced kind with three fixed records', () {
      expect(kindSettings, 'settings');
      expect(syncedKinds, contains(kindSettings));
      expect(syncedKinds.toSet(), hasLength(syncedKinds.length));
      expect(
        [settingsPayId, settingsGoalsId, settingsPlanId],
        ['pay', 'goals', 'plan'],
      );
    });

    test('the Drive file names of the records are known to both patterns', () {
      for (final id in [settingsPayId, settingsGoalsId, settingsPlanId]) {
        final name = recordFileName(kindSettings, id);
        expect(name, 'settings-$id.json');
        for (final pattern in [
          recordFileNamePattern,
          safeRecordFileNamePattern,
        ]) {
          final m = pattern.firstMatch(name);
          expect(m, isNotNull, reason: name);
          expect((m![1], m[2]), (kindSettings, id));
        }
      }
    });

    test('a record keeps its null fields through the file text', () {
      // a goal taken away is a field that says null: it must still be there
      // after the file is written and read, or the other device keeps the goal
      final r = rec(settingsGoalsId, const IntakeGoals(kcal: 2000).toFields());
      final taken = rec(
        settingsGoalsId,
        const IntakeGoals().toFields(),
        ts: 2000,
        base: r,
      );
      final back = SyncRecord.decode(taken.encode());
      expect(back.fields.containsKey('kcal'), isTrue);
      expect(back['kcal'], isNull);
      expect(IntakeGoals.fromRecord(back).kcal, isNull);
    });
  });

  group('the pay estimate', () {
    const full = PaySettings(
      hourly: 2850,
      eveningPct: 20,
      nightPct: 40,
      saturdayPct: 30,
      sundayPct: 50,
      holidayPct: 100,
    );

    test('no record: not set', () {
      expect(PaySettings.fromRecord(null), const PaySettings());
      expect(PaySettings.fromRecord(null).isSet, isFalse);
    });

    test('a record that says nothing: not set', () {
      expect(
        PaySettings.fromRecord(SyncRecord(id: 'pay', kind: kindSettings)),
        const PaySettings(),
      );
    });

    test('written and read back', () {
      expect(PaySettings.fromRecord(rec('pay', full.toFields())), full);
      const some = PaySettings(hourly: 3100, sundayPct: 75);
      expect(PaySettings.fromRecord(rec('pay', some.toFields())), some);
    });

    test('every setting is a field of its own, all numbers', () {
      final f = full.toFields();
      expect(f.keys.toSet(), {
        'hourly',
        'evening',
        'night',
        'saturday',
        'sunday',
        'holiday',
      });
      expect(f.values.every((v) => v is int), isTrue);
    });

    test('a number that is too big is cut, a bad one is "not set"', () {
      final p = PaySettings.fromRecord(
        rec('pay', {
          'hourly': 5000000000,
          'evening': 99999,
          'night': -5,
          'saturday': 'sok',
          'sunday': null,
          'holiday': 12.6,
        }),
      );
      expect(p.hourly, PaySettings.maxHourly);
      expect(p.eveningPct, PaySettings.maxPercent);
      expect(p.nightPct, 0);
      expect(p.saturdayPct, 0);
      expect(p.sundayPct, 0);
      expect(p.holidayPct, 13);
    });

    test('a record reads as the old device text did', () {
      for (final p in const [
        PaySettings(),
        PaySettings(hourly: 1),
        full,
        PaySettings(hourly: 999999, holidayPct: 1000),
      ]) {
        final viaText = PaySettings.decode(p.encode());
        final viaRecord = PaySettings.fromRecord(rec('pay', p.toFields()));
        expect(viaRecord, viaText, reason: '$p');
      }
    });
  });

  group('the goals', () {
    const all = IntakeGoals(
      kcal: 2200,
      protein: 140,
      carbs: 250,
      fat: 70,
      ml: 2500,
    );

    test('no record: no goals', () {
      expect(IntakeGoals.fromRecord(null).isEmpty, isTrue);
      expect(
        IntakeGoals.fromRecord(SyncRecord(id: 'goals', kind: kindSettings)),
        const IntakeGoals(),
      );
    });

    test('written and read back, whole or partly', () {
      expect(IntakeGoals.fromRecord(rec('goals', all.toFields())), all);
      const some = IntakeGoals(kcal: 1800, ml: 2000);
      expect(IntakeGoals.fromRecord(rec('goals', some.toFields())), some);
    });

    test('a goal that is not set is written as null, every field is there', () {
      expect(const IntakeGoals(kcal: 1800).toFields(), {
        'kcal': 1800,
        'protein': null,
        'carbs': null,
        'fat': null,
        'ml': null,
      });
    });

    test('a value out of range is not a goal (it is not bent to fit)', () {
      final g = IntakeGoals.fromRecord(
        rec('goals', {
          'kcal': IntakeGoals.minKcal - 1,
          'protein': 0,
          'carbs': IntakeGoals.maxGrams + 1,
          'fat': -4,
          'ml': IntakeGoals.maxMl + 1,
        }),
      );
      expect(g.isEmpty, isTrue);
      // the edges themselves are goals
      final edge = IntakeGoals.fromRecord(
        rec('goals', {
          'kcal': IntakeGoals.minKcal,
          'protein': IntakeGoals.minGrams,
          'carbs': IntakeGoals.maxGrams,
          'ml': IntakeGoals.maxMl,
        }),
      );
      expect(edge.kcal, IntakeGoals.minKcal);
      expect(edge.protein, IntakeGoals.minGrams);
      expect(edge.carbs, IntakeGoals.maxGrams);
      expect(edge.fat, isNull);
      expect(edge.ml, IntakeGoals.maxMl);
    });

    test('a value of the wrong kind is not a goal, and nothing throws', () {
      final g = IntakeGoals.fromRecord(
        rec('goals', {
          'kcal': '2000',
          'protein': true,
          'carbs': [1],
          'fat': {'a': 1},
          'ml': null,
        }),
      );
      expect(g.isEmpty, isTrue);
    });

    test('a goal taken away is gone on top of the old value', () {
      final set = rec('goals', all.toFields(), ts: 100);
      final taken = rec(
        'goals',
        const IntakeGoals(kcal: 2200).toFields(),
        ts: 200,
        base: set,
      );
      final g = IntakeGoals.fromRecord(taken);
      expect(g.kcal, 2200);
      expect(g.protein, isNull);
      expect(g.carbs, isNull);
      expect(g.fat, isNull);
      expect(g.ml, isNull);
    });

    test('a record reads as the old device text did', () {
      for (final g in const [
        IntakeGoals(),
        IntakeGoals(kcal: 2000),
        IntakeGoals(ml: 3000),
        all,
      ]) {
        final viaText = IntakeGoals.decode(g.encode());
        final viaRecord = IntakeGoals.fromRecord(rec('goals', g.toFields()));
        expect(viaRecord, viaText, reason: '$g');
      }
    });
  });

  group('the wishes of the local planner', () {
    const own = LocalPlanPrefs(
      sports: [
        PlanSport(name: 'Kajak', minutes: 90, outdoor: true),
        PlanSport(name: 'Gym', minutes: 75),
        PlanSport(name: 'Calisthenics', minutes: 40),
      ],
      perWeek: 5,
      band: PlanBand.evening,
    );

    void sameWishes(LocalPlanPrefs a, LocalPlanPrefs b, {String? reason}) {
      expect(a.sports, b.sports, reason: reason);
      expect(a.perWeek, b.perWeek, reason: reason);
      expect(a.band, b.band, reason: reason);
    }

    test('no record: the wishes of the first start', () {
      final p = LocalPlanPrefs.fromRecord(null);
      expect(p.sports, defaultPlanSports);
      expect(p.perWeek, 3);
      expect(p.band, PlanBand.any);
    });

    test('written and read back, the sports in their order', () {
      final p = LocalPlanPrefs.fromRecord(rec('plan', own.toFields()));
      sameWishes(p, own);
      expect(
        [for (final s in p.sports) s.name],
        ['Kajak', 'Gym', 'Calisthenics'],
      );
    });

    test('the sports are one field, a text: the list is one wish', () {
      final f = own.toFields();
      expect(f.keys.toSet(), {'sports', 'perWeek', 'band'});
      expect(f['sports'], isA<String>());
      expect(jsonDecode(f['sports']! as String), isA<List<Object?>>());
      expect(f['perWeek'], 5);
      expect(f['band'], 'evening');
    });

    test('a list the user emptied stays empty', () {
      const none = LocalPlanPrefs(sports: []);
      final p = LocalPlanPrefs.fromRecord(rec('plan', none.toFields()));
      expect(p.sports, isEmpty);
    });

    test('a list that is missing or not readable: the first-start sports', () {
      for (final v in <Object?>[
        null,
        42,
        true,
        'nem json',
        '{"a":1}',
        '"x"',
        '12',
        ['not', 'text'],
      ]) {
        final p = LocalPlanPrefs.fromRecord(
          rec('plan', {'sports': v, 'perWeek': 2}),
        );
        expect(p.sports, defaultPlanSports, reason: '$v');
        expect(p.perWeek, 2, reason: '$v');
      }
      // no field at all
      expect(
        LocalPlanPrefs.fromRecord(rec('plan', {'perWeek': 4})).sports,
        defaultPlanSports,
      );
    });

    test('bad sports are dropped, a long list is cut to twelve', () {
      final p = LocalPlanPrefs.fromRecord(
        rec('plan', {
          'sports':
              '[{"name":"Gym","minutes":60},{"name":"","minutes":60},'
              '{"name":"X","minutes":5},"Gym",null,{"name":"Úszás","minutes":30}]',
        }),
      );
      expect([for (final s in p.sports) s.name], ['Gym', 'Úszás']);
      final many = jsonEncode([
        for (var i = 0; i < 20; i++) {'name': 'Sport $i', 'minutes': 30},
      ]);
      expect(
        LocalPlanPrefs.fromRecord(rec('plan', {'sports': many})).sports,
        hasLength(LocalPlanPrefs.maxSports),
      );
    });

    test('the weekly wish is kept between 1 and 7, the band must be known', () {
      int n(Object? v) =>
          LocalPlanPrefs.fromRecord(rec('plan', {'perWeek': v})).perWeek;
      expect(n(0), 1);
      expect(n(-3), 1);
      expect(n(7), 7);
      expect(n(9), 7);
      expect(n('4'), 3);
      expect(n(2.5), 3);
      expect(n(null), 3);
      PlanBand b(Object? v) =>
          LocalPlanPrefs.fromRecord(rec('plan', {'band': v})).band;
      expect(b('morning'), PlanBand.morning);
      expect(b('night'), PlanBand.any);
      expect(b(7), PlanBand.any);
      expect(b(null), PlanBand.any);
    });

    test('wishes are equal when everything in them is equal, in order', () {
      const a = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Gym', minutes: 60),
          PlanSport(name: 'Úszás', minutes: 45),
        ],
        perWeek: 4,
        band: PlanBand.morning,
      );
      final same = LocalPlanPrefs.fromRecord(rec('plan', a.toFields()));
      expect(same, a);
      expect(same.hashCode, a.hashCode);
      expect(const LocalPlanPrefs(), const LocalPlanPrefs());
      expect(a.copyWith(perWeek: 5), isNot(a));
      expect(a.copyWith(band: PlanBand.evening), isNot(a));
      expect(a.copyWith(sports: a.sports.reversed.toList()), isNot(a));
      expect(a.copyWith(sports: a.sports.take(1).toList()), isNot(a));
      expect(a.copyWith(sports: []), isNot(a));
    });

    test('a record reads as the old device text did', () {
      for (final p in const [
        LocalPlanPrefs(),
        LocalPlanPrefs(sports: []),
        LocalPlanPrefs(perWeek: 7, band: PlanBand.morning),
        own,
      ]) {
        sameWishes(
          LocalPlanPrefs.fromRecord(rec('plan', p.toFields())),
          LocalPlanPrefs.decode(p.encode()),
          reason: p.encode(),
        );
      }
    });
  });

  group('two devices', () {
    test('a wage on one and a premium on the other: both stay', () {
      final base = rec(
        'pay',
        const PaySettings(hourly: 2500, sundayPct: 50).toFields(),
        ts: 100,
      );
      // device A raises the wage; device B (which has not seen it) sets the
      // premium of the holidays: each writes only what it changed
      final a = rec(
        'pay',
        const PaySettings(hourly: 2900, sundayPct: 50).toFields(),
        ts: 200,
        dev: 'aaaa',
        base: base,
      );
      final b = rec(
        'pay',
        const PaySettings(
          hourly: 2500,
          sundayPct: 50,
          holidayPct: 100,
        ).toFields(),
        ts: 210,
        dev: 'bbbb',
        base: base,
      );
      const want = PaySettings(hourly: 2900, sundayPct: 50, holidayPct: 100);
      expect(PaySettings.fromRecord(a.merge(b)), want);
      expect(PaySettings.fromRecord(b.merge(a)), want);
    });

    test('saving a form that changed one value touches only that value', () {
      final base = rec(
        'pay',
        const PaySettings(hourly: 2500, nightPct: 40).toFields(),
        ts: 100,
        dev: 'bbbb',
      );
      final saved = rec(
        'pay',
        const PaySettings(hourly: 2500, nightPct: 45).toFields(),
        ts: 500,
        dev: 'aaaa',
        base: base,
      );
      expect(saved.fields['hourly']!.ts, 100);
      expect(saved.fields['hourly']!.dev, 'bbbb');
      expect(saved.fields['night']!.ts, 500);
      expect(saved.fields['evening']!.ts, 100);
    });

    test('the same setting on both: the later write wins, on both devices', () {
      final base = rec('pay', const PaySettings(hourly: 2500).toFields());
      final early = rec(
        'pay',
        const PaySettings(hourly: 2600).toFields(),
        ts: 2000,
        dev: 'bbbb',
        base: base,
      );
      final late = rec(
        'pay',
        const PaySettings(hourly: 2700).toFields(),
        ts: 3000,
        dev: 'aaaa',
        base: base,
      );
      expect(PaySettings.fromRecord(early.merge(late)).hourly, 2700);
      expect(PaySettings.fromRecord(late.merge(early)).hourly, 2700);
    });

    test('the same moment: the device id decides, the same on both', () {
      final base = rec('pay', const PaySettings(hourly: 2500).toFields());
      final a = rec(
        'pay',
        const PaySettings(hourly: 2600).toFields(),
        ts: 2000,
        dev: 'aaaa',
        base: base,
      );
      final b = rec(
        'pay',
        const PaySettings(hourly: 2700).toFields(),
        ts: 2000,
        dev: 'bbbb',
        base: base,
      );
      expect(PaySettings.fromRecord(a.merge(b)).hourly, 2700);
      expect(PaySettings.fromRecord(b.merge(a)).hourly, 2700);
    });

    test('a goal taken away on one device is gone on the other', () {
      final base = rec(
        'goals',
        const IntakeGoals(kcal: 2000, ml: 2500).toFields(),
        ts: 100,
      );
      final taken = rec(
        'goals',
        const IntakeGoals(ml: 2500).toFields(),
        ts: 300,
        dev: 'bbbb',
        base: base,
      );
      for (final merged in [base.merge(taken), taken.merge(base)]) {
        final g = IntakeGoals.fromRecord(merged);
        expect(g.kcal, isNull);
        expect(g.ml, 2500);
      }
    });

    test('a goal set after another device took it away comes back', () {
      final base = rec('goals', const IntakeGoals(kcal: 2000).toFields());
      final taken = rec(
        'goals',
        const IntakeGoals().toFields(),
        ts: 2000,
        dev: 'aaaa',
        base: base,
      );
      final again = rec(
        'goals',
        const IntakeGoals(kcal: 2300).toFields(),
        ts: 3000,
        dev: 'bbbb',
        base: base,
      );
      for (final merged in [taken.merge(again), again.merge(taken)]) {
        expect(IntakeGoals.fromRecord(merged).kcal, 2300);
      }
    });

    test('a goal taken away EARLIER than another device set it: it stays', () {
      final base = rec('goals', const IntakeGoals(kcal: 2000).toFields());
      final taken = rec(
        'goals',
        const IntakeGoals().toFields(),
        ts: 2000,
        dev: 'aaaa',
        base: base,
      );
      final newer = rec(
        'goals',
        const IntakeGoals(kcal: 2400).toFields(),
        ts: 5000,
        dev: 'bbbb',
        base: base,
      );
      expect(IntakeGoals.fromRecord(taken.merge(newer)).kcal, 2400);
      expect(IntakeGoals.fromRecord(newer.merge(taken)).kcal, 2400);
    });

    test('the list of sports is not mixed from two devices', () {
      final base = rec('plan', const LocalPlanPrefs().toFields(), ts: 100);
      const a = LocalPlanPrefs(
        sports: [
          PlanSport(name: 'Gym', minutes: 60),
          PlanSport(name: 'Úszás', minutes: 45),
        ],
      );
      const b = LocalPlanPrefs(sports: [PlanSport(name: 'Kajak', minutes: 90)]);
      final fromA = rec('plan', a.toFields(), ts: 200, dev: 'aaaa', base: base);
      final fromB = rec('plan', b.toFields(), ts: 300, dev: 'bbbb', base: base);
      for (final merged in [fromA.merge(fromB), fromB.merge(fromA)]) {
        expect(LocalPlanPrefs.fromRecord(merged).sports, b.sports);
      }
    });

    test('the wishes of the planner merge field by field too', () {
      final base = rec('plan', const LocalPlanPrefs().toFields(), ts: 100);
      final weekly = rec(
        'plan',
        const LocalPlanPrefs(perWeek: 5).toFields(),
        ts: 200,
        dev: 'aaaa',
        base: base,
      );
      final band = rec(
        'plan',
        const LocalPlanPrefs(band: PlanBand.morning).toFields(),
        ts: 210,
        dev: 'bbbb',
        base: base,
      );
      for (final merged in [weekly.merge(band), band.merge(weekly)]) {
        final p = LocalPlanPrefs.fromRecord(merged);
        expect(p.perWeek, 5);
        expect(p.band, PlanBand.morning);
        expect(p.sports, defaultPlanSports);
      }
    });

    test('merging is the same in any order and any number of times', () {
      final r1 = rec(
        'pay',
        const PaySettings(hourly: 2500).toFields(),
        ts: 100,
      );
      final r2 = rec(
        'pay',
        const PaySettings(hourly: 2500, eveningPct: 20).toFields(),
        ts: 200,
        dev: 'bbbb',
        base: r1,
      );
      final r3 = rec(
        'pay',
        const PaySettings(hourly: 2600).toFields(),
        ts: 300,
        dev: 'cccc',
        base: r1,
      );
      final once = r1.merge(r2).merge(r3);
      for (final merged in [
        r3.merge(r2).merge(r1),
        r2.merge(r3).merge(r1).merge(r1),
        r1.merge(r3.merge(r2)),
      ]) {
        expect(merged.sameAs(once), isTrue);
      }
      final p = PaySettings.fromRecord(once);
      expect(p.hourly, 2600);
      expect(p.eveningPct, 20);
    });
  });
}
