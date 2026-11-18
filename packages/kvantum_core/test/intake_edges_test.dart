import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The edges of the food and fluid log that nothing held until the deliberate
/// breakage round of the 8th round: what is read back from a record (every
/// limit to the last unit, the meal that was chosen), what a log hands out,
/// the goals one field at a time, and how a suggestion is ordered and worded.
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

  IntakeLog logOf(List<FoodEntry> foods, [List<FluidEntry> fluids = const []]) {
    final records = <String, SyncRecord>{};
    for (final f in foods) {
      final id = intakeMonthId(f.day);
      records[id] = (records[id] ?? SyncRecord(id: id, kind: kindIntake)).edit(
        f.fields,
        ts: 1,
        dev: 'A',
      );
    }
    for (final w in fluids) {
      final id = intakeMonthId(w.day);
      records[id] = (records[id] ?? SyncRecord(id: id, kind: kindIntake)).edit(
        w.fields,
        ts: 1,
        dev: 'A',
      );
    }
    return IntakeLog.from(records.values);
  }

  const when = '"day":"2026-11-16","time":"09:00"';

  group('what is read back from a stored entry', () {
    test('a time or a day with something around it is none', () {
      expect(
        FoodEntry.decode(
          'a',
          '{"day":"2026-11-16","time":"09:00x","kcal":100}',
        ),
        isNull,
      );
      expect(
        FoodEntry.decode(
          'a',
          '{"day":"x2026-11-16","time":"09:00","kcal":100}',
        ),
        isNull,
      );
    });

    test('a number with a fraction is read as the whole it begins with', () {
      expect(FoodEntry.decode('a', '{$when,"kcal":300.5}')!.kcal, 300);
    });

    test('a name that is no text is still a name, and nothing throws', () {
      expect(FoodEntry.decode('a', '{$when,"kcal":100,"name":12}')!.name, '12');
    });

    test('the limits hold to the last unit', () {
      // food: 0 ... 5000 kcal, a macro 0 ... 500 g
      expect(FoodEntry.decode('a', '{$when,"kcal":0}')!.kcal, 0);
      expect(
        FoodEntry.decode('a', '{$when,"kcal":$maxFoodKcal}')!.kcal,
        maxFoodKcal,
      );
      expect(
        FoodEntry.decode('a', '{$when,"kcal":${maxFoodKcal + 1}}'),
        isNull,
      );
      expect(FoodEntry.decode('a', '{$when,"kcal":-1}'), isNull);
      expect(FoodEntry.decode('a', '{$when,"kcal":9,"protein":0}')!.protein, 0);
      expect(
        FoodEntry.decode('a', '{$when,"kcal":9,"fat":$maxMacroGrams}')!.fat,
        maxMacroGrams,
      );
      expect(
        FoodEntry.decode(
          'a',
          '{$when,"kcal":9,"fat":${maxMacroGrams + 1}}',
        )!.fat,
        isNull,
      );
      // drink: 10 ... 3000 ml
      expect(
        FluidEntry.decode('w', '{$when,"ml":$minFluidMl}')!.ml,
        minFluidMl,
      );
      expect(FluidEntry.decode('w', '{$when,"ml":${minFluidMl - 1}}'), isNull);
      expect(
        FluidEntry.decode('w', '{$when,"ml":$maxFluidMl}')!.ml,
        maxFluidMl,
      );
      expect(FluidEntry.decode('w', '{$when,"ml":${maxFluidMl + 1}}'), isNull);
    });

    test('the meal that was chosen is written, and read back', () {
      // (eight in the morning would be a breakfast by the clock)
      final f = food('a', minute: 8 * 60, meal: Meal.dinner);
      expect(f.encode(), contains('"meal":"${Meal.dinner.key}"'));
      expect(FoodEntry.decode('a', f.encode())!.meal, Meal.dinner);
      expect(
        FoodEntry.decode(
          'a',
          '{"day":"2026-11-16","time":"08:00","kcal":9,"meal":"d"}',
        )!.meal,
        Meal.dinner,
      );
      // no meal in the file: the clock decides
      expect(
        FoodEntry.decode(
          'a',
          '{"day":"2026-11-16","time":"08:00","kcal":9}',
        )!.meal,
        Meal.breakfast,
      );
    });

    test('says which limit a calorie of the wrong size broke', () {
      expect(
        () => food('a', kcal: maxFoodKcal + 1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('0 és $maxFoodKcal'),
          ),
        ),
      );
    });

    test('a food has macros when any one of the three was said', () {
      expect(food('a', protein: 1).hasMacros, isTrue);
      expect(food('a', carbs: 1).hasMacros, isTrue);
      expect(food('a', fat: 1).hasMacros, isTrue);
      expect(food('a').hasMacros, isFalse);
    });
  });

  group('what a log hands out', () {
    test('lists that nobody can change from outside', () {
      final log = logOf(
        [food('a')],
        [
          FluidEntry.checked(
            id: 'w',
            day: nov16,
            minute: 9 * 60,
            ml: 200,
            kind: DrinkKind.water,
          ),
        ],
      );
      expect(() => log.foods.add(food('x')), throwsUnsupportedError);
      expect(() => log.fluids.clear(), throwsUnsupportedError);
    });

    test('totals for a day asked with a time of day are those of the day', () {
      final log = logOf([food('a', kcal: 300)]);
      final t = log.totalsOn(DateTime.utc(2026, 11, 16, 15, 30));
      expect(t.kcal, 300);
      expect(t.foodCount, 1);
      expect(t.day, nov16);
    });

    test('the calories by meal are those of the meal that was chosen', () {
      final log = logOf([
        food('a', minute: 8 * 60, meal: Meal.dinner, kcal: 700),
        food('b', minute: 9 * 60, meal: Meal.breakfast, kcal: 200),
      ]);
      final by = log.totalsOn(nov16).kcalByMeal;
      expect(by[Meal.dinner], 700);
      expect(by[Meal.breakfast], 200);
      expect(by.length, 2);
    });
  });

  group('the goals, one field at a time', () {
    test('goals are empty only when nothing at all is set', () {
      expect(const IntakeGoals().isEmpty, isTrue);
      for (final g in const [
        IntakeGoals(kcal: 2000),
        IntakeGoals(protein: 100),
        IntakeGoals(carbs: 200),
        IntakeGoals(fat: 60),
        IntakeGoals(ml: 2500),
      ]) {
        expect(g.isEmpty, isFalse, reason: '$g');
      }
    });

    test('a macro goal is any one of the three', () {
      expect(const IntakeGoals(protein: 100).hasMacroGoal, isTrue);
      expect(const IntakeGoals(carbs: 200).hasMacroGoal, isTrue);
      expect(const IntakeGoals(fat: 60).hasMacroGoal, isTrue);
      expect(const IntakeGoals(kcal: 2000, ml: 2500).hasMacroGoal, isFalse);
    });

    test('what was typed in every field is what is kept', () {
      final g = IntakeGoals.checked(
        kcal: 2000,
        protein: 100,
        carbs: 200,
        fat: 60,
        ml: 2500,
      );
      expect(
        (g.kcal, g.protein, g.carbs, g.fat, g.ml),
        (2000, 100, 200, 60, 2500),
      );
    });

    test('goals that differ in any one field are not equal', () {
      const base = IntakeGoals(
        kcal: 2000,
        protein: 100,
        carbs: 200,
        fat: 60,
        ml: 2500,
      );
      expect(
        base,
        const IntakeGoals(
          kcal: 2000,
          protein: 100,
          carbs: 200,
          fat: 60,
          ml: 2500,
        ),
      );
      for (final other in const [
        IntakeGoals(kcal: 2001, protein: 100, carbs: 200, fat: 60, ml: 2500),
        IntakeGoals(kcal: 2000, protein: 101, carbs: 200, fat: 60, ml: 2500),
        IntakeGoals(kcal: 2000, protein: 100, carbs: 201, fat: 60, ml: 2500),
        IntakeGoals(kcal: 2000, protein: 100, carbs: 200, fat: 61, ml: 2500),
        IntakeGoals(kcal: 2000, protein: 100, carbs: 200, fat: 60, ml: 2501),
      ]) {
        expect(base == other, isFalse, reason: '$other');
        expect(base.hashCode == other.hashCode, isFalse, reason: '$other');
      }
    });

    test('a goal read from a record is a goal only within its limits', () {
      IntakeGoals read(Map<String, Object?> f) => IntakeGoals.fromRecord(
        SyncRecord(
          id: settingsGoalsId,
          kind: kindSettings,
        ).edit(f, ts: 1, dev: 'A'),
      );
      expect(read({'kcal': IntakeGoals.maxKcal}).kcal, IntakeGoals.maxKcal);
      expect(read({'kcal': IntakeGoals.maxKcal + 1}).kcal, isNull);
      expect(read({'kcal': IntakeGoals.minKcal}).kcal, IntakeGoals.minKcal);
      expect(read({'kcal': IntakeGoals.minKcal - 1}).kcal, isNull);
      expect(read({'ml': IntakeGoals.minMl}).ml, IntakeGoals.minMl);
      expect(read({'ml': IntakeGoals.minMl - 1}).ml, isNull);
      expect(read({'ml': IntakeGoals.maxMl + 1}).ml, isNull);
      expect(read({'fat': IntakeGoals.minGrams}).fat, IntakeGoals.minGrams);
      expect(read({'fat': IntakeGoals.minGrams - 1}).fat, isNull);
      expect(read({'fat': IntakeGoals.maxGrams + 1}).fat, isNull);
    });
  });

  group('how a suggestion is worded and ordered', () {
    final today = DateTime.utc(2026, 11, 16);

    test('the meal of a suggestion is that of the last time', () {
      final log = logOf([
        food('a', day: DateTime.utc(2026, 11, 11), name: 'Alma'),
        food(
          'b',
          day: DateTime.utc(2026, 11, 15),
          name: 'Alma',
          meal: Meal.dinner,
          minute: 8 * 60,
        ),
      ]);
      final s = suggestFoods(log, '', today).single;
      expect(s.meal, Meal.dinner);
      expect(s.uses, 2);
    });

    test('with equal use and day the names are ordered without accents', () {
      final log = logOf([food('a', name: 'Barack'), food('b', name: 'Árpa')]);
      expect(suggestFoods(log, '', today).map((e) => e.name), [
        'Árpa',
        'Barack',
      ]);
    });
  });

  group('a glass is told in decilitres', () {
    test('with as many decimals as it needs, up to two', () {
      expect(formatDeciliters(200), '2 dl');
      expect(formatDeciliters(250), '2,5 dl');
      expect(formatDeciliters(225), '2,25 dl');
      expect(formatDeciliters(50), '0,5 dl');
    });
  });
}
