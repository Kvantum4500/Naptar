import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'ai_providers.dart';

/// How long after the end of a workout the app still asks how it went.
const workoutAskWindow = Duration(hours: 36);

/// The clock of the questions after a workout (tests replace it).
final workoutClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The feedback on workouts, the newest day first.
final workoutLogsProvider = StreamProvider<List<WorkoutLogView>>(
  (ref) => ref.watch(recordRepoProvider).watch(kindWorkoutLog).map((recs) {
    final list = [for (final r in recs) WorkoutLogView(r)]
        .where((l) => !l.deleted && l.date != null)
        .toList();
    list.sort((a, b) => b.date!.compareTo(a.date!));
    return list;
  }),
);

/// Bumped when the app comes back to the front and every few minutes while it
/// is open: a workout may have ended meanwhile (nothing else tells the app).
class WorkoutRefresh extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final workoutRefreshProvider = NotifierProvider<WorkoutRefresh, int>(
  WorkoutRefresh.new,
);

/// Workouts the user said "later" to: they stay hidden until the app is
/// started again (and for good after [workoutAskWindow]).
class SnoozedWorkouts extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void add(String id) => state = {...state, id};
}

final snoozedWorkoutsProvider = NotifierProvider<SnoozedWorkouts, Set<String>>(
  SnoozedWorkouts.new,
);

/// A workout that has just ended and has no feedback yet.
class PendingWorkout {
  const PendingWorkout(this.occurrence);
  final Occurrence occurrence;

  String get id => workoutLogId(occurrence.eventId, occurrence.originalStart);
  String get title => occurrence.title;
  String get sport => sportKey(occurrence.title);
  int get minutes => occurrence.endUtc
      .difference(occurrence.startUtc)
      .inMinutes
      .clamp(1, 1440);

  /// The day the workout started (floating date).
  DateTime get day => DateTime.utc(
    occurrence.originalStart.year,
    occurrence.originalStart.month,
    occurrence.originalStart.day,
  );
}

/// The workout to ask about: the latest one that ended in the last
/// [workoutAskWindow], is not a shift or an all-day event, is plainly a
/// workout by its name, and has no feedback yet. Null when the question is
/// switched off or there is nothing to ask.
final pendingWorkoutProvider = FutureProvider<PendingWorkout?>((ref) async {
  ref.watch(eventsTickProvider);
  ref.watch(workoutRefreshProvider);
  final logs = await ref.watch(workoutLogsProvider.future);
  final snoozed = ref.watch(snoozedWorkoutsProvider);
  final settings = await ref.watch(aiSettingsProvider.future);
  if (!settings.workoutFeedback) return null;

  final now = ref.read(workoutClockProvider)().toUtc();
  final since = now.subtract(workoutAskWindow);
  final answered = {for (final l in logs) l.id};
  final occ = await ref
      .read(repoProvider)
      .occurrences(since.subtract(const Duration(days: 1)), now);
  PendingWorkout? best;
  for (final o in occ) {
    if (o.allDay ||
        o.isShift ||
        !isWorkoutTitle(o.title) ||
        o.endUtc.isAfter(now) ||
        !o.endUtc.isAfter(since)) {
      continue;
    }
    final p = PendingWorkout(o);
    if (answered.contains(p.id) || snoozed.contains(p.id)) continue;
    if (best == null || o.endUtc.isAfter(best.occurrence.endUtc)) best = p;
  }
  return best;
});

// ----------------------------------------------------------------- learning

const _declinedKey = 'wl.declined';

/// The sessions a "no" to a loosening rested on, per sport (this device only).
Future<Map<String, int>> readDeclinedLight(
  Future<String?> Function(String) read,
) async {
  try {
    final raw = jsonDecode(await read(_declinedKey) ?? '{}');
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  } on FormatException {
    return {};
  }
}

/// Bumped when the user answered a loosening (the suggestion list is re-read).
class LearningRefresh extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final learningRefreshProvider = NotifierProvider<LearningRefresh, int>(
  LearningRefresh.new,
);

/// The handbook changed (an agreed "easy" rule was added or taken away).
final _handbookTickProvider = StreamProvider<int>(
  (ref) => ref
      .watch(recordRepoProvider)
      .watch(kindHandbook)
      .map((r) => Object.hashAll(r.map((x) => '${x.id}:${x.updatedAt}'))),
);

/// What the feedback has taught so far, and what is still to be asked.
final workoutLearningProvider = FutureProvider<WorkoutLearning>((ref) async {
  ref.watch(learningRefreshProvider);
  ref.watch(_handbookTickProvider);
  final logs = await ref.watch(workoutLogsProvider.future);
  final settings = await ref.watch(aiSettingsProvider.future);
  if (!settings.workoutFeedback) return const WorkoutLearning();
  final repo = ref.read(recordRepoProvider);
  final now = ref.read(workoutClockProvider)();
  return learnFromWorkouts(
    logs,
    today: DateTime.utc(now.year, now.month, now.day),
    approvedLight: await ref.read(handbookStoreProvider).lightSports(),
    declinedAt: await readDeclinedLight(repo.meta),
  );
});

/// The answers to the two questions of the feedback: saved, remembered.
class WorkoutFeedbackActions {
  WorkoutFeedbackActions(this._ref);
  final Ref _ref;

  /// Saves the answers (only the given ones are written).
  Future<void> save(
    PendingWorkout w, {
    bool done = true,
    int? bodyLoad,
    int? mindLoad,
    int? energyStart,
    int? energyEnd,
    int? experience,
    String note = '',
  }) async {
    final fields = workoutLogFields(
      title: w.title,
      date: w.day,
      minutes: w.minutes,
      sport: w.sport,
      done: done,
      bodyLoad: bodyLoad,
      mindLoad: mindLoad,
      energyStart: energyStart,
      energyEnd: energyEnd,
      experience: experience,
      note: note,
    );
    await _ref.read(recordRepoProvider).edit(kindWorkoutLog, w.id, fields);
  }

  /// "Később": hidden until the app is started again.
  void later(PendingWorkout w) =>
      _ref.read(snoozedWorkoutsProvider.notifier).add(w.id);

  /// "Igen": the sport is easy for the user; the line goes to "Tanult
  /// szokások" (visible and deletable there).
  Future<void> agreeLight(RelaxSuggestion s) async {
    await _ref.read(handbookStoreProvider).agreeLight(s.sport);
    _ref.read(learningRefreshProvider.notifier).bump();
  }

  /// "Nem": remembered on this device; asked again after more sessions.
  Future<void> declineLight(RelaxSuggestion s) async {
    final repo = _ref.read(recordRepoProvider);
    final now = await readDeclinedLight(repo.meta);
    now[s.sport] = s.bandSamples;
    await repo.setMeta(_declinedKey, jsonEncode(now));
    _ref.read(learningRefreshProvider.notifier).bump();
  }
}

final workoutFeedbackActionsProvider = Provider<WorkoutFeedbackActions>(
  WorkoutFeedbackActions.new,
);
