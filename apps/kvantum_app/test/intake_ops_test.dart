import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/intake/intake_ops.dart';
import 'package:kvantum_app/intake/intake_providers.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

/// The food and fluid log in the app (8th round): what is written where, that
/// a move between months is all or nothing, that every change can be taken
/// back, and the goals and the shown day.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  final nov16 = DateTime.utc(2026, 11, 16);
  final clockStart = DateTime.utc(2026, 11, 16, 12);

  late AppDatabase db;
  late RecordRepository repo;
  late int nowMs;
  late int changed;
  late int ids;
  late IntakeOps ops;

  setUp(() async {
    db = await newDb();
    nowMs = clockStart.millisecondsSinceEpoch;
    repo = RecordRepository(db, deviceId: 'dev1', clock: () => nowMs);
    changed = 0;
    ids = 0;
    ops = IntakeOps(
      repo,
      newId: () => 'id${++ids}',
      onChanged: () => changed++,
    );
  });
  tearDown(() => db.close());

  Future<IntakeLog> log() async =>
      IntakeLog.from(await repo.watch(kindIntake).first);

  Future<SyncRecord?> monthRecord(String id) => repo.get(kindIntake, id);

  Future<FoodEntry> addFood({
    DateTime? day,
    int kcal = 300,
    String name = 'Zabkása',
  }) => ops.addFood(
    day: day ?? nov16,
    minute: 8 * 60,
    meal: Meal.breakfast,
    name: name,
    kcal: kcal,
  );

  group('a food', () {
    test('goes into the record of its month, and the sync is asked', () async {
      final e = await addFood();
      expect(e.id, 'id1');
      final r = (await monthRecord('2026-11'))!;
      expect(r.kind, kindIntake);
      expect(r['f.id1'], e.encode());
      expect(r.fields.keys, ['f.id1']);
      expect(changed, 1);
      final l = await log();
      expect(l.foodsOn(nov16).single.name, 'Zabkása');
    });

    test('of another month goes into another record', () async {
      await addFood(day: DateTime.utc(2026, 12, 1));
      expect(await monthRecord('2026-11'), isNull);
      expect(await monthRecord('2026-12'), isNotNull);
    });

    test('two of one day are two fields of one record', () async {
      await addFood();
      await addFood(name: 'Gyros', kcal: 850);
      final r = (await monthRecord('2026-11'))!;
      expect(r.fields.keys.toSet(), {'f.id1', 'f.id2'});
      expect((await log()).totalsOn(nov16).kcal, 1150);
    });

    test('a value that is out of range writes nothing', () async {
      await expectLater(addFood(kcal: 6000), throwsArgumentError);
      await expectLater(
        ops.addFood(day: nov16, minute: 1500, meal: Meal.lunch, kcal: 5),
        throwsArgumentError,
      );
      await expectLater(
        ops.addFood(day: nov16, minute: 60, meal: Meal.lunch),
        throwsArgumentError,
      );
      expect(await monthRecord('2026-11'), isNull);
      expect(changed, 0);
    });

    test('the ids are not reused by the real id maker', () async {
      final real = IntakeOps(repo);
      final a = await real.addFood(
        day: nov16,
        minute: 60,
        meal: Meal.snack,
        kcal: 1,
      );
      final b = await real.addFood(
        day: nov16,
        minute: 60,
        meal: Meal.snack,
        kcal: 1,
      );
      expect(a.id, isNot(b.id));
      expect(a.id.length, 36);
      expect((await log()).foods.length, 2);
    });

    test('saved again, it replaces the old values in its place', () async {
      final before = await addFood();
      final after = FoodEntry.checked(
        id: before.id,
        day: before.day,
        minute: before.minute,
        meal: Meal.lunch,
        name: 'Zabkása nagy',
        kcal: 450,
        protein: 15,
      );
      await ops.saveFood(before, after);
      final l = await log();
      expect(l.foods.length, 1);
      expect(l.foods.single.kcal, 450);
      expect(l.foods.single.meal, Meal.lunch);
      expect(l.foods.single.protein, 15);
      expect(changed, 2);
    });

    test('moved to another month it leaves the old one', () async {
      final before = await addFood(day: DateTime.utc(2026, 11, 30));
      final after = FoodEntry.checked(
        id: before.id,
        day: DateTime.utc(2026, 12, 1),
        minute: before.minute,
        meal: before.meal,
        name: before.name,
        kcal: before.kcal,
      );
      changed = 0;
      await ops.saveFood(before, after);
      expect((await monthRecord('2026-11'))!['f.id1'], isNull);
      expect((await monthRecord('2026-12'))!['f.id1'], after.encode());
      final l = await log();
      expect(l.foods.length, 1);
      expect(l.foods.single.day, DateTime.utc(2026, 12, 1));
      expect(changed, 1, reason: 'one change, one request to the sync');
    });

    test('a move is all or nothing', () async {
      final flaky = _FlakyRepo(db, clock: () => nowMs);
      final o = IntakeOps(flaky, newId: () => 'x1');
      final before = await o.addFood(
        day: DateTime.utc(2026, 11, 30),
        minute: 60,
        meal: Meal.snack,
        kcal: 100,
      );
      final after = FoodEntry.checked(
        id: before.id,
        day: DateTime.utc(2026, 12, 1),
        minute: 60,
        meal: Meal.snack,
        kcal: 100,
      );
      flaky.failOn = 2; // the new place is written, the old one cannot be
      await expectLater(o.saveFood(before, after), throwsStateError);
      expect(await flaky.get(kindIntake, '2026-12'), isNull);
      expect(
        (await flaky.get(kindIntake, '2026-11'))!['f.x1'],
        before.encode(),
      );
    });

    test('a removal can be taken back, and then it wins', () async {
      final e = await addFood();
      await ops.removeFood(e);
      expect((await log()).foods, isEmpty);
      final removedAt = (await monthRecord('2026-11'))!.fields['f.id1']!.ts;
      expect(await ops.restoreFood(e), isTrue);
      final back = (await monthRecord('2026-11'))!.fields['f.id1']!;
      expect(back.ts, greaterThan(removedAt));
      expect((await log()).foods.single.name, 'Zabkása');
    });

    test('a change is taken back, also across months', () async {
      final before = await addFood(day: DateTime.utc(2026, 11, 30));
      final after = FoodEntry.checked(
        id: before.id,
        day: DateTime.utc(2026, 12, 1),
        minute: before.minute,
        meal: before.meal,
        name: before.name,
        kcal: 999,
      );
      await ops.saveFood(before, after);
      expect(await ops.undoSaveFood(before, after), isTrue);
      final l = await log();
      expect(l.foods.length, 1);
      expect(l.foods.single.day, DateTime.utc(2026, 11, 30));
      expect(l.foods.single.kcal, 300);
      expect((await monthRecord('2026-12'))!['f.id1'], isNull);
    });
  });

  group('a drink', () {
    Future<FluidEntry> add({DateTime? day, int ml = 200}) => ops.addFluid(
      day: day ?? nov16,
      minute: 9 * 60,
      ml: ml,
      kind: DrinkKind.tea,
    );

    test('goes into the record of its month', () async {
      final w = await add(ml: 300);
      final r = (await monthRecord('2026-11'))!;
      expect(r['w.id1'], w.encode());
      expect(changed, 1);
      final l = await log();
      expect(l.fluidsOn(nov16).single.ml, 300);
      expect(l.fluidsOn(nov16).single.kind, DrinkKind.tea);
    });

    test('an amount out of range writes nothing', () async {
      await expectLater(add(ml: 5), throwsArgumentError);
      await expectLater(add(ml: 4000), throwsArgumentError);
      expect(await monthRecord('2026-11'), isNull);
      expect(changed, 0);
    });

    test('saved again, moved, removed and taken back', () async {
      final before = await add(day: DateTime.utc(2026, 11, 30));
      final after = FluidEntry.checked(
        id: before.id,
        day: DateTime.utc(2026, 12, 2),
        minute: 600,
        ml: 500,
      );
      await ops.saveFluid(before, after);
      expect((await monthRecord('2026-11'))!['w.id1'], isNull);
      expect((await log()).fluids.single.ml, 500);

      expect(await ops.undoSaveFluid(before, after), isTrue);
      expect((await log()).fluids.single.ml, 200);
      expect((await monthRecord('2026-12'))!['w.id1'], isNull);

      await ops.removeFluid(before);
      expect((await log()).fluids, isEmpty);
      expect(await ops.restoreFluid(before), isTrue);
      expect((await log()).fluids.length, 1);
    });

    test('a drink and a food of one day live in one record', () async {
      await add();
      await addFood();
      final r = (await monthRecord('2026-11'))!;
      expect(r.fields.keys.toSet(), {'w.id1', 'f.id2'});
      final t = (await log()).totalsOn(nov16);
      expect((t.kcal, t.ml), (300, 200));
    });
  });

  group('with another device\'s entries in the record', () {
    test('both are there', () async {
      // (what the sync brought: another device added a food to the month)
      await repo.edit(kindIntake, '2026-11', {
        ...FoodEntry.checked(
          id: 'other',
          day: nov16,
          minute: 700,
          meal: Meal.lunch,
          name: 'Gyros',
          kcal: 850,
        ).fields,
      });
      await addFood();
      final l = await log();
      expect(l.foods.map((f) => f.id).toSet(), {'other', 'id1'});
    });
  });

  group('the stamps', () {
    test('come from the clock of the app', () async {
      await addFood();
      expect((await monthRecord('2026-11'))!.fields['f.id1']!.ts, nowMs);
    });

    test('of one entry never go back, whatever the clock says', () async {
      final before = await addFood();
      final first = (await monthRecord('2026-11'))!.fields['f.id1']!.ts;
      nowMs -= 60000; // a clock that was set back
      final after = FoodEntry.checked(
        id: before.id,
        day: before.day,
        minute: before.minute,
        meal: before.meal,
        name: before.name,
        kcal: 999,
      );
      await ops.saveFood(before, after);
      final second = (await monthRecord('2026-11'))!.fields['f.id1']!.ts;
      expect(second, greaterThan(first));
    });
  });

  group('the provider of the log', () {
    ProviderContainer make() {
      final c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          appClockProvider.overrideWithValue(() => clockStart),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('follows what is written', () async {
      final c = make();
      final sub = c.listen(intakeLogProvider, (_, _) {});
      await pumpEventQueue();
      expect(sub.read().value!.foods, isEmpty);
      await c
          .read(intakeOpsProvider)
          .addFood(
            day: nov16,
            minute: 480,
            meal: Meal.breakfast,
            name: 'Zabkása',
            kcal: 300,
          );
      await pumpEventQueue();
      expect(sub.read().value!.foods.single.name, 'Zabkása');
    });
  });

  group('the goals', () {
    ProviderContainer make() {
      final c = ProviderContainer(overrides: baseOverrides(db));
      addTearDown(c.dispose);
      return c;
    }

    test('are empty until they are set', () async {
      final c = make();
      expect((await c.read(intakeGoalsProvider.future)).isEmpty, isTrue);
    });

    test('are kept on this device, in the settings, not as a record', () async {
      final c = make();
      await c.read(intakeGoalsProvider.future);
      const goals = IntakeGoals(kcal: 2200, protein: 150, ml: 2500);
      await c.read(intakeGoalsProvider.notifier).save(goals);
      expect(c.read(intakeGoalsProvider).value, goals);
      expect(await repo.meta(intakeGoalsKey), goals.encode());
      expect(await repo.watch(kindIntake).first, isEmpty);
      // (a new start reads them back)
      final again = make();
      expect(await again.read(intakeGoalsProvider.future), goals);
    });

    test('saved empty they remove the stored text', () async {
      final c = make();
      await c.read(intakeGoalsProvider.future);
      await c
          .read(intakeGoalsProvider.notifier)
          .save(const IntakeGoals(kcal: 2000));
      await c.read(intakeGoalsProvider.notifier).save(const IntakeGoals());
      expect(await repo.meta(intakeGoalsKey), isNull);
      expect(c.read(intakeGoalsProvider).value!.isEmpty, isTrue);
    });

    test('a stored text that is no goals is no goals', () async {
      await repo.setMeta(intakeGoalsKey, 'not json');
      final c = make();
      expect((await c.read(intakeGoalsProvider.future)).isEmpty, isTrue);
    });

    test('the key is the one the docs name', () {
      expect(intakeGoalsKey, 'intake.goals');
    });
  });

  group('the day that is shown', () {
    late ManualTimers timers;
    late DateTime clock;

    ProviderContainer make(DateTime start) {
      clock = start;
      timers = ManualTimers();
      final c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          appClockProvider.overrideWithValue(() => clock),
          midnightTimerProvider.overrideWithValue(timers.make),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('is today to begin with', () {
      final c = make(DateTime.utc(2026, 11, 16, 12));
      expect(c.read(intakeDayProvider), nov16);
    });

    test('moves a day at a time, across month ends, and can be set', () {
      final c = make(DateTime.utc(2026, 11, 30, 12));
      final day = c.read(intakeDayProvider.notifier);
      day.shift(1);
      expect(c.read(intakeDayProvider), DateTime.utc(2026, 12, 1));
      day.shift(-2);
      expect(c.read(intakeDayProvider), DateTime.utc(2026, 11, 29));
      day.set(DateTime(2027, 1, 5, 23, 30));
      expect(c.read(intakeDayProvider), DateTime.utc(2027, 1, 5));
      expect(c.read(intakeDayProvider).isUtc, isTrue);
    });

    test('whoever looks at today goes on to the next day at midnight', () {
      final c = make(DateTime.utc(2026, 11, 16, 12));
      c.listen(intakeDayProvider, (_, _) {});
      expect(c.read(intakeDayProvider), nov16);
      clock = DateTime.utc(2026, 11, 17, 12);
      timers.current.fire();
      expect(c.read(intakeDayProvider), DateTime.utc(2026, 11, 17));
    });

    test('whoever looks at another day stays there', () {
      final c = make(DateTime.utc(2026, 11, 16, 12));
      c.listen(intakeDayProvider, (_, _) {});
      c.read(intakeDayProvider.notifier).shift(-3);
      clock = DateTime.utc(2026, 11, 17, 12);
      timers.current.fire();
      expect(c.read(intakeDayProvider), DateTime.utc(2026, 11, 13));
    });
  });

  group('the length of the trend', () {
    test('is a week to begin with, and can be a month', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(intakeTrendDaysProvider), 7);
      c.read(intakeTrendDaysProvider.notifier).set(30);
      expect(c.read(intakeTrendDaysProvider), 30);
    });
  });
}

/// A repository whose n-th write fails (to see that a move is all or nothing).
class _FlakyRepo extends RecordRepository {
  _FlakyRepo(super.db, {super.clock}) : super(deviceId: 'flaky');

  int failOn = 0;
  int _writes = 0;

  @override
  Future<SyncRecord> edit(
    String kind,
    String id,
    Map<String, Object?> changes,
  ) async {
    if (failOn > 0 && ++_writes == failOn) throw StateError('disk is gone');
    return super.edit(kind, id, changes);
  }
}
