import 'event.dart';
import 'text_safety.dart';
import 'time.dart';
import 'weather.dart';
import 'workout.dart';

/// Hard constraints the AI may never violate. Enforced in code, not by prompt.
class PlanRules {
  const PlanRules({
    this.sleepStartHour = 23,
    this.sleepEndHour = 7,
    this.bufferMinutes = 15,
    this.minHoursBetweenHard = 48,
    this.maxWorkoutsPerWeek = 5,
    this.minEnergyForHard = 3,
    this.assumedEnergy = 3,
    this.hardFromMinutes = 60,
    this.shiftBufferFromMinutes = 45,
    this.shiftBufferHours = 8,
    this.tzid = 'Europe/Budapest',
  });
  final int sleepStartHour;
  final int sleepEndHour;
  final int bufferMinutes;
  final int minHoursBetweenHard;
  final int maxWorkoutsPerWeek;
  final int minEnergyForHard; // 1..5 physical energy

  /// The physical energy taken for a day without a check-in (a check-in exists
  /// only for today and the past, so every planned day lacks one). A hard
  /// session needs [minEnergyForHard]: with the defaults (3 and 3) a day
  /// without data is allowed, and raising the minimum to 4 makes such days
  /// light-only again.
  final int assumedEnergy;

  /// A workout of this many minutes or more is a hard one (unless its title
  /// says it is light: "könnyű", "nyújtás", "mobilitás" …).
  final int hardFromMinutes;

  /// A workout of this many minutes or more keeps the distance from a shift too.
  final int shiftBufferFromMinutes;

