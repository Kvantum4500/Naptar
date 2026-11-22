import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/intake/intake_ops.dart';
import 'package:kvantum_app/intake/intake_providers.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/ui/charts.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_app/ui/intake/intake_page.dart';
import 'package:kvantum_app/ui/intake/intake_text.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:sqlite3/common.dart' show SqliteException;

import 'support/harness.dart';
import 'support/manual_timers.dart';
import 'support/pickers.dart';
import 'support/semantics_tree.dart';
import 'support/turns.dart';

/// The page of the food and fluid log (8th round): what it shows for a day,
/// the quick drink buttons, the forms, the goals, the days, the charts.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  // 11:30 on the 16th in Budapest: lunch time, a Monday
  var clock = DateTime.utc(2026, 11, 16, 10, 30);
  final today = DateTime.utc(2026, 11, 16);
  late AppDatabase db;

  ProviderContainer scope(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(IntakePage)));

  Future<void> settle(WidgetTester tester) async {
    // the providers read the database for real: let them finish, then draw
    await tester.runAsync(turns);
    await tester.pumpAndSettle();
  }

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(400, 1000),
    double? textScale,
    ThemeData? theme,
    ThemeData? darkTheme,
    ThemeMode themeMode = ThemeMode.light,
    List<FoodEntry> foods = const [],
    List<FluidEntry> drinks = const [],
    IntakeGoals? goals,
    List<Override> overrides = const [],
  }) async {
    useSize(tester, size: size);
    clock = DateTime.utc(2026, 11, 16, 10, 30);
    db = await newDb();
    await tester.pumpWidget(
      app(
        const IntakePage(),
        db,
        extra: [
          appClockProvider.overrideWithValue(() => clock),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ...overrides,
        ],
        textScale: textScale,
        theme: theme,
        darkTheme: darkTheme,
        themeMode: themeMode,
      ),
    );
    await settle(tester);
    // (one write at a time, each followed by a settle: the stream the page
    // listens to is re-read in turns of the fake clock, and a second write
    // would wait for it for ever)
    final c = scope(tester);
    for (final f in foods) {
      await tester.runAsync(() => c.read(intakeOpsProvider).putFood(f));
      await settle(tester);
    }
    for (final w in drinks) {
      await tester.runAsync(() => c.read(intakeOpsProvider).putFluid(w));
      await settle(tester);
    }
    if (goals != null) {
      await tester.runAsync(
        () => c.read(intakeGoalsProvider.notifier).save(goals),
      );
      await settle(tester);
    }
  }

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
    day: day ?? today,
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
    day: day ?? today,
    minute: minute,
    ml: ml,
    kind: kind,
  );

  Finder inKcal(Finder f) =>
      find.descendant(of: find.byKey(const Key('intake-kcal')), matching: f);
  Finder inFluid(Finder f) =>
      find.descendant(of: find.byKey(const Key('intake-fluid')), matching: f);

  Future<IntakeLog> logOf(WidgetTester tester) async => (await tester.runAsync(
    () => scope(tester).read(intakeLogProvider.future),
  ))!;

  Future<void> tapKey(
    WidgetTester tester,
    String key, {
    bool scroll = false,
  }) async {
    if (scroll) {
      // (at a large text size the button may be below the fold of a form;
      // this puts it at the top of what scrolls, so it is not for the page)
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
    }
    await tester.tap(find.byKey(Key(key)));
    await settle(tester);
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  group('a day', () {
    testWidgets('begins on today with nothing logged', (tester) async {
      await boot(tester);
      expect(find.text(intakeDayTitle(today, today)), findsOneWidget);
      expect(find.text('Ma · ${fmtDateLong(today)}'), findsOneWidget);
      expect(find.byKey(const Key('intake-empty')), findsOneWidget);
      expect(inKcal(find.textContaining(formatKcal(0))), findsOneWidget);
      expect(inFluid(find.textContaining(formatVolume(0))), findsOneWidget);
      expect(find.byKey(const Key('intake-today')), findsNothing);
      expect(find.byKey(const Key('intake-kcal-bar')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('with only a drink in it is not an empty day', (tester) async {
      await boot(tester, drinks: [drink('w1')]);
      expect(find.byKey(const Key('intake-empty')), findsNothing);
      expect(inFluid(find.textContaining(formatVolume(200))), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('lists the meals from the first to the last', (tester) async {
      await boot(
        tester,
        size: const Size(400, 1600),
        foods: [
          food('d', meal: Meal.dinner, minute: 19 * 60, name: 'Rakott'),
          food('s', meal: Meal.snack, minute: 16 * 60, name: 'Alma'),
          food('l', meal: Meal.lunch, minute: 13 * 60, name: 'Leves'),
          food('b'),
        ],
      );
      final tops = [
        for (final m in Meal.values)
          tester.getTopLeft(find.byKey(Key('meal-header-${m.key}'))).dy,
      ];
      expect(tops, hasLength(Meal.values.length));
      expect(tops, orderedEquals([...tops]..sort()));
      await shutdown(tester, db);
    });

    testWidgets('shows what was eaten, by meal, with the sums', (tester) async {
      await boot(
        tester,
        foods: [
          food('a', kcal: 300, protein: 10, carbs: 40, fat: 8),
          food(
            'b',
            minute: 13 * 60,
            meal: Meal.lunch,
            name: 'Gyros',
            kcal: 850,
          ),
          food('c', minute: 9 * 60, kcal: 50, name: 'Kávé tejjel'),
        ],
      );
      expect(find.byKey(const Key('intake-empty')), findsNothing);
      expect(inKcal(find.textContaining(formatKcal(1200))), findsOneWidget);
      expect(
        find.text('Reggeli · ${formatKcal(350)}'),
        findsOneWidget,
        reason: 'the breakfast header says what it came to',
      );
      expect(find.text('Ebéd · ${formatKcal(850)}'), findsOneWidget);
      expect(find.byKey(const Key('meal-header-d')), findsNothing);
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(Key('food-$id')), findsOneWidget, reason: id);
      }
      // the line under a food: its time and the macros that were entered
      expect(
        find.text('08:00 · 10 g fehérje · 40 g szénhidrát · 8 g zsír'),
        findsOneWidget,
      );
      expect(find.text('13:00'), findsOneWidget);
      // (within a meal the earlier first: 08:00 before 09:00)
      expect(
        tester.getTopLeft(find.byKey(const Key('food-a'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('food-c'))).dy),
      );
      await shutdown(tester, db);
    });

    testWidgets('a food without a name shows its meal as the title', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [food('a', name: '', meal: Meal.snack)],
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('food-a')),
          matching: find.text('Nasi'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('shows the drinks with their sum', (tester) async {
      await boot(
        tester,
        drinks: [
          drink('w1', ml: 300, kind: DrinkKind.tea),
          drink('w2', ml: 500, minute: 600),
        ],
      );
      expect(find.text('Italok · ${formatVolume(800)}'), findsOneWidget);
      expect(find.text('Tea · ${formatVolume(300)}'), findsOneWidget);
      expect(find.text('Víz · ${formatVolume(500)}'), findsOneWidget);
      expect(inFluid(find.textContaining(formatVolume(800))), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('moves by a day, and back to today', (tester) async {
      await boot(
        tester,
        foods: [
          food('a'),
          food('y', day: DateTime.utc(2026, 11, 15), name: 'Tegnapi'),
        ],
      );
      expect(find.byKey(const Key('food-a')), findsOneWidget);
      await tapKey(tester, 'intake-prev');
      expect(
        find.text('Tegnap · ${fmtDateLong(DateTime.utc(2026, 11, 15))}'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('food-a')), findsNothing);
      expect(find.byKey(const Key('food-y')), findsOneWidget);
      expect(find.byKey(const Key('intake-today')), findsOneWidget);
      await tapKey(tester, 'intake-prev');
      expect(find.byKey(const Key('intake-empty')), findsOneWidget);
      await tapKey(tester, 'intake-today');
      expect(find.byKey(const Key('food-a')), findsOneWidget);
      expect(find.byKey(const Key('intake-today')), findsNothing);
      await tapKey(tester, 'intake-next');
      expect(
        find.text('Holnap · ${fmtDateLong(DateTime.utc(2026, 11, 17))}'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('the date button opens a date picker that moves the day', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-day');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('10'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(scope(tester).read(intakeDayProvider), DateTime.utc(2026, 11, 10));
      await shutdown(tester, db);
    });
  });

  group('the quick drink buttons', () {
    testWidgets('a tap logs the drink at once, with the time now', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'drink-200');
      final w = (await logOf(tester)).fluids.single;
      expect(w.ml, 200);
      expect(w.kind, DrinkKind.water);
      expect(w.day, today);
      expect(w.timeText, '11:30');
      expect(inFluid(find.textContaining(formatVolume(200))), findsOneWidget);
      expect(find.text('Víz · ${formatVolume(200)}'), findsOneWidget);
      expect(find.text('Italok · ${formatVolume(200)}'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('and says so, with a way back', (tester) async {
      await boot(tester);
      await tapKey(tester, 'drink-300');
      expect(find.text('${formatVolume(300)} víz felvéve'), findsOneWidget);
      expect(find.text('Visszavonás'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).fluids, isEmpty);
      expect(find.byKey(const Key('drinks-header')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the four sizes are 1, 2, 3 and 5 decilitres', (tester) async {
      await boot(tester);
      for (final (ml, label) in [
        (100, '1 dl'),
        (200, '2 dl'),
        (300, '3 dl'),
        (500, '5 dl'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('drink-$ml')),
            matching: find.text(formatDeciliters(ml)),
          ),
          findsOneWidget,
          reason: label,
        );
      }
      expect(quickDrinkAmounts, [100, 200, 300, 500]);
      await shutdown(tester, db);
    });

    testWidgets('the kind that is chosen is what is logged', (tester) async {
      await boot(tester);
      expect(find.text('Ital: Víz'), findsOneWidget);
      await tapKey(tester, 'drink-kind');
      await tester.tap(find.byKey(const Key('kind-item-tea')));
      await settle(tester);
      expect(find.text('Ital: Tea'), findsOneWidget);
      await tapKey(tester, 'drink-300');
      expect((await logOf(tester)).fluids.single.kind, DrinkKind.tea);
      expect(find.text('Tea · ${formatVolume(300)}'), findsOneWidget);
      expect(find.text('${formatVolume(300)} tea felvéve'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the form of "Más…" starts with the kind chosen on the page', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'drink-kind');
      await tester.tap(find.byKey(const Key('kind-item-tea')));
      await settle(tester);
      await tapKey(tester, 'drink-other');
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('kind-tea'))).selected,
        isTrue,
      );
      await enter(tester, 'fluid-ml', '250');
      await tapKey(tester, 'fluid-save');
      expect((await logOf(tester)).fluids.single.kind, DrinkKind.tea);
      await shutdown(tester, db);
    });

    testWidgets('on another day the drink is put at noon of that day', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-prev');
      await tapKey(tester, 'drink-500');
      final w = (await logOf(tester)).fluids.single;
      expect(w.day, DateTime.utc(2026, 11, 15));
      expect(w.timeText, '12:00');
      await shutdown(tester, db);
    });

    testWidgets('"Más…" asks for the amount, the kind and the time', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'drink-other');
      expect(find.text('Ital felvétele'), findsOneWidget);
      await enter(tester, 'fluid-ml', '350');
      await tester.tap(find.byKey(const Key('kind-coffee')));
      await tester.pump();
      await tapKey(tester, 'fluid-save');
      final w = (await logOf(tester)).fluids.single;
      expect((w.ml, w.kind, w.timeText), (350, DrinkKind.coffee, '11:30'));
      expect(find.text('Kávé · ${formatVolume(350)}'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('made in the form on another day and at another time: the '
        'page goes there, and the drink can be taken back', (tester) async {
      await boot(tester);
      await tapKey(tester, 'drink-other');
      await enter(tester, 'fluid-ml', '250');
      await tapKey(tester, 'fluid-day');
      await tester.tap(find.text('20'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tapKey(tester, 'fluid-time');
      await typeTimeInPicker(tester, 18, 5);
      await tapKey(tester, 'fluid-save');
      final w = (await logOf(tester)).fluids.single;
      expect(
        (w.day, w.timeText, w.ml),
        (DateTime.utc(2026, 11, 20), '18:05', 250),
      );
      expect(scope(tester).read(intakeDayProvider), DateTime.utc(2026, 11, 20));
      expect(find.text('Ital felvéve'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).fluids, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('the sizes in the form fill the amount in', (tester) async {
      await boot(tester);
      await tapKey(tester, 'drink-other');
      await tester.tap(find.byKey(const Key('fluid-fill-1000')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('fluid-ml')))
            .controller!
            .text,
        '1000',
      );
      await shutdown(tester, db);
    });

    testWidgets('an empty or a silly amount is refused, the form stays', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'drink-other');
      await tapKey(tester, 'fluid-save');
      expect(find.text('Add meg a mennyiséget.'), findsOneWidget);
      await enter(tester, 'fluid-ml', '5');
      await tapKey(tester, 'fluid-save');
      expect(find.textContaining('10 és 3000 ml'), findsOneWidget);
      await enter(tester, 'fluid-ml', '3500');
      await tapKey(tester, 'fluid-save');
      expect(find.textContaining('10 és 3000 ml'), findsOneWidget);
      expect(find.byKey(const Key('fluid-save')), findsOneWidget);
      expect((await logOf(tester)).fluids, isEmpty);
      await tapKey(tester, 'fluid-cancel');
      expect(find.byKey(const Key('fluid-save')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a drink is changed by a tap on it, and removed by its bin', (
      tester,
    ) async {
      await boot(tester, drinks: [drink('w1', ml: 300)]);
      await tapKey(tester, 'drink-w1');
      expect(find.text('Ital szerkesztése'), findsOneWidget);
      await enter(tester, 'fluid-ml', '450');
      await tapKey(tester, 'fluid-save');
      expect((await logOf(tester)).fluids.single.ml, 450);
      expect(find.text('Ital módosítva'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).fluids.single.ml, 300);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('drink-w1')),
          matching: find.byTooltip('Ital törlése'),
        ),
      );
      await settle(tester);
      expect((await logOf(tester)).fluids, isEmpty);
      expect(find.text('Ital törölve'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).fluids.single.ml, 300);
      await shutdown(tester, db);
    });

    testWidgets('a drink can be deleted from its form, too', (tester) async {
      await boot(tester, drinks: [drink('w1')]);
      await tapKey(tester, 'drink-w1');
      await tapKey(tester, 'fluid-delete');
      expect((await logOf(tester)).fluids, isEmpty);
      await shutdown(tester, db);
    });
  });

  group('a food', () {
    testWidgets('is added with the button: name, calories, and the meal that '
        'fits the time', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      expect(find.text('Étel felvétele'), findsOneWidget);
      await enter(tester, 'food-name', 'Zabkása tejjel');
      await enter(tester, 'food-kcal', '320');
      await tapKey(tester, 'food-save');
      final f = (await logOf(tester)).foods.single;
      expect((f.name, f.kcal, f.meal), ('Zabkása tejjel', 320, Meal.lunch));
      expect((f.day, f.timeText), (today, '11:30'));
      expect(inKcal(find.textContaining(formatKcal(320))), findsOneWidget);
      expect(find.text('Ebéd · ${formatKcal(320)}'), findsOneWidget);
      expect(find.text('Étel felvéve'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('that was just added can be taken back at once', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await enter(tester, 'food-name', 'Zabkása tejjel');
      await enter(tester, 'food-kcal', '320');
      await tapKey(tester, 'food-save');
      expect((await logOf(tester)).foods, hasLength(1));
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).foods, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('has the time that is typed in the form, and the meal '
        'follows it until one is chosen', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await enter(tester, 'food-name', 'Reggeli');
      await enter(tester, 'food-kcal', '300');
      await tapKey(tester, 'food-time');
      await typeTimeInPicker(tester, 7, 45);
      await tapKey(tester, 'food-save');
      final f = (await logOf(tester)).foods.single;
      expect((f.timeText, f.meal), ('07:45', Meal.breakfast));
      await shutdown(tester, db);
    });

    testWidgets('the meal can be chosen, and then it is the chosen one', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await tester.tap(find.byKey(const Key('meal-d')));
      await tester.pump();
      await enter(tester, 'food-kcal', '700');
      await tapKey(tester, 'food-save');
      expect((await logOf(tester)).foods.single.meal, Meal.dinner);
      expect(find.byKey(const Key('meal-header-d')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('may have no name', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await enter(tester, 'food-kcal', '120');
      await tapKey(tester, 'food-save');
      expect((await logOf(tester)).foods.single.name, '');
      await shutdown(tester, db);
    });

    testWidgets('the calories come from the macros when they are left out', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      expect(find.byKey(const Key('food-protein')), findsNothing);
      await tapKey(tester, 'food-macros-toggle');
      await enter(tester, 'food-protein', '10');
      await enter(tester, 'food-carbs', '20');
      await enter(tester, 'food-fat', '5');
      await tapKey(tester, 'food-save');
      final f = (await logOf(tester)).foods.single;
      expect(f.kcal, 165);
      expect((f.protein, f.carbs, f.fat), (10, 20, 5));
      expect(
        find.byKey(const Key('macro-Fehérje')),
        findsOneWidget,
        reason: 'the macros of the day are on the card',
      );
      expect(find.text(macroLine('Fehérje', 10, null)), findsOneWidget);
      expect(find.text(macroLine('Szénhidrát', 20, null)), findsOneWidget);
      expect(find.text(macroLine('Zsír', 5, null)), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('neither calories nor macros is refused, in words', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await tapKey(tester, 'food-save');
      expect(
        find.text('Add meg a kalóriát vagy legalább egy makrót.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('food-save')), findsOneWidget);
      await enter(tester, 'food-kcal', '9999');
      await tapKey(tester, 'food-save');
      expect(find.text('A kalória 0 és 5000 között lehet.'), findsOneWidget);
      expect((await logOf(tester)).foods, isEmpty);
      await tapKey(tester, 'food-cancel');
      expect(find.byKey(const Key('food-save')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the number fields of the form take digits only', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      await enter(tester, 'food-kcal', 'a1b2-c');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('food-kcal')))
            .controller!
            .text,
        '12',
      );
      await shutdown(tester, db);
    });

    testWidgets(
      'that is refused has its reason called out to a screen reader',
      (tester) async {
        final handle = tester.ensureSemantics();
        await boot(tester);
        await tapKey(tester, 'intake-add-food');
        await tapKey(tester, 'food-save');
        final error = tester.getSemantics(find.byKey(const Key('food-error')));
        expect(error.flagsCollection.isLiveRegion, isTrue);
        handle.dispose();
        await shutdown(tester, db);
      },
    );

    testWidgets('up to six earlier foods are offered, and no more', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [
          for (var i = 0; i < 8; i++)
            food('e$i', day: DateTime.utc(2026, 11, 1 + i), name: 'Étel $i'),
        ],
      );
      await tapKey(tester, 'intake-add-food');
      expect(find.byKey(const Key('suggest-5')), findsOneWidget);
      expect(find.byKey(const Key('suggest-6')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the meal that was chosen stays when the time changes or an '
        'earlier food is taken up', (tester) async {
      await boot(
        tester,
        foods: [
          food(
            'old',
            day: DateTime.utc(2026, 11, 10),
            name: 'Zabkása',
            kcal: 340,
          ),
        ],
      );
      await tapKey(tester, 'intake-add-food');
      await tester.tap(find.byKey(const Key('meal-d')));
      await tester.pump();
      // (a time of the morning: with no meal chosen it would be a breakfast)
      await tapKey(tester, 'food-time');
      await typeTimeInPicker(tester, 7, 45);
      bool dinner() =>
          tester.widget<ChoiceChip>(find.byKey(const Key('meal-d'))).selected;
      expect(dinner(), isTrue);
      // (and an earlier food, a breakfast, does not take the choice back)
      await tester.tap(find.byKey(const Key('suggest-0')));
      await tester.pump();
      expect(dinner(), isTrue);
      await tapKey(tester, 'food-save');
      expect((await logOf(tester)).foodsOn(today).single.meal, Meal.dinner);
      await shutdown(tester, db);
    });

    testWidgets('earlier foods are offered, and a tap fills the form', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [
          food(
            'old',
            day: DateTime.utc(2026, 11, 10),
            name: 'Zabkása',
            kcal: 340,
            protein: 12,
            carbs: 50,
            fat: 9,
            minute: 7 * 60,
          ),
          food('old2', day: DateTime.utc(2026, 11, 11), name: 'Gyros'),
        ],
      );
      await tapKey(tester, 'intake-add-food');
      expect(find.byKey(const Key('suggest-0')), findsOneWidget);
      await enter(tester, 'food-name', 'zab');
      expect(find.byKey(const Key('suggest-0')), findsOneWidget);
      expect(find.byKey(const Key('suggest-1')), findsNothing);
      await tester.tap(find.byKey(const Key('suggest-0')));
      await tester.pump();
      String text(String key) =>
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
      expect(text('food-name'), 'Zabkása');
      expect(text('food-kcal'), '340');
      expect(text('food-protein'), '12');
      expect(text('food-carbs'), '50');
      expect(text('food-fat'), '9');
      await tapKey(tester, 'food-save');
      final saved = (await logOf(tester)).foodsOn(today).single;
      expect((saved.name, saved.kcal, saved.protein), ('Zabkása', 340, 12));
      await shutdown(tester, db);
    });

    testWidgets('is changed by a tap on it, and the change can be taken back', (
      tester,
    ) async {
      await boot(tester, foods: [food('a', kcal: 300)]);
      await tapKey(tester, 'food-a');
      expect(find.text('Étel szerkesztése'), findsOneWidget);
      await enter(tester, 'food-kcal', '450');
      await tapKey(tester, 'food-save');
      expect((await logOf(tester)).foods.single.kcal, 450);
      expect(inKcal(find.textContaining(formatKcal(450))), findsOneWidget);
      expect(find.text('Étel módosítva'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).foods.single.kcal, 300);
      await shutdown(tester, db);
    });

    testWidgets('is removed by its bin, at once, and brought back', (
      tester,
    ) async {
      await boot(tester, foods: [food('a')]);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('food-a')),
          matching: find.byTooltip('Étel törlése'),
        ),
      );
      await settle(tester);
      expect((await logOf(tester)).foods, isEmpty);
      expect(find.byKey(const Key('food-a')), findsNothing);
      expect(find.text('Étel törölve'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect((await logOf(tester)).foods.single.id, 'a');
      expect(find.byKey(const Key('food-a')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('can be deleted from its form, too', (tester) async {
      await boot(tester, foods: [food('a')]);
      await tapKey(tester, 'food-a');
      await tapKey(tester, 'food-delete');
      expect((await logOf(tester)).foods, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('a new one has no delete button', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-add-food');
      expect(find.byKey(const Key('food-delete')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('moved to another day, the page follows it there', (
      tester,
    ) async {
      await boot(tester, foods: [food('a')]);
      await tapKey(tester, 'food-a');
      await tapKey(tester, 'food-day');
      await tester.tap(find.text('20'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tapKey(tester, 'food-save');
      final f = (await logOf(tester)).foods.single;
      expect(f.day, DateTime.utc(2026, 11, 20));
      expect(scope(tester).read(intakeDayProvider), DateTime.utc(2026, 11, 20));
      expect(find.byKey(const Key('food-a')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the macros of part of the day are said to be part', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [
          food('a', protein: 10),
          food('b', name: 'Más', minute: 9 * 60),
          food('c', name: 'Harmadik', minute: 10 * 60),
        ],
      );
      expect(find.byKey(const Key('macro-note')), findsOneWidget);
      expect(
        find.textContaining('(1 / 3)'),
        findsOneWidget,
        reason: 'one of three foods has macros',
      );
      await shutdown(tester, db);
    });

    testWidgets('every food with macros: the lines, and no note', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [
          food('a', protein: 10),
          food('b', name: 'Más', minute: 9 * 60, carbs: 20),
        ],
      );
      expect(find.byKey(const Key('macro-Fehérje')), findsOneWidget);
      expect(find.byKey(const Key('macro-Szénhidrát')), findsOneWidget);
      expect(find.byKey(const Key('macro-note')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('no macros, no macro lines', (tester) async {
      await boot(tester, foods: [food('a')]);
      expect(find.byKey(const Key('macro-Fehérje')), findsNothing);
      expect(find.byKey(const Key('macro-note')), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the goals', () {
    testWidgets('are set in a form, and kept', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-goals');
      expect(find.text('Napi célok'), findsOneWidget);
      expect(find.textContaining('szinkronizálódnak'), findsOneWidget);
      await enter(tester, 'goal-kcal', '2200');
      await enter(tester, 'goal-ml', '2500');
      await tapKey(tester, 'goals-save');
      final g = scope(tester).read(intakeGoalsProvider).value;
      expect((g!.kcal, g.ml), (2200, 2500));
      expect(find.text('még ${formatKcal(2200)}'), findsOneWidget);
      expect(find.text('még ${formatVolume(2500)}'), findsOneWidget);
      expect(find.byKey(const Key('intake-kcal-bar')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('are five fields, each a goal of its own', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-goals');
      await enter(tester, 'goal-kcal', '2300');
      await enter(tester, 'goal-protein', '120');
      await enter(tester, 'goal-carbs', '260');
      await enter(tester, 'goal-fat', '70');
      await enter(tester, 'goal-ml', '2600');
      await tapKey(tester, 'goals-save');
      final g = scope(tester).read(intakeGoalsProvider).value!;
      expect(
        (g.kcal, g.protein, g.carbs, g.fat, g.ml),
        (2300, 120, 260, 70, 2600),
      );
      await shutdown(tester, db);
    });

    testWidgets('can be as long as the limits: five digits for calories and '
        'fluid', (tester) async {
      await boot(tester);
      await tapKey(tester, 'intake-goals');
      String text(String key) =>
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
      // (a sixth digit is not taken; the grams take four)
      await enter(tester, 'goal-kcal', '123456');
      expect(text('goal-kcal'), '12345');
      await enter(tester, 'goal-kcal', '${IntakeGoals.maxKcal}');
      await enter(tester, 'goal-ml', '${IntakeGoals.maxMl}');
      expect(text('goal-kcal'), '${IntakeGoals.maxKcal}');
      expect(text('goal-ml'), '${IntakeGoals.maxMl}');
      await enter(tester, 'goal-protein', '12345');
      expect(text('goal-protein'), '1234');
      await enter(tester, 'goal-kcal', '${IntakeGoals.maxKcal}');
      await tapKey(tester, 'goals-save');
      // ('1234' grams is too much: the form says so and stays)
      expect(find.byKey(const Key('goals-error')), findsOneWidget);
      await enter(tester, 'goal-protein', '');
      await tapKey(tester, 'goals-save');
      final g = scope(tester).read(intakeGoalsProvider).value!;
      expect((g.kcal, g.ml), (IntakeGoals.maxKcal, IntakeGoals.maxMl));
      await shutdown(tester, db);
    });

    testWidgets('show how far the day is, in words and by a bar', (
      tester,
    ) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2200, ml: 2500),
        foods: [food('a', kcal: 1420)],
        drinks: [drink('w', ml: 1200)],
      );
      expect(find.byKey(const Key('intake-kcal-bar')), findsOneWidget);
      expect(find.text('még ${formatKcal(780)}'), findsOneWidget);
      expect(find.text('még ${formatVolume(1300)}'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('intake-kcal-bar')),
      );
      expect(bar.value, closeTo(1420 / 2200, 0.001));
      await shutdown(tester, db);
    });

    testWidgets('a day over its calorie goal says so, with a mark that is not '
        'only a colour', (tester) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2000),
        foods: [food('a', kcal: 2150)],
      );
      expect(find.text('${formatKcal(150)} a cél fölött'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('intake-kcal-bar')),
      );
      expect(bar.value, 1, reason: 'the bar is full, not beyond');
      await shutdown(tester, db);
    });

    testWidgets('a fluid goal that is reached is a good thing', (tester) async {
      await boot(
        tester,
        goals: const IntakeGoals(ml: 2000),
        drinks: [drink('w', ml: 2500)],
      );
      expect(find.text('${formatVolume(500)} a cél fölött'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a goal that is met exactly says it is done', (tester) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2000),
        foods: [food('a', kcal: 2000)],
      );
      expect(find.text('a cél teljesült'), findsOneWidget);
      // (the tick: not the arrow of a day that is over, nor the flag of one
      // that is still short)
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the macro goals show beside what was eaten', (tester) async {
      await boot(
        tester,
        goals: const IntakeGoals(protein: 150, carbs: 250),
        foods: [food('a', protein: 80, carbs: 100)],
      );
      expect(find.text(macroLine('Fehérje', 80, 150)), findsOneWidget);
      expect(find.text(macroLine('Szénhidrát', 100, 250)), findsOneWidget);
      expect(find.byKey(const Key('macro-Zsír')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a goal that is out of range is refused in the form', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'intake-goals');
      await enter(tester, 'goal-kcal', '100');
      await tapKey(tester, 'goals-save');
      expect(find.textContaining('kalória-cél'), findsOneWidget);
      expect(find.byKey(const Key('goals-save')), findsOneWidget);
      await tapKey(tester, 'goals-cancel');
      expect(find.byKey(const Key('goals-save')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the form starts with the goals that are set, and empty '
        'fields clear them', (tester) async {
      await boot(tester, goals: const IntakeGoals(kcal: 2200, ml: 2500));
      await tapKey(tester, 'intake-goals');
      String text(String key) =>
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
      expect(text('goal-kcal'), '2200');
      expect(text('goal-ml'), '2500');
      expect(text('goal-protein'), '');
      await enter(tester, 'goal-kcal', '');
      await enter(tester, 'goal-ml', '');
      await tapKey(tester, 'goals-save');
      final g = scope(tester).read(intakeGoalsProvider).value;
      expect(g!.isEmpty, isTrue);
      expect(find.byKey(const Key('intake-kcal-bar')), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the last days', () {
    Future<void> toTrend(WidgetTester tester) => tester.scrollUntilVisible(
      find.byKey(const Key('intake-kcal-chart')),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    BarChartPainter painterOf(WidgetTester tester, String key) => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((c) => c.painter)
        .whereType<BarChartPainter>()
        .single;

    testWidgets('are two charts, a week at first', (tester) async {
      await boot(
        tester,
        foods: [food('a', kcal: 2000)],
        drinks: [drink('w', ml: 1500)],
      );
      await toTrend(tester);
      expect(find.byKey(const Key('intake-kcal-chart')), findsOneWidget);
      expect(find.byKey(const Key('intake-fluid-chart')), findsOneWidget);
      final k = painterOf(tester, 'intake-kcal-chart');
      expect(k.values.length, 7);
      expect(k.values.last, 2000);
      expect(k.firstLabel, '11.10.');
      expect(k.lastLabel, 'ma');
      final f = painterOf(tester, 'intake-fluid-chart');
      expect(f.values.last, 1500);
      expect(k.goal, isNull, reason: 'no goal, no line');
      await shutdown(tester, db);
    });

    testWidgets('a month can be asked for', (tester) async {
      await boot(tester, foods: [food('a', kcal: 2000)]);
      await toTrend(tester);
      await tester.tap(find.byKey(const Key('trend-30')));
      await tester.pump();
      expect(painterOf(tester, 'intake-kcal-chart').values.length, 30);
      expect(painterOf(tester, 'intake-fluid-chart').values.length, 30);
      await tester.tap(find.byKey(const Key('trend-7')));
      await tester.pump();
      expect(painterOf(tester, 'intake-kcal-chart').values.length, 7);
      await shutdown(tester, db);
    });

    testWidgets('carry the goal as a dashed line with its label', (
      tester,
    ) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2200, ml: 2500),
        foods: [food('a', kcal: 2500)],
      );
      await toTrend(tester);
      final k = painterOf(tester, 'intake-kcal-chart');
      expect(k.goal, 2200);
      expect(k.goalLabel, 'cél ${formatKcal(2200)}');
      expect(k.maxValue, 2500, reason: 'the scale holds the tallest bar');
      expect(overGoal(k.values, k.goal), [6], reason: 'today is over');
      final f = painterOf(tester, 'intake-fluid-chart');
      expect(f.goal, 2500);
      expect(f.goalLabel, 'cél ${formatVolume(2500)}');
      expect(find.byKey(const Key('intake-trend-note')), findsOneWidget);
      expect(find.textContaining('kis nyíl'), findsOneWidget);
      expect(find.textContaining('▲'), findsNothing, reason: 'no glyph');
      await shutdown(tester, db);
    });

    testWidgets('the scale holds the goal when every bar is lower', (
      tester,
    ) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2200),
        foods: [food('a', kcal: 300)],
      );
      await toTrend(tester);
      expect(painterOf(tester, 'intake-kcal-chart').maxValue, 2500);
      await shutdown(tester, db);
    });

    testWidgets('are told of by the note: the dashed line is there when a '
        'calorie goal is set, or a fluid goal', (tester) async {
      await boot(tester, goals: const IntakeGoals(kcal: 2000));
      await toTrend(tester);
      String note() =>
          tester.widget<Text>(find.byKey(const Key('intake-trend-note'))).data!;
      expect(note(), contains('szaggatott vonal'));
      await shutdown(tester, db);
    });

    testWidgets('are told of by the note with a fluid goal alone, too', (
      tester,
    ) async {
      await boot(tester, goals: const IntakeGoals(ml: 2500));
      await toTrend(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('intake-trend-note'))).data!,
        contains('szaggatott vonal'),
      );
      await shutdown(tester, db);
    });

    testWidgets('are told of by the note without a word of a line when there '
        'is no goal', (tester) async {
      await boot(tester);
      await toTrend(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('intake-trend-note'))).data!,
        isNot(contains('szaggatott')),
      );
      await shutdown(tester, db);
    });

    testWidgets('have a table of the days that begins with today', (
      tester,
    ) async {
      await boot(
        tester,
        foods: [
          food('a', kcal: 2400),
          food('b', day: DateTime.utc(2026, 11, 14), kcal: 1600),
        ],
      );
      await toTrend(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('intake-table')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('intake-table')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intake-table')));
      await tester.pumpAndSettle();
      final log = await logOf(tester);
      final todayRow = find.text(intakeTrendRow(log.totalsOn(today)));
      final olderRow = find.text(
        intakeTrendRow(log.totalsOn(DateTime.utc(2026, 11, 14))),
      );
      expect(
        tester.getTopLeft(todayRow).dy,
        lessThan(tester.getTopLeft(olderRow).dy),
      );
      await shutdown(tester, db);
    });

    testWidgets('are said in words, too: the sentence and the table', (
      tester,
    ) async {
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2000),
        foods: [
          food('a', kcal: 2400),
          food('b', day: DateTime.utc(2026, 11, 14), kcal: 1600),
        ],
      );
      await toTrend(tester);
      final label = tester
          .widget<Semantics>(
            find
                .descendant(
                  of: find.byKey(const Key('intake-kcal-chart')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .label!;
      expect(label, contains('Kalória az elmúlt 7 napban'));
      expect(label, contains('átlag ${formatKcal(2000)} a rögzített 2 napon'));
      expect(
        label,
        contains('a cél ${formatKcal(2000)}, 1 napon volt fölötte'),
      );
      expect(label, contains('Ma ${formatKcal(2400)}'));
      await tester.scrollUntilVisible(
        find.byKey(const Key('intake-table')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('intake-table')),
          matching: find.textContaining('átlag ${formatKcal(2000)}'),
        ),
        findsOneWidget,
        reason: 'the average under the title of the table',
      );
      await tester.ensureVisible(find.byKey(const Key('intake-table')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intake-table')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          intakeTrendRow(
            (await logOf(tester)).totalsOn(DateTime.utc(2026, 11, 14)),
          ),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });
  });

  group('the words for a screen reader', () {
    testWidgets('the macro lines, and the note about them, are read out, too', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2200, protein: 150),
        foods: [
          food('a', protein: 80),
          food('b', name: 'Más', minute: 9 * 60),
        ],
      );
      expect(find.bySemanticsLabel(RegExp('Fehérje 80')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('A makrók összege')), findsOneWidget);
      await shutdown(tester, db);
      handle.dispose();
    });

    testWidgets('the calorie card is one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(
        tester,
        goals: const IntakeGoals(kcal: 2200),
        foods: [food('a', kcal: 1420)],
      );
      expect(
        find.bySemanticsLabel(
          'Kalória: ${formatKcal(1420)}, cél ${formatKcal(2200)}, '
          'még ${formatKcal(780)}.',
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
      handle.dispose();
    });

    testWidgets('the fluid card is one sentence, and a food is one line', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(
        tester,
        foods: [food('a', kcal: 320, name: 'Zabkása')],
        drinks: [drink('w', ml: 300, kind: DrinkKind.tea)],
      );
      expect(
        find.bySemanticsLabel('Folyadék: ${formatVolume(300)}.'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Zabkása, ${formatKcal(320)}, 08:00'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Tea · ${formatVolume(300)}, 09:00'),
        findsOneWidget,
      );
      // (one line each: not also piece by piece under it)
      for (final label in [
        'Zabkása, ${formatKcal(320)}, 08:00',
        'Tea · ${formatVolume(300)}, 09:00',
      ]) {
        expect(
          semanticChildCount(tester, find.bySemanticsLabel(label)),
          0,
          reason: label,
        );
      }
      await shutdown(tester, db);
      handle.dispose();
    });

    testWidgets('the buttons have names', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      for (final t in ['Előző nap', 'Következő nap', 'Az ital fajtája']) {
        expect(find.byTooltip(t), findsOneWidget, reason: t);
      }
      expect(
        find.byTooltip('Felvétel: ${formatDeciliters(200)}'),
        findsOneWidget,
      );
      await shutdown(tester, db);
      handle.dispose();
    });
  });

  group('at the largest text size', () {
    for (final (size, scale, dark) in [
      (const Size(360, 640), 2.0, false),
      (const Size(360, 640), 2.0, true),
      (const Size(360, 800), 1.0, false),
      (const Size(1280, 900), 1.0, true),
    ]) {
      testWidgets('nothing runs over: ${size.width.toInt()} px, ×$scale'
          '${dark ? ', dark' : ''}', (tester) async {
        await boot(
          tester,
          size: size,
          textScale: scale,
          theme: appThemeForTest(Brightness.light),
          darkTheme: appThemeForTest(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          goals: const IntakeGoals(
            kcal: 2200,
            protein: 150,
            carbs: 250,
            fat: 70,
            ml: 2500,
          ),
          foods: [
            food(
              'a',
              name: 'Töltött káposzta tejföllel és friss kenyérrel',
              kcal: 1250,
              protein: 80,
              carbs: 100,
              fat: 30,
            ),
            food('b', minute: 13 * 60, meal: Meal.lunch, name: ''),
          ],
          drinks: [drink('w', ml: 2750, kind: DrinkKind.tea)],
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('intake-fluid-chart')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    }

    testWidgets('and the forms fit, too', (tester) async {
      await boot(tester, size: const Size(360, 640), textScale: 2);
      await tapKey(tester, 'intake-goals');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'goals-cancel', scroll: true);
      await tapKey(tester, 'intake-add-food');
      await tapKey(tester, 'food-macros-toggle', scroll: true);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'food-cancel', scroll: true);
      // (the quick buttons are below the fold of the page at this size)
      await tapKey(tester, 'drink-other', scroll: true);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'fluid-cancel', scroll: true);
      await shutdown(tester, db);
    });
  });

  group('a change that cannot be written', () {
    final diskFull = FileSystemException(
      'x',
      '/p',
      const OSError('No space left on device', 28),
    );
    final diskWords = errorInfoFor(diskFull).text;
    late MemoryDiagSink sink;
    late DiagLog log;

    setUp(() {
      sink = MemoryDiagSink();
      log = DiagLog()..attach(sink);
    });

    Future<void> bootFailing(
      WidgetTester tester, {
      Size size = const Size(400, 1000),
      double? textScale,
      ThemeMode themeMode = ThemeMode.light,
      List<FoodEntry> foods = const [],
      List<FluidEntry> drinks = const [],
    }) => boot(
      tester,
      size: size,
      textScale: textScale,
      theme: appThemeForTest(Brightness.light),
      darkTheme: appThemeForTest(Brightness.dark),
      themeMode: themeMode,
      foods: foods,
      drinks: drinks,
      overrides: [
        intakeOpsProvider.overrideWith(
          (ref) => _FailingOps(ref.watch(recordRepoProvider)),
        ),
        syncedSettingsProvider.overrideWith(
          (ref) => _FailingSettings(ref.watch(recordRepoProvider)),
        ),
        diagLogProvider.overrideWithValue(log),
      ],
    );

    _FailingOps ops(WidgetTester tester) =>
        scope(tester).read(intakeOpsProvider) as _FailingOps;

    _FailingSettings settings(WidgetTester tester) =>
        scope(tester).read(syncedSettingsProvider) as _FailingSettings;

    void fail(WidgetTester tester, [Object? error]) => ops(tester)
      ..error = error ?? diskFull
      ..failing = true;

    Future<String> logged(WidgetTester tester) async {
      await tester.runAsync(log.flush);
      return sink.lines.join('\n');
    }

    String field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    String words(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(Key(key))).data!;

    /// The text of the bar that is up.
    String bar(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .data!;

    Future<void> tapBin(WidgetTester tester, String row, String tip) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(Key(row)),
          matching: find.byTooltip(tip),
        ),
      );
      await settle(tester);
    }

    group('a food', () {
      testWidgets('stays in its form, with what was typed, and says why', (
        tester,
      ) async {
        await bootFailing(tester);
        fail(tester);
        await tapKey(tester, 'intake-add-food');
        await enter(tester, 'food-name', 'Zabkása tejjel');
        await enter(tester, 'food-kcal', '320');
        await tapKey(tester, 'food-save');
        // the form is still there, with the words of the error
        expect(find.byKey(const Key('food-save')), findsOneWidget);
        expect(words(tester, 'food-error'), diskWords);
        expect(diskWords, startsWith('Elfogyott a hely az eszközön.'));
        expect(field(tester, 'food-name'), 'Zabkása tejjel');
        expect(field(tester, 'food-kcal'), '320');
        // nothing is saved, nothing is offered, nothing is shown
        expect((await logOf(tester)).foods, isEmpty);
        expect(find.text('Étel felvéve'), findsNothing);
        expect(find.text('Visszavonás'), findsNothing);
        expect(scope(tester).read(intakeDayProvider), today);
        // the cause is in the log, by its code
        final text = await logged(tester);
        expect(text, contains('food.save_failed'));
        expect(text, isNot(contains('Zabkása')), reason: 'not what was typed');
        // the buttons are free again; with room on the disk the same tap saves
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('food-save')))
              .onPressed,
          isNotNull,
        );
        expect(find.text('Mentés'), findsOneWidget);
        ops(tester).failing = false;
        await tapKey(tester, 'food-save');
        expect(find.byKey(const Key('food-save')), findsNothing);
        expect((await logOf(tester)).foods.single.name, 'Zabkása tejjel');
        expect(find.text('Étel felvéve'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('that is changed stays as it was, and the form says why', (
        tester,
      ) async {
        await bootFailing(tester, foods: [food('a', kcal: 300)]);
        fail(tester, StateError('belső részlet'));
        await tapKey(tester, 'food-a');
        await enter(tester, 'food-kcal', '450');
        await tapKey(tester, 'food-save');
        expect(find.byKey(const Key('food-save')), findsOneWidget);
        // (an error nobody foresaw: told as it is, and the form is the proof
        // that what was typed is not lost)
        expect(words(tester, 'food-error'), errorInfoFor(StateError('x')).text);
        expect(words(tester, 'food-error'), contains('nem vesznek el'));
        expect(words(tester, 'food-error'), isNot(contains('belső részlet')));
        expect(field(tester, 'food-kcal'), '450');
        expect((await logOf(tester)).foods.single.kcal, 300);
        expect(find.text('Étel módosítva'), findsNothing);
        expect(await logged(tester), contains('food.save_failed'));
        await shutdown(tester, db);
      });

      testWidgets('that cannot be deleted from its form stays, and the form '
          'says why', (tester) async {
        await bootFailing(tester, foods: [food('a')]);
        fail(tester);
        await tapKey(tester, 'food-a');
        await tapKey(tester, 'food-delete');
        expect(find.byKey(const Key('food-save')), findsOneWidget);
        expect(words(tester, 'food-error'), diskWords);
        expect((await logOf(tester)).foods.single.id, 'a');
        expect(find.text('Étel törölve'), findsNothing);
        expect(find.byKey(const Key('food-a')), findsOneWidget);
        final text = await logged(tester);
        expect(text, contains('food.delete_failed'));
        expect(text, isNot(contains('food.save_failed')));
        await shutdown(tester, db);
      });

      testWidgets('that is on another day does not take the page there when '
          'it was not saved', (tester) async {
        await bootFailing(tester, foods: [food('a')]);
        fail(tester);
        await tapKey(tester, 'food-a');
        await tapKey(tester, 'food-day');
        await tester.tap(find.text('20'));
        await tester.pump();
        await tester.tap(find.text('OK'));
        await tester.pump();
        await tapKey(tester, 'food-save');
        expect(find.byKey(const Key('food-save')), findsOneWidget);
        expect(scope(tester).read(intakeDayProvider), today);
        expect((await logOf(tester)).foods.single.day, today);
        await shutdown(tester, db);
      });

      testWidgets('that its bin cannot remove says so in the bar, in words '
          'that fit a tap', (tester) async {
        await bootFailing(tester, foods: [food('a')]);
        fail(tester, StateError('belső részlet'));
        await tapBin(tester, 'food-a', 'Étel törlése');
        expect(
          bar(tester),
          'Nem sikerült törölni az ételt: Programhiba történt. '
          'Részletek: Diagnosztika.',
        );
        expect(bar(tester), isNot(contains('nem vesznek el')));
        expect(bar(tester), isNot(contains('belső részlet')));
        expect(find.text('Visszavonás'), findsNothing);
        expect(find.byKey(const Key('food-a')), findsOneWidget);
        expect((await logOf(tester)).foods.single.id, 'a');
        expect(await logged(tester), contains('food.delete_failed'));
        await shutdown(tester, db);
      });

      testWidgets('that its bin cannot remove for want of room says what to '
          'do', (tester) async {
        await bootFailing(tester, foods: [food('a')]);
        fail(tester);
        await tapBin(tester, 'food-a', 'Étel törlése');
        expect(bar(tester), 'Nem sikerült törölni az ételt: $diskWords');
        await shutdown(tester, db);
      });

      testWidgets('is told in the words of the database when that is full', (
        tester,
      ) async {
        await bootFailing(tester);
        final dbFull = SqliteException(
          extendedResultCode: 13,
          message: 'database or disk is full',
        );
        fail(tester, dbFull);
        await tapKey(tester, 'intake-add-food');
        await enter(tester, 'food-kcal', '320');
        await tapKey(tester, 'food-save');
        expect(
          words(tester, 'food-error'),
          startsWith('Elfogyott a hely az adatbázis írásához.'),
        );
        expect(words(tester, 'food-error'), errorInfoFor(dbFull).text);
        await shutdown(tester, db);
      });
    });

    group('a drink', () {
      testWidgets('of a quick button that cannot be written says so in the '
          'bar, and nothing is logged', (tester) async {
        await bootFailing(tester);
        fail(tester);
        await tapKey(tester, 'drink-200');
        expect(bar(tester), 'Nem sikerült felvenni az italt: $diskWords');
        expect((await logOf(tester)).fluids, isEmpty);
        expect(find.textContaining('felvéve'), findsNothing);
        expect(find.text('Visszavonás'), findsNothing);
        expect(await logged(tester), contains('fluid.add_failed'));
        // (the next tap, with room on the disk, goes through)
        ops(tester).failing = false;
        await tapKey(tester, 'drink-200');
        expect((await logOf(tester)).fluids.single.ml, 200);
        expect(find.text('${formatVolume(200)} víz felvéve'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('of the form stays in it, with the amount, and the form '
          'says why', (tester) async {
        await bootFailing(tester);
        fail(tester);
        await tapKey(tester, 'drink-other');
        await enter(tester, 'fluid-ml', '450');
        await tapKey(tester, 'fluid-save');
        expect(find.byKey(const Key('fluid-save')), findsOneWidget);
        expect(words(tester, 'fluid-error'), diskWords);
        expect(field(tester, 'fluid-ml'), '450');
        expect((await logOf(tester)).fluids, isEmpty);
        expect(find.text('Ital felvéve'), findsNothing);
        expect(await logged(tester), contains('fluid.save_failed'));
        ops(tester).failing = false;
        await tapKey(tester, 'fluid-save');
        expect(find.byKey(const Key('fluid-save')), findsNothing);
        expect((await logOf(tester)).fluids.single.ml, 450);
        await shutdown(tester, db);
      });

      testWidgets('that is changed stays as it was, and the form says why', (
        tester,
      ) async {
        await bootFailing(tester, drinks: [drink('w1', ml: 300)]);
        fail(tester);
        await tapKey(tester, 'drink-w1');
        await enter(tester, 'fluid-ml', '450');
        await tapKey(tester, 'fluid-save');
        expect(words(tester, 'fluid-error'), diskWords);
        expect((await logOf(tester)).fluids.single.ml, 300);
        expect(find.text('Ital módosítva'), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('that cannot be deleted from its form stays, and the form '
          'says why', (tester) async {
        await bootFailing(tester, drinks: [drink('w1')]);
        fail(tester);
        await tapKey(tester, 'drink-w1');
        await tapKey(tester, 'fluid-delete');
        expect(find.byKey(const Key('fluid-save')), findsOneWidget);
        expect(words(tester, 'fluid-error'), diskWords);
        expect((await logOf(tester)).fluids, hasLength(1));
        final text = await logged(tester);
        expect(text, contains('fluid.delete_failed'));
        expect(text, isNot(contains('fluid.save_failed')));
        await shutdown(tester, db);
      });

      testWidgets('that its bin cannot remove says so in the bar', (
        tester,
      ) async {
        await bootFailing(tester, drinks: [drink('w1')]);
        fail(tester);
        await tapBin(tester, 'drink-w1', 'Ital törlése');
        expect(bar(tester), 'Nem sikerült törölni az italt: $diskWords');
        expect((await logOf(tester)).fluids, hasLength(1));
        expect(await logged(tester), contains('fluid.delete_failed'));
        await shutdown(tester, db);
      });
    });

    group('the goals', () {
      testWidgets('stay in their form, with what was typed, and the form says '
          'why', (tester) async {
        await bootFailing(tester);
        settings(tester).error = diskFull;
        await tapKey(tester, 'intake-goals');
        await enter(tester, 'goal-kcal', '2200');
        await enter(tester, 'goal-ml', '2500');
        await tapKey(tester, 'goals-save');
        expect(find.byKey(const Key('goals-save')), findsOneWidget);
        expect(words(tester, 'goals-error'), diskWords);
        expect(field(tester, 'goal-kcal'), '2200');
        expect(field(tester, 'goal-ml'), '2500');
        expect(scope(tester).read(intakeGoalsProvider).value!.isEmpty, isTrue);
        expect(find.byKey(const Key('intake-kcal-bar')), findsNothing);
        expect(await logged(tester), contains('goals.save_failed'));
        settings(tester).error = null;
        await tapKey(tester, 'goals-save');
        expect(find.byKey(const Key('goals-save')), findsNothing);
        expect(scope(tester).read(intakeGoalsProvider).value!.kcal, 2200);
        await shutdown(tester, db);
      });
    });

    group('a form', () {
      testWidgets('is held while its write goes on: no second tap, no way '
          'out', (tester) async {
        await bootFailing(tester);
        final gate = Completer<void>();
        ops(tester).gate = gate;
        await tapKey(tester, 'intake-add-food');
        await enter(tester, 'food-kcal', '320');
        await tester.tap(find.byKey(const Key('food-save')));
        await tester.pump();
        expect(find.text('Mentés…'), findsOneWidget);
        for (final key in ['food-save', 'food-cancel']) {
          final onPressed = key == 'food-save'
              ? tester.widget<FilledButton>(find.byKey(Key(key))).onPressed
              : tester.widget<TextButton>(find.byKey(Key(key))).onPressed;
          expect(onPressed, isNull, reason: key);
        }
        // (the way back of the phone does not close it either)
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await tester.pump();
        expect(find.byKey(const Key('food-save')), findsOneWidget);
        expect(ops(tester).writes, 1, reason: 'one write, not two');
        gate.complete();
        await settle(tester);
        expect(find.byKey(const Key('food-save')), findsNothing);
        expect((await logOf(tester)).foods, hasLength(1));
        await shutdown(tester, db);
      });

      testWidgets('with a failed write fits at the largest text size, light '
          'and dark', (tester) async {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await bootFailing(
            tester,
            size: const Size(360, 640),
            textScale: 2,
            themeMode: mode,
          );
          fail(tester);
          await tapKey(tester, 'intake-add-food');
          await enter(tester, 'food-kcal', '320');
          await tapKey(tester, 'food-save', scroll: true);
          expect(find.byKey(const Key('food-error')), findsOneWidget);
          await tester.ensureVisible(find.byKey(const Key('food-error')));
          expect(tester.takeException(), isNull);
          await shutdown(tester, db);
        }
      });
    });
  });
}

/// The ops of the page with writes that fail or wait when a test says so: with
/// [failing] set, every write throws [error] and writes nothing; with [gate]
/// set, a write waits for it first. Both are off until a test turns them on
/// (the page seeds its data through these very ops).
class _FailingOps extends IntakeOps {
  _FailingOps(super.repo);

  bool failing = false;
  Object error = StateError('nincs hely');
  Completer<void>? gate;

  /// How many writes were begun.
  int writes = 0;

  Future<T> _go<T>(Future<T> Function() real) async {
    writes++;
    final g = gate;
    if (g != null) await g.future;
    if (failing) throw error;
    return real();
  }

  @override
  Future<void> putFood(FoodEntry entry) => _go(() => super.putFood(entry));

  @override
  Future<void> putFluid(FluidEntry entry) => _go(() => super.putFluid(entry));

  @override
  Future<FluidEntry> addFluid({
    required DateTime day,
    required int minute,
    required int ml,
    DrinkKind kind = DrinkKind.water,
  }) => _go(() => super.addFluid(day: day, minute: minute, ml: ml, kind: kind));

  @override
  Future<void> saveFood(FoodEntry before, FoodEntry after) =>
      _go(() => super.saveFood(before, after));

  @override
  Future<void> saveFluid(FluidEntry before, FluidEntry after) =>
      _go(() => super.saveFluid(before, after));

  @override
  Future<void> removeFood(FoodEntry e) => _go(() => super.removeFood(e));

  @override
  Future<void> removeFluid(FluidEntry e) => _go(() => super.removeFluid(e));
}

/// The synced settings whose saving of the goals fails while [error] is set.
class _FailingSettings extends SyncedSettings {
  _FailingSettings(super.repo);

  Object? error;

  @override
  Future<void> saveIntakeGoals(IntakeGoals goals) {
    final e = error;
    if (e != null) throw e;
    return super.saveIntakeGoals(goals);
  }
}

ThemeData appThemeForTest(Brightness b) =>
    ThemeData(colorSchemeSeed: Colors.indigo, brightness: b);
