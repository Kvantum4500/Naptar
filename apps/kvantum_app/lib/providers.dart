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
  (ref) =>
      ref.watch(repoProvider).watchAll().map((e) => e.length * 31 + e.hashCode),
);

DateTime _today() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day);
}

class SelectedDay extends Notifier<DateTime> {
  @override
  DateTime build() => _today();
  void set(DateTime d) => state = d;
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

/// Occurrences for the 6-week grid of the visible month, grouped by day.
final monthOccurrencesProvider =
    FutureProvider<Map<DateTime, List<Occurrence>>>((ref) async {
      ref.watch(eventsTickProvider);
      final month = ref.watch(visibleMonthProvider);
      final grid = monthGrid(month);
      final (from, to) = windowOf(
        grid.first,
        grid.last.add(const Duration(days: 1)),
      );
      final occ = await ref.watch(repoProvider).occurrences(from, to);
      final map = <DateTime, List<Occurrence>>{};
      for (final o in occ) {
        for (final d in daysOf(o)) {
          (map[d] ??= []).add(o);
        }
      }
      return map;
    });
