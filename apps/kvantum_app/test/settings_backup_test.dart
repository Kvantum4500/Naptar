import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_dialogs.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'backup_service_test.dart' show Device, device;

/// The settings in a backup (8th round): the wage and its premiums, the goals
/// and the wishes of the planner go in with the rest (they are records like
/// the others), come back on another device, and a restore does not take a
/// newer value of the device away.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  const pay = PaySettings(hourly: 2850, eveningPct: 20, sundayPct: 50);
  const goals = IntakeGoals(kcal: 2200, ml: 2500);
  const plan = LocalPlanPrefs(
    sports: [PlanSport(name: 'Kajak', minutes: 90, outdoor: true)],
    perWeek: 5,
    band: PlanBand.morning,
  );

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

  Future<void> seed(Device d) async {
    final s = SyncedSettings(d.records);
    await s.savePay(pay);
    await s.saveIntakeGoals(goals);
    await s.savePlan(plan);
  }

  group('a backup', () {
    test('holds the three groups of settings, and says how many', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindSettings], 3);
      expect(
        [
          for (final text in file.data.records)
            if (SyncRecord.decode(text).kind == kindSettings)
              SyncRecord.decode(text).id,
        ]..sort(),
        ['goals', 'pay', 'plan'],
      );
    });

    test('says so in words, too', () {
      expect(backupCountsText({kindSettings: 3}), '3 beállítás-csoport');
      expect(
        backupCountsText({kindIntake: 1, kindSettings: 2}),
        '1 étkezési hónap · 2 beállítás-csoport',
      );
      expect(backupCountsText({kindSettings: 0}), 'üres');
    });

    test('of a device that entered nothing holds none', () async {
      final file = await a.service().open(await a.service().create());
      expect(file.meta.counts[kindSettings], 0);
    });

    test('locked, still holds them', () async {
      await seed(a);
      final locked = await a.service().create(password: 'jelszo');
      final file = await a.service().open(locked, password: 'jelszo');
      expect(file.meta.counts[kindSettings], 3);
    });
  });

  group('a restore', () {
    test('brings the settings back on an empty device', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      final preview = await b.service().preview(file);
      expect(preview.records.added, 3);
      final s = SyncedSettings(b.records);
      expect(
        await s.watchPay().first,
        const PaySettings(),
        reason: 'a preview writes nothing',
      );
      await b.service().restore(file, overwrite: false);
      expect(await s.watchPay().first, pay);
      expect(await s.watchIntakeGoals().first, goals);
      expect(await s.watchPlan().first, plan);
    });

    test('queues what it puts back for upload', () async {
      await seed(a);
      final file = await b.service().open(await a.service().create());
      await b.service().restore(file, overwrite: false);
      final dirty = {for (final r in await b.records.dirty()) r.id};
      expect(dirty, containsAll(['pay', 'goals', 'plan']));
    });

    test('on the device it came from changes nothing', () async {
      await seed(a);
      final file = await a.service().open(await a.service().create());
      final preview = await a.service().preview(file);
      expect(preview.changesNothing, isTrue);
      expect(preview.records.same, 3);
    });

    test('does not take away a newer value of the device', () async {
      await seed(a);
      final bytes = await a.service().create();
      // (the wage is raised later: a newer write)
      a.clock.ms += 60000;
      await SyncedSettings(a.records).savePay(pay.copyWith(hourly: 3100));
      final file = await a.service().open(bytes);
      await a.service().restore(file, overwrite: false);
      expect((await SyncedSettings(a.records).watchPay().first).hourly, 3100);
    });

    test(
      'puts back a goal that is gone on the device only if it is newer',
      () async {
        await seed(a);
        final bytes = await a.service().create();
        a.clock.ms += 60000;
        await SyncedSettings(a.records).saveIntakeGoals(const IntakeGoals());
        final file = await a.service().open(bytes);
        await a.service().restore(file, overwrite: false);
        expect(
          (await SyncedSettings(a.records).watchIntakeGoals().first).isEmpty,
          isTrue,
          reason: 'the goals were taken away after the backup was made',
        );
      },
    );
  });
}
