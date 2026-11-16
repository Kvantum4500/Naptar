import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'intake_ops.dart';

/// The food and fluid log, every month in one.
final intakeLogProvider = StreamProvider<IntakeLog>(
  (ref) => ref.watch(recordRepoProvider).watch(kindIntake).map(IntakeLog.from),
);

/// What the changes of the log are done by (and ask the sync to run after).
final intakeOpsProvider = Provider<IntakeOps>(
  (ref) => IntakeOps(
    ref.watch(recordRepoProvider),
    onChanged: () => ref.read(syncControllerProvider.notifier).requestSync(),
  ),
);

/// The goals of the log: what the user set, on every device (see
/// [SyncedSettings]). The assistant is never told of them.
class IntakeGoalsNotifier extends StreamNotifier<IntakeGoals> {
  @override
  Stream<IntakeGoals> build() =>
      ref.watch(syncedSettingsProvider).watchIntakeGoals();

  /// Saves the goals; a goal that is left out is taken away on every device.
  Future<void> save(IntakeGoals goals) =>
      ref.read(syncedSettingsProvider).saveIntakeGoals(goals);
}

final intakeGoalsProvider =
    StreamNotifierProvider<IntakeGoalsNotifier, IntakeGoals>(
      IntakeGoalsNotifier.new,
    );

/// The day the page of the log shows. Whoever looks at "today" keeps looking at
/// today when the midnight passes.
class IntakeDay extends Notifier<DateTime> {
  @override
  DateTime build() {
    ref.listen(todayProvider, (before, now) {
      if (before != null && state == before) state = now;
    });
    return ref.read(todayProvider);
  }

  void set(DateTime day) => state = DateTime.utc(day.year, day.month, day.day);

  void shift(int days) =>
      state = DateTime.utc(state.year, state.month, state.day + days);
}

final intakeDayProvider = NotifierProvider<IntakeDay, DateTime>(IntakeDay.new);

/// How many days the trend shows: a week or a month.
class IntakeTrendDays extends Notifier<int> {
  @override
  int build() => 7;
  void set(int days) => state = days;
}

final intakeTrendDaysProvider = NotifierProvider<IntakeTrendDays, int>(
  IntakeTrendDays.new,
);
