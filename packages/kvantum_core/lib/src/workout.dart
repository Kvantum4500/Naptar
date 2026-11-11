/// What counts as a workout and which workouts are hard: decided in code from
/// the title and the length, not from the model's word alone (a model that
/// calls every session "light" would switch the energy, shift and rest rules
/// off). The titles are read without accents, so "Futas" is "Futás".
library;

import 'text_safety.dart';

/// A title that says the session is light, whatever its length.
final _lightTitle = RegExp(
  r'konnyu|konnyed|nyujt|mobilit|relax|regener|lazit|stretch|seta',
);

/// A title that is plainly a workout (also for events the user typed in).
final _workoutTitle = RegExp(
  r'edz|gym|calisthenics|street\s*workout|kajak|maszas|kerekpar|bicikl|futas|futni|uszas|crossfit|evez',
);

/// Words that make a session hard even when it is short.
final _hardTitle = RegExp(r'nehez|intenziv|hiit|intervall|maximalis|verseny');

/// "Könnyű edzés", "Nyújtás", "Mobilitás", "Séta" …: light by name.
bool isLightTitle(String title) => _lightTitle.hasMatch(foldHu(title));

/// Whether the name alone says this is a workout (Gym, Calisthenics, Street
/// Workout, kajak, mászás, kerékpár, futás, úszás, "edzés" …).
bool isWorkoutTitle(String title) => _workoutTitle.hasMatch(foldHu(title));

/// Whether the title says the session is hard ("nehéz", "intenzív", "HIIT" …).
bool isHardTitle(String title) => _hardTitle.hasMatch(foldHu(title));

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
  return modelSaysHard || length.inMinutes >= fromMinutes || isHardTitle(title);
}

// ---------------------------------------------------------------- sports

/// The kinds of workout the program tells apart, in the order they are tried
/// (the first that matches wins). The key is plain ASCII: it goes into the
/// workout log, the request to the model and the learned rules.
final _sports = <(String, RegExp)>[
  ('street_workout', RegExp(r'street\s*workout')),
  ('calisthenics', RegExp(r'calisthenics')),
  ('gym', RegExp(r'\bgym\b|edzoterem|konditerem|sulyzo')),
  ('crossfit', RegExp(r'crossfit')),
  ('kajak', RegExp(r'kajak|evez')),
  ('maszas', RegExp(r'maszas')),
  ('kerekpar', RegExp(r'kerekpar|bicikl')),
  ('futas', RegExp(r'futas|futni|futo\b')),
  ('uszas', RegExp(r'uszas|uszni')),
];

const _sportLabels = {
  'street_workout': 'Street Workout',
  'calisthenics': 'Calisthenics',
  'gym': 'Gym',
  'crossfit': 'CrossFit',
  'kajak': 'Kajak',
  'maszas': 'Mászás',
  'kerekpar': 'Kerékpár',
  'futas': 'Futás',
  'uszas': 'Úszás',
  'edzes': 'Edzés',
};

/// The kind of workout a title names ("gym", "calisthenics" …), "edzes" for
/// any other workout, and '' when the title is no workout at all.
String sportKey(String title) {
  final t = foldHu(title);
  for (final (key, re) in _sports) {
    if (re.hasMatch(t)) return key;
  }
  return isWorkoutTitle(title) ? 'edzes' : '';
}

/// Whether [key] is one of the keys [sportKey] gives.
bool isSportKey(String key) => _sportLabels.containsKey(key);

/// The name of a sport for the screen ("Calisthenics", "Kerékpár").
String sportLabel(String key) => _sportLabels[key] ?? key;
