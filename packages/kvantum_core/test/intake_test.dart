import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The food and fluid log (8th round): the entries, how they are checked, how
/// a month record holds them, what two devices make of the same month, the sums
/// of a day, the goals, the suggestions and the trend.
void main() {
  final nov16 = DateTime.utc(2026, 11, 16);

  FoodEntry food(
    String id, {
    DateTime? day,
    int minute = 8 * 60,
    Meal meal = Meal.breakfast,
    String name = 'Zabkása',
    int? kcal = 300,
    int? protein,
    int? carbs,
    int? fat,
  }) => FoodEntry.checked(
    id: id,
    day: day ?? nov16,
    minute: minute,
    meal: meal,
    name: name,
    kcal: kcal,
    protein: protein,
    carbs: carbs,
    fat: fat,
  );

  FluidEntry drink(
    String id, {
    DateTime? day,
    int minute = 9 * 60,
    int ml = 200,
    DrinkKind kind = DrinkKind.water,
  }) => FluidEntry.checked(
    id: id,
    day: day ?? nov16,
    minute: minute,
    ml: ml,
    kind: kind,
  );

  SyncRecord month(
    String id,
    Map<String, Object?> changes, {
    int ts = 1,
    String dev = 'A',
    SyncRecord? base,
  }) => (base ?? SyncRecord(id: id, kind: kindIntake)).edit(
    changes,
    ts: ts,
    dev: dev,
  );

  /// A log of [foods] and [fluids], each in the record of its own month.
  IntakeLog logOf({
    List<FoodEntry> foods = const [],
    List<FluidEntry> fluids = const [],
  }) {
    final records = <String, SyncRecord>{};
    void put(String monthId, Map<String, Object?> f) {
      records[monthId] = month(monthId, f, base: records[monthId]);
    }

    for (final f in foods) {
      put(intakeMonthId(f.day), f.fields);
    }
    for (final w in fluids) {
      put(intakeMonthId(w.day), w.fields);
    }
    return IntakeLog.from(records.values);
  }

  Matcher argError(String part) => throwsA(
    isA<ArgumentError>().having(
      (e) => '${e.message}',
      'message',
      contains(part),
    ),
  );

  group('the meals', () {
    test('the form starts with the meal that fits the time of day', () {
      for (final (minute, meal) in [
        (0, Meal.breakfast),
        (629, Meal.breakfast), // 10:29
        (630, Meal.lunch), // 10:30
        (899, Meal.lunch), // 14:59
        (900, Meal.snack), // 15:00
        (1019, Meal.snack), // 16:59
        (1020, Meal.dinner), // 17:00
        (1259, Meal.dinner), // 20:59
        (1260, Meal.snack), // 21:00
        (1439, Meal.snack), // 23:59
      ]) {
        expect(Meal.forMinute(minute), meal, reason: '$minute');
      }
    });

    test('a meal is told by its key, and an unknown key is none', () {
      for (final m in Meal.values) {
        expect(Meal.fromKey(m.key), m);
      }
      expect(Meal.fromKey('x'), isNull);
      expect(Meal.fromKey(null), isNull);
      expect(Meal.fromKey(3), isNull);
      expect({for (final m in Meal.values) m.key}.length, Meal.values.length);
    });

    test('the names are the Hungarian ones', () {
      expect(Meal.values.map((m) => m.label), [
        'Reggeli',
        'Ebéd',
        'Vacsora',
        'Nasi',
      ]);
    });
  });

  group('the drinks', () {
    test('a kind is told by its key, and an unknown key is none', () {
      for (final k in DrinkKind.values) {
        expect(DrinkKind.fromKey(k.key), k);
      }
      expect(DrinkKind.fromKey('beer'), isNull);
      expect(DrinkKind.fromKey(null), isNull);
      expect(
        {for (final k in DrinkKind.values) k.key}.length,
        DrinkKind.values.length,
      );
    });

    test('the names are the Hungarian ones', () {
      expect(DrinkKind.values.map((k) => k.label), [
        'Víz',
        'Kávé',
        'Tea',
        'Üdítő',
        'Tej',
        'Egyéb',
      ]);
    });
  });

  group('time and month', () {
    test('a time of day is written with two digits each', () {
      expect(minuteText(0), '00:00');
      expect(minuteText(485), '08:05');
      expect(minuteText(1439), '23:59');
      expect(minuteText(600), '10:00');
    });

    test('the record of a day is named by its month', () {
      expect(intakeMonthId(DateTime.utc(2026, 11, 16)), '2026-11');
      expect(intakeMonthId(DateTime.utc(2027, 1, 1)), '2027-01');
      expect(intakeMonthId(DateTime.utc(2026, 12, 31)), '2026-12');
      expect(intakeMonthId(DateTime(2026, 3, 9, 23, 59)), '2026-03');
    });

    test('the fields of an entry are named by kind and id', () {
      expect(foodFieldKey('a1'), 'f.a1');
      expect(fluidFieldKey('a1'), 'w.a1');
    });

    test('the calories of the macros are 4, 4 and 9 per gram', () {
      expect(kcalFromMacros(protein: 10, carbs: 20, fat: 5), 165);
      expect(kcalFromMacros(protein: 1), 4);
      expect(kcalFromMacros(carbs: 1), 4);
      expect(kcalFromMacros(fat: 1), 9);
      expect(kcalFromMacros(), 0);
    });
  });

  group('a food, checked', () {
    test('the values are kept', () {
      final f = food(
        'a1',
        name: 'Zabkása tejjel',
        kcal: 320,
        protein: 12,
        carbs: 48,
        fat: 9,
      );
      expect(f.id, 'a1');
      expect(f.day, nov16);
      expect(f.minute, 480);
      expect(f.timeText, '08:00');
      expect(f.meal, Meal.breakfast);
      expect(f.name, 'Zabkása tejjel');
      expect(f.title, 'Zabkása tejjel');
      expect(f.kcal, 320);
      expect((f.protein, f.carbs, f.fat), (12, 48, 9));
      expect(f.hasMacros, isTrue);
    });

    test('the name is trimmed, and cut at 60 characters', () {
      expect(food('a', name: '  Zabkása  ').name, 'Zabkása');
      expect(food('a', name: 'x' * 80).name, 'x' * 60);
      expect(food('a', name: 'x' * 59 + ' y').name, 'x' * 59);
    });

    test('a food needs no name: the list then shows the meal', () {
      final f = food('a', name: '   ', meal: Meal.snack);
      expect(f.name, '');
      expect(f.title, 'Nasi');
    });

    test('the day is a date, whatever the time of the one given', () {
      final f = food('a', day: DateTime(2026, 11, 16, 13, 30));
      expect(f.day, nov16);
      expect(f.day.isUtc, isTrue);
    });

    test('the calories are 0 to 5000', () {
      expect(food('a', kcal: 0).kcal, 0);
      expect(food('a', kcal: 5000).kcal, 5000);
      expect(() => food('a', kcal: -1), argError('kalória'));
      expect(() => food('a', kcal: 5001), argError('kalória'));
    });

    test('each macro is 0 to 500 grams', () {
      expect(food('a', protein: 0, carbs: 500, fat: 500).carbs, 500);
      expect(() => food('a', protein: -1), argError('makrók'));
      expect(() => food('a', carbs: 501), argError('makrók'));
      expect(() => food('a', fat: 501), argError('makrók'));
    });

    test('without calories they are worked out from the macros', () {
      final f = food('a', kcal: null, protein: 10, carbs: 20, fat: 5);
      expect(f.kcal, 165);
      expect(food('a', kcal: null, fat: 10).kcal, 90);
    });

    test('calories that are given are not replaced by the macros', () {
      expect(food('a', kcal: 100, protein: 50).kcal, 100);
    });

    test('neither calories nor macros is no food', () {
      expect(() => food('a', kcal: null), argError('Add meg'));
    });

    test('calories worked out may not pass the limit either', () {
      expect(
        () => food('a', kcal: null, carbs: 500, fat: 500),
        argError('kalória'),
      );
    });

    test('the id is a short word of letters, digits, - and _', () {
      expect(food('a-B_9').id, 'a-B_9');
      expect(food('x' * 40).id.length, 40);
      for (final bad in ['', 'a b', 'a.b', 'é', 'x' * 41, 'a/b']) {
        expect(() => food(bad), argError('azonosító'), reason: bad);
      }
    });

    test('the time is a minute of the day', () {
      expect(food('a', minute: 0).timeText, '00:00');
      expect(food('a', minute: 1439).timeText, '23:59');
      expect(() => food('a', minute: -1), argError('időpont'));
      expect(() => food('a', minute: 1440), argError('időpont'));
    });
  });

  group('a food in the record', () {
    test('it is written as one field and read back the same', () {
      final f = food(
        'a1',
        name: 'Gyros',
        kcal: 850,
        minute: 12 * 60 + 40,
        meal: Meal.lunch,
        protein: 40,
        carbs: 70,
        fat: 38,
      );
      expect(f.fields.keys, ['f.a1']);
      final back = FoodEntry.decode('a1', f.fields['f.a1'])!;
      expect(back.id, 'a1');
      expect(back.day, f.day);
      expect(back.minute, f.minute);
      expect(back.meal, Meal.lunch);
      expect(back.name, 'Gyros');
      expect(back.kcal, 850);
      expect((back.protein, back.carbs, back.fat), (40, 70, 38));
    });

    test('only what was given is written', () {
      final j = jsonDecode(
        food('a', name: '', kcal: 100).encode(),
      ) as Map<String, dynamic>;
      expect(j.keys.toSet(), {'day', 'time', 'meal', 'kcal'});
      final k =
          jsonDecode(food('a', protein: 5).encode()) as Map<String, dynamic>;
      expect(k.keys.toSet(), {
        'day',
        'time',
        'meal',
        'name',
        'kcal',
        'protein',
      });
    });

    test('the value is a text, so an unchanged entry is not re-stamped', () {
      final f = food('a', name: 'Gyros');
      final r1 = month('2026-11', f.fields, ts: 10);
      final r2 = r1.edit(f.fields, ts: 99, dev: 'A');
      expect(r2.fields['f.a']!.ts, 10);
    });

    test('removing it writes null into its field', () {
      expect(FoodEntry.removal('a1'), {'f.a1': null});
    });

    test('what cannot be read is no entry', () {
      final good = food('a').encode();
      expect(FoodEntry.decode('a', good), isNotNull);
      for (final bad in <Object?>[
        null,
        5,
        true,
        '',
        'not json',
        '[]',
        '"x"',
        '{}',
        jsonEncode({'time': '08:00', 'kcal': 100}), // no day
        jsonEncode({'day': '2026-11-16', 'kcal': 100}), // no time
        jsonEncode({'day': '2026-11-16', 'time': '08:00'}), // no calories
        jsonEncode({'day': '2026-02-30', 'time': '08:00', 'kcal': 1}),
        jsonEncode({'day': '2026-11-16T00:00', 'time': '08:00', 'kcal': 1}),
        jsonEncode({'day': '2026-11-16', 'time': '8:05', 'kcal': 1}),
        jsonEncode({'day': '2026-11-16', 'time': '24:00', 'kcal': 1}),
        jsonEncode({'day': '2026-11-16', 'time': '08:60', 'kcal': 1}),
        jsonEncode({'day': '2026-11-16', 'time': '08:00', 'kcal': '300'}),
        jsonEncode({'day': '2026-11-16', 'time': '08:00', 'kcal': -1}),
        jsonEncode({'day': '2026-11-16', 'time': '08:00', 'kcal': 5001}),
      ]) {
        expect(FoodEntry.decode('a', bad), isNull, reason: '$bad');
      }
    });

    test('an entry with an id that is no id is not read', () {
      final v = food('a').encode();
      expect(FoodEntry.decode('', v), isNull);
      expect(FoodEntry.decode('a b', v), isNull);
      expect(FoodEntry.decode('x' * 41, v), isNull);
    });

    test('a macro that is out of range is dropped, the entry stays', () {
      final e = FoodEntry.decode(
        'a',
        jsonEncode({
          'day': '2026-11-16',
          'time': '08:00',
          'kcal': 100,
          'protein': 501,
          'carbs': -1,
          'fat': 'x',
        }),
      )!;
      expect(e.kcal, 100);
      expect((e.protein, e.carbs, e.fat), (null, null, null));
      expect(e.hasMacros, isFalse);
    });

    test('an unknown meal reads as the one that fits the time', () {
      String v(String time) => jsonEncode({
        'day': '2026-11-16',
        'time': time,
        'meal': 'z',
        'kcal': 1,
      });
      expect(FoodEntry.decode('a', v('08:00'))!.meal, Meal.breakfast);
      expect(FoodEntry.decode('a', v('12:00'))!.meal, Meal.lunch);
      expect(FoodEntry.decode('a', v('18:00'))!.meal, Meal.dinner);
    });

    test('a name that is too long is cut, other keys are ignored', () {
      final e = FoodEntry.decode(
        'a',
        jsonEncode({
          'day': '2026-11-16',
          'time': '08:00',
          'kcal': 1,
          'name': 'y' * 100,
          'future': {'x': 1},
        }),
      )!;
      expect(e.name, 'y' * 60);
    });
  });

  group('a drink, checked', () {
    test('the values are kept, the kind is water by default', () {
      final w = FluidEntry.checked(
        id: 'w1',
        day: nov16,
        minute: 9 * 60 + 5,
        ml: 300,
      );
      expect(w.id, 'w1');
      expect(w.day, nov16);
      expect(w.timeText, '09:05');
      expect(w.ml, 300);
      expect(w.kind, DrinkKind.water);
    });

    test('the amount is 10 to 3000 millilitres', () {
      expect(drink('a', ml: 10).ml, 10);
      expect(drink('a', ml: 3000).ml, 3000);
      expect(() => drink('a', ml: 9), argError('mennyiség'));
      expect(() => drink('a', ml: 3001), argError('mennyiség'));
      expect(() => drink('a', ml: 0), argError('mennyiség'));
    });

    test('the id and the time are checked like a food\'s', () {
      expect(() => drink(''), argError('azonosító'));
      expect(() => drink('a b'), argError('azonosító'));
      expect(() => drink('a', minute: 1440), argError('időpont'));
      expect(() => drink('a', minute: -1), argError('időpont'));
    });

    test('the day is a date', () {
      expect(drink('a', day: DateTime(2026, 11, 16, 22)).day, nov16);
    });
  });

  group('a drink in the record', () {
    test('it is written as one field and read back the same', () {
      final w = drink('w1', ml: 250, minute: 600, kind: DrinkKind.coffee);
      expect(w.fields.keys, ['w.w1']);
      final back = FluidEntry.decode('w1', w.fields['w.w1'])!;
      expect((back.id, back.day, back.minute), ('w1', nov16, 600));
      expect((back.ml, back.kind), (250, DrinkKind.coffee));
    });

    test('removing it writes null into its field', () {
      expect(FluidEntry.removal('w1'), {'w.w1': null});
    });

    test('an unknown kind reads as "other"', () {
      final e = FluidEntry.decode(
        'a',
        jsonEncode({
          'day': '2026-11-16',
          'time': '09:00',
          'ml': 200,
          'kind': 'beer',
        }),
      )!;
      expect(e.kind, DrinkKind.other);
    });

    test('what cannot be read is no drink', () {
      for (final bad in <Object?>[
        null,
        7,
        'x',
        '[]',
        jsonEncode({'time': '09:00', 'ml': 200}),
        jsonEncode({'day': '2026-11-16', 'ml': 200}),
        jsonEncode({'day': '2026-11-16', 'time': '09:00'}),
        jsonEncode({'day': '2026-11-16', 'time': '09:00', 'ml': 9}),
        jsonEncode({'day': '2026-11-16', 'time': '09:00', 'ml': 3001}),
        jsonEncode({'day': '2026-11-16', 'time': '09:00', 'ml': '200'}),
        jsonEncode({'day': '2026-13-16', 'time': '09:00', 'ml': 200}),
      ]) {
        expect(FluidEntry.decode('a', bad), isNull, reason: '$bad');
      }
      expect(FluidEntry.decode('a b', drink('a').encode()), isNull);
    });
  });

  group('the log of the records', () {
    test('an empty log has nothing in it', () {
      final log = IntakeLog.from(const []);
      expect(log.foods, isEmpty);
      expect(log.fluids, isEmpty);
      expect(log.foodsOn(nov16), isEmpty);
      expect(log.fluidsOn(nov16), isEmpty);
      expect(log.totalsOn(nov16).hasData, isFalse);
      expect(IntakeLog.empty.foods, isEmpty);
      expect(IntakeLog.empty.totalsOn(nov16).kcal, 0);
    });

    test('the entries come back, oldest first, whatever their order', () {
      final log = logOf(
        foods: [
          food('c', day: DateTime.utc(2026, 11, 17), minute: 60),
          food('b', minute: 13 * 60, meal: Meal.lunch),
          food('a', minute: 8 * 60),
          food('z', minute: 8 * 60), // the same minute: by id
          food('d', day: DateTime.utc(2026, 12, 2)),
        ],
        fluids: [
          drink('w2', minute: 700),
          drink('w1', minute: 500),
          drink('w0', day: DateTime.utc(2026, 11, 1)),
        ],
      );
      expect(log.foods.map((f) => f.id), ['a', 'z', 'b', 'c', 'd']);
      expect(log.fluids.map((w) => w.id), ['w0', 'w1', 'w2']);
    });

    test('a day asks for its own entries only', () {
      final log = logOf(
        foods: [
          food('a'),
          food('b', day: DateTime.utc(2026, 11, 17)),
        ],
        fluids: [drink('w', day: DateTime.utc(2026, 11, 17))],
      );
      expect(log.foodsOn(nov16).map((f) => f.id), ['a']);
      expect(log.foodsOn(DateTime.utc(2026, 11, 17)).map((f) => f.id), ['b']);
      expect(log.foodsOn(DateTime.utc(2026, 11, 18)), isEmpty);
      expect(log.fluidsOn(nov16), isEmpty);
      expect(log.fluidsOn(DateTime.utc(2026, 11, 17)).map((w) => w.id), ['w']);
      // (a time of day does not matter)
      expect(log.foodsOn(DateTime(2026, 11, 16, 23, 59)).length, 1);
    });

    test('an entry is found by its id', () {
      final log = logOf(foods: [food('a')], fluids: [drink('w')]);
      expect(log.foodById('a')!.kcal, 300);
      expect(log.foodById('nope'), isNull);
      expect(log.fluidById('w')!.ml, 200);
      expect(log.fluidById('a'), isNull);
    });

    test('other kinds of record are passed over', () {
      final task = SyncRecord(
        id: 't',
        kind: kindTask,
      ).edit({'f.a': food('a').encode()}, ts: 1, dev: 'A');
      final log = IntakeLog.from([task]);
      expect(log.foods, isEmpty);
    });

    test('a removed entry is not there', () {
      var r = month('2026-11', {...food('a').fields, ...drink('w').fields});
      r = r.edit(
        {...FoodEntry.removal('a'), ...FluidEntry.removal('w')},
        ts: 5,
        dev: 'A',
      );
      final log = IntakeLog.from([r]);
      expect(log.foods, isEmpty);
      expect(log.fluids, isEmpty);
    });

    test('an unreadable field does not hide the others', () {
      final r = month('2026-11', {
        ...food('a').fields,
        'f.broken': 'not json',
        'f.worse': 12,
        'w.broken': null,
        'deleted': false,
        'note': 'x',
        'g.other': food('g').encode(),
        ...drink('w').fields,
      });
      final log = IntakeLog.from([r]);
      expect(log.foods.map((f) => f.id), ['a']);
      expect(log.fluids.map((w) => w.id), ['w']);
    });

    test('the day written in the entry decides, not the month record', () {
      final r = month(
        '2026-11',
        food('a', day: DateTime.utc(2026, 12, 5)).fields,
      );
      final log = IntakeLog.from([r]);
      expect(log.foodsOn(DateTime.utc(2026, 12, 5)).length, 1);
      expect(log.foodsOn(nov16), isEmpty);
    });

    test('the same id in two months counts once: the newer write wins', () {
      final nov = month(
        '2026-11',
        food('a', day: DateTime.utc(2026, 11, 30), kcal: 100).fields,
        ts: 10,
      );
      final dec = month(
        '2026-12',
        food('a', day: DateTime.utc(2026, 12, 1), kcal: 400).fields,
        ts: 20,
      );
      for (final order in [
        [nov, dec],
        [dec, nov],
      ]) {
        final log = IntakeLog.from(order);
        expect(log.foods.length, 1);
        expect(log.foods.single.day, DateTime.utc(2026, 12, 1));
        expect(log.foods.single.kcal, 400);
      }
      final novNewer = month(
        '2026-11',
        food('a', day: DateTime.utc(2026, 11, 30), kcal: 100).fields,
        ts: 30,
      );
      final log = IntakeLog.from([novNewer, dec]);
      expect(log.foods.single.kcal, 100);
    });

    test('a removal in the old month does not hide the move', () {
      final nov = month('2026-11', FoodEntry.removal('a'), ts: 30);
      final dec = month(
        '2026-12',
        food('a', day: DateTime.utc(2026, 12, 1)).fields,
        ts: 20,
      );
      expect(IntakeLog.from([nov, dec]).foods.length, 1);
    });
  });

  group('two devices', () {
    test('entries added at the same time to one day are all kept', () {
      final base = SyncRecord(id: '2026-11', kind: kindIntake);
      final phone = base.edit(
        {...food('p1').fields, ...drink('pw').fields},
        ts: 10,
        dev: 'phone',
      );
      final pc = base.edit(
        {...food('c1', name: 'Gyros').fields, ...drink('cw').fields},
        ts: 11,
        dev: 'pc',
      );
      final both = phone.merge(pc);
      expect(both.sameAs(pc.merge(phone)), isTrue);
      final log = IntakeLog.from([both]);
      expect(log.foods.map((f) => f.id).toSet(), {'p1', 'c1'});
      expect(log.fluids.map((w) => w.id).toSet(), {'pw', 'cw'});
    });

    test('a removal and an edit of one entry: the later write wins', () {
      final base = month('2026-11', food('a').fields, ts: 5);
      final removed = base.edit(FoodEntry.removal('a'), ts: 30, dev: 'phone');
      final edited = base.edit(food('a', kcal: 999).fields, ts: 20, dev: 'pc');
      expect(IntakeLog.from([removed.merge(edited)]).foods, isEmpty);
      expect(IntakeLog.from([edited.merge(removed)]).foods, isEmpty);

      final editedLater = base.edit(
        food('a', kcal: 999).fields,
        ts: 40,
        dev: 'pc',
      );
      final back = IntakeLog.from([removed.merge(editedLater)]);
      expect(back.foods.single.kcal, 999);
    });

    test('taking a removal back (undo) wins over the removal', () {
      final base = month('2026-11', food('a').fields, ts: 5);
      final removed = base.edit(FoodEntry.removal('a'), ts: 30, dev: 'A');
      final back = removed.edit(food('a').fields, ts: 31, dev: 'A');
      expect(IntakeLog.from([back]).foods.length, 1);
    });

    test('the same entries in any order of merging give the same log', () {
      final a = month('2026-11', food('a').fields, ts: 1, dev: 'x');
      final b = month('2026-11', food('b', kcal: 5).fields, ts: 2, dev: 'y');
      final c = month('2026-11', FoodEntry.removal('a'), ts: 3, dev: 'z');
      final one = a.merge(b).merge(c);
      final two = c.merge(b).merge(a);
      final three = b.merge(a.merge(c));
      expect(one.sameAs(two), isTrue);
      expect(one.sameAs(three), isTrue);
      expect(IntakeLog.from([one]).foods.map((f) => f.id), ['b']);
    });

    test('the file survives the trip as JSON', () {
      final rec = month('2026-11', {
        ...food('a', name: 'Gyros', kcal: 850).fields,
        ...drink('w', ml: 330).fields,
      });
      final back = SyncRecord.decode(rec.encode());
      expect(back.kind, kindIntake);
      final log = IntakeLog.from([back]);
      expect(log.foods.single.name, 'Gyros');
      expect(log.fluids.single.ml, 330);
    });

    test('the kind is synced and its file name is recognised', () {
      expect(syncedKinds, contains(kindIntake));
      expect(kindIntake, 'intake');
      final name = recordFileName(kindIntake, '2026-11');
      expect(name, 'intake-2026-11.json');
      final m = recordFileNamePattern.firstMatch(name)!;
      expect((m[1], m[2]), (kindIntake, '2026-11'));
      expect(safeRecordFileNamePattern.hasMatch(name), isTrue);
    });
  });

  group('the sums of a day', () {
    final log = logOf(
      foods: [
        food('a', kcal: 300, protein: 10, carbs: 40, fat: 8),
        food('b', minute: 13 * 60, meal: Meal.lunch, name: 'Gyros', kcal: 700),
        food('c', minute: 16 * 60, meal: Meal.snack, kcal: 150, protein: 5),
        food('d', day: DateTime.utc(2026, 11, 17), kcal: 9999 - 5000),
        food('e', minute: 19 * 60, meal: Meal.dinner, name: 'Leves', kcal: 250),
        food('f', minute: 9 * 60, kcal: 50),
      ],
      fluids: [
        drink('w1', ml: 200),
        drink('w2', ml: 300, kind: DrinkKind.coffee),
        drink('w3', day: DateTime.utc(2026, 11, 17), ml: 500),
      ],
    );

    test('the calories, the macros and the drinks are added up', () {
      final t = log.totalsOn(nov16);
      expect(t.day, nov16);
      expect(t.kcal, 300 + 700 + 150 + 250 + 50);
      expect((t.protein, t.carbs, t.fat), (15, 40, 8));
      expect(t.foodCount, 5);
      expect(t.withMacros, 2);
      expect(t.withoutMacros, 3);
      expect(t.ml, 500);
      expect(t.fluidCount, 2);
      expect(t.hasFood && t.hasFluid && t.hasData, isTrue);
    });

    test('every meal has its own sum', () {
      final t = log.totalsOn(nov16);
      expect(t.kcalByMeal, {
        Meal.breakfast: 350,
        Meal.lunch: 700,
        Meal.snack: 150,
        Meal.dinner: 250,
      });
    });

    test('another day does not leak into this one', () {
      final t = log.totalsOn(DateTime.utc(2026, 11, 17));
      expect(t.kcal, 4999);
      expect(t.ml, 500);
      expect(t.foodCount, 1);
    });

    test('a day with nothing is all zeros', () {
      final t = log.totalsOn(DateTime.utc(2026, 11, 1));
      expect((t.kcal, t.protein, t.carbs, t.fat, t.ml), (0, 0, 0, 0, 0));
      expect((t.foodCount, t.fluidCount, t.withMacros), (0, 0, 0));
      expect(t.kcalByMeal, isEmpty);
      expect(t.hasFood || t.hasFluid || t.hasData, isFalse);
    });

    test('a food alone makes a day of data, so does a drink alone', () {
      final onlyFood = logOf(foods: [food('a')]).totalsOn(nov16);
      expect((onlyFood.hasFood, onlyFood.hasFluid), (true, false));
      expect(onlyFood.hasData, isTrue);
      final onlyDrink = logOf(fluids: [drink('w')]).totalsOn(nov16);
      expect((onlyDrink.hasFood, onlyDrink.hasFluid), (false, true));
      expect(onlyDrink.hasData, isTrue);
    });

    test('a time of day in the question does not matter', () {
      expect(log.totalsOn(DateTime(2026, 11, 16, 23, 30)).kcal, 1450);
    });
  });

  group('the goals', () {
    test('nothing is set until it is set', () {
      const g = IntakeGoals();
      expect(g.isEmpty, isTrue);
      expect(g.hasMacroGoal, isFalse);
      expect(g.encode(), '{}');
      expect(IntakeGoals.decode(null).isEmpty, isTrue);
    });

    test('the goals are written and read back', () {
      const g = IntakeGoals(
        kcal: 2200,
        protein: 150,
        carbs: 250,
        fat: 70,
        ml: 2500,
      );
      expect(IntakeGoals.decode(g.encode()), g);
      expect(g.isEmpty, isFalse);
      expect(g.hasMacroGoal, isTrue);
    });

    test('only what is set is written', () {
      expect(const IntakeGoals(kcal: 2200).encode(), '{"kcal":2200}');
      expect(const IntakeGoals(ml: 2500).encode(), '{"ml":2500}');
      expect(const IntakeGoals(fat: 70).hasMacroGoal, isTrue);
      expect(const IntakeGoals(kcal: 1).hasMacroGoal, isFalse);
    });

    test('a stored value that is not usable is not set, the rest stays', () {
      final g = IntakeGoals.decode(
        jsonEncode({
          'kcal': 100, // under 500
          'protein': 0, // under 1
          'carbs': 1001,
          'fat': 'x',
          'ml': 2500,
        }),
      );
      expect(g.kcal, isNull);
      expect(g.protein, isNull);
      expect(g.carbs, isNull);
      expect(g.fat, isNull);
      expect(g.ml, 2500);
      for (final bad in ['', 'x', '[]', '12']) {
        expect(IntakeGoals.decode(bad).isEmpty, isTrue, reason: bad);
      }
    });

    test('typed goals are checked', () {
      expect(IntakeGoals.checked().isEmpty, isTrue);
      expect(IntakeGoals.checked(kcal: 500, ml: 100).kcal, 500);
      expect(IntakeGoals.checked(kcal: 10000, ml: 10000).ml, 10000);
      expect(() => IntakeGoals.checked(kcal: 499), argError('kalória-cél'));
      expect(() => IntakeGoals.checked(kcal: 10001), argError('kalória-cél'));
      expect(() => IntakeGoals.checked(protein: 0), argError('makró-cél'));
      expect(() => IntakeGoals.checked(carbs: 1001), argError('makró-cél'));
      expect(() => IntakeGoals.checked(fat: -5), argError('makró-cél'));
      expect(() => IntakeGoals.checked(ml: 99), argError('folyadék-cél'));
      expect(() => IntakeGoals.checked(ml: 10001), argError('folyadék-cél'));
      expect(IntakeGoals.checked(protein: 1, carbs: 1000).protein, 1);
    });

    test('goals that say the same are equal', () {
      expect(const IntakeGoals(kcal: 1), const IntakeGoals(kcal: 1));
      expect(
        const IntakeGoals(kcal: 1).hashCode,
        const IntakeGoals(kcal: 1).hashCode,
      );
      expect(const IntakeGoals(kcal: 1), isNot(const IntakeGoals(kcal: 2)));
      expect(const IntakeGoals(kcal: 1), isNot(const IntakeGoals(ml: 1)));
      expect(const IntakeGoals(protein: 1), isNot(const IntakeGoals(fat: 1)));
    });
  });

  group('the way to a goal', () {
    test('short of it', () {
      final p = intakeProgress(1420, 2200)!;
      expect(p.done, 1420);
      expect(p.goal, 2200);
      expect(p.left, 780);
      expect(p.fraction, closeTo(0.645, 0.001));
      expect((p.met, p.over), (false, false));
    });

    test('exactly there', () {
      final p = intakeProgress(2200, 2200)!;
      expect(p.left, 0);
      expect(p.fraction, 1);
      expect((p.met, p.over), (true, false));
    });

    test('past it', () {
      final p = intakeProgress(2350, 2200)!;
      expect(p.left, -150);
      expect(p.fraction, greaterThan(1));
      expect((p.met, p.over), (true, true));
    });

    test('without a goal there is no progress', () {
      expect(intakeProgress(500, null), isNull);
    });

    test('a goal of nothing is not divided by', () {
      expect(const IntakeProgress(5, 0).fraction, 0);
    });
  });

  group('the numbers in words', () {
    test('calories have a space between the thousands', () {
      expect(formatKcal(0), '0 kcal');
      expect(formatKcal(999), '999 kcal');
      expect(formatKcal(1000), '1 000 kcal');
      expect(formatKcal(12345), '12 345 kcal');
      expect(formatKcal(-150), '-150 kcal');
    });

    test('grams', () {
      expect(formatGrams(12), '12 g');
      expect(formatGrams(1000), '1 000 g');
    });

    test('a volume is in millilitres under a litre, else in litres', () {
      expect(formatVolume(0), '0 ml');
      expect(formatVolume(300), '300 ml');
      expect(formatVolume(999), '999 ml');
      expect(formatVolume(1000), '1 l');
      expect(formatVolume(1200), '1,2 l');
      expect(formatVolume(1250), '1,25 l');
      expect(formatVolume(1205), '1,205 l');
      expect(formatVolume(2500), '2,5 l');
      expect(formatVolume(10000), '10 l');
    });

    test('the size of a glass is in decilitres', () {
      expect(formatDeciliters(100), '1 dl');
      expect(formatDeciliters(200), '2 dl');
      expect(formatDeciliters(250), '2,5 dl');
      expect(formatDeciliters(50), '0,5 dl');
      expect(formatDeciliters(500), '5 dl');
      expect(formatDeciliters(1000), '10 dl');
    });
  });

  group('the suggestions', () {
    final today = DateTime.utc(2026, 11, 16);
    DateTime ago(int days) => DateTime.utc(2026, 11, 16 - days);

    test('with no query the most used come first', () {
      final log = logOf(
        foods: [
          food('a1', day: ago(5), name: 'Zabkása', kcal: 300),
          food('a2', day: ago(4), name: 'Zabkása', kcal: 310),
          food('a3', day: ago(3), name: 'Zabkása', kcal: 320),
          food('b1', day: ago(1), name: 'Gyros', kcal: 850),
          food('c1', day: ago(2), name: 'Alma', kcal: 80),
          food('c2', day: ago(6), name: 'Alma', kcal: 90),
        ],
      );
      final s = suggestFoods(log, '', today);
      expect(s.map((e) => e.name), ['Zabkása', 'Alma', 'Gyros']);
      expect(s.map((e) => e.uses), [3, 2, 1]);
    });

    test('of equal use the more recent comes first, then the name', () {
      final log = logOf(
        foods: [
          food('a', day: ago(5), name: 'Alma'),
          food('b', day: ago(1), name: 'Banán'),
          food('c', day: ago(1), name: 'Cékla'),
        ],
      );
      expect(suggestFoods(log, '', today).map((e) => e.name), [
        'Banán',
        'Cékla',
        'Alma',
      ]);
    });

    test('the values are those of the last time', () {
      final log = logOf(
        foods: [
          food('a', day: ago(9), name: 'Zabkása', kcal: 300),
          food(
            'b',
            day: ago(2),
            name: 'zabkása  ',
            kcal: 340,
            protein: 12,
            carbs: 50,
            fat: 9,
            minute: 7 * 60,
            meal: Meal.breakfast,
          ),
        ],
      );
      final s = suggestFoods(log, '', today).single;
      expect(s.name, 'zabkása');
      expect(s.kcal, 340);
      expect((s.protein, s.carbs, s.fat), (12, 50, 9));
      expect(s.meal, Meal.breakfast);
      expect(s.uses, 2);
      expect(s.lastDay, ago(2));
    });

    test('a query finds by the start first, then by the middle', () {
      final log = logOf(
        foods: [
          food('a', day: ago(3), name: 'Túrós tészta'),
          food('b', day: ago(2), name: 'Rakott túró'),
          food('c', day: ago(1), name: 'Túró rudi'),
          food('d', day: ago(1), name: 'Alma'),
        ],
      );
      expect(suggestFoods(log, 'túró', today).map((e) => e.name), [
        'Túró rudi',
        'Túrós tészta',
        'Rakott túró',
      ]);
    });

    test('accents, case and spaces of the query do not matter', () {
      final log = logOf(
        foods: [food('a', day: ago(1), name: 'Töltött  Káposzta')],
      );
      for (final q in [
        'toltott',
        'TÖLTÖTT',
        ' toltott kaposzta ',
        'kaposzta',
      ]) {
        expect(suggestFoods(log, q, today).length, 1, reason: q);
      }
      expect(suggestFoods(log, 'zzz', today), isEmpty);
    });

    test('a name written with other accents or spaces is one food', () {
      final log = logOf(
        foods: [
          food('a', day: ago(3), name: 'Rántotta'),
          food('b', day: ago(2), name: 'rantotta'),
          food('c', day: ago(1), name: 'Rántotta  '),
        ],
      );
      final s = suggestFoods(log, '', today);
      expect(s.length, 1);
      expect(s.single.uses, 3);
    });

    test('only the last 180 days and not the future-less old ones', () {
      final log = logOf(
        foods: [
          food('old', day: ago(181), name: 'Régi'),
          food('edge', day: ago(180), name: 'Határ'),
          food('new', day: ago(1), name: 'Új'),
        ],
      );
      expect(suggestFoods(log, '', today).map((e) => e.name), ['Új', 'Határ']);
      expect(suggestFoods(log, '', today, withinDays: 10).map((e) => e.name), [
        'Új',
      ]);
    });

    test('a food without a name is not suggested', () {
      final log = logOf(
        foods: [food('a', day: ago(1), name: '')],
      );
      expect(suggestFoods(log, '', today), isEmpty);
    });

    test('there are at most "limit" of them', () {
      final log = logOf(
        foods: [
          for (var i = 0; i < 20; i++)
            food('f$i', day: ago(1), name: 'Étel ${'abcdefghijklmnopqrst'[i]}'),
        ],
      );
      expect(suggestFoods(log, '', today).length, 8);
      expect(suggestFoods(log, '', today, limit: 3).length, 3);
      expect(suggestFoods(log, 'étel', today, limit: 100).length, 20);
    });

    test('a food of another day is not confused with this one', () {
      final log = logOf(
        foods: [food('a', day: ago(1), name: 'Alma')],
      );
      expect(suggestFoods(log, 'alm', today).single.name, 'Alma');
    });
  });

  group('the trend', () {
    final today = DateTime.utc(2026, 11, 16);
    DateTime ago(int days) => DateTime.utc(2026, 11, 16 - days);

    test('the days are the last n, the oldest first, today last', () {
      final t = buildIntakeTrend(IntakeLog.empty, today, 7);
      expect(t.days.length, 7);
      expect(t.days.first.day, ago(6));
      expect(t.days.last.day, today);
      for (var i = 1; i < t.days.length; i++) {
        expect(t.days[i].day.difference(t.days[i - 1].day).inDays, 1);
      }
    });

    test('a month back crosses the end of the month', () {
      final t = buildIntakeTrend(IntakeLog.empty, today, 30);
      expect(t.days.first.day, DateTime.utc(2026, 10, 18));
      expect(t.days.length, 30);
    });

    test('the number of days is held to 1 … 366', () {
      expect(buildIntakeTrend(IntakeLog.empty, today, 0).days.length, 1);
      expect(buildIntakeTrend(IntakeLog.empty, today, -5).days.length, 1);
      expect(buildIntakeTrend(IntakeLog.empty, today, 5000).days.length, 366);
    });

    test('nothing logged is no average', () {
      final t = buildIntakeTrend(IntakeLog.empty, today, 7);
      expect((t.foodDays, t.fluidDays), (0, 0));
      expect(t.avgKcal, isNull);
      expect(t.avgMl, isNull);
    });

    test('the average is over the days that have something', () {
      final log = logOf(
        foods: [
          food('a', day: ago(0), kcal: 2000),
          food('b', day: ago(2), kcal: 1000),
          food('c', day: ago(2), kcal: 1001),
          food('d', day: ago(20), kcal: 5000), // outside the 7 days
        ],
        fluids: [
          drink('w1', day: ago(1), ml: 1000),
          drink('w2', day: ago(1), ml: 500),
          drink('w3', day: ago(3), ml: 1500),
        ],
      );
      final t = buildIntakeTrend(log, today, 7);
      expect(t.foodDays, 2);
      expect(t.avgKcal, 2001); // (2000 + 2001) / 2 = 2000.5 -> 2001
      expect(t.fluidDays, 2);
      expect(t.avgMl, 1500); // (1500 + 1500) / 2
      expect(t.days.last.kcal, 2000);
      expect(t.days[4].kcal, 2001); // two days ago
      expect(t.days[0].kcal, 0);
    });

    test('a wider window takes more days in', () {
      final log = logOf(
        foods: [
          food('a', day: ago(0), kcal: 2000),
          food('d', day: ago(20), kcal: 1000),
        ],
      );
      expect(buildIntakeTrend(log, today, 7).foodDays, 1);
      final month = buildIntakeTrend(log, today, 30);
      expect(month.foodDays, 2);
      expect(month.avgKcal, 1500);
    });

    test('every day has its macros and meals too', () {
      final log = logOf(foods: [food('a', day: ago(1), kcal: 100, protein: 7)]);
      final t = buildIntakeTrend(log, today, 3);
      expect(t.days[1].protein, 7);
      expect(t.days[1].kcalByMeal, {Meal.breakfast: 100});
    });
  });
}
