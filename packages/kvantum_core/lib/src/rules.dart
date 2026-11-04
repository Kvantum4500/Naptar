import 'event.dart';
import 'time.dart';

/// Hard constraints the AI may never violate. Enforced in code, not by prompt.
class PlanRules {
  const PlanRules({
    this.sleepStartHour = 23,
    this.sleepEndHour = 7,
    this.bufferMinutes = 15,
    this.minHoursBetweenHard = 48,
    this.maxWorkoutsPerWeek = 5,
    this.minEnergyForHard = 3,
    this.shiftBufferHours = 8,
    this.tzid = 'Europe/Budapest',
  });
  final int sleepStartHour;
  final int sleepEndHour;
  final int bufferMinutes;
  final int minHoursBetweenHard;
  final int maxWorkoutsPerWeek;
  final int minEnergyForHard; // 1..5 physical energy

  /// A hard session may not start/end this close to a shift.
  final int shiftBufferHours;
  final String tzid;
}

class ProposedBlock {
  const ProposedBlock({
    required this.title,
    required this.startUtc,
    required this.endUtc,
    this.isWorkout = true,
    this.isHard = false,
    this.taskId,
    this.taskDue,
    this.taskEstimateMin,
    this.taskEnergy,
  });

  /// Set when the block works on a task: enables the deadline / length /
  /// energy checks. [taskDue] is a floating date, inclusive.
  final String? taskId;
  final DateTime? taskDue;
  final int? taskEstimateMin;
  final int? taskEnergy;
  final String title;
  final DateTime startUtc;
  final DateTime endUtc;
  final bool isWorkout;
  final bool isHard;
}

