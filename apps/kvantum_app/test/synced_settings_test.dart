import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart' show Size, SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/local_plan_prefs.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_app/intake/intake_providers.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/shift_pay_card.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/turns.dart';

/// The settings that live on every device (8th round): the pay estimate, the
/// goals of the food and fluid log and the wishes of the local planner are
/// three small synced records. What is written, what the screens see of what
/// another device brought, and how what an older version kept on the device
/// alone is taken over.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
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

  late AppDatabase db;
  late RecordRepository repo;
  late int nowMs;
  late int changed;
  late SyncedSettings store;

  setUp(() async {
    db = await newDb();
    nowMs = DateTime.utc(2026, 11, 16, 12).millisecondsSinceEpoch;
    repo = RecordRepository(db, deviceId: 'dev1', clock: () => nowMs);
    changed = 0;
    store = SyncedSettings(repo, onChanged: () => changed++);
  });
  tearDown(() => db.close());

  /// A record another device wrote: [fields] at [ts], by "dev2".
  SyncRecord fromOtherDevice(
    String id,
    Map<String, Object?> fields, {
    int? ts,
  }) => SyncRecord(
    id: id,
    kind: kindSettings,
  ).edit(fields, ts: ts ?? nowMs + 1000, dev: 'dev2');

  group('the store', () {
    test('nothing saved: nothing is set', () async {
      expect(await store.watchPay().first, const PaySettings());
      expect(await store.watchIntakeGoals().first, const IntakeGoals());
      expect(await store.watchPlan().first, const LocalPlanPrefs());
      expect(await repo.all(kindSettings), isEmpty);
    });

    test('a save is one record per group, queued for the sync', () async {
      await store.savePay(pay);
      await store.saveIntakeGoals(goals);
      await store.savePlan(plan);
      expect(
        {for (final r in await repo.all(kindSettings)) r.id},
        {settingsPayId, settingsGoalsId, settingsPlanId},
      );
      expect(
        PaySettings.fromRecord(await repo.get(kindSettings, settingsPayId)),
        pay,
      );
      expect(
        IntakeGoals.fromRecord(await repo.get(kindSettings, settingsGoalsId)),
        goals,
      );
      expect(
        LocalPlanPrefs.fromRecord(await repo.get(kindSettings, settingsPlanId)),
        plan,
      );
      expect(
        {for (final r in await repo.dirty()) r.id},
        {settingsPayId, settingsGoalsId, settingsPlanId},
      );
      expect(changed, 3, reason: 'every save asks the sync to run');
    });

    test(
      'a first save writes only what is set, the rest stays unset',
      () async {
        await store.savePay(const PaySettings(hourly: 2850));
        final r = await repo.get(kindSettings, settingsPayId);
        expect(r!.fields.keys, ['hourly']);
        // (later saves do not add what was never set, either)
        await store.savePay(const PaySettings(hourly: 2900));
        expect((await repo.get(kindSettings, settingsPayId))!.fields.keys, [
          'hourly',
        ]);
        await store.saveIntakeGoals(const IntakeGoals(ml: 2500));
        expect((await repo.get(kindSettings, settingsGoalsId))!.fields.keys, [
          'ml',
        ]);
        await store.savePlan(const LocalPlanPrefs(perWeek: 5));
        expect((await repo.get(kindSettings, settingsPlanId))!.fields.keys, [
          'perWeek',
        ]);
      },
    );

    test(
      'a save that changes nothing writes nothing and asks for nothing',
      () async {
        await store.savePay(pay);
        await store.saveIntakeGoals(goals);
        await store.savePlan(plan);
        expect(changed, 3);
        final before = {
          for (final r in await repo.all(kindSettings)) r.id: r.encode(),
        };
        nowMs += 60000;
        await store.savePay(pay);
        await store.saveIntakeGoals(goals);
        await store.savePlan(plan);
        expect(changed, 3, reason: 'nothing to upload');
        expect({
          for (final r in await repo.all(kindSettings)) r.id: r.encode(),
        }, before);
      },
    );

    test('what is saved is what is watched', () async {
      await store.savePay(pay);
      await store.saveIntakeGoals(goals);
      await store.savePlan(plan);
      expect(await store.watchPay().first, pay);
      expect(await store.watchIntakeGoals().first, goals);
      expect(await store.watchPlan().first, plan);
    });

    test(
      'settings that say nothing, with nothing saved, leave no record',
      () async {
        await store.savePay(const PaySettings());
        await store.saveIntakeGoals(const IntakeGoals());
        await store.savePlan(const LocalPlanPrefs());
        expect(await repo.all(kindSettings), isEmpty);
        expect(changed, 0, reason: 'there is nothing to upload');
      },
    );

    test(
      'saved empty over something, they take it away (and say so)',
      () async {
        await store.savePay(pay);
        await store.saveIntakeGoals(goals);
        await store.savePay(const PaySettings());
        await store.saveIntakeGoals(const IntakeGoals());
        expect(await store.watchPay().first, const PaySettings());
        expect(await store.watchIntakeGoals().first, const IntakeGoals());
        // the records are still there, saying "nothing": that is what tells the
        // other devices to take the values away too
        final r = await repo.get(kindSettings, settingsGoalsId);
        expect(r, isNotNull);
        expect(r!.fields.containsKey('kcal'), isTrue);
        expect(r['kcal'], isNull);
        expect({for (final d in await repo.dirty()) d.id}, contains('goals'));
      },
    );

    test('what another device brought is watched without a restart', () async {
      final seen = <PaySettings>[];
      final sub = store.watchPay().listen(seen.add);
      addTearDown(sub.cancel);
      await turns();
      expect(seen, [const PaySettings()]);
      await repo.applyRemote(fromOtherDevice('pay', pay.toFields()));
      await turns();
      expect(seen.last, pay);
    });

    test('the change of one group is no news to the others', () async {
      final goalsSeen = <IntakeGoals>[];
      final paySeen = <PaySettings>[];
      final a = store.watchIntakeGoals().listen(goalsSeen.add);
      final b = store.watchPay().listen(paySeen.add);
      addTearDown(a.cancel);
      addTearDown(b.cancel);
      await turns();
      await store.savePay(pay);
      await turns();
      await store.savePlan(plan);
      await turns();
      expect(goalsSeen, [const IntakeGoals()], reason: 'nothing changed there');
      expect(paySeen, [const PaySettings(), pay]);
    });

    test('a wage on one device and a premium on the other both stay', () async {
      await store.savePay(const PaySettings(hourly: 2500, sundayPct: 50));
      final mine = await repo.get(kindSettings, settingsPayId);
      // the other device, which saw the same, sets the premium of the holidays
      // later (it writes only what it changed)
      final theirs = mine!.edit(
        const PaySettings(
          hourly: 2500,
          sundayPct: 50,
          holidayPct: 100,
        ).toFields(),
        ts: nowMs + 5000,
        dev: 'dev2',
      );
      nowMs += 9000;
      // meanwhile this one raises the wage
      await store.savePay(const PaySettings(hourly: 2900, sundayPct: 50));
      await repo.applyRemote(theirs);
      expect(
        await store.watchPay().first,
        const PaySettings(hourly: 2900, sundayPct: 50, holidayPct: 100),
      );
    });

    test(
      'the key and the ids are the ones the older versions and the files use',
      () {
        expect(legacyPaySettingsKey, 'pay.settings');
        expect(legacyIntakeGoalsKey, 'intake.goals');
        expect(legacyLocalPlanKey, 'plan.local');
        expect(
          [settingsPayId, settingsGoalsId, settingsPlanId],
          ['pay', 'goals', 'plan'],
        );
      },
    );
  });

  group('taking over what an older version kept on the device alone', () {
    Future<void> seedOld() async {
      await repo.setMeta(legacyPaySettingsKey, pay.encode());
      await repo.setMeta(legacyIntakeGoalsKey, goals.encode());
      await repo.setMeta(legacyLocalPlanKey, plan.encode());
    }

    test('the three texts become three records, and the texts go', () async {
      await seedOld();
      expect(await store.takeOverOldSettings(), isTrue);
      expect(await store.watchPay().first, pay);
      expect(await store.watchIntakeGoals().first, goals);
      expect(await store.watchPlan().first, plan);
      for (final k in [
        legacyPaySettingsKey,
        legacyIntakeGoalsKey,
        legacyLocalPlanKey,
      ]) {
        expect(await repo.meta(k), isNull, reason: k);
      }
      expect(
        {for (final r in await repo.dirty()) r.id},
        {settingsPayId, settingsGoalsId, settingsPlanId},
        reason: 'they are queued for the other devices',
      );
      expect(changed, 1, reason: 'the sync is asked for once');
    });

    test('with nothing to take over, nothing happens', () async {
      expect(await store.takeOverOldSettings(), isFalse);
      expect(await repo.all(kindSettings), isEmpty);
      expect(changed, 0);
    });

    test(
      'is all or nothing: a failure at the end takes the beginning back',
      () async {
        await seedOld();
        final broken = SyncedSettings(
          _BreaksAtPlan(db, deviceId: 'dev1', clock: () => nowMs),
        );
        await expectLater(broken.takeOverOldSettings(), throwsStateError);
        expect(await repo.all(kindSettings), isEmpty);
        for (final k in [
          legacyPaySettingsKey,
          legacyIntakeGoalsKey,
          legacyLocalPlanKey,
        ]) {
          expect(await repo.meta(k), isNotNull, reason: k);
        }
        // (and the next start does it, whole)
        expect(await store.takeOverOldSettings(), isTrue);
        expect(await store.watchPay().first, pay);
        expect(await repo.meta(legacyLocalPlanKey), isNull);
      },
    );

    test('run twice, it is the same as once', () async {
      await seedOld();
      await store.takeOverOldSettings();
      final first = {
        for (final r in await repo.all(kindSettings)) r.id: r.encode(),
      };
      nowMs += 60000;
      expect(await store.takeOverOldSettings(), isFalse);
      expect({
        for (final r in await repo.all(kindSettings)) r.id: r.encode(),
      }, first);
      expect(changed, 1);
    });

    test(
      'one group alone is taken over, the others stay as they are',
      () async {
        await repo.setMeta(legacyIntakeGoalsKey, goals.encode());
        expect(await store.takeOverOldSettings(), isTrue);
        expect(
          {for (final r in await repo.all(kindSettings)) r.id},
          {settingsGoalsId},
        );
        expect(await repo.meta(legacyIntakeGoalsKey), isNull);
      },
    );

    test(
      'a record that is there is never overwritten; the text just goes',
      () async {
        await repo.applyRemote(
          fromOtherDevice('pay', const PaySettings(hourly: 3300).toFields()),
        );
        await repo.setMeta(legacyPaySettingsKey, pay.encode());
        expect(await store.takeOverOldSettings(), isFalse);
        expect(await store.watchPay().first, const PaySettings(hourly: 3300));
        expect(await repo.meta(legacyPaySettingsKey), isNull);
        expect(changed, 0);
      },
    );

    test('goals taken away on another device are not brought back', () async {
      // the record is there and says "no goals": that is the user's last word
      await repo.applyRemote(
        fromOtherDevice('goals', const IntakeGoals().toFields()),
      );
      await repo.setMeta(legacyIntakeGoalsKey, goals.encode());
      await store.takeOverOldSettings();
      expect(await store.watchIntakeGoals().first, const IntakeGoals());
      expect(await repo.meta(legacyIntakeGoalsKey), isNull);
    });

    test('texts that say nothing, or are damaged, leave no record', () async {
      await repo.setMeta(legacyPaySettingsKey, '{}');
      await repo.setMeta(legacyIntakeGoalsKey, 'not json');
      await repo.setMeta(legacyLocalPlanKey, const LocalPlanPrefs().encode());
      expect(await store.takeOverOldSettings(), isFalse);
      expect(await repo.all(kindSettings), isEmpty);
      for (final k in [
        legacyPaySettingsKey,
        legacyIntakeGoalsKey,
        legacyLocalPlanKey,
      ]) {
        expect(await repo.meta(k), isNull, reason: k);
      }
      expect(changed, 0);
    });

    test('only what the old text really set is written', () async {
      await repo.setMeta(legacyPaySettingsKey, '{"hourly":2500}');
      await repo.setMeta(legacyIntakeGoalsKey, '{"ml":2000}');
      await repo.setMeta(
        legacyLocalPlanKey,
        const LocalPlanPrefs(band: PlanBand.evening).encode(),
      );
      await store.takeOverOldSettings();
      expect((await repo.get(kindSettings, settingsPayId))!.fields.keys, [
        'hourly',
      ]);
      expect((await repo.get(kindSettings, settingsGoalsId))!.fields.keys, [
        'ml',
      ]);
      expect((await repo.get(kindSettings, settingsPlanId))!.fields.keys, [
        'band',
      ]);
    });

    test('values out of range are cut the way they always were', () async {
      await repo.setMeta(
        legacyPaySettingsKey,
        '{"hourly":99999999,"evening":-5,"sunday":5000}',
      );
      await store.takeOverOldSettings();
      final p = await store.watchPay().first;
      expect(p.hourly, PaySettings.maxHourly);
      expect(p.eveningPct, 0);
      expect(p.sundayPct, PaySettings.maxPercent);
    });
  });

  group('the screens see them', () {
    late ProviderContainer c;

    /// A container with the three settings listened to, the way the screens
    /// that show them do (a provider nobody listens to is paused: it would not
    /// give its first value, which is why nothing reads their `.future`).
    ProviderContainer listening() {
      final k = ProviderContainer(overrides: baseOverrides(db));
      addTearDown(k.dispose);
      k.listen(paySettingsProvider, (_, _) {});
      k.listen(intakeGoalsProvider, (_, _) {});
      k.listen(localPlanPrefsProvider, (_, _) {});
      return k;
    }

    setUp(() => c = listening());

    test('pay settings: saved through the notifier, read back', () async {
      expect(await c.read(paySettingsProvider.future), const PaySettings());
      await c.read(paySettingsProvider.notifier).save(pay);
      await turns();
      expect(c.read(paySettingsProvider).value, pay);
    });

    test('goals: saved through the notifier, read back', () async {
      expect((await c.read(intakeGoalsProvider.future)).isEmpty, isTrue);
      await c.read(intakeGoalsProvider.notifier).save(goals);
      await turns();
      expect(c.read(intakeGoalsProvider).value, goals);
    });

    test(
      'the wishes of the planner: saved through the notifier, read back',
      () async {
        expect(
          await c.read(localPlanPrefsProvider.future),
          const LocalPlanPrefs(),
        );
        await c.read(localPlanPrefsProvider.notifier).save(plan);
        await turns();
        expect(c.read(localPlanPrefsProvider).value, plan);
      },
    );

    test('a new start reads them back', () async {
      await c.read(paySettingsProvider.notifier).save(pay);
      await c.read(intakeGoalsProvider.notifier).save(goals);
      await c.read(localPlanPrefsProvider.notifier).save(plan);
      final again = listening();
      expect(await again.read(paySettingsProvider.future), pay);
      expect(await again.read(intakeGoalsProvider.future), goals);
      expect(await again.read(localPlanPrefsProvider.future), plan);
    });

    test('what another device brought shows without a restart', () async {
      await c.read(paySettingsProvider.future);
      await c.read(intakeGoalsProvider.future);
      await c.read(localPlanPrefsProvider.future);
      await repo.applyRemote(fromOtherDevice('pay', pay.toFields()));
      await repo.applyRemote(fromOtherDevice('goals', goals.toFields()));
      await repo.applyRemote(fromOtherDevice('plan', plan.toFields()));
      await turns();
      expect(c.read(paySettingsProvider).value, pay);
      expect(c.read(intakeGoalsProvider).value, goals);
      expect(c.read(localPlanPrefsProvider).value, plan);
    });

    test('a record that is no settings is no settings', () async {
      await repo.applyRemote(
        fromOtherDevice('pay', {'hourly': 'sok', 'evening': null}),
      );
      await repo.applyRemote(fromOtherDevice('goals', {'kcal': 1, 'ml': -3}));
      await repo.applyRemote(
        fromOtherDevice('plan', {'sports': 'nem json', 'perWeek': 99}),
      );
      final k = listening();
      expect(await k.read(paySettingsProvider.future), const PaySettings());
      expect((await k.read(intakeGoalsProvider.future)).isEmpty, isTrue);
      final p = await k.read(localPlanPrefsProvider.future);
      expect(p.sports, defaultPlanSports);
      expect(p.perWeek, 7);
    });

    test(
      'the core that builds what a model is told knows no settings record',
      () {
        final found = <String>[];
        for (final f in Directory(
          '../../packages/kvantum_core/lib/src',
        ).listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart')) continue;
          final name = f.path.replaceAll('\\', '/').split('/').last;
          // (the list of the kinds, and the three groups themselves)
          if ({
            'models.dart',
            'pay_estimate.dart',
            'intake.dart',
            'local_plan.dart',
          }.contains(name)) {
            continue;
          }
          if (f.readAsStringSync().contains('kindSettings')) found.add(name);
        }
        expect(found, isEmpty);
      },
    );

    test(
      'nothing in the app reads their future: an unlistened one is paused',
      () {
        final used = <String>[];
        for (final f in Directory('lib').listSync(recursive: true)) {
          if (f is! File || !f.path.endsWith('.dart')) continue;
          final text = f.readAsStringSync();
          if (RegExp(
            r'(paySettingsProvider|intakeGoalsProvider|localPlanPrefsProvider)'
            r'\s*\.future',
          ).hasMatch(text)) {
            used.add(f.path);
          }
        }
        expect(used, isEmpty);
      },
    );
  });

  group('at the start of the app', () {
    testWidgets('the older settings move into the synced records', (
      tester,
    ) async {
      useSize(tester, size: const Size(360, 800));
      await tester.runAsync(() async {
        await repo.setMeta(legacyPaySettingsKey, pay.encode());
        await repo.setMeta(legacyIntakeGoalsKey, goals.encode());
        await repo.setMeta(legacyLocalPlanKey, plan.encode());
      });
      await tester.pumpWidget(
        app(
          const RootShell(),
          db,
          extra: [walletBridgeProvider.overrideWithValue(FakeWallet())],
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(turns);
      await tester.pumpAndSettle();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(RootShell)),
      );
      await tester.runAsync(() async {
        final r = c.read(recordRepoProvider);
        expect(
          PaySettings.fromRecord(await r.get(kindSettings, settingsPayId)),
          pay,
        );
        expect(
          IntakeGoals.fromRecord(await r.get(kindSettings, settingsGoalsId)),
          goals,
        );
        expect(
          LocalPlanPrefs.fromRecord(await r.get(kindSettings, settingsPlanId)),
          plan,
        );
        expect(await r.meta(legacyPaySettingsKey), isNull);
        expect(await r.meta(legacyIntakeGoalsKey), isNull);
        expect(await r.meta(legacyLocalPlanKey), isNull);
      });
      // unmount first so drift's stream-cleanup timers run (tearDown closes
      // the database)
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}

/// A repository that cannot clear the old text of the planner's wishes (the
/// last step of the take-over).
class _BreaksAtPlan extends RecordRepository {
  _BreaksAtPlan(super.db, {super.deviceId, super.clock});

  @override
  Future<void> setMeta(String key, String? value) {
    if (key == legacyLocalPlanKey && value == null) {
      throw StateError('the disk is full');
    }
    return super.setMeta(key, value);
  }
}
