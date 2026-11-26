import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_dialogs.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'backup_service_test.dart' show Device, device;

/// The food and fluid log in a backup (8th round): it goes in with the rest,
/// comes back on another device, and a restore never brings back what was
/// removed since.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  final nov16 = DateTime.utc(2026, 11, 16);

  late Device a;
  late Device b;
  setUp(() async {
    a = await device();
    b = await device();
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  FoodEntry food(String id, {int kcal = 300, String name = 'Zabkása'}) =>
      FoodEntry.checked(
        id: id,
        day: nov16,
        minute: 480,
        meal: Meal.breakfast,
        name: name,
        kcal: kcal,
      );

  FluidEntry drink(String id, {int ml = 300}) =>
      FluidEntry.checked(id: id, day: nov16, minute: 540, ml: ml);

  Future<void> seed(Device d) async {
    await d.records.edit(kindIntake, '2026-11', {
      ...food('f1').fields,
      ...food('f2', kcal: 850, name: 'Gyros').fields,
      ...drink('w1').fields,
    });
    await d.records.edit(kindIntake, '2026-10', {
      ...FoodEntry.checked(
        id: 'f0',
        day: DateTime.utc(2026, 10, 15),
        minute: 480,
        meal: Meal.breakfast,
        name: 'Októberi',
        kcal: 300,
      ).fields,
    });
  }

  Future<IntakeLog> logOf(Device d) async =>
      IntakeLog.from(await d.records.all(kindIntake));

  group('a backup', () {
    test('holds the months of the log, and says how many', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindIntake], 2);
      expect([
        for (final text in file.data.records)
          if (SyncRecord.decode(text).kind == kindIntake) text,
      ], hasLength(2));
    });

    test('says so in words, too', () {
      expect(backupCountsText({kindIntake: 2}), '2 étkezési hónap');
      expect(
        backupCountsText({'events': 3, kindIntake: 1}),
        '3 esemény · 1 étkezési hónap',
      );
      expect(backupCountsText({kindIntake: 0}), 'üres');
    });

    test('of a device with nothing in the log holds no month of it', () async {
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindIntake], 0);
    });

    test('locked, still holds it', () async {
      await seed(a);
      final locked = await a.service().create(password: 'jelszo');
      final file = await a.service().open(locked, password: 'jelszo');
      expect(file.meta.counts[kindIntake], 2);
    });
  });

  group('a restore', () {
    test('brings the log back on an empty device', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      final preview = await b.service().preview(file);
      expect(preview.records.added, 2);
      expect(
        (await logOf(b)).foods,
        isEmpty,
        reason: 'a preview writes nothing',
      );
      await b.service().restore(file, overwrite: false);
      final log = await logOf(b);
      expect(log.foods.map((f) => f.id).toSet(), {'f0', 'f1', 'f2'});
      expect(log.fluids.single.ml, 300);
      expect(log.totalsOn(nov16).kcal, 1150);
      expect(log.foodById('f2')!.name, 'Gyros');
    });

    test('queues what it puts back for upload', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      await b.service().restore(file, overwrite: false);
      final dirty = await b.records.dirty();
      expect({
        for (final r in dirty) '${r.kind}:${r.id}',
      }, containsAll(['intake:2026-11', 'intake:2026-10']));
    });

    test('on the device it came from changes nothing', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final preview = await a.service().preview(file);
      expect(preview.changesNothing, isTrue);
      expect(preview.records.same, 2);
    });

    test('does not bring back an entry that was removed since', () async {
      await seed(a);
      final bytes = await a.service().create();
      // (the entry is removed later: a newer write)
      a.clock.ms += 60000;
      await a.records.edit(kindIntake, '2026-11', FoodEntry.removal('f2'));
      expect((await logOf(a)).foodById('f2'), isNull);
      final file = await a.service().open(bytes);
      await a.service().restore(file, overwrite: false);
      expect(
        (await logOf(a)).foodById('f2'),
        isNull,
        reason: 'the backup is older than the removal',
      );
      expect((await logOf(a)).foodById('f1'), isNotNull);
    });

    test('adds what is missing and keeps what is newer', () async {
      await seed(a);
      final bytes = await a.service().create();
      // the other device has its own entry in the same month, and a newer
      // value for one of the backup's
      await b.records.edit(kindIntake, '2026-11', {
        ...food('own', name: 'Saját').fields,
      });
      b.clock.ms += 120000;
      await b.records.edit(kindIntake, '2026-11', {
        ...food('f1', kcal: 111).fields,
      });
      final file = await b.service().open(bytes);
      await b.service().restore(file, overwrite: false);
      final log = await logOf(b);
      expect(log.foodById('own'), isNotNull, reason: 'kept');
      expect(log.foodById('f2'), isNotNull, reason: 'added from the backup');
      expect(log.foodById('f1')!.kcal, 111, reason: 'the newer one is kept');
    });
  });
}
