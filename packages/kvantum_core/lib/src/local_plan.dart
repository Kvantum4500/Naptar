/// The workout planner that needs no model: for when the quota of the free
/// tier is used up, the key is missing, or the user simply prefers the program
/// to do it. It is a plain search over the free times of the calendar, and
/// EVERY candidate is judged by the same [validateProposal] the model's
/// proposals go through (sleep, the sleep after a night shift, the distance
/// from the shifts, rest between hard sessions, the weekly cap, energy,
/// weather, clashes): what it offers has passed every rule, and the rules are
/// not written twice.
///
/// On top of the rules it follows the habits the handbook states in words and
/// that were never in code: at most one workout a day, the workout of the sport
/// that was done longest ago first (so the week rotates through the user's
/// sports), a preferred time of day, outdoor sports only in their season.
library;

import 'dart:convert';

import 'assistant_models.dart';
import 'event.dart';
import 'free_slots.dart';
import 'models.dart';
import 'rules.dart';
import 'text_safety.dart';
import 'time.dart';
import 'weather.dart';
import 'workout.dart';

/// One sport the user plans with: what it is called, how long a session is,
/// and whether it is done outside (then the season and the forecast count).
class PlanSport {
  const PlanSport({
    required this.name,
    required this.minutes,
    this.outdoor = false,
  });

  final String name;
  final int minutes;
  final bool outdoor;

  /// The title of the event: "Calisthenics 45 perc" (the sport and the time, as
  /// the handbook wants it). A name that does not say it is a workout gets the
  /// word "edzés", or the calendar would not count it as one later.
  String get title {
    final base = '$name $minutes perc';
    return isWorkoutTitle(base) ? base : '$name edzés $minutes perc';
  }

  /// What the program tells sports apart by ("gym", "calisthenics" …, or the
  /// plain name when it is none of them).
  String get key {
    final k = sportKey(title);
    return k.isNotEmpty && k != 'edzes' ? k : foldHu(name);
  }

  /// A sport the user typed in: a name of 1–40 characters and 15–180 minutes.
  /// Anything else is not a sport (null).
  static PlanSport? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = '${json['name'] ?? ''}'
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final minutes = json['minutes'];
    if (name.isEmpty || name.length > 40) return null;
    if (minutes is! int || minutes < 15 || minutes > 180) return null;
    return PlanSport(
      name: name,
      minutes: minutes,
      outdoor: json['outdoor'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'minutes': minutes,
    if (outdoor) 'outdoor': true,
  };

  @override
  bool operator ==(Object other) =>
      other is PlanSport &&
      other.name == name &&
      other.minutes == minutes &&
      other.outdoor == outdoor;

  @override
  int get hashCode => Object.hash(name, minutes, outdoor);

  @override
  String toString() => 'PlanSport($name, $minutes, outdoor: $outdoor)';
}

/// The sports of the first start: the two the handbook names first.
const defaultPlanSports = [
  PlanSport(name: 'Calisthenics', minutes: 45),
  PlanSport(name: 'Gym', minutes: 60),
];

/// When in the day the user likes to work out. Only a preference: a session
/// outside the band is planned when nothing inside it fits.
class PlanBand {
  const PlanBand._(this.id, this.label, this.fromHour, this.toHour);

  final String id;
  final String label;
  final int fromHour;
  final int toHour;

  /// No wish: late morning to evening, which is where most days have room.
  static const any = PlanBand._('any', 'Bármikor', 10, 19);
  static const morning = PlanBand._('morning', 'Reggel', 6, 10);
  static const forenoon = PlanBand._('forenoon', 'Délelőtt', 9, 13);
  static const afternoon = PlanBand._('afternoon', 'Délután', 13, 18);
  static const evening = PlanBand._('evening', 'Este', 17, 21);

  static const values = [any, morning, forenoon, afternoon, evening];

  /// The band with this id; "any" for an unknown one.
  static PlanBand byId(String? id) =>
      values.firstWhere((b) => b.id == id, orElse: () => any);

  @override
  String toString() => 'PlanBand($id)';
}

/// What the user told the local planner (stored on the device only).
class LocalPlanPrefs {
  const LocalPlanPrefs({
    this.sports = defaultPlanSports,
    this.perWeek = 3,
    this.band = PlanBand.any,
  });

