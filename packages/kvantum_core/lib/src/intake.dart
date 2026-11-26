import 'dart:convert';

import 'models.dart';
import 'sync_record.dart';
import 'text_safety.dart';

// The food and fluid log: what was eaten (with calories and, if the user wants,
// protein / carbohydrate / fat) and what was drunk, a day at a time.
//
// Where it lives: ONE synced record per MONTH ([kindIntake], id "2026-11"), and
// every entry is a field of it: "f.<id>" for a food, "w.<id>" for a drink; the
// value is the entry as a compact JSON text, and null means "removed". The
// record is merged field by field (last writer wins per field), so two devices
// that each add something to the same day both keep what they added - which a
// list inside one field could not promise - and the Drive holds twelve files a
// year, not thousands.
//
// A day is a floating date (a UTC midnight) and a time is minutes since
// midnight on the wall clock of the display zone: the log says "08:15", never
// an instant, so it reads the same wherever the device is.
//
// Everything here is pure: the app hands over the records it has and shows what
// comes back.

/// The prefix of a food's field in the month record.
const foodFieldPrefix = 'f.';

/// The prefix of a drink's field in the month record.
const fluidFieldPrefix = 'w.';

/// The largest values taken (a slip of a finger must not make a million).
const maxFoodKcal = 5000;
const maxMacroGrams = 500;
const maxFoodName = 60;
const minFluidMl = 10;
const maxFluidMl = 3000;

/// How many days a suggestion looks back by default.
const suggestionWindowDays = 180;

/// What a gram of each macro nutrient counts for when only the macros are
/// entered (4 kcal per gram of protein or carbohydrate, 9 per gram of fat).
int kcalFromMacros({int? protein, int? carbs, int? fat}) =>
    4 * (protein ?? 0) + 4 * (carbs ?? 0) + 9 * (fat ?? 0);

/// The id of the record that holds [day]: "2026-11".
String intakeMonthId(DateTime day) => isoDay(day).substring(0, 7);

/// The field of food [id] in its month record.
String foodFieldKey(String id) => '$foodFieldPrefix$id';

/// The field of drink [id] in its month record.
String fluidFieldKey(String id) => '$fluidFieldPrefix$id';

final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

