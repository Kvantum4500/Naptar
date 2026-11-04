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
    this.tzid = 'Europe/Budapest',
  });
  final int sleepStartHour;
  final int sleepEndHour;
  final int bufferMinutes;
  final int minHoursBetweenHard;
  final int maxWorkoutsPerWeek;
  final int minEnergyForHard; // 1..5 physical energy
  final String tzid;
}

class ProposedBlock {
  const ProposedBlock({
    required this.title,
    required this.startUtc,
    required this.endUtc,
    this.isWorkout = true,
    this.isHard = false,
  });
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
