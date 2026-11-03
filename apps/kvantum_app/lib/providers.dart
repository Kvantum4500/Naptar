import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'data/db.dart';
import 'data/event_repository.dart';
import 'ui/day_utils.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final repoProvider = Provider<EventRepository>(
  (ref) => EventRepository(ref.watch(dbProvider)),
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

DateTime _today() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day);
}

class SelectedDay extends Notifier<DateTime> {
  @override
  DateTime build() => _today();
  void set(DateTime d) => state = DateTime.utc(d.year, d.month, d.day);
}

class VisibleMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final t = _today();
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
