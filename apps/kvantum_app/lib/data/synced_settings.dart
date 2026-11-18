import 'package:kvantum_core/kvantum_core.dart';

import 'record_repository.dart';

/// Where the pay settings were kept before they were synced (one text in the
/// meta table of the device). Read once, to take them over; see
/// [SyncedSettings.takeOverOldSettings].
const legacyPaySettingsKey = 'pay.settings';

/// The same for the goals of the food and fluid log.
const legacyIntakeGoalsKey = 'intake.goals';

/// The same for the wishes of the local planner.
const legacyLocalPlanKey = 'plan.local';

/// The settings the user enters once and finds on every device: the pay
/// estimate, the goals of the food and fluid log and the wishes of the local
/// planner. Each group is one small synced record ([kindSettings]) and each
/// setting a field of it (see settings in the core), so what is typed on one
/// device reaches the others with the next sync, and a wage changed on one and
/// a premium changed on another both stay.
///
/// Like every record, they are in the backup and in Drive. The assistant is
/// never told of them (the source guards in the tests keep it so).
class SyncedSettings {
  SyncedSettings(this._repo, {this.onChanged});

  final RecordRepository _repo;

  /// Told after every change (the app asks the sync to run).
  final void Function()? onChanged;

  /// The settings of group [id] as they are now, and again after every change
  /// (also one that comes from another device with the sync). Nothing saved is
  /// the settings of "not set".
  Stream<T> _watch<T>(String id, T Function(SyncRecord?) read) => _repo
      .watch(kindSettings)
      .map((records) {
        for (final r in records) {
          if (r.id == id) return read(r);
        }
        return read(null);
      })
      // (a change of another group is no news to this one)
      .distinct();

  Stream<PaySettings> watchPay() =>
      _watch(settingsPayId, PaySettings.fromRecord);

  Stream<IntakeGoals> watchIntakeGoals() =>
      _watch(settingsGoalsId, IntakeGoals.fromRecord);

  Stream<LocalPlanPrefs> watchPlan() =>
      _watch(settingsPlanId, LocalPlanPrefs.fromRecord);

  /// The wishes of the local planner as they are now, read once (what the plan
  /// is made of: nothing listens, so there is no stream to wait for).
  Future<LocalPlanPrefs> readPlan() async =>
      LocalPlanPrefs.fromRecord(await _repo.get(kindSettings, settingsPlanId));

  /// What of [fields] there is to write into [existing] (null: the group has no
  /// record yet), [defaults] being what each field says when it was never
  /// written. Only what is new or changed is written: that is the one stamped
  /// anew, so a form saved with one number changed takes nothing from what
  /// another device wrote to the others. And a field that was never written and
  /// says what its default says is left out altogether: a device that did not
  /// set it must not take the place of a device that did (its stamp would be the
  /// newer one).
  Map<String, Object?> _changes(
    SyncRecord? existing,
    Map<String, Object?> fields,
    Map<String, Object?> defaults,
  ) {
    final out = <String, Object?>{};
    for (final e in fields.entries) {
      final there = existing?.fields[e.key];
      if (there == null ? e.value != defaults[e.key] : there.value != e.value) {
        out[e.key] = e.value;
      }
    }
    return out;
  }

  /// Writes the changes of group [id] (see [_changes]) and asks the sync to run;
  /// nothing changed, nothing is written and nothing is uploaded.
  Future<void> _save(
    String id,
    Map<String, Object?> fields,
    Map<String, Object?> defaults,
  ) async {
    final changes = _changes(
      await _repo.get(kindSettings, id),
      fields,
      defaults,
    );
    if (changes.isEmpty) return;
    await _repo.edit(kindSettings, id, changes);
    onChanged?.call();
  }

  Future<void> savePay(PaySettings settings) =>
      _save(settingsPayId, settings.toFields(), const PaySettings().toFields());

  /// Saves the goals; a goal that is not set is taken away everywhere.
  Future<void> saveIntakeGoals(IntakeGoals goals) =>
      _save(settingsGoalsId, goals.toFields(), const IntakeGoals().toFields());

  Future<void> savePlan(LocalPlanPrefs prefs) => _save(
    settingsPlanId,
    prefs.toFields(),
    const LocalPlanPrefs().toFields(),
  );

  /// Moves what an older version kept on this device only (the texts in the
  /// meta table) into the synced records, once, so that what the user entered
  /// is not lost and reaches the other devices. A record that is there already
  /// is what the user set last, here or on another device: it is never
  /// overwritten, the old text just goes. Settings that say nothing leave no
  /// record. Returns whether a record was written (the sync is worth asking
  /// for then).
  ///
  /// It is meant to run at every start: it does nothing when there is nothing
  /// to take over, and it does the same if it is run twice.
  Future<bool> takeOverOldSettings() => _repo.db.transaction(() async {
    var wrote = false;

    Future<void> take({
      required String oldKey,
      required String id,
      required Map<String, Object?> Function(String text) fields,
      required Map<String, Object?> defaults,
    }) async {
      final text = await _repo.meta(oldKey);
      if (text == null) return;
      if (await _repo.get(kindSettings, id) == null) {
        // (only what the old text really set: the rest stays unset, so it
        // cannot take the place of what another device set)
        final changes = _changes(null, fields(text), defaults);
        if (changes.isNotEmpty) {
          await _repo.edit(kindSettings, id, changes);
          wrote = true;
        }
      }
      await _repo.setMeta(oldKey, null);
    }

    await take(
      oldKey: legacyPaySettingsKey,
      id: settingsPayId,
      fields: (t) => PaySettings.decode(t).toFields(),
      defaults: const PaySettings().toFields(),
    );
    await take(
      oldKey: legacyIntakeGoalsKey,
      id: settingsGoalsId,
      fields: (t) => IntakeGoals.decode(t).toFields(),
      defaults: const IntakeGoals().toFields(),
    );
    await take(
      oldKey: legacyLocalPlanKey,
      id: settingsPlanId,
      fields: (t) => LocalPlanPrefs.decode(t).toFields(),
      defaults: const LocalPlanPrefs().toFields(),
    );
    if (wrote) onChanged?.call();
    return wrote;
  });
}