  /// The sports in the order they are listed (the order of a tie).
  final List<PlanSport> sports;

  /// How many workouts to have in a week (the ones already in the calendar
  /// count): 1–7.
  final int perWeek;
  final PlanBand band;

  LocalPlanPrefs copyWith({
    List<PlanSport>? sports,
    int? perWeek,
    PlanBand? band,
  }) => LocalPlanPrefs(
    sports: sports ?? this.sports,
    perWeek: perWeek ?? this.perWeek,
    band: band ?? this.band,
  );

  String encode() => jsonEncode({
    'v': 1,
    'sports': [for (final s in sports) s.toJson()],
    'perWeek': perWeek,
    'band': band.id,
  });

  /// Reads what [encode] wrote. Whatever is missing or damaged is the default
  /// (a list of sports the user emptied stays empty: that is their wish).
  static LocalPlanPrefs decode(String? text) {
    if (text == null || text.trim().isEmpty) return const LocalPlanPrefs();
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      return const LocalPlanPrefs();
    }
    if (j is! Map) return const LocalPlanPrefs();
    final raw = j['sports'];
    final sports = raw is List
        ? [
            for (final s in raw.take(12))
              if (PlanSport.tryParse(s) case final PlanSport p) p,
          ]
        : defaultPlanSports;
    final n = j['perWeek'];
    return LocalPlanPrefs(
      sports: sports,
      perWeek: n is int ? n.clamp(1, 7) : 3,
      band: PlanBand.byId(j['band'] is String ? j['band'] as String : null),
    );
  }
}

/// What the local planner came up with.
class LocalPlan {
  const LocalPlan({
    required this.items,
    required this.summary,
    this.dropped = const [],
    this.wanted = 0,
    this.alreadyBooked = 0,
  });

  /// The sessions, each one checked by every rule. Hard ones are marked.
  final List<ProposalItem> items;

  /// One sentence for the head of the answer.
  final String summary;

  /// Why something did not fit (empty when everything did).
  final List<String> dropped;

  /// How many sessions the user's weekly wish asked for in all, the ones
  /// already in the calendar included.
  final int wanted;

  /// How many workouts the calendar already had in the window.
  final int alreadyBooked;
}

