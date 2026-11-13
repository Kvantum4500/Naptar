import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../ai/workout_providers.dart';
import '../providers.dart';
import 'charts.dart';
import 'theme.dart';

/// The periods the page can show, in weeks.
const progressRanges = <(int, String)>[
  (4, '4 hét'),
  (12, '12 hét'),
  (26, 'Fél év'),
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "11.16." for the day.
String progressDay(DateTime d) => '${_two(d.month)}.${_two(d.day)}.';

/// The line of one week for the table of data under the charts.
String weekRow(WeekVolume w) {
  final bits = <String>[
    if (w.sessions == 0 && w.skipped == 0)
      'nem volt edzés'
    else ...[
      '${w.sessions} edzés, ${minutesText(w.minutes)}',
      if (w.skipped > 0) '${w.skipped} kihagyva',
    ],
    if (w.bodyLoad != null || w.mindLoad != null)
      'nehézség ${w.bodyLoad == null ? '–' : oneDecimal(w.bodyLoad!)}'
          ' / ${w.mindLoad == null ? '–' : oneDecimal(w.mindLoad!)}',
    if (w.energyStart != null && w.energyEnd != null)
      'energia ${oneDecimal(w.energyStart!)} → ${oneDecimal(w.energyEnd!)}',
  ];
  return '${progressDay(w.monday)} héttől: ${bits.join(' · ')}';
}

/// What a screen reader says for the bars.
String barsLabel(ProgressData data) {
  final sessions = data.weeks.fold<int>(0, (n, w) => n + w.sessions);
  final minutes = data.weeks.fold<int>(0, (n, w) => n + w.minutes);
  final now = data.weeks.last;
  return 'Heti edzésmennyiség az utolsó ${data.weeks.length} hétben: '
      'összesen $sessions edzés, ${minutesText(minutes)}. '
      'Ebben a héten ${now.sessions} edzés, ${minutesText(now.minutes)}.';
}

/// What a screen reader says for the lines of the check-in.
String linesLabel(ProgressData data, Iterable<CheckInMetric> shown) {
  final parts = <String>[];
  for (final m in shown) {
    final answers = data.days[m]!;
    if (answers.isEmpty) {
      parts.add('${m.label}: nincs válasz');
      continue;
    }
    final average = mean([for (final p in answers) p.value])!;
    final lately = data.trend[m]!.last.value;
    parts.add(
      '${m.label}: ${answers.length} válasz, átlag ${oneDecimal(average)}/5, '
      'a legutóbbi napokban ${oneDecimal(lately)}/5',
    );
  }
  return 'Napi közérzet ${progressDay(data.from)} és ${progressDay(data.to)} '
      'között. ${parts.join('; ')}.';
}

LineMarker markerOf(CheckInMetric m) => switch (m) {
  CheckInMetric.physical => LineMarker.circle,
  CheckInMetric.mental => LineMarker.square,
  CheckInMetric.mood => LineMarker.triangle,
  CheckInMetric.sleep => LineMarker.diamond,
};

Color colorOf(BuildContext context, CheckInMetric m) {
  final scheme = Theme.of(context).colorScheme;
  final status = statusColorsOf(context);
  return switch (m) {
    CheckInMetric.physical => scheme.primary,
    CheckInMetric.mental => scheme.tertiary,
    CheckInMetric.mood => status.warn,
    CheckInMetric.sleep => status.ok,
  };
}

/// The page that shows how the weeks went: the training week by week, how the
/// days felt, how hard the workouts were. All of it is drawn from what the
/// daily check-in and the feedback after workouts have already collected.
class ProgressPage extends ConsumerStatefulWidget {
  const ProgressPage({super.key});

  @override
  ConsumerState<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends ConsumerState<ProgressPage> {
  int _weeks = 12;
  final _shown = <CheckInMetric>{CheckInMetric.physical, CheckInMetric.sleep};

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(workoutLogsProvider).value ?? const [];
    final checkIns = ref.watch(checkInsProvider).value ?? const [];
    final today = ref.watch(todayProvider);
    final data = buildProgress(
      logs: logs,
      checkIns: checkIns,
      today: today,
      weeks: _weeks,
    );
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Haladás')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                key: const Key('progress-range'),
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (weeks, label) in progressRanges)
                    ChoiceChip(
                      key: Key('range-$weeks'),
                      label: Text(label),
                      selected: _weeks == weeks,
                      onSelected: (_) => setState(() => _weeks = weeks),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (!data.hasData)
                Card(
                  key: const Key('progress-empty'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Még nincs elég adat. A napi check-in és az edzés utáni '
                      'visszajelzés kitöltése után itt látod a heti '
                      'edzésmennyiséget és a trendeket.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              else ...[
                _Section(
                  'Ez a hét',
                  Card(
                    key: const Key('progress-summary'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < data.summary.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                data.summary[i],
                                style: i == 0
                                    ? theme.textTheme.titleSmall
                                    : theme.textTheme.bodyMedium,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                _Section('Heti edzésmennyiség', _bars(context, data)),
                _Section('Hogyan érezted magad', _lines(context, data)),
                if (data.weeks.any(
                  (w) => w.bodyLoad != null || w.mindLoad != null,
                ))
                  _Section('Az edzések nehézsége', _difficulty(context, data)),
                _Section(
                  'Adatok szövegesen',
                  ExpansionTile(
                    key: const Key('progress-table'),
                    title: const Text('Hetek számokkal'),
                    children: [
                      for (final w in data.weeks.reversed)
                        ListTile(dense: true, title: Text(weekRow(w))),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _bars(BuildContext context, ProgressData data) {
    final minutes = [for (final w in data.weeks) w.minutes.toDouble()];
    final top = niceMinutesMax(
      minutes.fold<double>(0, (a, b) => a > b ? a : b).round(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BarChart(
          key: const Key('progress-bars'),
          values: minutes,
          maxValue: top.toDouble(),
          maxLabel: minutesText(top),
          firstLabel: progressDay(data.weeks.first.monday),
          lastLabel: 'ez a hét',
          semanticLabel: barsLabel(data),
        ),
        Text(
          'Percek hetenként; a jobb szélső oszlop a mostani hét, még nem kész.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _lines(BuildContext context, ProgressData data) {
    final shown = [
      for (final m in CheckInMetric.values)
        if (_shown.contains(m)) m,
    ];
    final anyAnswer = shown.any((m) => data.days[m]!.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          key: const Key('progress-metrics'),
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final m in CheckInMetric.values)
              FilterChip(
                key: Key('metric-${m.name}'),
                // (the shape is in the label, not the avatar: the check mark of
                // a chosen chip would cover an avatar, and the shape is what ties
                // the chip to its line)
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      markerOf(m).icon,
                      size: 14,
                      color: colorOf(context, m),
                    ),
                    const SizedBox(width: 6),
                    Flexible(child: Text(m.label)),
                  ],
                ),
                selected: _shown.contains(m),
                onSelected: (on) => setState(() {
                  if (on) {
                    _shown.add(m);
                  } else {
                    _shown.remove(m);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text(
            'Válassz legalább egy mutatót.',
            key: const Key('progress-no-metric'),
            style: Theme.of(context).textTheme.bodyMedium,
          )
        else if (!anyAnswer)
          Text(
            'Ebben az időszakban nem volt válasz.',
            key: const Key('progress-no-answer'),
            style: Theme.of(context).textTheme.bodyMedium,
          )
        else ...[
          LineChart(
            key: const Key('progress-lines'),
            series: [
              for (final m in shown)
                LineSeries(
                  label: m.label,
                  color: colorOf(context, m),
                  marker: markerOf(m),
                  dots: data.days[m]!,
                  line: data.trend[m]!,
                ),
            ],
            from: data.from,
            to: data.to,
            firstLabel: progressDay(data.from),
            lastLabel: 'ma',
            semanticLabel: linesLabel(data, shown),
          ),
          Text(
            'A pont egy nap válasza (1 rossz … 5 kiváló), a vonal az utolsó '
            '7 nap átlaga.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _difficulty(BuildContext context, ProgressData data) {
    List<DayValue> weekly(double? Function(WeekVolume) of) => [
      for (final w in data.weeks)
        if (of(w) != null) DayValue(w.monday, of(w)!),
    ];
    final body = weekly((w) => w.bodyLoad);
    final mind = weekly((w) => w.mindLoad);
    final scheme = Theme.of(context).colorScheme;
    final series = [
      LineSeries(
        label: 'Fizikai nehézség',
        color: scheme.primary,
        marker: LineMarker.circle,
        dots: const [],
        line: body,
        markAll: true,
      ),
      LineSeries(
        label: 'Mentális nehézség',
        color: scheme.tertiary,
        marker: LineMarker.square,
        dots: const [],
        line: mind,
        markAll: true,
      ),
    ];
    String describe(String name, List<DayValue> l) => l.isEmpty
        ? '$name: nincs adat'
        : '$name: ${l.length} héten, átlag '
              '${oneDecimal(mean([for (final p in l) p.value])!)}/5';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(s.marker.icon, size: 14, color: s.color),
                  const SizedBox(width: 6),
                  // (at a large text size the name wraps instead of running over)
                  Flexible(child: Text(s.label)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        LineChart(
          key: const Key('progress-difficulty'),
          series: series,
          from: data.weeks.first.monday,
          to: data.weeks.last.monday,
          firstLabel: progressDay(data.weeks.first.monday),
          lastLabel: progressDay(data.weeks.last.monday),
          semanticLabel:
              'Az edzések nehézsége hetenként (1 könnyű … 5 nagyon nehéz). '
              '${describe('Fizikai', body)}; ${describe('Mentális', mind)}.',
        ),
        Text(
          'A heti átlag az edzés utáni visszajelzésekből; 1 könnyű, 5 nagyon nehéz.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.child);
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // (a node of its own: the note under a chart must not be read as part
        // of the heading)
        Semantics(
          container: true,
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        child,
      ],
    ),
  );
}
