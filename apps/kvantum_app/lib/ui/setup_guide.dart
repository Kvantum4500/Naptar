import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/ai_providers.dart';
import '../notify/reminders.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';

/// What a new installation can be set up with, in the order it is offered.
enum SetupStep { signIn, aiKey, place, reminders, wallet }

/// Whether the first-run guide may show at all. On in the app (main.dart),
/// off by default so that a screen under test is not changed by it.
final setupGuideProvider = Provider<bool>((_) => false);

/// What is known about this installation: which steps make sense on this
/// device and which are done. Only looked at, never changed or asked for.
class SetupFacts {
  const SetupFacts({
    this.googleConfigured = false,
    this.signedIn = false,
    this.aiKey = false,
    this.place = false,
    this.remindersSupported = false,
    this.remindersOn = false,
    this.walletSupported = false,
    this.walletOn = false,
  });

  final bool googleConfigured;
  final bool signedIn;
  final bool aiKey;
  final bool place;
  final bool remindersSupported;
  final bool remindersOn;
  final bool walletSupported;
  final bool walletOn;

  /// Whether [step] can be done on this device at all (there is no Google
  /// sign-in in a build without keys, no reminders on Windows).
  bool relevant(SetupStep step) => switch (step) {
    SetupStep.signIn => googleConfigured,
    SetupStep.aiKey || SetupStep.place => true,
    SetupStep.reminders => remindersSupported,
    SetupStep.wallet => walletSupported,
  };

  bool done(SetupStep step) => switch (step) {
    SetupStep.signIn => signedIn,
    SetupStep.aiKey => aiKey,
    SetupStep.place => place,
    SetupStep.reminders => remindersOn,
    SetupStep.wallet => walletOn,
  };
}

/// The step to offer now and how far along the user is.
class SetupNext {
  const SetupNext(this.step, this.number, this.total);
  final SetupStep step;

  /// 1-based position among the steps of this device.
  final int number;
  final int total;
}

/// The first step that makes sense here and is neither done nor set aside, or
/// null when there is none (the guide has nothing more to say).
SetupNext? nextSetupStep(SetupFacts facts, Set<SetupStep> skipped) {
  final steps = [
    for (final s in SetupStep.values)
      if (facts.relevant(s)) s,
  ];
  var handled = 0;
  for (final s in steps) {
    if (facts.done(s) || skipped.contains(s)) {
      handled++;
      continue;
    }
    return SetupNext(s, handled + 1, steps.length);
  }
  return null;
}

/// What the user told the guide: "not needed" for a step, "hide" for all.
class SetupFlags {
  const SetupFlags({
    this.loaded = false,
    this.dismissed = false,
    this.skipped = const {},
  });
  final bool loaded;
  final bool dismissed;
  final Set<SetupStep> skipped;
}

/// Remembered between runs, in the meta table of the database.
class SetupFlagsNotifier extends Notifier<SetupFlags> {
  static const _dismissedKey = 'setup.dismissed';
  static String _skipKey(SetupStep s) => 'setup.skip.${s.name}';

  @override
  SetupFlags build() {
    Future.microtask(_load);
    return const SetupFlags();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    final dismissed = await repo.meta(_dismissedKey) == '1';
    final skipped = <SetupStep>{};
    for (final s in SetupStep.values) {
      if (await repo.meta(_skipKey(s)) == '1') skipped.add(s);
    }
    if (!ref.mounted) return;
    state = SetupFlags(loaded: true, dismissed: dismissed, skipped: skipped);
  }

  /// "Nem kell": this step is not offered again.
  void skip(SetupStep step) {
    state = SetupFlags(
      loaded: true,
      dismissed: state.dismissed,
      skipped: {...state.skipped, step},
    );
    ref.read(repoProvider).setMeta(_skipKey(step), '1');
  }

  /// "Elrejtés": the guide is gone for good (until [reset]).
  void dismiss() {
    state = SetupFlags(loaded: true, dismissed: true, skipped: state.skipped);
    ref.read(repoProvider).setMeta(_dismissedKey, '1');
  }

  /// The guide starts again from the top (Settings has the button).
  void reset() {
    state = const SetupFlags(loaded: true);
    final repo = ref.read(repoProvider);
    repo.setMeta(_dismissedKey, null);
    for (final s in SetupStep.values) {
      repo.setMeta(_skipKey(s), null);
    }
  }
}

final setupFlagsProvider = NotifierProvider<SetupFlagsNotifier, SetupFlags>(
  SetupFlagsNotifier.new,
);

/// What the installation has set up. Invalidate it when something that is not
/// watched may have changed (a key saved in Settings, back from the system's
/// settings).
final setupFactsProvider = FutureProvider<SetupFacts>((ref) async {
  // (watching the value, not `.future`: a settings change that is assigned
  // must be seen, and the future of a provider that has data keeps the old one)
  final aiNow = ref.watch(aiSettingsProvider);
  final ai = aiNow.hasValue
      ? aiNow.requireValue
      : await ref.watch(aiSettingsProvider.future);
  final key = await ref.read(apiKeyStoreProvider).read(provider: ai.provider);
  final bridge = ref.watch(walletBridgeProvider);
  final walletOn =
      bridge.supported &&
      await bridge.isEnabled() &&
      await ref.read(walletIngestProvider).auto;
  final remindersNow = ref.watch(reminderSettingsProvider);
  final reminders = remindersNow.hasValue
      ? remindersNow.requireValue
      : await ref.watch(reminderSettingsProvider.future);
  return SetupFacts(
    // (the controller says it: no Google keys in the build, no sign-in)
    googleConfigured: ref.watch(
      syncControllerProvider.select((s) => s.configured),
    ),
    signedIn: ref.watch(syncControllerProvider.select((s) => s.signedIn)),
    aiKey: key != null && key.isNotEmpty,
    place: ai.place != null,
    remindersSupported: ref.watch(reminderSchedulerProvider).supported,
    remindersOn: reminders.any,
    walletSupported: bridge.supported,
    walletOn: walletOn,
  );
});