/// Plans workouts for the [days] days from [from] (a floating date).
///
/// [existing] must hold the calendar around the window: the ISO weeks it
/// touches and a few days on both sides (the weekly cap and the rest between
/// hard sessions look that far), and the last weeks too, for the rotation of
/// the sports. [log] is the feedback on past workouts (what was done and when);
/// [nowUtc] keeps a session from starting in the past when the window starts
/// today. The same input always gives the same plan.
LocalPlan planWorkoutsLocally({
  required DateTime from,
  int days = 7,
  required LocalPlanPrefs prefs,
  required PlanRules rules,
  required List<Occurrence> existing,
  List<WorkoutLogView> log = const [],
  Map<DateTime, int> energyByDate = const {},
  Map<DateTime, DayWeather> weatherByDate = const {},
  DateTime? nowUtc,
}) {
  final tz = rules.tzid;
  final first = floating(from.year, from.month, from.day);
  final span = days.clamp(1, 14);
  final perWeek = prefs.perWeek.clamp(1, 7);
  final window = [for (var i = 0; i < span; i++) first.add(Duration(days: i))];
  final windowEnd = first.add(Duration(days: span));
  final sports = prefs.sports;

  if (sports.isEmpty) {
    return const LocalPlan(
      items: [],
      summary: 'Nincs megadott sport, ezért nincs mit tervezni. Adj meg legalább egyet a Beállításokban („Helyi terv”).',
    );
  }

  DateTime dayOf(DateTime utc) {
    final w = toWallClock(tz, utc);
    return floating(w.year, w.month, w.day);
  }

  // The workouts the calendar already has (typed in, or an earlier plan).
  final booked = [
    for (final x in existing)
      if (!x.allDay && !x.isShift && isWorkoutTitle(x.title)) x,
  ];
  final bookedDays = [for (final x in booked) dayOf(x.startUtc)];
  final inWindow = [
    for (final d in bookedDays)
      if (!d.isBefore(first) && d.isBefore(windowEnd)) d,
  ];
  final need = perWeek - inWindow.length;
  if (need <= 0) {
    return LocalPlan(
      items: const [],
      summary:
          'A naptárban már ott van a heti cél: ${inWindow.length} edzés a következő $span napra, nincs mit hozzátenni.',
      wanted: perWeek,
      alreadyBooked: inWindow.length,
    );
  }

  // When each sport was last done: the feedback and the calendar (what is
  // booked ahead counts as done on its day, so a sport that is planned already
  // goes to the back of the line).
  final lastDone = <String, DateTime>{};
  void done(String sport, DateTime day) {
    if (sport.isEmpty) return;
    final old = lastDone[sport];
    if (old == null || day.isAfter(old)) lastDone[sport] = day;
  }

  // The key a title belongs to: one of the user's sports when it names it (so
  // a sport of their own is told apart from a plain "edzés"), else what the
  // program tells sports apart by.
  String keyOf(String title, String fallback) {
    final t = foldHu(title);
    for (final s in sports) {
      if (t.contains(foldHu(s.name))) return s.key;
    }
    return fallback;
  }

  for (final l in log) {
    final d = l.date;
    if (l.done && !l.deleted && d != null) done(keyOf(l.title, l.sport), d);
  }
  for (final x in booked) {
    done(keyOf(x.title, sportKey(x.title)), dayOf(x.startUtc));
  }

  final dayTaken = {...inWindow};
  final otherDays = [...bookedDays];
  final chosen = <ProposalItem>[];
  final rationale = <ProposalItem, String>{};
  Map<String, int> tally = {};

  // The sports in the order they are due: never done first, then the one done
  // longest ago; a tie keeps the order of the list.
  List<PlanSport> dueOrder() {
    final order = [
      for (var i = 0; i < sports.length; i++) (i: i, sport: sports[i]),
    ];
    order.sort((a, b) {
      final x = lastDone[a.sport.key], y = lastDone[b.sport.key];
      if (x == null && y == null) return a.i.compareTo(b.i);
      if (x == null) return -1;
      if (y == null) return 1;
      final c = x.compareTo(y);
      return c != 0 ? c : a.i.compareTo(b.i);
    });
    return [for (final o in order) o.sport];
  }

  List<Violation> check(List<ProposalItem> items) => validateProposal(
    [for (final i in items) i.toBlock(rules: rules)],
    existing: existing,
    rules: rules,
    energyByDate: energyByDate,
    weatherByDate: weatherByDate,
  );

  // The best place for one session of [sport]: the best day, and in it the
  // first time (in the order of the wish) that every rule lets through.
  ({ProposalItem item, DateTime day, double cost})? place(PlanSport sport) {
    ({ProposalItem item, DateTime day, double cost})? best;
    for (var di = 0; di < window.length; di++) {
      final day = window[di];
      if (dayTaken.contains(day)) {
        tally['day'] = (tally['day'] ?? 0) + 1;
        continue;
      }
      if (sport.outdoor && !_inSeason(sport, day.month)) {
        tally['season'] = (tally['season'] ?? 0) + 1;
        continue;
      }
      for (final start in _starts(day, sport, prefs.band, rules, existing)) {
        final item = _item(sport, start, rules);
        if (nowUtc != null &&
            item.startUtc.isBefore(nowUtc.add(const Duration(minutes: 15)))) {
          continue;
        }
        final broken = check([...chosen, item]);
        if (broken.isNotEmpty) {
          final cause = _causeOf(broken.first.code, item, existing, rules);
          tally[cause] = (tally[cause] ?? 0) + 1;
          continue;
        }
        var near = 3;
        for (final o in otherDays) {
          final gap = o.difference(day).inDays.abs();
          if (gap < near) near = gap;
        }
        final cost =
            (3 - near) * 100 +
            _bandPenalty(start, sport.minutes, prefs.band) * 10 +
            di;
        if (best == null || cost < best.cost) {
          best = (item: item, day: day, cost: cost);
        }
        break; // the first time that fits is the best one of this day
      }
    }
    return best;
  }

  var unplaced = 0;
  for (var k = 0; k < need; k++) {
    tally = {};
    ({ProposalItem item, DateTime day, double cost})? got;
    PlanSport? used;
    for (final sport in dueOrder()) {
      got = place(sport);
      if (got != null) {
        used = sport;
        break;
      }
    }
    if (got == null || used == null) {
      unplaced = need - k;
      break;
    }
    final since = lastDone[used.key];
    final forecast = weatherByDate[got.day] != null;
    rationale[got.item] = [
      'Helyi terv:',
      since == null
          ? 'ebből a sportból még nincs rögzített edzés, ezért ez következik.'
          : 'a legrégebben végzett sport (utoljára ${got.day.difference(since).inDays} napja).',
      if (used.outdoor && !forecast)
        'Előrejelzés nélkül, az évszak alapján javasolt.',
    ].join(' ');
    chosen.add(got.item);
    dayTaken.add(got.day);
    otherDays.add(got.day);
    done(used.key, got.day);
  }

  // What the user sees: sorted by time, each with its reason, hard ones marked
  // by the code's own verdict.
  chosen.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final items = [
    for (final i in chosen)
      ProposalItem(
        title: i.title,
        startWall: i.startWall,
        endWall: i.endWall,
        tzid: i.tzid,
        kind: i.kind,
        hard: i.isHardSession(rules: rules),
        reason: rationale[i] ?? '',
        outdoor: i.outdoor,
      ),
  ];

  final total = items.length + inWindow.length;
  final dropped = <String>[];
  if (unplaced > 0) {
    dropped.addAll(_why(unplaced, total, perWeek, span, tally, rules));
  }
  final head = items.isEmpty
      ? 'Helyi terv, modell nélkül: a következő $span napra nem fért be új edzés.'
      : 'Helyi terv, modell nélkül: ${items.length} edzés a következő $span napra${unplaced > 0 ? ' (a heti cél $perWeek lett volna)' : ''}.';
  return LocalPlan(
    items: items,
    summary: head,
    dropped: dropped,
    wanted: perWeek,
    alreadyBooked: inWindow.length,
  );
}

