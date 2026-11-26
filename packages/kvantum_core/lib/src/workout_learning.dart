/// What the program learns from the feedback after workouts: from how many
/// minutes a kind of workout is a hard one FOR THE USER.
///
/// - **Tighter, by itself:** a kind of 45–59 minutes whose latest
///   [tightenMinSamples] sessions felt hard (on average [tightenAverage] or more
///   of 5) counts as hard from [tightenFrom] minutes. Caution needs no
///   permission.
/// - **Looser, only with a yes:** a kind of 60–89 minutes whose latest
///   [relaxMinSamples] sessions felt easy (on average [relaxAverage] or less) is
///   only *suggested* as easy. The user's "yes" is written to "Tanult szokások" as a
///   marked line ([lightRuleText]); only then does it count as hard from
///   [relaxTo] minutes instead of 60. Deleting the line takes it back.
/// - New feedback that shows the opposite (the latest [tightenMinSamples]
///   sessions of 60–89 minutes felt hard) takes a loosening back at once.
library;

import 'models.dart';
import 'text_safety.dart';
import 'workout.dart';

/// A 45–59 minute kind needs this many recent sessions to be tightened …
const tightenMinSamples = 3;

/// … with this average perceived difficulty or more (1 easy … 5 very hard) …
const tightenAverage = 4.0;

/// … and is then hard from this many minutes.
const tightenFrom = 45;

/// A 60–89 minute kind needs this many recent sessions to be suggested as easy …
const relaxMinSamples = 5;

/// … with this average difficulty or less …
const relaxAverage = 2.0;

/// … and, once the user agreed, is hard from this many minutes.
const relaxTo = 90;

/// After a "no" the suggestion comes back only with this many new sessions.
const relaxAskAgainAfter = 5;

/// Only the feedback of this many days counts …
const learnWindowDays = 120;

/// … and of each kind only the latest this many sessions.
const learnMaxPerSport = 12;

/// The marker of a learned "this is easy for me" rule: `[könnyű: gym] …`.
final _lightRule = RegExp(r'^\[könnyű:\s*([a-z_]+)\]');

/// The line "Tanult szokások" gets when the user agrees that [sport] is easy
/// up to [relaxTo] minutes.
String lightRuleText(String sport, {int base = 60}) =>
    '[könnyű: $sport] A(z) ${sportLabel(sport)} $base–${relaxTo - 1} perc számomra könnyű (a visszajelzéseim szerint), ezt ne vedd nehéz edzésnek.';

/// The sports whose "easy" rule the user has agreed to, from the lines of
/// "Tanult szokások".
Set<String> lightSportsFrom(Iterable<String> learnedRules) => {
  for (final r in learnedRules)
    if (_lightRule.firstMatch(r.trim()) case final m?)
      if (isSportKey(m[1]!)) m[1]!,
};

/// A suggestion to treat a kind of workout as easy, to be answered yes or no.
class RelaxSuggestion {
  const RelaxSuggestion({
    required this.sport,
    required this.samples,
    required this.average,
    required this.bandSamples,
  });
  final String sport;

  /// How many of the latest sessions of 60–89 minutes it rests on.
  final int samples;
  final double average;

  /// How many sessions of 60–89 minutes there are in all (a "no" remembers
  /// this: the question comes back after [relaxAskAgainAfter] more).
  final int bandSamples;

  /// The sentence the user is asked.
  String get question =>
      'Megtanultam: a ${sportLabel(sport)} (60–${relaxTo - 1} perc) számodra könnyű: az utolsó $samples alkalom átlagosan ${average.toStringAsFixed(1)}/5 nehézségű volt. Annak vegyem?';
}

/// The limits that follow from the feedback, and what is still to be asked.
class WorkoutLearning {
  const WorkoutLearning({
    this.tightened = const {},
    this.relaxed = const {},
    this.suggestions = const [],
  });

  /// Sports that count as hard from [tightenFrom] minutes.
  final Map<String, int> tightened;

  /// Sports the user agreed to treat as easy: hard from [relaxTo] minutes.
  final Map<String, int> relaxed;

  /// Loosenings the user has not answered yet.
  final List<RelaxSuggestion> suggestions;

  /// For [PlanRules.hardFromBySport] (tightening wins over loosening).
  Map<String, int> get hardFromBySport => {...relaxed, ...tightened};

  bool get isEmpty => tightened.isEmpty && relaxed.isEmpty;
}

double _avg(Iterable<int> v) =>
    v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

/// The average of the latest [n] values of a newest-first list, null when
/// there are fewer than [n] of them.
double? _latestAvg(List<int> newestFirst, int n) =>
    newestFirst.length < n ? null : _avg(newestFirst.take(n));

