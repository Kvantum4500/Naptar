/// What counts as a workout and which workouts are hard: decided in code from
/// the title and the length, not from the model's word alone (a model that
/// calls every session "light" would switch the energy, shift and rest rules
/// off).
library;

/// A title that says the session is light, whatever its length.
final _lightTitle = RegExp(
  r'könnyű|könnyed|nyújt|mobilit|relax|regener|lazít|stretch|séta',
);

/// A title that is plainly a workout (also for events the user typed in).
final _workoutTitle = RegExp(
  r'edz|gym|calisthenics|street\s*workout|kajak|mászás|kerékpár|bicikl|futás|futni|úszás|crossfit|evez',
);

/// Words that make a session hard even when it is short.
final _hardTitle = RegExp(r'nehéz|intenzív|hiit|intervall|maximális|verseny');

/// "Könnyű edzés", "Nyújtás", "Mobilitás", "Séta" …: light by name.
bool isLightTitle(String title) => _lightTitle.hasMatch(title.toLowerCase());

/// Whether the name alone says this is a workout (Gym, Calisthenics, Street
/// Workout, kajak, mászás, kerékpár, futás, úszás, "edzés" …).
bool isWorkoutTitle(String title) =>
    _workoutTitle.hasMatch(title.toLowerCase());

/// Whether a workout is a hard one. A light title ("könnyű", "nyújtás",
/// "mobilitás" …) is never hard. Otherwise it is hard when the model says so,
/// when it lasts [fromMinutes] or more, or when its title says so.
bool isHardWorkout({
  required String title,
  required Duration length,
  bool modelSaysHard = false,
  int fromMinutes = 60,
}) {
  if (isLightTitle(title)) return false;
  return modelSaysHard ||
      length.inMinutes >= fromMinutes ||
      _hardTitle.hasMatch(title.toLowerCase());
}