// ---------------------------------------------------------------- helpers

ProposalItem _item(PlanSport sport, DateTime startWall, PlanRules rules) {
  final item = ProposalItem(
    title: sport.title,
    startWall: startWall,
    endWall: startWall.add(Duration(minutes: sport.minutes)),
    tzid: rules.tzid,
    kind: 'workout',
    hard: false,
    reason: '',
    outdoor: sport.outdoor,
  );
  return item.withHard(item.isHardSession(rules: rules));
}

/// The months an outdoor sport is planned in: the handbook's seasons (kajak
/// May–September, the others spring to autumn). The forecast, when there is
/// one, decides about the day itself.
bool _inSeason(PlanSport sport, int month) {
  final (from, to) = sport.key == 'kajak' ? (5, 9) : (4, 10);
  return month >= from && month <= to;
}

/// How many hours of the session lie outside the wished band.
double _bandPenalty(DateTime wallStart, int minutes, PlanBand band) {
  final s = wallStart.hour + wallStart.minute / 60;
  final e = s + minutes / 60;
  final before = band.fromHour - s;
  final after = e - band.toHour;
  return (before > 0 ? before : 0) + (after > 0 ? after : 0);
}

/// The wall-clock starts to try on [day], the wished band first: every half
/// hour from 05:00 to 22:00, and the start of every free window (rounded up to
/// 5 minutes), so a tight gap between two events is used too. The rules judge
/// each of them; this only decides the order.
List<DateTime> _starts(
  DateTime day,
  PlanSport sport,
  PlanBand band,
  PlanRules rules,
  List<Occurrence> existing,
) {
  final tz = rules.tzid;
  final seen = <int>{};
  final out = <DateTime>[];
  void add(DateTime wall) {
    if (seen.add(wall.millisecondsSinceEpoch)) out.add(wall);
  }

  for (var m = 5 * 60; m <= 22 * 60; m += 30) {
    add(floating(day.year, day.month, day.day, m ~/ 60, m % 60));
  }
  final from = resolveWallClock(tz, floating(day.year, day.month, day.day));
  final to = resolveWallClock(
    tz,
    floating(day.year, day.month, day.day).add(const Duration(days: 1)),
  );
  for (final slot in findFreeSlots(
    busy: existing,
    fromUtc: from,
    toUtc: to,
    minLength: Duration(minutes: sport.minutes),
    rules: rules,
  )) {
    final w = toWallClock(tz, slot.startUtc);
    final up = floating(
      w.year,
      w.month,
      w.day,
      w.hour,
      w.minute + (5 - w.minute % 5) % 5,
    );
    if (up.year == day.year && up.month == day.month && up.day == day.day) {
      add(up);
    }
  }
  out.sort((a, b) {
    final c = _bandPenalty(
      a,
      sport.minutes,
      band,
    ).compareTo(_bandPenalty(b, sport.minutes, band));
    return c != 0 ? c : a.compareTo(b);
  });
  return out;
}

