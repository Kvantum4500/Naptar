part of '../assistant_service.dart';

/// How many days ahead the local plan looks (from tomorrow).
const localPlanDays = 7;

// The workout plan the program makes by itself, with no model and no key:
// reads what the planner needs from the device and hands it to the plain
// planner of the core ([planWorkoutsLocally]). Part of the library of
// AssistantService (it works with the service's learned rules, its workout log
// and its forecast).
extension _LocalPlanning on AssistantService {
  Future<AssistantOutcome> _planLocally(
    LocalPlanPrefs prefs,
    AiSettings settings,
  ) async {
    // the limits the user's own workouts have taught, and the workout log
    await _learn();
    final first = _today.add(const Duration(days: 1));
    // The rules look at the weeks around the window (the cap, the 48 hours,
    // the distance from the shifts), the rotation of the sports at the weeks
    // before it.
    final existing = await events.occurrences(
      resolveWallClock(_tz, first.subtract(const Duration(days: 28))),
      resolveWallClock(
        _tz,
        first.add(const Duration(days: localPlanDays + 10)),
      ),
    );
    // (the forecast is public data; it is only used when it is switched on)
    _forecastFuture = null;
    final forecast = await _forecastFor(settings);
    final plan = planWorkoutsLocally(
      from: first,
      days: localPlanDays,
      prefs: prefs,
      rules: _rules,
      existing: existing,
      log: _workoutLogs,
      energyByDate: await _energyByDate(),
      weatherByDate: {for (final w in forecast ?? <DayWeather>[]) w.day: w},
      nowUtc: _nowUtc,
    );
    return AssistantOutcome(
      summary: plan.summary,
      items: plan.items,
      dropped: plan.dropped,
      calls: 0,
      localAnswer: const LocalAnswer(
        LocalKind.plan,
        'A program a naptáradból, a szabályokból és a megadott sportjaidból tervezett, modell és kulcs nélkül. Semmi nem hagyta el az eszközt.',
      ),
    );
  }
}
