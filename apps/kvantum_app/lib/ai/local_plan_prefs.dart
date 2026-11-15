import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';

/// Where the wishes of the local planner (the sports, the weekly goal, the time
/// of day) are kept: on this device only, as one text in the meta table. They
/// are not a record the sync copies, the model is never told of them, and the
/// backup does not hold them (they are entered again on a new device).
const localPlanKey = 'plan.local';

class LocalPlanPrefsNotifier extends AsyncNotifier<LocalPlanPrefs> {
  @override
  Future<LocalPlanPrefs> build() async => LocalPlanPrefs.decode(
    await ref.watch(recordRepoProvider).meta(localPlanKey),
  );

  Future<void> save(LocalPlanPrefs prefs) async {
    await ref.read(recordRepoProvider).setMeta(localPlanKey, prefs.encode());
    state = AsyncData(prefs);
  }
}

final localPlanPrefsProvider =
    AsyncNotifierProvider<LocalPlanPrefsNotifier, LocalPlanPrefs>(
      LocalPlanPrefsNotifier.new,
    );
