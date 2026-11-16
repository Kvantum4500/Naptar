import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../intake/intake_providers.dart';
import '../../providers.dart';
import '../day_utils.dart';
import '../format.dart';

// The forms of the food and fluid page: a food, a drink, the goals. Each is a
// dialog that makes the checked entry itself and hands it back; the page writes
// it and offers "Visszavonás".

/// The minute of the day on the wall clock of the display zone, now.
int intakeMinuteNow(WidgetRef ref) {
  final wall = toWallClock(defaultTz, ref.read(appClockProvider)().toUtc());
  return wall.hour * 60 + wall.minute;
}

/// The time a new entry of [day] starts with: now for today, noon for another
/// day (the time of a day that is over is not "now").
int intakeStartMinute(WidgetRef ref, DateTime day) =>
    day == ref.read(todayProvider) ? intakeMinuteNow(ref) : 12 * 60;

/// What a food form hands back: the entry as it was and as it is now (null
/// "now" is a deletion, null "before" a new entry).
class FoodEdit {
  const FoodEdit(this.before, this.after);
  final FoodEntry? before;
  final FoodEntry? after;
}

/// The same for a drink.
class FluidEdit {
  const FluidEdit(this.before, this.after);
  final FluidEntry? before;
  final FluidEntry? after;
}

Future<TimeOfDay?> _pickTime(BuildContext context, int minute) =>
    showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: w!,
      ),
    );

