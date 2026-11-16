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

/// Where the goals are kept: on this device only. They are not a record the
/// sync copies, the assistant is never told of them, and the backup does not
/// hold them (they have to be entered again on a new device).
const intakeGoalsKey = 'intake.goals';

class IntakeGoalsNotifier extends AsyncNotifier<IntakeGoals> {
  @override
  Future<IntakeGoals> build() async => IntakeGoals.decode(
    await ref.watch(recordRepoProvider).meta(intakeGoalsKey),
  );

  /// Saves the goals; goals that say nothing remove the stored text.
  Future<void> save(IntakeGoals goals) async {
    await ref
        .read(recordRepoProvider)
        .setMeta(intakeGoalsKey, goals.isEmpty ? null : goals.encode());
    state = AsyncData(goals);
  }
}

final intakeGoalsProvider =
    AsyncNotifierProvider<IntakeGoalsNotifier, IntakeGoals>(
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