/// The reason, in a few words, behind a violation code. A clash with a SHIFT is
/// a shift's doing (not "the other events of the calendar").
String _causeOf(
  String code,
  ProposalItem item,
  List<Occurrence> existing,
  PlanRules rules,
) => switch (code) {
  'shift_rest' || 'shift_sleep' => 'shift',
  'sleep_window' => 'sleep',
  'conflict' =>
    _touchesShift(item, existing, rules.bufferMinutes) ? 'shift' : 'busy',
  'self_conflict' || 'bad_range' => 'busy',
  'rest' => 'rest',
  'weekly_cap' => 'cap',
  'low_energy' || 'no_data_hard' => 'energy',
  'weather' => 'weather',
  _ => 'other',
};

/// Whether [item], with the buffer on both sides, overlaps a shift.
bool _touchesShift(ProposalItem item, List<Occurrence> existing, int buffer) {
  final gap = Duration(minutes: buffer);
  return existing.any(
    (x) =>
        x.isShift &&
        !x.allDay &&
        item.startUtc.isBefore(x.endUtc.add(gap)) &&
        x.startUtc.isBefore(item.endUtc.add(gap)),
  );
}

/// Says why fewer sessions fit than the wish asked for: the two things that
/// stood in the way most often, and, when the shifts are the main one, how many
/// fit in all.
List<String> _why(
  int unplaced,
  int total,
  int perWeek,
  int span,
  Map<String, int> tally,
  PlanRules rules,
) {
  const words = {
    'shift': 'a műszakok (az éjszakás műszak utáni alvás, és a műszak előtt és után legalább {sh} óra távolság)',
    'sleep': 'az alvási sáv',
    'busy': 'a naptár többi eseménye',
    'rest': 'a két nehéz edzés közötti {rest} óra pihenő',
    'cap': 'a heti legfeljebb {cap} edzés',
    'energy': 'az energiaszint (nehéz edzéshez legalább {en}/5 kell)',
    'weather': 'az időjárás (szabadtéri sportnál)',
    'season': 'az évszak (szabadtéri sportnál)',
    'day': 'a napi legfeljebb egy edzés',
    'other': 'a szabályok',
  };
  String word(String cause) => words[cause]!
      .replaceAll('{sh}', '${rules.shiftBufferHours}')
      .replaceAll('{rest}', '${rules.minHoursBetweenHard}')
      .replaceAll('{cap}', '${rules.maxWorkoutsPerWeek}')
      .replaceAll('{en}', '${rules.minEnergyForHard}');
  final ranked = tally.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final out = <String>[];
  if (ranked.isNotEmpty && ranked.first.key == 'shift') {
    out.add(
      'A műszak miatt ebben az időszakban (a következő $span nap) $total edzés fér be, a cél $perWeek lett volna. Műszakos ciklusban kevés szabad ablak marad.',
    );
  } else {
    out.add(
      'A szabályok miatt ebben az időszakban (a következő $span nap) $total edzés fér be, a cél $perWeek lett volna.',
    );
  }
  if (ranked.isNotEmpty) {
    final top = [for (final e in ranked.take(2)) word(e.key)];
    out.add('Ami a legtöbbször útban volt: ${top.join(', továbbá ')}.');
  }
  return out;
}
