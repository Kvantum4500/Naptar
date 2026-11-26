import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_app/drive/drive_sync_engine.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/harness.dart';

/// The settings on two devices (8th round): what is entered on one reaches the
/// other through Drive, as its own small files, and a setting changed on each
/// device in the meantime is not lost on either.
void main() {
  // several in-memory databases = several devices in these tests
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase dbA;
  late AppDatabase dbB;
  late RecordRepository repoA;
  late RecordRepository repoB;
  late SyncedSettings a;
  late SyncedSettings b;
  late FakeDrive drive;
  late DriveSyncEngine engineA;
  late DriveSyncEngine engineB;
  var clock = 1000;

  RecordRepository repoFor(AppDatabase d, String dev) =>
      RecordRepository(d, deviceId: dev, clock: () => ++clock);

  setUp(() async {
    clock = 1000;
    dbA = await newDb();
    dbB = await newDb();
    repoA = repoFor(dbA, 'A');
    repoB = repoFor(dbB, 'B');
    a = SyncedSettings(repoA);
    b = SyncedSettings(repoB);
    drive = FakeDrive();
    engineA = DriveSyncEngine(repoA, drive);
    engineB = DriveSyncEngine(repoB, drive);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  const pay = PaySettings(
    hourly: 2850,
    eveningPct: 20,
    nightPct: 40,
    sundayPct: 50,
  );
  const goals = IntakeGoals(kcal: 2200, protein: 150, ml: 2500);
  const plan = LocalPlanPrefs(
    sports: [
      PlanSport(name: 'Kajak', minutes: 90, outdoor: true),
      PlanSport(name: 'Gym', minutes: 60),
    ],
    perWeek: 4,
    band: PlanBand.evening,
  );

  test('each group goes up as a file of its own, once', () async {
    await a.savePay(pay);
    await a.saveIntakeGoals(goals);
    await a.savePlan(plan);
    final r1 = await engineA.sync();
    expect(r1.pushed, 3);
    expect(
      {for (final f in drive.files.values) f.name},
      {'settings-pay.json', 'settings-goals.json', 'settings-plan.json'},
    );
    expect(await repoA.dirtyCount(), 0);
    final r2 = await engineA.sync();
    expect(r2.pushed, 0);
    expect(drive.writes, 3);
  });

  test('what one device entered shows on the other after the sync', () async {
    await a.savePay(pay);
    await a.saveIntakeGoals(goals);
    await a.savePlan(plan);
    await engineA.sync();
    // (nothing on the other device yet)
    expect(await b.watchPay().first, const PaySettings());
    final r = await engineB.sync();
    expect(r.pulled, 3);
    expect(await b.watchPay().first, pay);
    expect(await b.watchIntakeGoals().first, goals);
    expect(await b.watchPlan().first, plan);
    expect(
      await repoB.dirtyCount(),
      0,
      reason: 'it only received them: nothing to send back',
    );
  });

  test(
    'a wage changed on one device and a premium on the other: both stay',
    () async {
      await a.savePay(const PaySettings(hourly: 2500, sundayPct: 50));
      await engineA.sync();
      await engineB.sync();
      // (the two are apart now: each changes one thing)
      await a.savePay(const PaySettings(hourly: 2900, sundayPct: 50));
      await b.savePay(
        const PaySettings(hourly: 2500, sundayPct: 50, holidayPct: 100),
      );
      await engineA.sync();
      await engineB.sync();
      await engineA.sync();
      const both = PaySettings(hourly: 2900, sundayPct: 50, holidayPct: 100);
      expect(await a.watchPay().first, both);
      expect(await b.watchPay().first, both);
    },
  );

  test('a device that set nothing of a setting does not take the place of the '
      'one that did', () async {
    await a.savePay(const PaySettings(hourly: 2500, eveningPct: 20));
    await engineA.sync();
    // (the other device has not heard of it yet, and sets the wage only)
    await b.savePay(const PaySettings(hourly: 2600));
    await engineB.sync();
    await engineA.sync();
    for (final s in [a, b]) {
      final p = await s.watchPay().first;
      expect(p.hourly, 2600, reason: 'the later write of the wage');
      expect(p.eveningPct, 20, reason: 'the premium was set only on one');
    }
  });

  test(
    'the same setting on both: the later one wins on both devices',
    () async {
      await a.savePay(const PaySettings(hourly: 2500));
      await engineA.sync();
      await engineB.sync();
      await a.savePay(const PaySettings(hourly: 2600));
      await b.savePay(const PaySettings(hourly: 2700)); // later
      await engineA.sync();
      await engineB.sync();
      await engineA.sync();
      expect((await a.watchPay().first).hourly, 2700);
      expect((await b.watchPay().first).hourly, 2700);
    },
  );

  test('a goal taken away on one device is gone on the other', () async {
    await a.saveIntakeGoals(goals);
    await engineA.sync();
    await engineB.sync();
    expect(await b.watchIntakeGoals().first, goals);
    await b.saveIntakeGoals(const IntakeGoals(ml: 2500));
    await engineB.sync();
    await engineA.sync();
    final g = await a.watchIntakeGoals().first;
    expect(g.kcal, isNull);
    expect(g.protein, isNull);
    expect(g.ml, 2500);
  });

  test(
    'the old texts of one device reach the other once they are taken over',
    () async {
      await repoA.setMeta(legacyPaySettingsKey, pay.encode());
      await repoA.setMeta(legacyLocalPlanKey, plan.encode());
      expect(await a.takeOverOldSettings(), isTrue);
      await engineA.sync();
      await engineB.sync();
      expect(await b.watchPay().first, pay);
      expect(await b.watchPlan().first, plan);
    },
  );

  test(
    'a file that is no settings is no settings, and breaks nothing',
    () async {
      drive.externalWrite(
        'settings-pay.json',
        SyncRecord(id: settingsPayId, kind: kindSettings)
            .edit(
              {'hourly': 'sok', 'evening': -3, 'night': 99999},
              ts: 5000,
              dev: 'X',
            )
            .encode(),
      );
      drive.externalWrite('settings-goals.json', '{"nem": "rekord"}');
      await engineA.sync();
      final p = await a.watchPay().first;
      expect(p.hourly, 0);
      expect(p.eveningPct, 0);
      expect(p.nightPct, PaySettings.maxPercent);
      expect((await a.watchIntakeGoals().first).isEmpty, isTrue);
    },
  );
}
