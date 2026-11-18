import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../intake/intake_ops.dart';
import '../../intake/intake_providers.dart';
import '../../providers.dart';
import '../text_scale.dart';
import '../theme.dart';
import '../undo_service.dart';
import 'intake_dialogs.dart';
import 'intake_text.dart';
import 'intake_trend.dart';

/// The amounts of the quick drink buttons, in millilitres.
const quickDrinkAmounts = [100, 200, 300, 500];

/// One day of the food and fluid log: the calories and the fluids against the
/// goals, the quick buttons for a drink, what was eaten and drunk, and under
/// them the last days as charts.
class IntakePage extends ConsumerStatefulWidget {
  const IntakePage({super.key});

  @override
  ConsumerState<IntakePage> createState() => _IntakePageState();
}

class _IntakePageState extends ConsumerState<IntakePage> {
  DrinkKind _kind = DrinkKind.water;

  // ------------------------------------------------------------- the day

  Future<void> _chooseDay() async {
    final day = ref.read(intakeDayProvider);
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(day.year, day.month, day.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) ref.read(intakeDayProvider.notifier).set(d);
  }

  // ---------------------------------------------------------------- food

  Future<void> _addFood() async {
    final day = ref.read(intakeDayProvider);
    final undo = _Undo.of(context, ref);
    final edit = await showFoodDialog(context, day: day);
    if (edit != null) await _applyFood(edit, undo);
  }

  Future<void> _editFood(FoodEntry f) async {
    final undo = _Undo.of(context, ref);
    final edit = await showFoodDialog(context, day: f.day, existing: f);
    if (edit != null) await _applyFood(edit, undo);
  }

  Future<void> _deleteFood(FoodEntry f) =>
      _applyFood(FoodEdit(f, null), _Undo.of(context, ref));

  Future<void> _applyFood(FoodEdit edit, _Undo u) async {
    final before = edit.before, after = edit.after;
    if (after == null) {
      await u.ops.removeFood(before!);
      u.service.offer(
        u.site,
        message: 'Étel törölve',
        undo: () => u.ops.restoreFood(before),
      );
      return;
    }
    if (before == null) {
      await u.ops.putFood(after);
      u.service.offer(
        u.site,
        message: 'Étel felvéve',
        undo: () async {
          await u.ops.removeFood(after);
          return true;
        },
      );
    } else {
      await u.ops.saveFood(before, after);
      u.service.offer(
        u.site,
        message: 'Étel módosítva',
        undo: () => u.ops.undoSaveFood(before, after),
      );
    }
    // (an entry of another day: show it)
    if (mounted && after.day != ref.read(intakeDayProvider)) {
      ref.read(intakeDayProvider.notifier).set(after.day);
    }
  }

  // --------------------------------------------------------------- fluid

  Future<void> _drink(int ml) async {
    final day = ref.read(intakeDayProvider);
    final u = _Undo.of(context, ref);
    final kind = _kind;
    final entry = await u.ops.addFluid(
      day: day,
      minute: intakeStartMinute(ref, day),
      ml: ml,
      kind: kind,
    );
    u.service.offer(
      u.site,
      message: '${formatVolume(ml)} ${kind.label.toLowerCase()} felvéve',
      undo: () async {
        await u.ops.removeFluid(entry);
        return true;
      },
    );
  }

  Future<void> _otherDrink() async {
    final day = ref.read(intakeDayProvider);
    final u = _Undo.of(context, ref);
    final edit = await showFluidDialog(context, day: day, kind: _kind);
    if (edit != null) await _applyFluid(edit, u);
  }

  Future<void> _editFluid(FluidEntry w) async {
    final u = _Undo.of(context, ref);
    final edit = await showFluidDialog(context, day: w.day, existing: w);
    if (edit != null) await _applyFluid(edit, u);
  }

  Future<void> _deleteFluid(FluidEntry w) =>
      _applyFluid(FluidEdit(w, null), _Undo.of(context, ref));

  Future<void> _applyFluid(FluidEdit edit, _Undo u) async {
    final before = edit.before, after = edit.after;
    if (after == null) {
      await u.ops.removeFluid(before!);
      u.service.offer(
        u.site,
        message: 'Ital törölve',
        undo: () => u.ops.restoreFluid(before),
      );
      return;
    }
    if (before == null) {
      await u.ops.putFluid(after);
      u.service.offer(
        u.site,
        message: 'Ital felvéve',
        undo: () async {
          await u.ops.removeFluid(after);
          return true;
        },
      );
    } else {
      await u.ops.saveFluid(before, after);
      u.service.offer(
        u.site,
        message: 'Ital módosítva',
        undo: () => u.ops.undoSaveFluid(before, after),
      );
    }
    if (mounted && after.day != ref.read(intakeDayProvider)) {
      ref.read(intakeDayProvider.notifier).set(after.day);
    }
  }

  // --------------------------------------------------------------- goals

