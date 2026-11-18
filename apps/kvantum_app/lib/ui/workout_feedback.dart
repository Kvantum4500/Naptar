import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../ai/workout_providers.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart' show defaultTz;
import 'format.dart';

/// How often the app looks again for a workout that has just ended while it is
/// open (it also looks when it comes back to the front).
const workoutLookEvery = Duration(minutes: 5);

const _questions = [
  ('bodyLoad', 'Fizikailag mennyire volt nehéz?', 'könnyű', 'nagyon nehéz'),
  ('mindLoad', 'Mentálisan mennyire volt nehéz?', 'könnyű', 'nagyon nehéz'),
  ('energyStart', 'Mennyi energiával kezdted?', 'kimerült', 'tele energiával'),
  (
    'energyEnd',
    'Mennyi energiával fejezted be?',
    'kimerült',
    'tele energiával',
  ),
  ('experience', 'Milyen élmény volt?', 'rossz', 'kiváló'),
];

/// Under the daily check-in: after a workout the app asks how it went (a few
/// taps, never required), and, when the answers have shown that a kind of
/// workout is easy for the user, asks whether to treat it as easy.
class WorkoutFeedbackBanner extends ConsumerStatefulWidget {
  const WorkoutFeedbackBanner({super.key});

  @override
  ConsumerState<WorkoutFeedbackBanner> createState() =>
      _WorkoutFeedbackBannerState();
}

class _WorkoutFeedbackBannerState extends ConsumerState<WorkoutFeedbackBanner>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(workoutLookEvery, (_) => _look());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _look();
  }

  void _look() {
    if (mounted) ref.read(workoutRefreshProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingWorkoutProvider).value;
    final suggestion = ref
        .watch(workoutLearningProvider)
        .value
        ?.suggestions
        .firstOrNull;
    if (pending == null && suggestion == null) return const SizedBox.shrink();
    return Column(
      children: [
        if (pending != null) _FeedbackBar(pending: pending),
        if (suggestion != null) _RelaxCard(suggestion: suggestion),
      ],
    );
  }
}

class _FeedbackBar extends ConsumerWidget {
  const _FeedbackBar({required this.pending});
  final PendingWorkout pending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final o = pending.occurrence;
    final tz = o.tzid ?? defaultTz;
    final range =
        '${fmtTime(toWallClock(tz, o.startUtc))}–${fmtTime(toWallClock(tz, o.endUtc))}';
    return Material(
      key: const Key('workout-feedback'),
      color: scheme.secondaryContainer.withValues(alpha: .6),
      child: InkWell(
        onTap: () => openWorkoutFeedback(context, pending),
        // (the text above, the buttons below: nothing is cut off on a phone)
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(
                  Icons.fitness_center,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hogy ment: ${pending.title} ($range)? Pár koppintás, és az asszisztens tanul belőle.',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        children: [
                          TextButton(
                            key: const Key('workout-later'),
                            onPressed: () => ref
                                .read(workoutFeedbackActionsProvider)
                                .later(pending),
                            child: const Text('Később'),
                          ),
                          TextButton(
                            key: const Key('workout-open'),
                            onPressed: () =>
                                openWorkoutFeedback(context, pending),
                            child: const Text('Kitöltöm'),
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
      ),
    );
  }
}

/// "A kind of workout is easy for you, shall I treat it as such?": a yes goes
/// to "Tanult szokások" (where it can be deleted), a no is remembered.
class _RelaxCard extends ConsumerWidget {
  const _RelaxCard({required this.suggestion});
  final RelaxSuggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final actions = ref.read(workoutFeedbackActionsProvider);
    return Material(
      key: const Key('workout-relax'),
      color: scheme.tertiaryContainer.withValues(alpha: .6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                Icons.psychology_outlined,
                size: 18,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.question,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const Key('relax-no'),
                          onPressed: () => actions.declineLight(suggestion),
                          child: const Text('Nem'),
                        ),
                        FilledButton(
                          key: const Key('relax-yes'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.maybeOf(
                              context,
                            );
                            await actions.agreeLight(suggestion);
                            messenger?.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Rögzítve a Tanult szokások közé (Beállítások → Kézikönyv), ott törölheted is.',
                                ),
                              ),
                            );
                          },
                          child: const Text('Igen'),
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

Future<void> openWorkoutFeedback(BuildContext context, PendingWorkout w) =>
    showDialog<void>(
      context: context,
      builder: (_) => WorkoutFeedbackDialog(pending: w),
    );

/// Five quick scales and a note. Every answer is optional; "Kihagytam" says
/// the workout did not happen; "Később" asks again at the next start.
class WorkoutFeedbackDialog extends ConsumerStatefulWidget {
  const WorkoutFeedbackDialog({super.key, required this.pending});
  final PendingWorkout pending;

  @override
  ConsumerState<WorkoutFeedbackDialog> createState() =>
      _WorkoutFeedbackDialogState();
}

class _WorkoutFeedbackDialogState extends ConsumerState<WorkoutFeedbackDialog> {
  final _v = <String, int?>{for (final q in _questions) q.$1: null};
  final _note = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save({required bool done}) async {
    if (_saving) return;
    if (done && _v.values.every((x) => x == null)) {
      setState(() => _error = 'Válaszolj legalább egy kérdésre.');
      return;
    }
    _saving = true;
    await ref
        .read(workoutFeedbackActionsProvider)
        .save(
          widget.pending,
          done: done,
          bodyLoad: _v['bodyLoad'],
          mindLoad: _v['mindLoad'],
          energyStart: _v['energyStart'],
          energyEnd: _v['energyEnd'],
          experience: _v['experience'],
          note: _note.text,
        );
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    return AlertDialog(
      title: Text('Hogy ment: ${p.title}?'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${fmtDateLong(p.day)} · ${p.minutes} perc',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              for (final (key, label, low, high) in _questions) ...[
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 1; i <= 5; i++)
                      ChoiceChip(
                        key: Key('$key-$i'),
                        label: Text('$i'),
                        selected: _v[key] == i,
                        onSelected: (on) {
                          // tapping the chosen value again keeps it (an
                          // answer is never silently dropped)
                          if (on) setState(() => _v[key] = i);
                        },
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 4),
                  // (each half may wrap: a large system font must not push the
                  // end of the scale off the dialog)
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '1 = $low',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '5 = $high',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                key: const Key('workout-note'),
                controller: _note,
                maxLines: 2,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Megjegyzés (nem kötelező, nem megy ki sehova)',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('feedback-later'),
          onPressed: () {
            ref.read(workoutFeedbackActionsProvider).later(p);
            Navigator.pop(context);
          },
          child: const Text('Később'),
        ),
        TextButton(
          key: const Key('feedback-skipped'),
          onPressed: () => _save(done: false),
          child: const Text('Kihagytam'),
        ),
        FilledButton(
          key: const Key('feedback-save'),
          onPressed: () => _save(done: true),
          child: const Text('Mentés'),
        ),
      ],
    );
  }
}