/// "08:05" for 485 (minutes since midnight).
String minuteText(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';

int? _parseMinute(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(v);
  return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
}

/// A floating date in "2026-11-16" form; null when it is not a real date
/// ("2026-02-30" is none).
DateTime? _parseDay(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
  if (m == null) return null;
  final y = int.parse(m[1]!);
  final mo = int.parse(m[2]!);
  final d = int.parse(m[3]!);
  final day = DateTime.utc(y, mo, d);
  return day.year == y && day.month == mo && day.day == d ? day : null;
}

int? _intIn(Object? v, int lo, int hi) {
  // (an infinite number, "1e999" in a file, has no integer: toInt() would throw)
  final n = v is num && v.isFinite ? v.toInt() : null;
  return (n == null || n < lo || n > hi) ? null : n;
}

String _cut(Object? v, int max) {
  final t = '${v ?? ''}'.trim();
  return t.length > max ? t.substring(0, max).trimRight() : t;
}

Map<String, dynamic>? _object(Object? value) {
  if (value is! String) return null;
  try {
    final j = jsonDecode(value);
    return j is Map<String, dynamic> ? j : null;
  } on FormatException {
    return null;
  }
}

/// A day's meals. Breakfast, lunch, dinner and the snacks between.
enum Meal {
  breakfast('b', 'Reggeli'),
  lunch('l', 'Ebéd'),
  dinner('d', 'Vacsora'),
  snack('s', 'Nasi');

  const Meal(this.key, this.label);

  /// What the record stores.
  final String key;
  final String label;

  static Meal? fromKey(Object? key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return null;
  }

  /// The meal that fits a time of day ([minute] since midnight): the default
  /// the form starts with, which the user can always change.
  static Meal forMinute(int minute) {
    if (minute < 10 * 60 + 30) return breakfast;
    if (minute < 15 * 60) return lunch;
    if (minute < 17 * 60) return snack;
    if (minute < 21 * 60) return dinner;
    return snack;
  }
}

/// What was drunk. Water is the default; the others only tell the log apart.
enum DrinkKind {
  water('water', 'Víz'),
  coffee('coffee', 'Kávé'),
  tea('tea', 'Tea'),
  soda('soda', 'Üdítő'),
  milk('milk', 'Tej'),
  other('other', 'Egyéb');

  const DrinkKind(this.key, this.label);
  final String key;
  final String label;

  static DrinkKind? fromKey(Object? key) {
    for (final k in values) {
      if (k.key == key) return k;
    }
    return null;
  }
}

/// One thing eaten.
class FoodEntry {
  const FoodEntry._({
    required this.id,
    required this.day,
    required this.minute,
    required this.meal,
    required this.name,
    required this.kcal,
    this.protein,
    this.carbs,
    this.fat,
  });

  /// A food entry made from what the user typed, every value checked: throws
  /// an [ArgumentError] with a sentence to show when something is out of range.
  /// The calories may be left out when at least one macro is given: they are
  /// then worked out from the macros ([kcalFromMacros]).
  factory FoodEntry.checked({
    required String id,
    required DateTime day,
    required int minute,
    required Meal meal,
    String name = '',
    int? kcal,
    int? protein,
    int? carbs,
    int? fat,
  }) {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError('Az azonosító nem megfelelő.');
    }
    if (minute < 0 || minute > 24 * 60 - 1) {
      throw ArgumentError('Az időpont 00:00 és 23:59 között lehet.');
    }
    for (final g in [protein, carbs, fat]) {
      if (g != null && (g < 0 || g > maxMacroGrams)) {
        throw ArgumentError(
          'A makrók 0 és $maxMacroGrams gramm között lehetnek.',
        );
      }
    }
    final hasMacros = protein != null || carbs != null || fat != null;
    if (kcal == null && !hasMacros) {
      throw ArgumentError('Add meg a kalóriát vagy legalább egy makrót.');
    }
    final total =
        kcal ?? kcalFromMacros(protein: protein, carbs: carbs, fat: fat);
    if (total < 0 || total > maxFoodKcal) {
      throw ArgumentError('A kalória 0 és $maxFoodKcal között lehet.');
    }
    return FoodEntry._(
      id: id,
      day: DateTime.utc(day.year, day.month, day.day),
      minute: minute,
      meal: meal,
      name: _cut(name, maxFoodName),
      kcal: total,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );
  }

  final String id;

  /// The day (a floating date: a UTC midnight).
  final DateTime day;

  /// The time of day, minutes since midnight.
  final int minute;
  final Meal meal;

  /// What it was; may be empty (then the list shows the meal's name).
  final String name;
  final int kcal;

  /// Grams, or null where the user did not say.
  final int? protein;
  final int? carbs;
  final int? fat;

  bool get hasMacros => protein != null || carbs != null || fat != null;
  String get timeText => minuteText(minute);

  /// What a list shows as the title.
  String get title => name.isEmpty ? meal.label : name;

  /// The compact JSON text that is the value of the record field.
  String encode() => jsonEncode({
    'day': isoDay(day),
    'time': minuteText(minute),
    'meal': meal.key,
    if (name.isNotEmpty) 'name': name,
    'kcal': kcal,
    'protein': ?protein,
    'carbs': ?carbs,
    'fat': ?fat,
  });

  /// The change that writes this entry into its month record.
  Map<String, Object?> get fields => {foodFieldKey(id): encode()};

  /// The change that removes food [id] from its month record.
  static Map<String, Object?> removal(String id) => {foodFieldKey(id): null};

  /// Reads a field value; null when it is not a usable entry (a corrupt file
  /// must never crash the log: that entry is simply not shown). A macro that is
  /// out of range is dropped, the entry stays; without a day, a time or the
  /// calories it cannot.
  static FoodEntry? decode(String id, Object? value) {
    final j = _object(value);
    if (j == null || !_safeId.hasMatch(id)) return null;
    final day = _parseDay(j['day']);
    final minute = _parseMinute(j['time']);
    final kcal = _intIn(j['kcal'], 0, maxFoodKcal);
    if (day == null || minute == null || kcal == null) return null;
    return FoodEntry._(
      id: id,
      day: day,
      minute: minute,
      meal: Meal.fromKey(j['meal']) ?? Meal.forMinute(minute),
      name: _cut(j['name'], maxFoodName),
      kcal: kcal,
      protein: _intIn(j['protein'], 0, maxMacroGrams),
      carbs: _intIn(j['carbs'], 0, maxMacroGrams),
      fat: _intIn(j['fat'], 0, maxMacroGrams),
    );
  }
}

