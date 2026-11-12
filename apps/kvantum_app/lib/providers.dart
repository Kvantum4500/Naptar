import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'data/db.dart';
import 'data/event_repository.dart';
import 'data/finance_repository.dart';
import 'data/housekeeping.dart';
import 'finance/wallet_bridge.dart';
import 'finance/wallet_ingest.dart';
import 'data/record_repository.dart';
import 'diag/diag_log.dart';
import 'sync/sync_controller.dart';
import 'ui/day_utils.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Where the database file is (null for an in-memory one, as in tests); the
/// Diagnostics page shows its size.
final dbPathProvider = Provider<String?>((_) => null);

final financeRepoProvider = Provider<FinanceRepository>(
  (ref) => FinanceRepository(
    ref.watch(dbProvider),
    // a change starts a mail run (debounced; does nothing when signed out)
    onChanged: () => ref.read(syncControllerProvider.notifier).requestSync(),
  ),
);

final finTxProvider = StreamProvider<List<FinTx>>(
  (ref) => ref.watch(financeRepoProvider).watchTx(),
);
final finCategoriesProvider = StreamProvider<List<FinCategory>>(
  (ref) => ref.watch(financeRepoProvider).watchCategories(),
);
final finBudgetsProvider = StreamProvider<List<FinBudget>>(
  (ref) => ref.watch(financeRepoProvider).watchBudgets(),
);
final finRecurringProvider = StreamProvider<List<FinRecurring>>(
  (ref) => ref.watch(financeRepoProvider).watchRecurring(),
);
final finGoalsProvider = StreamProvider<List<FinGoal>>(
  (ref) => ref.watch(financeRepoProvider).watchGoals(),
);
final finDepositsProvider = StreamProvider<List<FinDeposit>>(
  (ref) => ref.watch(financeRepoProvider).watchDeposits(),
);

final walletBridgeProvider = Provider<WalletBridge>(
  (_) => ChannelWalletBridge(),
);

final walletIngestProvider = Provider<WalletIngest>(
  (ref) => WalletIngest(
    ref.watch(financeRepoProvider),
    ref.watch(walletBridgeProvider),
  ),
);

final repoProvider = Provider<EventRepository>(
  (ref) =>
      EventRepository(ref.watch(dbProvider), log: ref.watch(diagLogProvider)),
);

/// Emits whenever any event changes; views re-query occurrences from it.
final eventsTickProvider = StreamProvider<int>(
  (ref) => ref
      .watch(repoProvider)
      .watchAll()
      .map(
        (e) => Object.hashAll(e.map((x) => '${x.id}:${x.version}:${x.etag}')),
      ),
);

/// The clock of the app (replaced by tests).
final appClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Starts the timer that wakes [todayProvider] at midnight (replaced by tests).
final midnightTimerProvider =
    Provider<Timer Function(Duration, void Function())>((_) => Timer.new);

/// Today's date in the display zone (a floating y/m/d). It changes at midnight
/// of that zone, and when the app comes back to the front (a timer may have
/// stood still while the device slept), so a calendar left open overnight
/// moves on to the new day.
class Today extends Notifier<DateTime> {
  Timer? _timer;

  @override
  DateTime build() {
    ref.onDispose(() => _timer?.cancel());
    final now = ref.read(appClockProvider)();
    _arm(now);
    return todayIn(now);
  }

  void _arm(DateTime now) {
    _timer?.cancel();
    final wall = toWallClock(defaultTz, now.toUtc());
    final midnight = resolveWallClock(
      defaultTz,
      DateTime.utc(wall.year, wall.month, wall.day + 1),
    );
    // a moment after midnight, never before it
    final wait = midnight.difference(now.toUtc()) + const Duration(seconds: 1);
    _timer = ref.read(midnightTimerProvider)(wait, refresh);
  }

  /// Looks at the clock again (midnight, or the app is in front again).
  void refresh() {
    final now = ref.read(appClockProvider)();
    _arm(now);
    final t = todayIn(now);
    if (t != state) state = t;
  }
}

final todayProvider = NotifierProvider<Today, DateTime>(Today.new);

class SelectedDay extends Notifier<DateTime> {
  @override
  DateTime build() {
    // whoever was looking at "today" keeps looking at today
    ref.listen(todayProvider, (before, now) {
      if (before != null && state == before) state = now;
    });
    return ref.read(todayProvider);
  }

  void set(DateTime d) => state = DateTime.utc(d.year, d.month, d.day);
}

class VisibleMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    ref.listen(todayProvider, (before, now) {
      if (before != null &&
          state == DateTime.utc(before.year, before.month, 1)) {
        state = DateTime.utc(now.year, now.month, 1);
      }
    });
    final t = ref.read(todayProvider);
    return DateTime.utc(t.year, t.month, 1);
  }

  void set(DateTime d) => state = DateTime.utc(d.year, d.month, 1);
}

final selectedDayProvider = NotifierProvider<SelectedDay, DateTime>(
  SelectedDay.new,
);
final visibleMonthProvider = NotifierProvider<VisibleMonth, DateTime>(
  VisibleMonth.new,
);

enum CalView { month, week, day }

/// Month is the start view; the choice is remembered between runs.
class ViewMode extends Notifier<CalView> {
  static const _key = 'calView';

  @override
  CalView build() {
    Future.microtask(_load);
    return CalView.month;
  }

  Future<void> _load() async {
    final saved = await ref.read(repoProvider).meta(_key);
    final v = CalView.values.where((e) => e.name == saved).firstOrNull;
    if (v != null && v != state) state = v;
  }

  void set(CalView v) {
    state = v;
    ref.read(repoProvider).setMeta(_key, v.name);
  }
}

final viewModeProvider = NotifierProvider<ViewMode, CalView>(ViewMode.new);

/// Inclusive first day .. exclusive end day (floating dates).
class DayRange {
  const DayRange(this.first, this.endExclusive);
  final DateTime first;
  final DateTime endExclusive;
  @override
  bool operator ==(Object other) =>
      other is DayRange &&
      other.first == first &&
      other.endExclusive == endExclusive;
  @override
  int get hashCode => Object.hash(first, endExclusive);
}

/// Occurrences overlapping [range], grouped by every day they touch.
final rangeOccurrencesProvider =
    FutureProvider.family<Map<DateTime, List<Occurrence>>, DayRange>((
      ref,
      range,
    ) async {
      ref.watch(eventsTickProvider);
      final (from, to) = windowOf(range.first, range.endExclusive);
      final occ = await ref.watch(repoProvider).occurrences(from, to);
      final map = <DateTime, List<Occurrence>>{};
      for (final o in occ) {
        for (final d in daysOf(o)) {
          (map[d] ??= []).add(o);
        }
      }
      return map;
    });

/// The 6-week grid of the visible month.
final monthRangeProvider = Provider<DayRange>((ref) {
  final grid = monthGrid(ref.watch(visibleMonthProvider));
  return DayRange(grid.first, grid.last.add(const Duration(days: 1)));
});

/// Week (Mon..Sun) around the selected day, or just the day in day view.
final weekRangeProvider = Provider<DayRange>((ref) {
  final d = ref.watch(selectedDayProvider);
  final first = startOfWeek(d);
  return DayRange(first, first.add(const Duration(days: 7)));
});

final dayRangeProvider = Provider<DayRange>((ref) {
  final d = ref.watch(selectedDayProvider);
  return DayRange(d, d.add(const Duration(days: 1)));
});

/// Occurrences for whichever range the active view needs.
final monthOccurrencesProvider =
    FutureProvider<Map<DateTime, List<Occurrence>>>(
      (ref) => ref.watch(
        rangeOccurrencesProvider(ref.watch(monthRangeProvider)).future,
      ),
    );

/// Quiet upkeep of the local data (see [Housekeeping]).
final housekeepingProvider = Provider<Housekeeping>(
  (ref) => Housekeeping(
    events: ref.watch(repoProvider),
    finance: ref.watch(financeRepoProvider),
    now: ref.watch(appClockProvider),
  ),
);

final recordRepoProvider = Provider<RecordRepository>(
  (ref) => RecordRepository(ref.watch(dbProvider)),
);

/// Open tasks first (overdue, then by due date, priority), done tasks last.
final tasksProvider = StreamProvider<List<TaskView>>(
  (ref) => ref.watch(recordRepoProvider).watch(kindTask).map((recs) {
    final list = [for (final r in recs) TaskView(r)]
        .where((t) => !t.deleted)
        .toList();
    list.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      final da = a.due, db = b.due;
      if (da != null && db != null && da != db) return da.compareTo(db);
      if ((da == null) != (db == null)) return da == null ? 1 : -1;
      if (a.priority != b.priority) return b.priority.compareTo(a.priority);
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return list;
  }),
);

/// Newest check-in first.
final checkInsProvider = StreamProvider<List<CheckInView>>(
  (ref) => ref.watch(recordRepoProvider).watch(kindCheckIn).map((recs) {
    final list = [for (final r in recs) CheckInView(r)]
        .where((c) => !c.deleted && c.date != null)
        .toList();
    list.sort((a, b) => b.date!.compareTo(a.date!));
    return list;
  }),
);