/// The latest sessions of each sport that count for learning: done, rated,
/// with a length, within [learnWindowDays] of [today].
Map<String, List<WorkoutLogView>> _recent(
  Iterable<WorkoutLogView> logs,
  DateTime today,
) {
  final from = today.subtract(const Duration(days: learnWindowDays));
  final by = <String, List<WorkoutLogView>>{};
  for (final l in logs) {
    final d = l.date;
    if (l.deleted ||
        !l.done ||
        l.bodyLoad == null ||
        l.minutes == null ||
        d == null ||
        d.isBefore(from) ||
        d.isAfter(today.add(const Duration(days: 1))) ||
        !isSportKey(l.sport)) {
      continue;
    }
    (by[l.sport] ??= []).add(l);
  }
  for (final list in by.values) {
    list.sort((a, b) {
      final c = b.date!.compareTo(a.date!);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
    if (list.length > learnMaxPerSport) {
      list.removeRange(learnMaxPerSport, list.length);
    }
  }
  return by;
}

/// What the feedback teaches. [approvedLight] are the sports the user agreed
/// are easy (see [lightSportsFrom]); [declinedAt] maps a sport to the number of
/// sessions it rested on when the user said no (this device remembers it).
WorkoutLearning learnFromWorkouts(
  Iterable<WorkoutLogView> logs, {
  required DateTime today,
  Set<String> approvedLight = const {},
  Map<String, int> declinedAt = const {},
  int base = 60,
}) {
  final tightened = <String, int>{};
  final relaxed = <String, int>{};
  final suggestions = <RelaxSuggestion>[];
  final sports = _recent(logs, today).entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final MapEntry(key: sport, value: list) in sports) {
    List<int> load(int from, int to) => [
      for (final l in list)
        if (l.minutes! >= from && l.minutes! < to) l.bodyLoad!,
    ];
    // short of the line but hard: hard from 45 minutes
    final mid = _latestAvg(load(tightenFrom, base), tightenMinSamples);
    if (mid != null && mid >= tightenAverage) {
      tightened[sport] = tightenFrom;
      continue;
    }
    final long = load(base, relaxTo);
    if (approvedLight.contains(sport)) {
      // an agreed loosening is taken back when the new sessions say otherwise
      final latest = _latestAvg(long, tightenMinSamples);
      final hardAgain = latest != null && latest >= tightenAverage;
      if (!hardAgain) relaxed[sport] = relaxTo;
      continue;
    }
    final easy = _latestAvg(long, relaxMinSamples);
    if (easy != null && easy <= relaxAverage) {
      final before = declinedAt[sport];
      // (long.length is every session of the band, not only the latest few)
      if (before != null && long.length < before + relaxAskAgainAfter) {
        continue;
      }
      suggestions.add(
        RelaxSuggestion(
          sport: sport,
          samples: relaxMinSamples,
          average: easy,
          bandSamples: long.length,
        ),
      );
    }
  }
  return WorkoutLearning(
    tightened: tightened,
    relaxed: relaxed,
    suggestions: suggestions,
  );
}

// ------------------------------------------------------------- for the model

String _md(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One short line per recent workout feedback, newest first:
/// `05-02 gym 60p nf4 nm2 e3/2 k4` (day, kind, minutes, difficulty of body and
/// mind, energy at the start / at the end, how it was) or `05-01 gym 60p
/// kihagyta`. (No `>`: the text cleaning removes it.) The note and the title never go: the kind is the generic name.
List<String> workoutLogLines(
  Iterable<WorkoutLogView> logs, {
  required DateTime today,
  int max = 10,
  int days = 60,
}) {
  final from = today.subtract(Duration(days: days));
  final list =
      [
        for (final l in logs)
          if (!l.deleted &&
              l.date != null &&
              l.minutes != null &&
              !l.date!.isBefore(from) &&
              !l.date!.isAfter(today.add(const Duration(days: 1))) &&
              (!l.done || l.answered))
            l,
      ]..sort((a, b) {
        final c = b.date!.compareTo(a.date!);
        return c != 0 ? c : b.id.compareTo(a.id);
      });
  String sportOf(WorkoutLogView l) => isSportKey(l.sport) ? l.sport : 'edzes';
  return [
    for (final l in list.take(max))
      [
        _md(l.date!),
        sportOf(l),
        '${l.minutes}p',
        if (!l.done)
          'kihagyta'
        else ...[
          if (l.bodyLoad != null) 'nf${l.bodyLoad}',
          if (l.mindLoad != null) 'nm${l.mindLoad}',
          if (l.energyStart != null || l.energyEnd != null)
            'e${l.energyStart ?? '?'}/${l.energyEnd ?? '?'}',
          if (l.experience != null) 'k${l.experience}',
        ],
      ].join(' '),
  ].map((s) => sanitizeText(s, max: 60)).toList();
}