  /// A hard session (or a workout of [shiftBufferFromMinutes]) may not
  /// start/end this close to a shift.
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
    this.outdoor = false,
  });

  /// Done outside (set by the model or recognised from the title): the
  /// forecast of that day is checked.
  final bool outdoor;

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

  /// The text that may go back to the model. [events] / [checkins] say which
  /// of the user's own data it is allowed to learn about: details that come
  /// from a source the user switched off are replaced by a generic sentence,
  /// and everything else is sanitised like any other free text.
  String forModel({required bool events, required bool checkins}) {
    switch (code) {
      case 'conflict':
      case 'shift_rest':
        if (!events) {
          return 'Ütközik egy meglévő eseménnyel, vagy túl közel van egy műszakhoz.';
        }
      case 'low_energy':
      case 'no_data_hard':
        if (!checkins) return 'Erre a napra nehéz edzés nem javasolható.';
    }
    return sanitizeText(message, max: 300);
  }

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
  Map<DateTime, DayWeather> weatherByDate = const {},
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
    // (any overlap counts: a block that spans the whole night starts and ends
    // outside the sleep window and still takes the sleep away)
    if (_touchesSleep(s, e, rules)) {
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
    // Outdoor activities need fitting weather (when a forecast is known).
    if (b.outdoor || outdoorSport(b.title)) {
      final day = floating(s.year, s.month, s.day);
      final w = weatherByDate[day];
      final why = w == null ? null : weatherProblem(w, title: b.title);
      if (why != null) {
        v.add(
          Violation(
            'weather',
            '„${b.title}” szabadtéri, de ${day.toIso8601String().substring(0, 10)}-n az időjárás nem alkalmas: $why',
          ),
        );
      }
    }
    // A hard session, and any workout of 45 minutes or more, keeps its
    // distance from a shift.
    final minutes = b.endUtc.difference(b.startUtc).inMinutes;
    if (b.isHard || (b.isWorkout && minutes >= rules.shiftBufferFromMinutes)) {
      final rest = Duration(hours: rules.shiftBufferHours);
      for (final x in existing.where((x) => x.isShift && !x.allDay)) {
        if (b.startUtc.isBefore(x.endUtc.add(rest)) &&
            x.startUtc.isBefore(b.endUtc.add(rest))) {
          v.add(
            Violation(
              'shift_rest',
              '„${b.title}” ${b.isHard ? 'nehéz ' : ''}edzés, de a műszakhoz (${x.title}) túl közel van (előtte és utána legalább ${rules.shiftBufferHours} óra kell)',
            ),
          );
          break;
        }
      }
    }
    // Energy gate for hard sessions. A day without a check-in (every planned
    // day) is taken as [PlanRules.assumedEnergy].
    if (b.isHard) {
      final day = floating(s.year, s.month, s.day);
      final known = energyByDate[day];
      final energy = known ?? rules.assumedEnergy;
      if (energy < rules.minEnergyForHard) {
        final date = day.toIso8601String().substring(0, 10);
        v.add(
          known == null
              ? Violation(
                  'no_data_hard',
                  '„${b.title}” nehéz edzés, de $date-ra nincs check-in (${rules.assumedEnergy}/5 energiát feltételezve), a nehézhez legalább ${rules.minEnergyForHard}/5 kell',
                )
              : Violation(
                  'low_energy',
                  '„${b.title}” nehéz edzés, de a fizikai energia $date-n csak $known/5 (legalább ${rules.minEnergyForHard} kell)',
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

  // The workouts already in the calendar (typed in, or an earlier plan) count
  // as much as the proposed ones: for the rest between hard sessions and for
  // the weekly cap. Shifts and all-day events are never workouts.
  final booked = [
    for (final x in existing)
      if (!x.allDay && !x.isShift && isWorkoutTitle(x.title)) x,
  ];

  // Rest between hard sessions: every pair of neighbours of which at least one
  // is proposed (what is already booked is not judged again).
  final line = <({DateTime start, DateTime end, String title, bool planned})>[
    for (final b in sorted.where((b) => b.isHard))
      (start: b.startUtc, end: b.endUtc, title: b.title, planned: true),
    for (final x in booked)
      if (isHardWorkout(
        title: x.title,
        length: x.endUtc.difference(x.startUtc),
        fromMinutes: rules.hardFromMinutes,
      ))
        (start: x.startUtc, end: x.endUtc, title: x.title, planned: false),
  ]..sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < line.length; i++) {
    final a = line[i - 1], b = line[i];
    if (!a.planned && !b.planned) continue;
    final gap = b.start.difference(a.end);
    // (an overlap with something booked is a 'conflict' already)
    if (gap < Duration.zero && (!a.planned || !b.planned)) continue;
    if (gap < Duration(hours: rules.minHoursBetweenHard)) {
      v.add(
        Violation(
          'rest',
          a.planned && b.planned
              ? 'Két nehéz edzés között legalább ${rules.minHoursBetweenHard} óra kell'
              : 'Két nehéz edzés között legalább ${rules.minHoursBetweenHard} óra kell („${a.title}” és „${b.title}”)',
        ),
      );
    }
  }

  // Weekly workout cap (ISO week, user zone), for the weeks the proposal
  // touches: the proposed workouts plus the booked ones.
  String weekOf(DateTime utc) {
    final w = toWallClock(rules.tzid, utc);
    final monday = w.subtract(Duration(days: w.weekday - 1));
    return '${monday.year}-${monday.month}-${monday.day}';
  }

  final perWeek = <String, int>{};
  for (final b in sorted.where((b) => b.isWorkout)) {
    final k = weekOf(b.startUtc);
    perWeek[k] = (perWeek[k] ?? 0) + 1;
  }
  final bookedPerWeek = <String, int>{};
  for (final x in booked) {
    final k = weekOf(x.startUtc);
    if (perWeek.containsKey(k)) bookedPerWeek[k] = (bookedPerWeek[k] ?? 0) + 1;
  }
  perWeek.forEach((k, planned) {
    final already = bookedPerWeek[k] ?? 0;
    final n = planned + already;
    if (n > rules.maxWorkoutsPerWeek) {
      v.add(
        Violation(
          'weekly_cap',
          '$n edzés a(z) $k-i hétre (legfeljebb ${rules.maxWorkoutsPerWeek} megengedett${already > 0 ? '; ebből $already már a naptárban van' : ''})',
        ),
      );
    }
  });
  return v;
}

/// Whether the wall-clock interval [s, e) takes any of the sleep window, the
/// nights on both sides of it included.
bool _touchesSleep(DateTime s, DateTime e, PlanRules r) {
  if (r.sleepStartHour == r.sleepEndHour) return false;
  var day = floating(s.year, s.month, s.day).subtract(const Duration(days: 1));
  final last = floating(e.year, e.month, e.day);
  while (!day.isAfter(last)) {
    final from = floating(day.year, day.month, day.day, r.sleepStartHour);
    final to = floating(day.year, day.month, day.day, r.sleepEndHour).add(
      // (23:00 -> 07:00 ends the next morning)
      r.sleepStartHour > r.sleepEndHour
          ? const Duration(days: 1)
          : Duration.zero,
    );
    if (s.isBefore(to) && from.isBefore(e)) return true;
    day = day.add(const Duration(days: 1));
  }
  return false;
}