/// One drink.
class FluidEntry {
  const FluidEntry._({
    required this.id,
    required this.day,
    required this.minute,
    required this.ml,
    required this.kind,
  });

  /// A drink made from what the user typed, checked like [FoodEntry.checked].
  factory FluidEntry.checked({
    required String id,
    required DateTime day,
    required int minute,
    required int ml,
    DrinkKind kind = DrinkKind.water,
  }) {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError('Az azonosító nem megfelelő.');
    }
    if (minute < 0 || minute > 24 * 60 - 1) {
      throw ArgumentError('Az időpont 00:00 és 23:59 között lehet.');
    }
    if (ml < minFluidMl || ml > maxFluidMl) {
      throw ArgumentError(
        'A mennyiség $minFluidMl és $maxFluidMl ml között lehet.',
      );
    }
    return FluidEntry._(
      id: id,
      day: DateTime.utc(day.year, day.month, day.day),
      minute: minute,
      ml: ml,
      kind: kind,
    );
  }

  final String id;
  final DateTime day;
  final int minute;
  final int ml;
  final DrinkKind kind;

  String get timeText => minuteText(minute);

  String encode() => jsonEncode({
    'day': isoDay(day),
    'time': minuteText(minute),
    'ml': ml,
    'kind': kind.key,
  });

  Map<String, Object?> get fields => {fluidFieldKey(id): encode()};

  static Map<String, Object?> removal(String id) => {fluidFieldKey(id): null};

  /// Reads a field value; null when it is not a usable drink. An unknown kind
  /// reads as "other" (a newer version may know more kinds).
  static FluidEntry? decode(String id, Object? value) {
    final j = _object(value);
    if (j == null || !_safeId.hasMatch(id)) return null;
    final day = _parseDay(j['day']);
    final minute = _parseMinute(j['time']);
    final ml = _intIn(j['ml'], minFluidMl, maxFluidMl);
    if (day == null || minute == null || ml == null) return null;
    return FluidEntry._(
      id: id,
      day: day,
      minute: minute,
      ml: ml,
      kind: DrinkKind.fromKey(j['kind']) ?? DrinkKind.other,
    );
  }
}

/// What one day came to.
class DayTotals {
  const DayTotals({
    required this.day,
    this.kcal = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    this.foodCount = 0,
    this.withMacros = 0,
    this.ml = 0,
    this.fluidCount = 0,
    this.kcalByMeal = const {},
  });

  final DateTime day;
  final int kcal;

  /// The sums of the grams that were entered: an entry without macros adds
  /// nothing here, so they are a floor, not the whole day (see [withMacros]).
  final int protein;
  final int carbs;
  final int fat;
  final int foodCount;

  /// How many of the [foodCount] entries have at least one macro.
  final int withMacros;
  final int ml;
  final int fluidCount;
  final Map<Meal, int> kcalByMeal;

  bool get hasFood => foodCount > 0;
  bool get hasFluid => fluidCount > 0;
  bool get hasData => hasFood || hasFluid;

  /// How many entries have no macros at all.
  int get withoutMacros => foodCount - withMacros;
}

/// Everything in the log: all the foods and drinks of all the month records.
class IntakeLog {
  IntakeLog._(this.foods, this.fluids)
    : _foodDays = _index(foods, (e) => isoDay(e.day)),
      _fluidDays = _index(fluids, (e) => isoDay(e.day));

  /// The log of the month [records] (other kinds are passed over). An entry is
  /// found by its id: the same id in two months (a day moved from one month to
  /// the next while the other device edited it) counts once, the newer write
  /// wins; a removed or unreadable entry is not there.
  factory IntakeLog.from(Iterable<SyncRecord> records) {
    final foods = <String, (FieldValue, FoodEntry)>{};
    final fluids = <String, (FieldValue, FluidEntry)>{};
    for (final r in records) {
      if (r.kind != kindIntake) continue;
      for (final e in r.fields.entries) {
        final key = e.key;
        if (key.startsWith(foodFieldPrefix)) {
          final id = key.substring(foodFieldPrefix.length);
          final entry = FoodEntry.decode(id, e.value.value);
          final old = foods[id];
          if (entry != null && (old == null || e.value.beats(old.$1))) {
            foods[id] = (e.value, entry);
          }
        } else if (key.startsWith(fluidFieldPrefix)) {
          final id = key.substring(fluidFieldPrefix.length);
          final entry = FluidEntry.decode(id, e.value.value);
          final old = fluids[id];
          if (entry != null && (old == null || e.value.beats(old.$1))) {
            fluids[id] = (e.value, entry);
          }
        }
      }
    }
    final foodList = [for (final v in foods.values) v.$2]
      ..sort((a, b) => _order(a.day, a.minute, a.id, b.day, b.minute, b.id));
    final fluidList = [for (final v in fluids.values) v.$2]
      ..sort((a, b) => _order(a.day, a.minute, a.id, b.day, b.minute, b.id));
    return IntakeLog._(
      List.unmodifiable(foodList),
      List.unmodifiable(fluidList),
    );
  }

