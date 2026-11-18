import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_log.dart';
import '../notify/reminders.dart'
    show reminderDebounceProvider, reminderTimerProvider;
import '../providers.dart';
import '../ui/day_utils.dart';
import 'widget_bridge.dart';
import 'widget_data.dart';

/// What was last handed to the widget, and the runs one after the other.
class _WidgetRuns {
  Future<void> last = Future.value();
  String? lastSnapshot;
}

/// Counts the times the app came back to the front. The widget may have been
/// put on the home screen (or taken off and put back) while the app was away,
/// and nothing in the calendar has changed to say so: the sync looks again.
class WidgetKick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final widgetKickProvider = NotifierProvider<WidgetKick, int>(WidgetKick.new);

final _widgetRunsProvider = Provider<_WidgetRuns>((_) => _WidgetRuns());

/// Keeps the home-screen widget in step with the calendar and the tasks.
/// Watch it once from the home page. Like the reminders it waits for the
/// calendar to settle, and a snapshot equal to the last one is not sent again.
final widgetSyncProvider = Provider<void>((ref) {
  final bridge = ref.read(widgetBridgeProvider);
  if (!bridge.active) return;
  ref.watch(eventsTickProvider);
  ref.watch(tasksProvider);
  ref.watch(todayProvider); // (at midnight the days move on)
  ref.watch(widgetKickProvider);
  final runs = ref.read(_widgetRunsProvider);
  final timer = ref.read(reminderTimerProvider)(
    ref.read(reminderDebounceProvider),
    () {
      // everything the run needs is taken now: it must not touch [ref] after
      // the provider has been rebuilt or disposed
      final repo = ref.read(repoProvider);
      final now = ref.read(appClockProvider)().toUtc();
      final tasks = ref.read(tasksProvider).value ?? const <TaskView>[];
      final log = ref.read(diagLogProvider);
      runs.last = runs.last.then((_) async {
        try {
          // no widget on any home screen: nothing is prepared, and what was
          // sent before is forgotten (the platform side drops its copy when
          // the last widget goes), so that a widget put there later is filled
          if (!await bridge.isPlaced()) {
            runs.lastSnapshot = null;
            return;
          }
          final occurrences = await repo.occurrences(
            resolveWallClock(defaultTz, todayIn(now)),
            now.add(const Duration(days: 15)),
          );
          final snapshot = widgetSnapshot(
            nowUtc: now,
            occurrences: occurrences,
            tasks: tasks,
          );
          if (snapshot == runs.lastSnapshot) return;
          // (false: the widget went away just now, nothing was kept for it)
          final taken = await bridge.update(snapshot);
          runs.lastSnapshot = taken ? snapshot : null;
        } catch (e, st) {
          // the widget is a convenience; never break the app because of it
          log.error('widget', 'update.failed', e, st);
        }
      });
    },
  );
  ref.onDispose(timer.cancel);
});