class Violation {
  const Violation(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

/// [existing] = occurrences already in the calendar. [energyByDate] maps a
/// floating date (y/m/d, UTC-flagged) to the user's physical energy 1..5.
List<Violation> validateProposal(
  List<ProposedBlock> proposal, {
  required List<Occurrence> existing,
  required PlanRules rules,
  Map<DateTime, int> energyByDate = const {},
}) {
  final v = <Violation>[];
  final buffer = Duration(minutes: rules.bufferMinutes);
  final sorted = [...proposal]
    ..sort((a, b) => a.startUtc.compareTo(b.startUtc));

  for (var i = 0; i < sorted.length; i++) {
    final b = sorted[i];
    if (!b.endUtc.isAfter(b.startUtc)) {
      v.add(
        Violation(
          'bad_range',
          '„${b.title}”: a befejezésnek a kezdés után kell lennie',
        ),
      );
      continue;
    }
    // Sleep window (in the user's zone).
    final s = toWallClock(rules.tzid, b.startUtc);
    final e = toWallClock(rules.tzid, b.endUtc);
    if (_inSleep(s, rules) ||
        _inSleep(e.subtract(const Duration(minutes: 1)), rules)) {
      v.add(Violation('sleep_window', '„${b.title}” az alvási sávba esik'));
    }
    // Overlap + buffer with existing events (all-day events do not block).
    for (final x in existing.where((x) => !x.allDay)) {
      if (b.startUtc.isBefore(x.endUtc.add(buffer)) &&
          x.startUtc.isBefore(b.endUtc.add(buffer))) {
        v.add(
          Violation(
            'conflict',
            '„${b.title}” ütközik ezzel: „${x.title}” (a ${rules.bufferMinutes} perc puffert is beleszámítva)',
          ),
        );
      }
    }
    // Overlap among proposed blocks.
    if (i > 0 && sorted[i - 1].endUtc.add(buffer).isAfter(b.startUtc)) {
      v.add(
        Violation(
          'self_conflict',
          '„${b.title}” átfedi ezt: „${sorted[i - 1].title}”',
        ),
      );
    }
    // Energy gate for hard sessions.
    if (b.isHard) {
      final day = floating(s.year, s.month, s.day);
      final energy = energyByDate[day];
      final rest = Duration(hours: rules.shiftBufferHours);
      for (final x in existing.where((x) => x.isShift && !x.allDay)) {
        if (b.startUtc.isBefore(x.endUtc.add(rest)) &&
            x.startUtc.isBefore(b.endUtc.add(rest))) {
          v.add(
            Violation(
              'shift_rest',
              '„${b.title}” nehéz edzés, de a műszakhoz (${x.title}) túl közel van (előtte és utána legalább ${rules.shiftBufferHours} óra kell)',
            ),
          );
          break;
        }
      }
      if (energy == null) {
        v.add(
          Violation(
            'no_data_hard',
            '„${b.title}” nehéz edzés, de ${day.toIso8601String().substring(0, 10)}-ra nincs check-in; check-in nélkül csak könnyű edzés javasolható',
          ),
        );
      }
      if (energy != null && energy < rules.minEnergyForHard) {
        v.add(
          Violation(
            'low_energy',
            '„${b.title}” nehéz edzés, de a fizikai energia ${day.toIso8601String().substring(0, 10)}-n csak $energy/5 (legalább ${rules.minEnergyForHard} kell)',
          ),
        );
      }
    }
  }

  // Task blocks: deadline, enough time in total, energy.
  final byTask = <String, List<ProposedBlock>>{};
  for (final b in sorted.where((b) => b.taskId != null)) {
    byTask.putIfAbsent(b.taskId!, () => []).add(b);
    final end = toWallClock(
      rules.tzid,
      b.endUtc.subtract(const Duration(minutes: 1)),
    );
    final due = b.taskDue;
    if (due != null &&
        floating(
          end.year,
          end.month,
          end.day,
        ).isAfter(floating(due.year, due.month, due.day))) {
      v.add(
        Violation(
          'after_due',
          '„${b.title}” a feladat határideje (${due.toIso8601String().substring(0, 10)}) utánra esik',
        ),
      );
    }
    final need = b.taskEnergy;
    if (need != null && need >= 4) {
      final s = toWallClock(rules.tzid, b.startUtc);
      final day = floating(s.year, s.month, s.day);
      final energy = energyByDate[day];
      if (energy != null && energy < 3) {
        v.add(
          Violation(
            'task_energy',
            '„${b.title}” nagy energiát igénylő feladat, de a fizikai energia ${day.toIso8601String().substring(0, 10)}-n csak $energy/5',
          ),
        );
      }
    }
  }
  byTask.forEach((id, blocks) {
    final est = blocks.first.taskEstimateMin;
    if (est == null) return;
    final total = blocks.fold<int>(
      0,
      (a, b) => a + b.endUtc.difference(b.startUtc).inMinutes,
    );
    if (total < est) {
      v.add(
        Violation(
          'task_too_short',
          '„${blocks.first.title}”: a feladat becsült ideje $est perc, de csak $total perc van beütemezve',
        ),
      );
    }
  });

  // Rest between hard sessions.
  final hard = sorted.where((b) => b.isHard).toList();
  for (var i = 1; i < hard.length; i++) {
    final gap = hard[i].startUtc.difference(hard[i - 1].endUtc);
    if (gap < Duration(hours: rules.minHoursBetweenHard)) {
      v.add(
        Violation(
          'rest',
          'Két nehéz edzés között legalább ${rules.minHoursBetweenHard} óra kell',
        ),
      );
    }
  }

  // Weekly workout cap (ISO week, user zone).
  final perWeek = <String, int>{};
  for (final b in sorted.where((b) => b.isWorkout)) {
    final w = toWallClock(rules.tzid, b.startUtc);
    final monday = w.subtract(Duration(days: w.weekday - 1));
    final key = '${monday.year}-${monday.month}-${monday.day}';
    perWeek[key] = (perWeek[key] ?? 0) + 1;
  }
  perWeek.forEach((k, n) {
    if (n > rules.maxWorkoutsPerWeek) {
      v.add(
        Violation(
          'weekly_cap',
          '$n edzés a(z) $k-i hétre (legfeljebb ${rules.maxWorkoutsPerWeek} megengedett)',
        ),
      );
    }
  });
  return v;
}

bool _inSleep(DateTime wall, PlanRules r) {
  final h = wall.hour;
  return r.sleepStartHour > r.sleepEndHour
      ? (h >= r.sleepStartHour || h < r.sleepEndHour)
      : (h >= r.sleepStartHour && h < r.sleepEndHour);
}