  Future<void> _goals() async {
    final current = ref.read(intakeGoalsProvider).value ?? const IntakeGoals();
    final goals = await showGoalsDialog(context, current: current);
    if (goals != null) {
      await ref.read(intakeGoalsProvider.notifier).save(goals);
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(intakeLogProvider).value ?? IntakeLog.empty;
    final goals = ref.watch(intakeGoalsProvider).value ?? const IntakeGoals();
    final day = ref.watch(intakeDayProvider);
    final today = ref.watch(todayProvider);
    final totals = log.totalsOn(day);
    final foods = log.foodsOn(day);
    final drinks = log.fluidsOn(day);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('intake-add-food'),
        onPressed: _addFood,
        icon: const Icon(Icons.restaurant),
        label: const Text('Étel'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              _DayBar(
                day: day,
                today: today,
                onPrev: () => ref.read(intakeDayProvider.notifier).shift(-1),
                onNext: () => ref.read(intakeDayProvider.notifier).shift(1),
                onPick: _chooseDay,
                onToday: () => ref.read(intakeDayProvider.notifier).set(today),
              ),
              const SizedBox(height: 8),
              _KcalCard(totals: totals, goals: goals, onGoals: _goals),
              const SizedBox(height: 8),
              _FluidCard(
                totals: totals,
                goals: goals,
                kind: _kind,
                onKind: (k) => setState(() => _kind = k),
                onQuick: _drink,
                onOther: _otherDrink,
              ),
              const SizedBox(height: 8),
              if (!totals.hasData)
                Card(
                  key: const Key('intake-empty'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Még nincs rögzítés ezen a napon. Az „Étel” gombbal vagy '
                      'a víz-gombokkal kezdheted.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              for (final m in Meal.values)
                if (foods.any((f) => f.meal == m)) ...[
                  _ListHeader(
                    key: Key('meal-header-${m.key}'),
                    '${m.label} · ${formatKcal(totals.kcalByMeal[m] ?? 0)}',
                  ),
                  for (final f in foods.where((f) => f.meal == m))
                    _EntryTile(
                      key: Key('food-${f.id}'),
                      title: f.title,
                      detail: foodDetail(f),
                      amount: formatKcal(f.kcal),
                      spoken: spokenFood(f),
                      onTap: () => _editFood(f),
                      onDelete: () => _deleteFood(f),
                      deleteTip: 'Étel törlése',
                    ),
                ],
              if (drinks.isNotEmpty) ...[
                _ListHeader(
                  key: const Key('drinks-header'),
                  'Italok · ${formatVolume(totals.ml)}',
                ),
                for (final w in drinks)
                  _EntryTile(
                    key: Key('drink-${w.id}'),
                    title: drinkTitle(w),
                    detail: w.timeText,
                    amount: null,
                    spoken: spokenDrink(w),
                    onTap: () => _editFluid(w),
                    onDelete: () => _deleteFluid(w),
                    deleteTip: 'Ital törlése',
                  ),
              ],
              const SizedBox(height: 24),
              const IntakeTrendSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a change needs to offer "Visszavonás": taken before the first await,
/// while the page is still there.
class _Undo {
  _Undo(this.ops, this.service, this.site);
  final IntakeOps ops;
  final UndoService service;
  final UndoSite site;

  factory _Undo.of(BuildContext context, WidgetRef ref) => _Undo(
    ref.read(intakeOpsProvider),
    ref.read(undoServiceProvider),
    UndoSite.of(context),
  );
}

// -------------------------------------------------------------------- day

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.today,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
    required this.onToday,
  });
  final DateTime day;
  final DateTime today;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final isToday = day == today;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('intake-prev'),
              tooltip: 'Előző nap',
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: TextButton(
                key: const Key('intake-day'),
                onPressed: onPick,
                child: Text(
                  intakeDayTitle(day, today),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              key: const Key('intake-next'),
              tooltip: 'Következő nap',
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (!isToday)
          TextButton.icon(
            key: const Key('intake-today'),
            onPressed: onToday,
            icon: const Icon(Icons.today),
            label: const Text('Ugrás mára'),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ cards

/// The mark of where a day stands against a goal: an icon and the words next
/// to it, in the colour of the state (the colour is never the only sign).
class _GoalState extends StatelessWidget {
  const _GoalState({
    required this.progress,
    required this.words,
    required this.goodWhenOver,
  });
  final IntakeProgress progress;
  final String words;

  /// A goal that is a floor (fluids): reaching or passing it is good. For the
  /// calories, passing it only gets a mild warning, no verdict.
  final bool goodWhenOver;

  @override
  Widget build(BuildContext context) {
    final status = statusColorsOf(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final over = progress.over;
    final (icon, color) = over
        ? (
            goodWhenOver ? Icons.check_circle : Icons.arrow_upward,
            goodWhenOver ? status.ok : status.warn,
          )
        : progress.met
        ? (Icons.check_circle, status.ok)
        : (Icons.flag_outlined, muted);
    return Row(
      children: [
        Icon(icon, size: context.scaled(18), color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            words,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.title, {this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
      ?action,
    ],
  );
}

class _KcalCard extends StatelessWidget {
  const _KcalCard({
    required this.totals,
    required this.goals,
    required this.onGoals,
  });
  final DayTotals totals;
  final IntakeGoals goals;
  final VoidCallback onGoals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = intakeProgress(totals.kcal, goals.kcal);
    final macros = [
      ('Fehérje', totals.protein, goals.protein),
      ('Szénhidrát', totals.carbs, goals.carbs),
      ('Zsír', totals.fat, goals.fat),
    ].where((m) => m.$2 > 0 || m.$3 != null).toList();
    final partial = totals.withMacros > 0 && totals.withoutMacros > 0;
    return Card(
      key: const Key('intake-kcal'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(
              'Kalória',
              action: TextButton(
                key: const Key('intake-goals'),
                onPressed: onGoals,
                child: const Text('Célok…'),
              ),
            ),
            Semantics(
              container: true,
              label: spokenKcal(totals, goals),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: formatKcal(totals.kcal),
                      style: theme.textTheme.headlineSmall,
                      children: [
                        if (progress != null)
                          TextSpan(
                            text: ' / ${formatKcal(progress.goal)}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      key: const Key('intake-kcal-bar'),
                      value: progress.fraction.clamp(0.0, 1.0),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 8),
                    _GoalState(
                      progress: progress,
                      words: kcalWords(progress),
                      goodWhenOver: false,
                    ),
                  ],
                ],
              ),
            ),
            // (outside the sentence above: a screen reader reads these lines
            // one by one, they are not part of that sentence)
            for (final (name, grams, goal) in macros)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  macroLine(name, grams, goal),
                  key: Key('macro-$name'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            if (macros.isNotEmpty && partial)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'A makrók összege csak azokból az ételekből van, '
                  'ahol megadtad (${totals.withMacros} / '
                  '${totals.foodCount}).',
                  key: const Key('macro-note'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FluidCard extends StatelessWidget {
  const _FluidCard({
    required this.totals,
    required this.goals,
    required this.kind,
    required this.onKind,
    required this.onQuick,
    required this.onOther,
  });
  final DayTotals totals;
  final IntakeGoals goals;
  final DrinkKind kind;
  final void Function(DrinkKind) onKind;
  final void Function(int) onQuick;
  final VoidCallback onOther;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = intakeProgress(totals.ml, goals.ml);
    return Card(
      key: const Key('intake-fluid'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardTitle('Folyadék'),
            Semantics(
              container: true,
              label: spokenFluid(totals, goals),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: formatVolume(totals.ml),
                      style: theme.textTheme.headlineSmall,
                      children: [
                        if (progress != null)
                          TextSpan(
                            text: ' / ${formatVolume(progress.goal)}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      key: const Key('intake-fluid-bar'),
                      value: progress.fraction.clamp(0.0, 1.0),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 8),
                    _GoalState(
                      progress: progress,
                      words: volumeWords(progress),
                      goodWhenOver: true,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final ml in quickDrinkAmounts)
                  ActionChip(
                    key: Key('drink-$ml'),
                    avatar: const Icon(Icons.add),
                    label: Text(formatDeciliters(ml)),
                    tooltip: 'Felvétel: ${formatDeciliters(ml)}',
                    onPressed: () => onQuick(ml),
                  ),
                ActionChip(
                  key: const Key('drink-other'),
                  label: const Text('Más…'),
                  onPressed: onOther,
                ),
                PopupMenuButton<DrinkKind>(
                  key: const Key('drink-kind'),
                  tooltip: 'Az ital fajtája',
                  initialValue: kind,
                  onSelected: onKind,
                  itemBuilder: (_) => [
                    for (final k in DrinkKind.values)
                      PopupMenuItem(
                        key: Key('kind-item-${k.key}'),
                        value: k,
                        child: Text(k.label),
                      ),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.local_drink_outlined),
                    label: Text('Ital: ${kind.label}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- list

class _ListHeader extends StatelessWidget {
  const _ListHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

/// One food or one drink of the day: tap to change it, the bin to remove it.
/// At a large text size the amount goes under the words, so that neither is
/// squeezed.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.title,
    required this.detail,
    required this.amount,
    required this.spoken,
    required this.onTap,
    required this.onDelete,
    required this.deleteTip,
  });
  final String title;
  final String detail;
  final String? amount;
  final String spoken;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String deleteTip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stack = context.textFactor() >= 1.5;
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyLarge),
        if (stack && amount != null)
          Text(amount!, style: theme.textTheme.titleSmall),
        Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              label: spoken,
              excludeSemantics: true,
              onTap: onTap,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: stack || amount == null
                      ? words
                      : Row(
                          children: [
                            Expanded(child: words),
                            const SizedBox(width: 8),
                            Text(amount!, style: theme.textTheme.titleSmall),
                          ],
                        ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: deleteTip,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