  /// A log with nothing in it.
  static final IntakeLog empty = IntakeLog._(const [], const []);

  /// Oldest first (day, time, id).
  final List<FoodEntry> foods;
  final List<FluidEntry> fluids;

  final Map<String, List<FoodEntry>> _foodDays;
  final Map<String, List<FluidEntry>> _fluidDays;

  /// The foods of [day], in time order.
  List<FoodEntry> foodsOn(DateTime day) => _foodDays[isoDay(day)] ?? const [];

  /// The drinks of [day], in time order.
  List<FluidEntry> fluidsOn(DateTime day) =>
      _fluidDays[isoDay(day)] ?? const [];

  FoodEntry? foodById(String id) {
    for (final f in foods) {
      if (f.id == id) return f;
    }
    return null;
  }

  FluidEntry? fluidById(String id) {
    for (final f in fluids) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// What [day] came to.
  DayTotals totalsOn(DateTime day) {
    final day0 = DateTime.utc(day.year, day.month, day.day);
    var kcal = 0, protein = 0, carbs = 0, fat = 0, withMacros = 0, ml = 0;
    final byMeal = <Meal, int>{};
    final foodsOfDay = foodsOn(day0);
    for (final f in foodsOfDay) {
      kcal += f.kcal;
      protein += f.protein ?? 0;
      carbs += f.carbs ?? 0;
      fat += f.fat ?? 0;
      if (f.hasMacros) withMacros++;
      byMeal[f.meal] = (byMeal[f.meal] ?? 0) + f.kcal;
    }
    final fluidsOfDay = fluidsOn(day0);
    for (final w in fluidsOfDay) {
      ml += w.ml;
    }
    return DayTotals(
      day: day0,
      kcal: kcal,
      protein: protein,
      carbs: carbs,
      fat: fat,
      foodCount: foodsOfDay.length,
      withMacros: withMacros,
      ml: ml,
      fluidCount: fluidsOfDay.length,
      kcalByMeal: Map.unmodifiable(byMeal),
    );
  }
}

int _order(DateTime ad, int am, String ai, DateTime bd, int bm, String bi) {
  final c = ad.compareTo(bd);
  if (c != 0) return c;
  if (am != bm) return am.compareTo(bm);
  return ai.compareTo(bi);
}

Map<String, List<T>> _index<T>(List<T> sorted, String Function(T) dayOf) {
  final out = <String, List<T>>{};
  for (final e in sorted) {
    (out[dayOf(e)] ??= []).add(e);
  }
  return {for (final e in out.entries) e.key: List.unmodifiable(e.value)};
}

// -------------------------------------------------------------------- goals

/// What the user aims for in a day. Nothing is set until the user sets it: the
/// program names no "healthy" amount, and a goal that is not set shows only the
/// total.
class IntakeGoals {
  const IntakeGoals({this.kcal, this.protein, this.carbs, this.fat, this.ml});

  /// A set of goals made from what the user typed, every value checked (an
  /// [ArgumentError] with a sentence to show); a goal left null is not set.
  factory IntakeGoals.checked({
    int? kcal,
    int? protein,
    int? carbs,
    int? fat,
    int? ml,
  }) {
    if (kcal != null && (kcal < minKcal || kcal > maxKcal)) {
      throw ArgumentError('A kalória-cél $minKcal és $maxKcal között lehet.');
    }
    for (final g in [protein, carbs, fat]) {
      if (g != null && (g < minGrams || g > maxGrams)) {
        throw ArgumentError(
          'A makró-cél $minGrams és $maxGrams g között lehet.',
        );
      }
    }
    if (ml != null && (ml < minMl || ml > maxMl)) {
      throw ArgumentError('A folyadék-cél $minMl és $maxMl ml között lehet.');
    }
    return IntakeGoals(
      kcal: kcal,
      protein: protein,
      carbs: carbs,
      fat: fat,
      ml: ml,
    );
  }

