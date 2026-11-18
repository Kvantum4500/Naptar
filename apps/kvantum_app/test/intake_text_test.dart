import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ui/intake/intake_text.dart';
import 'package:kvantum_core/kvantum_core.dart';

/// The words of the food and fluid page (8th round), without drawing.
void main() {
  setUpAll(() async => initializeDateFormatting('hu'));

  const nbsp = ' ';
  final nov16 = DateTime.utc(2026, 11, 16);

  FoodEntry food({
    int kcal = 300,
    String name = 'Zabkása',
    int? p,
    int? c,
    int? f,
    int minute = 480,
    Meal meal = Meal.breakfast,
  }) => FoodEntry.checked(
    id: 'a',
    day: nov16,
    minute: minute,
    meal: meal,
    name: name,
    kcal: kcal,
    protein: p,
    carbs: c,
    fat: f,
  );

  group('how far a day is from a goal', () {
    test('short of it: what is left', () {
      expect(kcalWords(const IntakeProgress(1420, 2200)), 'még 780${nbsp}kcal');
      expect(volumeWords(const IntakeProgress(1200, 2500)), 'még 1,3${nbsp}l');
      expect(gramsWords(const IntakeProgress(80, 150)), 'még 70${nbsp}g');
    });

    test('exactly there', () {
      expect(kcalWords(const IntakeProgress(2200, 2200)), 'a cél teljesült');
      expect(volumeWords(const IntakeProgress(2500, 2500)), 'a cél teljesült');
    });

    test('past it: by how much', () {
      expect(
        kcalWords(const IntakeProgress(2350, 2200)),
        '150${nbsp}kcal a cél fölött',
      );
      expect(
        volumeWords(const IntakeProgress(3000, 2500)),
        '500${nbsp}ml a cél fölött',
      );
    });

    test('a thousand is written with a space, as everywhere', () {
      expect(
        kcalWords(const IntakeProgress(0, 2200)),
        'még 2${nbsp}200${nbsp}kcal',
      );
    });
  });

  group('the day', () {
    test('is named as today, yesterday or tomorrow, else by its date', () {
      String long(DateTime d) => intakeDayTitle(d, d).substring(5);
      expect(intakeDayTitle(nov16, nov16), 'Ma · ${long(nov16)}');
      final y = DateTime.utc(2026, 11, 15);
      expect(intakeDayTitle(y, nov16), 'Tegnap · ${long(y)}');
      final t = DateTime.utc(2026, 11, 17);
      expect(intakeDayTitle(t, nov16), 'Holnap · ${long(t)}');
      final far = DateTime.utc(2026, 11, 1);
      expect(intakeDayTitle(far, nov16), long(far));
      expect(intakeDayTitle(far, nov16).contains('Ma'), isFalse);
    });

    test('across the end of a month, too', () {
      final end = DateTime.utc(2026, 11, 30);
      expect(
        intakeDayTitle(DateTime.utc(2026, 12, 1), end).startsWith('Holnap'),
        isTrue,
      );
      expect(
        intakeDayTitle(end, DateTime.utc(2026, 12, 1)).startsWith('Tegnap'),
        isTrue,
      );
    });

    test('the short form under a chart', () {
      expect(intakeDayShort(DateTime.utc(2026, 11, 5)), '11.05.');
      expect(intakeDayShort(DateTime.utc(2026, 1, 20)), '01.20.');
    });
  });

  group('what a screen reader says', () {
    test('the calories, with and without a goal', () {
      final day = DayTotals(day: nov16, kcal: 1420, foodCount: 2);
      expect(
        spokenKcal(day, const IntakeGoals()),
        'Kalória: 1${nbsp}420${nbsp}kcal.',
      );
      expect(
        spokenKcal(day, const IntakeGoals(kcal: 2200)),
        'Kalória: 1${nbsp}420${nbsp}kcal, cél 2${nbsp}200${nbsp}kcal, '
        'még 780${nbsp}kcal.',
      );
      expect(
        spokenKcal(day, const IntakeGoals(kcal: 1000)),
        contains('420${nbsp}kcal a cél fölött'),
      );
    });

    test('the fluids, with and without a goal', () {
      final day = DayTotals(day: nov16, ml: 1200, fluidCount: 4);
      expect(spokenFluid(day, const IntakeGoals()), 'Folyadék: 1,2${nbsp}l.');
      expect(
        spokenFluid(day, const IntakeGoals(ml: 2500)),
        'Folyadék: 1,2${nbsp}l, cél 2,5${nbsp}l, még 1,3${nbsp}l.',
      );
    });

    test('a food and a drink', () {
      expect(
        spokenFood(food(p: 10)),
        'Zabkása, 300${nbsp}kcal, 08:00 · 10 g fehérje',
      );
      final w = FluidEntry.checked(
        id: 'w',
        day: nov16,
        minute: 9 * 60 + 5,
        ml: 300,
        kind: DrinkKind.tea,
      );
      expect(spokenDrink(w), 'Tea · 300${nbsp}ml, 09:05');
      expect(drinkTitle(w), 'Tea · 300${nbsp}ml');
    });
  });

  group('the lines of the list', () {
    test('a food: the time, and the macros that were entered', () {
      expect(foodDetail(food()), '08:00');
      expect(foodDetail(food(p: 10)), '08:00 · 10 g fehérje');
      expect(
        foodDetail(food(p: 10, c: 20, f: 5)),
        '08:00 · 10 g fehérje · 20 g szénhidrát · 5 g zsír',
      );
      expect(foodDetail(food(c: 20)), '08:00 · 20 g szénhidrát');
      expect(foodDetail(food(f: 0)), '08:00 · 0 g zsír');
      // (a zero that was entered is told, as nothing is not)
      expect(foodDetail(food(c: 0)), '08:00 · 0 g szénhidrát');
      expect(foodDetail(food(p: 0)), '08:00 · 0 g fehérje');
    });

    test('a macro line, with and without a goal', () {
      expect(macroLine('Fehérje', 80, null), 'Fehérje 80${nbsp}g');
      expect(
        macroLine('Fehérje', 80, 150),
        'Fehérje 80${nbsp}g / 150${nbsp}g · még 70${nbsp}g',
      );
      expect(
        macroLine('Zsír', 90, 70),
        'Zsír 90${nbsp}g / 70${nbsp}g · 20${nbsp}g a cél fölött',
      );
    });
  });

  group('the table under the charts', () {
    test('a day with something: calories and fluids', () {
      final d = DayTotals(
        day: nov16,
        kcal: 1420,
        foodCount: 2,
        ml: 1200,
        fluidCount: 3,
      );
      expect(
        intakeTrendRow(d),
        endsWith(': 1${nbsp}420${nbsp}kcal · 1,2${nbsp}l'),
      );
    });

    test('only what was logged is told', () {
      expect(
        intakeTrendRow(DayTotals(day: nov16, kcal: 5, foodCount: 1)),
        endsWith(': 5${nbsp}kcal'),
      );
      expect(
        intakeTrendRow(DayTotals(day: nov16, ml: 300, fluidCount: 1)),
        endsWith(': 300${nbsp}ml'),
      );
    });

    test('a day with nothing says so (it is not a day of zero)', () {
      expect(
        intakeTrendRow(DayTotals(day: nov16)),
        endsWith(': nincs rögzítés'),
      );
    });
  });

  group('the sentence for a chart', () {
    List<DayTotals> week(List<int> kcal, {List<bool>? food}) => [
      for (var i = 0; i < kcal.length; i++)
        DayTotals(
          day: DateTime.utc(2026, 11, 10 + i),
          kcal: kcal[i],
          foodCount: (food ?? [for (final k in kcal) k > 0])[i] ? 1 : 0,
        ),
    ];

    String say(List<DayTotals> days, {int? goal}) => intakeBarsLabel(
      what: 'Kalória',
      days: days,
      of: (d) => d.kcal,
      recorded: (d) => d.hasFood,
      amount: formatKcal,
      goal: goal,
    );

    test('nothing logged', () {
      expect(
        say(week([0, 0, 0])),
        'Kalória az elmúlt 3 napban: nincs rögzítés.',
      );
    });

    test('the average is over the days that have something', () {
      final s = say(week([2000, 0, 1000, 0, 3000]));
      expect(s, contains('az elmúlt 5 napban'));
      expect(s, contains('átlag 2${nbsp}000${nbsp}kcal a rögzített 3 napon'));
      expect(s, contains('Ma 3${nbsp}000${nbsp}kcal.'));
    });

    test('today with nothing yet', () {
      final s = say(week([2000, 0]));
      expect(s, endsWith('Ma még nincs rögzítés.'));
    });

    test('with a goal: how many days were over it', () {
      final s = say(week([2500, 1000, 2100, 1900]), goal: 2000);
      expect(s, contains('a cél 2${nbsp}000${nbsp}kcal, 2 napon volt fölötte'));
    });

    test('a day exactly at the goal is not over it', () {
      expect(say(week([2000]), goal: 2000), contains('0 napon volt fölötte'));
    });

    test('without a goal it does not talk of one', () {
      expect(say(week([100, 200])), isNot(contains('cél')));
    });

    test('the average is rounded', () {
      // (1001 + 1002) / 2 = 1001.5 -> 1002
      expect(say(week([1001, 1002])), contains('átlag 1${nbsp}002${nbsp}kcal'));
    });
  });
}
