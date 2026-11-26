import 'package:kvantum_core/kvantum_core.dart';

import '../../sync/error_catalog.dart';
import '../format.dart';

// The words of the food and fluid page: pure functions, so that what the page
// and a screen reader say can be tested without drawing anything.

/// What the bar says when a change that has no form of its own did not go
/// through: what was tried ([what], "törölni az ételt") and why, in words the
/// user can use. The sentence the catalog adds to an error nobody foresaw, that
/// what was typed is not lost, is left out: there was nothing typed.
String failureLine(String what, Object error) {
  final info = errorInfoFor(error);
  final why = info.action == ErrorAction.diagnostics
      ? '${info.title} Részletek: Diagnosztika.'
      : info.text;
  return 'Nem sikerült $what: $why';
}

/// How far a day is from a goal, in words: "még 780 kcal", "a cél teljesült"
/// or "150 kcal a cél fölött" (told by [amount], the number with its unit).
String goalWords(IntakeProgress p, String Function(int) amount) {
  if (p.over) return '${amount(-p.left)} a cél fölött';
  if (p.met) return 'a cél teljesült';
  return 'még ${amount(p.left)}';
}

String kcalWords(IntakeProgress p) => goalWords(p, formatKcal);
String volumeWords(IntakeProgress p) => goalWords(p, formatVolume);
String gramsWords(IntakeProgress p) => goalWords(p, formatGrams);

/// "Ma · 2026. nov. 16., hétfő" (also "Tegnap" and "Holnap").
String intakeDayTitle(DateTime day, DateTime today) {
  final long = fmtDateLong(day);
  final diff = DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  return switch (diff) {
    0 => 'Ma · $long',
    -1 => 'Tegnap · $long',
    1 => 'Holnap · $long',
    _ => long,
  };
}

/// What a screen reader says for the calories of a day.
String spokenKcal(DayTotals t, IntakeGoals g) {
  final p = intakeProgress(t.kcal, g.kcal);
  return 'Kalória: ${formatKcal(t.kcal)}'
      '${p == null ? '' : ', cél ${formatKcal(p.goal)}, ${kcalWords(p)}'}.';
}

/// What a screen reader says for the fluids of a day.
String spokenFluid(DayTotals t, IntakeGoals g) {
  final p = intakeProgress(t.ml, g.ml);
  return 'Folyadék: ${formatVolume(t.ml)}'
      '${p == null ? '' : ', cél ${formatVolume(p.goal)}, ${volumeWords(p)}'}.';
}

/// The line of one macro: "Fehérje 80 g" or "Fehérje 80 g / 150 g" (with a
/// goal), and the words "még 70 g" after it.
String macroLine(String name, int grams, int? goal) {
  final p = intakeProgress(grams, goal);
  return p == null
      ? '$name ${formatGrams(grams)}'
      : '$name ${formatGrams(grams)} / ${formatGrams(p.goal)} · '
            '${gramsWords(p)}';
}

/// The line under a food: its time and the macros that were entered.
String foodDetail(FoodEntry f) => [
  f.timeText,
  if (f.protein != null) '${f.protein} g fehérje',
  if (f.carbs != null) '${f.carbs} g szénhidrát',
  if (f.fat != null) '${f.fat} g zsír',
].join(' · ');

/// The title of a drink in a list: "Tea · 3 dl".
String drinkTitle(FluidEntry w) => '${w.kind.label} · ${formatVolume(w.ml)}';

/// What a screen reader says for one food of the list.
String spokenFood(FoodEntry f) =>
    '${f.title}, ${formatKcal(f.kcal)}, ${foodDetail(f)}';

/// What a screen reader says for one drink of the list.
String spokenDrink(FluidEntry w) => '${drinkTitle(w)}, ${w.timeText}';

/// The line of one day for the table of data under the charts.
String intakeTrendRow(DayTotals d) {
  final what = [
    if (d.hasFood) formatKcal(d.kcal),
    if (d.hasFluid) formatVolume(d.ml),
  ];
  return '${fmtDateLong(d.day)}: '
      '${what.isEmpty ? 'nincs rögzítés' : what.join(' · ')}';
}

/// The first day under a chart: "11.10."
String intakeDayShort(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}.'
    '${d.day.toString().padLeft(2, '0')}.';

/// What a screen reader says in place of a chart of one amount per day:
/// [of] reads the amount of a day, [recorded] says whether the day has any
/// entry (a day with nothing logged is not a day of zero), [amount] writes it.
String intakeBarsLabel({
  required String what,
  required List<DayTotals> days,
  required int Function(DayTotals) of,
  required bool Function(DayTotals) recorded,
  required String Function(int) amount,
  int? goal,
}) {
  final head = '$what az elmúlt ${days.length} napban';
  final seen = days.where(recorded).toList();
  if (seen.isEmpty) return '$head: nincs rögzítés.';
  final sum = seen.fold<int>(0, (n, d) => n + of(d));
  final average = (sum / seen.length).round();
  final over = goal == null ? 0 : days.where((d) => of(d) > goal).length;
  final today = days.last;
  return '$head: átlag ${amount(average)} a rögzített ${seen.length} napon'
      '${goal == null ? '' : '; a cél ${amount(goal)}, $over napon volt fölötte'}'
      '. ${recorded(today) ? 'Ma ${amount(of(today))}' : 'Ma még nincs rögzítés'}'
      '.';
}