  static const minKcal = 500;
  static const maxKcal = 10000;
  static const minGrams = 1;
  static const maxGrams = 1000;
  static const minMl = 100;
  static const maxMl = 10000;

  final int? kcal;
  final int? protein;
  final int? carbs;
  final int? fat;
  final int? ml;

  bool get isEmpty =>
      kcal == null &&
      protein == null &&
      carbs == null &&
      fat == null &&
      ml == null;

  /// Whether any macro goal is set.
  bool get hasMacroGoal => protein != null || carbs != null || fat != null;

  String encode() => jsonEncode({
    'kcal': ?kcal,
    'protein': ?protein,
    'carbs': ?carbs,
    'fat': ?fat,
    'ml': ?ml,
  });

  /// Reads the stored goals; a value that is not usable is simply not set.
  /// (Where the goals were kept before they were synced: read once, to take
  /// them over.)
  static IntakeGoals decode(String? text) {
    if (text == null) return const IntakeGoals();
    final j = _object(text);
    if (j == null) return const IntakeGoals();
    return IntakeGoals._read((field) => j[field]);
  }

  /// The goals of the synced record `settings/goals` ([kindSettings]); no
  /// record, or a field that is missing, null or out of range, is "not set".
  /// Never throws: the record may come from another device.
  static IntakeGoals fromRecord(SyncRecord? record) => record == null
      ? const IntakeGoals()
      : IntakeGoals._read((field) => record[field]);

  static IntakeGoals _read(Object? Function(String field) value) => IntakeGoals(
    kcal: _intIn(value('kcal'), minKcal, maxKcal),
    protein: _intIn(value('protein'), minGrams, maxGrams),
    carbs: _intIn(value('carbs'), minGrams, maxGrams),
    fat: _intIn(value('fat'), minGrams, maxGrams),
    ml: _intIn(value('ml'), minMl, maxMl),
  );

  /// What to write into the record, field by field. A goal that is not set is
  /// written as null: that is how a goal is taken away on every device (a field
  /// that is left out would keep its old value).
  Map<String, Object?> toFields() => {
    'kcal': kcal,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
    'ml': ml,
  };

  @override
  bool operator ==(Object other) =>
      other is IntakeGoals &&
      other.kcal == kcal &&
      other.protein == protein &&
      other.carbs == carbs &&
      other.fat == fat &&
      other.ml == ml;

  @override
  int get hashCode => Object.hash(kcal, protein, carbs, fat, ml);
}

/// How far a day is from a goal.
class IntakeProgress {
  const IntakeProgress(this.done, this.goal);
  final int done;
  final int goal;

  /// 0 … and beyond 1 when the goal is passed.
  double get fraction => goal <= 0 ? 0 : done / goal;

  /// How much is left to the goal; negative when it is passed.
  int get left => goal - done;

  /// Whether the goal is reached (passed or met exactly).
  bool get met => done >= goal;

  /// Whether the goal is passed.
  bool get over => done > goal;
}

/// The progress towards [goal], or null when no goal is set.
IntakeProgress? intakeProgress(int done, int? goal) =>
    goal == null ? null : IntakeProgress(done, goal);

// ------------------------------------------------------------------ numbers

String _grouped(int n) {
  final digits = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write('\u00A0');
    b.write(digits[i]);
  }
  return b.toString();
}

/// 1420 -> "1 420 kcal" (non-breaking space), negative with a minus sign.
String formatKcal(int kcal) => '${_grouped(kcal)}\u00A0kcal';

/// 12 -> "12 g".
String formatGrams(int grams) => '${_grouped(grams)}\u00A0g';

/// 300 -> "300 ml", 1000 -> "1 l", 1250 -> "1,25 l", 2500 -> "2,5 l".
String formatVolume(int ml) {
  if (ml < 1000) return '$ml\u00A0ml';
  final liters = (ml / 1000).toStringAsFixed(3);
  final trimmed = liters
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceAll('.', ',');
  return '$trimmed\u00A0l';
}

