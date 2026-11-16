import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../intake/intake_providers.dart';
import '../../providers.dart';
import '../charts.dart';
import 'intake_text.dart';

/// The periods the trend can show, in days.
const intakeTrendRanges = <(int, String)>[(7, '7 nap'), (30, '30 nap')];

/// The last days of the log as charts: the calories and the fluids a day, each
/// with the goal as a dashed line (and an arrow over the days that passed it),
/// and the same in numbers under them.
class IntakeTrendSection extends ConsumerWidget {
  const IntakeTrendSection({super.key});

  Widget _chart(
    BuildContext context, {
    required Key key,
    required String what,
    required List<DayTotals> days,
    required int Function(DayTotals) of,
    required bool Function(DayTotals) recorded,
    required String Function(int) amount,
    int? goal,
    Color? color,
  }) {
    final largest = days.fold<int>(0, (m, d) => math.max(m, of(d)));
    final top = niceCountMax(math.max(largest, goal ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(what, style: Theme.of(context).textTheme.titleSmall),
        ),
        BarChart(
          key: key,
          values: [for (final d in days) of(d).toDouble()],
          maxValue: top.toDouble(),
          maxLabel: amount(top),
          firstLabel: intakeDayShort(days.first.day),
          lastLabel: 'ma',
          semanticLabel: intakeBarsLabel(
            what: what,
            days: days,
            of: of,
            recorded: recorded,
            amount: amount,
            goal: goal,
          ),
          goal: goal?.toDouble(),
          goalLabel: goal == null ? null : 'cél ${amount(goal)}',
          color: color,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(intakeLogProvider).value ?? IntakeLog.empty;
    final goals = ref.watch(intakeGoalsProvider).value ?? const IntakeGoals();
    final today = ref.watch(todayProvider);
    final range = ref.watch(intakeTrendDaysProvider);
    final trend = buildIntakeTrend(log, today, range);
    final theme = Theme.of(context);
    final hasGoal = goals.kcal != null || goals.ml != null;
    final averages = [
      if (trend.avgKcal != null) 'átlag ${formatKcal(trend.avgKcal!)}',
      if (trend.avgMl != null) 'átlag ${formatVolume(trend.avgMl!)}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Az elmúlt napok', style: theme.textTheme.titleMedium),
          ),
        ),
        Wrap(
          key: const Key('intake-trend-range'),
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (days, label) in intakeTrendRanges)
              ChoiceChip(
                key: Key('trend-$days'),
                label: Text(label),
                selected: range == days,
                onSelected: (_) =>
                    ref.read(intakeTrendDaysProvider.notifier).set(days),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _chart(
          context,
          key: const Key('intake-kcal-chart'),
          what: 'Kalória',
          days: trend.days,
          of: (d) => d.kcal,
          recorded: (d) => d.hasFood,
          amount: formatKcal,
          goal: goals.kcal,
        ),
        const SizedBox(height: 16),
        _chart(
          context,
          key: const Key('intake-fluid-chart'),
          what: 'Folyadék',
          days: trend.days,
          of: (d) => d.ml,
          recorded: (d) => d.hasFluid,
          amount: formatVolume,
          goal: goals.ml,
          color: theme.colorScheme.tertiary,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Napokra bontva; a jobb szélső oszlop a mai nap, még nem kész.'
            '${hasGoal ? ' A szaggatott vonal a célod, az oszlop fölötti kis '
                      'nyíl a cél fölötti napot mutatja.' : ''}',
            key: const Key('intake-trend-note'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          container: true,
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Adatok szövegesen',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        ExpansionTile(
          key: const Key('intake-table'),
          title: const Text('Napok számokkal'),
          subtitle: averages.isEmpty ? null : Text(averages),
          children: [
            for (final d in trend.days.reversed)
              ListTile(dense: true, title: Text(intakeTrendRow(d))),
          ],
        ),
      ],
    );
  }
}
