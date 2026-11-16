import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';

/// The wishes of the local planner (the sports, the weekly goal, the time of
/// day): what the user entered, on every device (see [SyncedSettings]). They
/// only feed the program's own planner: the model is never told of them.
class LocalPlanPrefsNotifier extends StreamNotifier<LocalPlanPrefs> {
  @override
  Stream<LocalPlanPrefs> build() =>
      ref.watch(syncedSettingsProvider).watchPlan();

  Future<void> save(LocalPlanPrefs prefs) =>
      ref.read(syncedSettingsProvider).savePlan(prefs);
}

final localPlanPrefsProvider =
    StreamNotifierProvider<LocalPlanPrefsNotifier, LocalPlanPrefs>(
      LocalPlanPrefsNotifier.new,
    );