/// 200 -> "2 dl", 250 -> "2,5 dl", 50 -> "0,5 dl": the size of a glass.
String formatDeciliters(int ml) {
  final dl = (ml / 100).toStringAsFixed(2);
  final trimmed = dl.replaceFirst(RegExp(r'\.?0+$'), '').replaceAll('.', ',');
  return '$trimmed\u00A0dl';
}

// -------------------------------------------------------------- suggestions

/// A food the user ate before, offered when a new one is typed.
class FoodSuggestion {
  const FoodSuggestion({
    required this.name,
    required this.kcal,
    required this.meal,
    required this.uses,
    required this.lastDay,
    this.protein,
    this.carbs,
    this.fat,
  });

  /// As the user wrote it the last time.
  final String name;

  /// The values of the last time.
  final int kcal;
  final int? protein;
  final int? carbs;
  final int? fat;
  final Meal meal;

  /// How many times it was eaten in the window.
  final int uses;
  final DateTime lastDay;
}

String _nameKey(String name) =>
    foldHu(name).trim().replaceAll(RegExp(r'\s+'), ' ');

/// The foods eaten in the last [withinDays] days up to [today], one per name
/// (accents, case and spaces ignored), with the values of the last time. With a
/// [query] only those that contain it (the ones that START with it first); with
/// none the most used ones, the recent first among equals.
List<FoodSuggestion> suggestFoods(
  IntakeLog log,
  String query,
  DateTime today, {
  int limit = 8,
  int withinDays = suggestionWindowDays,
}) {
  final from = DateTime.utc(today.year, today.month, today.day - withinDays);
  final groups = <String, List<FoodEntry>>{};
  for (final f in log.foods) {
    if (f.name.isEmpty || f.day.isBefore(from)) continue;
    (groups[_nameKey(f.name)] ??= []).add(f);
  }
  final q = _nameKey(query);
  final ranked = <(int, FoodSuggestion)>[];
  for (final e in groups.entries) {
    final rank = q.isEmpty
        ? 0
        : e.key.startsWith(q)
        ? 0
        : e.key.contains(q)
        ? 1
        : -1;
    if (rank < 0) continue;
    // (the log is oldest first: the last one is the latest)
    final last = e.value.last;
    ranked.add((
      rank,
      FoodSuggestion(
        name: last.name,
        kcal: last.kcal,
        protein: last.protein,
        carbs: last.carbs,
        fat: last.fat,
        meal: last.meal,
        uses: e.value.length,
        lastDay: last.day,
      ),
    ));
  }
  ranked.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2.uses != b.$2.uses) return b.$2.uses.compareTo(a.$2.uses);
    final c = b.$2.lastDay.compareTo(a.$2.lastDay);
    if (c != 0) return c;
    return foldHu(a.$2.name).compareTo(foldHu(b.$2.name));
  });
  return [for (final r in ranked.take(limit)) r.$2];
}

// -------------------------------------------------------------------- trend

/// The last days of the log, for the charts.
class IntakeTrend {
  const IntakeTrend({
    required this.days,
    required this.foodDays,
    required this.fluidDays,
    this.avgKcal,
    this.avgMl,
  });

  /// Oldest first; exactly as many as were asked for, the last one is today.
  final List<DayTotals> days;

  /// On how many of them something was eaten / drunk.
  final int foodDays;
  final int fluidDays;

  /// The average of the days that have something (a day with nothing logged is
  /// not a day of zero), or null when there is none.
  final int? avgKcal;
  final int? avgMl;
}

/// The last [days] (1 … 366) up to and including [today].
IntakeTrend buildIntakeTrend(IntakeLog log, DateTime today, int days) {
  final n = days.clamp(1, 366);
  final list = [
    for (var i = n - 1; i >= 0; i--)
      log.totalsOn(DateTime.utc(today.year, today.month, today.day - i)),
  ];
  final withFood = list.where((d) => d.hasFood).toList();
  final withFluid = list.where((d) => d.hasFluid).toList();
  int? avg(Iterable<int> values) => values.isEmpty
      ? null
      : (values.reduce((a, b) => a + b) / values.length).round();
  return IntakeTrend(
    days: List.unmodifiable(list),
    foodDays: withFood.length,
    fluidDays: withFluid.length,
    avgKcal: avg(withFood.map((d) => d.kcal)),
    avgMl: avg(withFluid.map((d) => d.ml)),
  );
}