Future<DateTime?> _pickDay(BuildContext context, DateTime day) =>
    showDatePicker(
      context: context,
      initialDate: DateTime(day.year, day.month, day.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

int? _number(TextEditingController c) {
  final t = c.text.trim();
  return t.isEmpty ? null : int.tryParse(t);
}

Widget _numberField(
  Key key,
  TextEditingController controller,
  String label, {
  String? suffix,
  String? helper,
  int maxLength = 4,
  bool autofocus = false,
  void Function(String)? onChanged,
}) => TextField(
  key: key,
  controller: controller,
  autofocus: autofocus,
  keyboardType: TextInputType.number,
  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
  maxLength: maxLength,
  onChanged: onChanged,
  decoration: InputDecoration(
    labelText: label,
    suffixText: suffix,
    helperText: helper,
    helperMaxLines: 3,
    counterText: '',
  ),
);

Widget _errorLine(Key key, String? error, BuildContext context) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          liveRegion: true,
          child: Text(
            error,
            key: key,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );

// -------------------------------------------------------------------- food

Future<FoodEdit?> showFoodDialog(
  BuildContext context, {
  required DateTime day,
  FoodEntry? existing,
}) => showDialog<FoodEdit>(
  context: context,
  builder: (_) => _FoodDialog(day: day, existing: existing),
);

class _FoodDialog extends ConsumerStatefulWidget {
  const _FoodDialog({required this.day, this.existing});
  final DateTime day;
  final FoodEntry? existing;

  @override
  ConsumerState<_FoodDialog> createState() => _FoodDialogState();
}

class _FoodDialogState extends ConsumerState<_FoodDialog> {
  late final TextEditingController _name;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late Meal _meal;
  late bool _mealTouched;
  late int _minute;
  late DateTime _day;
  late bool _macros;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _kcal = TextEditingController(text: e == null ? '' : '${e.kcal}');
    _protein = TextEditingController(text: e?.protein?.toString() ?? '');
    _carbs = TextEditingController(text: e?.carbs?.toString() ?? '');
    _fat = TextEditingController(text: e?.fat?.toString() ?? '');
    _day = e?.day ?? widget.day;
    _minute = e?.minute ?? intakeStartMinute(ref, _day);
    _meal = e?.meal ?? Meal.forMinute(_minute);
    _mealTouched = e != null;
    _macros = e?.hasMacros ?? false;
  }

  @override
  void dispose() {
    for (final c in [_name, _kcal, _protein, _carbs, _fat]) {
      c.dispose();
    }
    super.dispose();
  }

  void _use(FoodSuggestion s) => setState(() {
    _name.text = s.name;
    _kcal.text = '${s.kcal}';
    _protein.text = s.protein?.toString() ?? '';
    _carbs.text = s.carbs?.toString() ?? '';
    _fat.text = s.fat?.toString() ?? '';
    _macros = s.protein != null || s.carbs != null || s.fat != null;
    if (!_mealTouched) _meal = s.meal;
    _error = null;
  });

  Future<void> _time() async {
    final t = await _pickTime(context, _minute);
    if (t == null || !mounted) return;
    setState(() {
      _minute = t.hour * 60 + t.minute;
      if (!_mealTouched) _meal = Meal.forMinute(_minute);
    });
  }

  Future<void> _date() async {
    final d = await _pickDay(context, _day);
    if (d == null || !mounted) return;
    setState(() => _day = DateTime.utc(d.year, d.month, d.day));
  }

  void _save() {
    try {
      final entry = FoodEntry.checked(
        id: widget.existing?.id ?? ref.read(intakeOpsProvider).newId(),
        day: _day,
        minute: _minute,
        meal: _meal,
        name: _name.text,
        kcal: _number(_kcal),
        protein: _number(_protein),
        carbs: _number(_carbs),
        fat: _number(_fat),
      );
      Navigator.pop(context, FoodEdit(widget.existing, entry));
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(intakeLogProvider).value ?? IntakeLog.empty;
    final today = ref.watch(todayProvider);
    final suggestions = suggestFoods(log, _name.text, today, limit: 6);
    final existing = widget.existing;
    return AlertDialog(
      scrollable: true,
      title: Text(existing == null ? 'Étel felvétele' : 'Étel szerkesztése'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('food-name'),
            controller: _name,
            autofocus: existing == null,
            maxLength: maxFoodName,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Étel neve (nem kötelező)',
              counterText: '',
            ),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Korábbi ételeid',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < suggestions.length; i++)
                  ActionChip(
                    key: Key('suggest-$i'),
                    label: Text(
                      '${suggestions[i].name} · '
                      '${formatKcal(suggestions[i].kcal)}',
                    ),
                    onPressed: () => _use(suggestions[i]),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final m in Meal.values)
                ChoiceChip(
                  key: Key('meal-${m.key}'),
                  label: Text(m.label),
                  selected: _meal == m,
                  onSelected: (_) => setState(() {
                    _meal = m;
                    _mealTouched = true;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _numberField(
            const Key('food-kcal'),
            _kcal,
            'Kalória',
            suffix: 'kcal',
            helper: 'Ha üresen hagyod, a makrókból számolom.',
          ),
          TextButton.icon(
            key: const Key('food-macros-toggle'),
            onPressed: () => setState(() => _macros = !_macros),
            icon: Icon(_macros ? Icons.expand_less : Icons.expand_more),
            label: const Text('Makrók (gramm)'),
          ),
          if (_macros) ...[
            _numberField(
              const Key('food-protein'),
              _protein,
              'Fehérje',
              suffix: 'g',
              maxLength: 3,
            ),
            _numberField(
              const Key('food-carbs'),
              _carbs,
              'Szénhidrát',
              suffix: 'g',
              maxLength: 3,
            ),
            _numberField(
              const Key('food-fat'),
              _fat,
              'Zsír',
              suffix: 'g',
              maxLength: 3,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                key: const Key('food-day'),
                onPressed: _date,
                icon: const Icon(Icons.event),
                label: Text(fmtDateLong(_day)),
              ),
              OutlinedButton.icon(
                key: const Key('food-time'),
                onPressed: _time,
                icon: const Icon(Icons.schedule),
                label: Text(minuteText(_minute)),
              ),
            ],
          ),
          _errorLine(const Key('food-error'), _error, context),
        ],
      ),
      actions: [
        if (existing != null)
          TextButton(
            key: const Key('food-delete'),
            onPressed: () => Navigator.pop(context, FoodEdit(existing, null)),
            child: const Text('Törlés'),
          ),
        TextButton(
          key: const Key('food-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(
          key: const Key('food-save'),
          onPressed: _save,
          child: const Text('Mentés'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- drink

Future<FluidEdit?> showFluidDialog(
  BuildContext context, {
  required DateTime day,
  FluidEntry? existing,
  DrinkKind kind = DrinkKind.water,
}) => showDialog<FluidEdit>(
  context: context,
  builder: (_) => _FluidDialog(day: day, existing: existing, kind: kind),
);

/// The amounts the form offers to fill in.
const fluidAmounts = [100, 200, 300, 500, 1000];

class _FluidDialog extends ConsumerStatefulWidget {
  const _FluidDialog({required this.day, required this.kind, this.existing});
  final DateTime day;
  final FluidEntry? existing;
  final DrinkKind kind;

  @override
  ConsumerState<_FluidDialog> createState() => _FluidDialogState();
}

class _FluidDialogState extends ConsumerState<_FluidDialog> {
  late final TextEditingController _ml;
  late DrinkKind _kind;
  late int _minute;
  late DateTime _day;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _ml = TextEditingController(text: e == null ? '' : '${e.ml}');
    _kind = e?.kind ?? widget.kind;
    _day = e?.day ?? widget.day;
    _minute = e?.minute ?? intakeStartMinute(ref, _day);
  }

  @override
  void dispose() {
    _ml.dispose();
    super.dispose();
  }

  Future<void> _time() async {
    final t = await _pickTime(context, _minute);
    if (t == null || !mounted) return;
    setState(() => _minute = t.hour * 60 + t.minute);
  }

  Future<void> _date() async {
    final d = await _pickDay(context, _day);
    if (d == null || !mounted) return;
    setState(() => _day = DateTime.utc(d.year, d.month, d.day));
  }

  void _save() {
    final ml = _number(_ml);
    if (ml == null) {
      setState(() => _error = 'Add meg a mennyiséget.');
      return;
    }
    try {
      final entry = FluidEntry.checked(
        id: widget.existing?.id ?? ref.read(intakeOpsProvider).newId(),
        day: _day,
        minute: _minute,
        ml: ml,
        kind: _kind,
      );
      Navigator.pop(context, FluidEdit(widget.existing, entry));
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      scrollable: true,
      title: Text(existing == null ? 'Ital felvétele' : 'Ital szerkesztése'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _numberField(
            const Key('fluid-ml'),
            _ml,
            'Mennyiség',
            suffix: 'ml',
            autofocus: existing == null,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final ml in fluidAmounts)
                ActionChip(
                  key: Key('fluid-fill-$ml'),
                  label: Text(formatDeciliters(ml)),
                  onPressed: () => setState(() => _ml.text = '$ml'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final k in DrinkKind.values)
                ChoiceChip(
                  key: Key('kind-${k.key}'),
                  label: Text(k.label),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                key: const Key('fluid-day'),
                onPressed: _date,
                icon: const Icon(Icons.event),
                label: Text(fmtDateLong(_day)),
              ),
              OutlinedButton.icon(
                key: const Key('fluid-time'),
                onPressed: _time,
                icon: const Icon(Icons.schedule),
                label: Text(minuteText(_minute)),
              ),
            ],
          ),
          _errorLine(const Key('fluid-error'), _error, context),
        ],
      ),
      actions: [
        if (existing != null)
          TextButton(
            key: const Key('fluid-delete'),
            onPressed: () => Navigator.pop(context, FluidEdit(existing, null)),
            child: const Text('Törlés'),
          ),
        TextButton(
          key: const Key('fluid-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(
          key: const Key('fluid-save'),
          onPressed: _save,
          child: const Text('Mentés'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- goals

/// Asks for the goals; null when the form is cancelled. A field left empty is
/// a goal that is not set.
Future<IntakeGoals?> showGoalsDialog(
  BuildContext context, {
  required IntakeGoals current,
}) => showDialog<IntakeGoals>(
  context: context,
  builder: (_) => _GoalsDialog(current: current),
);

class _GoalsDialog extends StatefulWidget {
  const _GoalsDialog({required this.current});
  final IntakeGoals current;

  @override
  State<_GoalsDialog> createState() => _GoalsDialogState();
}

class _GoalsDialogState extends State<_GoalsDialog> {
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _ml;
  String? _error;

  @override
  void initState() {
    super.initState();
    final g = widget.current;
    _kcal = TextEditingController(text: g.kcal?.toString() ?? '');
    _protein = TextEditingController(text: g.protein?.toString() ?? '');
    _carbs = TextEditingController(text: g.carbs?.toString() ?? '');
    _fat = TextEditingController(text: g.fat?.toString() ?? '');
    _ml = TextEditingController(text: g.ml?.toString() ?? '');
  }

  @override
  void dispose() {
    for (final c in [_kcal, _protein, _carbs, _fat, _ml]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      Navigator.pop(
        context,
        IntakeGoals.checked(
          kcal: _number(_kcal),
          protein: _number(_protein),
          carbs: _number(_carbs),
          fat: _number(_fat),
          ml: _number(_ml),
        ),
      );
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Napi célok'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'A célokat te adod meg, a program nem javasol értéket. Amit üresen '
          'hagysz, ahhoz nincs cél. A célok a többi eszközödre is átmennek '
          '(szinkronizálódnak).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _numberField(
          const Key('goal-kcal'),
          _kcal,
          'Kalória',
          suffix: 'kcal',
          maxLength: 5,
        ),
        _numberField(
          const Key('goal-protein'),
          _protein,
          'Fehérje',
          suffix: 'g',
        ),
        _numberField(
          const Key('goal-carbs'),
          _carbs,
          'Szénhidrát',
          suffix: 'g',
        ),
        _numberField(const Key('goal-fat'), _fat, 'Zsír', suffix: 'g'),
        _numberField(
          const Key('goal-ml'),
          _ml,
          'Folyadék',
          suffix: 'ml',
          maxLength: 5,
        ),
        _errorLine(const Key('goals-error'), _error, context),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('goals-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Mégse'),
      ),
      FilledButton(
        key: const Key('goals-save'),
        onPressed: _save,
        child: const Text('Mentés'),
      ),
    ],
  );
}
