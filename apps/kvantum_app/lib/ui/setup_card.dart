import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/settings_page.dart';
import '../sync/sync_controller.dart';
import 'setup_guide.dart';

/// The words of a step: what to do, why, and the button that starts it.
({String title, String detail, String action}) setupWords(SetupStep step) =>
    switch (step) {
      SetupStep.signIn => (
        title: 'Belépés a Google-fiókkal',
        detail: 'A naptár és a feladatok így kerülnek át a másik eszközre is.',
        action: 'Belépés',
      ),
      SetupStep.aiKey => (
        title: 'AI-kulcs megadása',
        detail:
            'Az asszisztens kulcs nélkül nem tud tervezni. Ingyenes kulcsot a '
            'szolgáltatók adnak.',
        action: 'Megnyitás',
      ),
      SetupStep.place => (
        title: 'Hely megadása (nem kötelező)',
        detail: 'Az időjárás-alapú tervezéshez kell.',
        action: 'Megnyitás',
      ),
      SetupStep.reminders => (
        title: 'Emlékeztetők bekapcsolása',
        detail: 'Műszak előtti és esti check-in értesítés.',
        action: 'Megnyitás',
      ),
      SetupStep.wallet => (
        title: 'Wallet-fizetések átvétele (nem kötelező)',
        detail: 'A kártyás fizetések maguktól bekerülnek a Pénzügyekbe.',
        action: 'Megnyitás',
      ),
    };

/// The first-run guide above the calendar: one step at a time (what to set up
/// next and why), each with "Nem kell", and "Elrejtés" for all. It looks at
/// the installation and asks for nothing: no permission is requested and
/// nothing is opened until a button is pressed. It disappears by itself when
/// every step is done or set aside.
class SetupCard extends ConsumerStatefulWidget {
  const SetupCard({super.key});

  @override
  ConsumerState<SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends ConsumerState<SetupCard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // back from the system's own settings (notification access, ...)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(setupFactsProvider);
  }

  Future<void> _open(SetupStep step) async {
    if (step == SetupStep.signIn) {
      await ref.read(syncControllerProvider.notifier).signIn();
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
    // what was set there is not watched (a key): look again
    if (mounted) ref.invalidate(setupFactsProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(setupGuideProvider)) return const SizedBox.shrink();
    final flags = ref.watch(setupFlagsProvider);
    final facts = ref.watch(setupFactsProvider).value;
    if (!flags.loaded || flags.dismissed || facts == null) {
      return const SizedBox.shrink();
    }
    final next = nextSetupStep(facts, flags.skipped);
    if (next == null) return const SizedBox.shrink();

    final words = setupWords(next.step);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final flagsNotifier = ref.read(setupFlagsProvider.notifier);
    return Material(
      key: const Key('setup-card'),
      color: scheme.primaryContainer.withValues(alpha: .5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.checklist, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Első lépések · ${next.number}/${next.total}',
                      style: theme.labelMedium?.copyWith(color: scheme.primary),
                    ),
                  ),
                  Text(
                    words.title,
                    style: theme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(words.detail, style: theme.bodySmall),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      children: [
                        TextButton(
                          onPressed: flagsNotifier.dismiss,
                          child: const Text('Elrejtés'),
                        ),
                        TextButton(
                          onPressed: () => flagsNotifier.skip(next.step),
                          child: const Text('Nem kell'),
                        ),
                        FilledButton.tonal(
                          onPressed: () => _open(next.step),
                          child: Text(words.action),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
