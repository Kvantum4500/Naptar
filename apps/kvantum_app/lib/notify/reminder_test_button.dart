import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diag/diag_log.dart';
import 'reminders.dart';
import 'windows_reminders.dart';

/// "Try a notification": hands the system one that shows in half a minute, so
/// that the user sees at once whether the reminders reach them - also with the
/// program closed. Only where the scheduler can do that (Windows).
class ReminderTestButton extends ConsumerStatefulWidget {
  const ReminderTestButton({super.key});

  /// How long the test notification takes.
  static const delay = Duration(seconds: 30);

  @override
  ConsumerState<ReminderTestButton> createState() => _ReminderTestButtonState();
}

class _ReminderTestButtonState extends ConsumerState<ReminderTestButton> {
  bool _busy = false;

  Future<void> _try(TestableReminders scheduler) async {
    final log = ref.read(diagLogProvider);
    final messenger = ScaffoldMessenger.of(context);
    final error = Theme.of(context).colorScheme.error;
    setState(() => _busy = true);
    SnackBar bar;
    try {
      await scheduler.scheduleTest(ReminderTestButton.delay);
      log.info('reminders', 'test.scheduled');
      bar = const SnackBar(
        duration: Duration(seconds: 10),
        content: Text(
          'A próba-értesítés fél perc múlva megjelenik; addig a programot '
          'be is zárhatod. Ha nem jelenik meg: nézd meg a Windows '
          'Beállítások → Rendszer → Értesítések oldalán, hogy a Kvantum '
          'Naptár engedélyezve van-e, és hogy nincs-e bekapcsolva a „Ne '
          'zavarjanak” mód.',
        ),
      );
    } catch (e, st) {
      log.error('reminders', 'test.failed', e, st);
      bar = SnackBar(
        backgroundColor: error,
        content: const Text(
          'A próba-értesítést nem sikerült beütemezni. A Windows nem '
          'engedte az értesítések használatát.',
        ),
      );
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(bar);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheduler = ref.watch(reminderSchedulerProvider);
    if (scheduler is! TestableReminders) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: const Key('reminder-test'),
        onPressed: _busy ? null : () => _try(scheduler as TestableReminders),
        icon: const Icon(Icons.notifications_active_outlined),
        label: const Text('Próba-értesítés (fél perc múlva)'),
      ),
    );
  }
}
