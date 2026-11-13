import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'a11y.dart';
import 'day_utils.dart';
import 'format.dart';
import 'month_view.dart' show OpenOccurrence;
import 'palette.dart';
import 'tasks_page.dart' show openTaskEditor;
import 'text_scale.dart';

/// "Ma", "Holnap", "Holnapután" and "Tegnap" for the days around [today];
/// null for any other day.
String? relativeDayName(DateTime day, DateTime today) =>
    switch (dateOnly(day).difference(dateOnly(today)).inDays) {
      0 => 'Ma',
      1 => 'Holnap',
      2 => 'Holnapután',
      -1 => 'Tegnap',
      _ => null,
    };

/// "Ma · péntek, nov. 13." / "kedd, nov. 17."
String agendaDayTitle(DateTime day, DateTime today) {
  final date = DateFormat(
    'EEEE, MMM d.',
    'hu',
  ).format(DateTime(day.year, day.month, day.day));
  final rel = relativeDayName(day, today);
  return rel == null ? date : '$rel · $date';
}

/// The time column of an event row: "09:00 / 10:30", "egész nap", or "folyt."
/// for a day an event only continues on.
String agendaWhen(Occurrence o, DateTime day) {
  if (o.allDay) return 'egész nap';
  final tz = o.tzid ?? defaultTz;
  final s = toWallClock(tz, o.startUtc), e = toWallClock(tz, o.endUtc);
  if (dateOnly(s) != day) return 'folyt.';
  final continues = e.isAfter(day.add(const Duration(days: 1)));
  return '${fmtTime(s)}\n${continues ? '→' : fmtTime(e)}';
}

/// The next [agendaDays] days as a list: for each day that has something, its
/// events (all-day first, then by start) and the open tasks due on it. Overdue
/// open tasks come first when the list reaches back to today.
class AgendaView extends ConsumerWidget {
  const AgendaView({super.key, required this.onOpen});
  final OpenOccurrence onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(agendaRangeProvider);
    final occ = ref.watch(rangeOccurrencesProvider(range)).value ?? const {};
    final tasks = ref.watch(tasksProvider).value ?? const <TaskView>[];
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    final days = [
      for (var i = 0; i < agendaDays; i++) range.first.add(Duration(days: i)),
    ];
    final showsToday = days.contains(today);
    final overdue = showsToday
        ? [
            for (final t in tasks)
              if (t.isOverdue(today)) t,
          ]
        : const <TaskView>[];

    final children = <Widget>[];
    if (overdue.isNotEmpty) {
      children.add(_DayHeader('Késésben', color: theme.colorScheme.error));
      for (final t in overdue) {
        children.add(_TaskRow(task: t, overdue: true));
      }
    }
    for (final d in days) {
      final events = [...(occ[d] ?? const <Occurrence>[])]
        ..sort((a, b) {
          if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
          return a.startUtc.compareTo(b.startUtc);
        });
      final due = [
        for (final t in tasks)
          if (!t.done && t.due == d) t,
      ];
      if (events.isEmpty && due.isEmpty) continue;
      children.add(_DayHeader(agendaDayTitle(d, today)));
      for (final o in events) {
        children.add(_EventRow(o: o, day: d, onOpen: onOpen));
      }
      for (final t in due) {
        children.add(_TaskRow(task: t));
      }
    }

    if (children.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nincs esemény és határidős feladat ebben az időszakban.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const Key('agenda-list'),
          padding: const EdgeInsets.only(bottom: 96),
          children: children,
        ),
      ),
    );
  }
}

/// The width of the time column ("07:00" over "08:30"): 52 pixels at the
/// normal text size, wider with larger text so that a time is not broken.
double _whenWidth(BuildContext context) => 52 * context.textFactor(max: 2);

class _DayHeader extends StatelessWidget {
  const _DayHeader(this.title, {this.color});
  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color),
      ),
    ),
  );
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.o, required this.day, required this.onOpen});
  final Occurrence o;
  final DateTime day;
  final OpenOccurrence onOpen;

  @override
  Widget build(BuildContext context) {
    final bg = eventColor(o.colorId);
    return Semantics(
      container: true,
      button: true,
      label: spokenEvent(o, day),
      child: InkWell(
        key: ValueKey('agenda-event-${o.eventId}-${o.originalStart}-$day'),
        onTap: () => onOpen(o),
        // (the words are in the label above)
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: _whenWidth(context),
                  child: Text(
                    agendaWhen(o, day),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Container(
                  width: 4,
                  height: 34 * context.textFactor(max: 2),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    o.title.isEmpty ? '(nincs cím)' : o.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task, this.overdue = false});
  final TaskView task;
  final bool overdue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final due = task.due == null ? '' : ', határidő: ${fmtDate(task.due!)}';
    return Semantics(
      container: true,
      button: true,
      label: overdue
          ? 'Késésben lévő feladat: ${task.title}$due'
          : 'Feladat: ${task.title}$due',
      child: InkWell(
        key: ValueKey('agenda-task-${task.id}'),
        onTap: () => openTaskEditor(context, ref, task: task),
        // (the words are in the label above)
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: _whenWidth(context),
                  child: Icon(
                    Icons.check_box_outline_blank,
                    size: 20,
                    color: overdue ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: task.title),
                        if (overdue && task.due != null)
                          TextSpan(
                            text: '  ·  határidő: ${fmtDate(task.due!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.error,
                            ),
                          )
                        else
                          TextSpan(
                            text: '  ·  feladat',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
