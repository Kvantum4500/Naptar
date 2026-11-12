import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'breakpoints.dart';
import 'day_utils.dart';
import 'format.dart';
import 'palette.dart';

typedef OpenOccurrence = void Function(Occurrence o);

/// Month grid. A wide cell shows colour bars with the title (and the time, if
/// it fits) and a "+N további" link; a narrow one (a phone held upright) only
/// coloured dots, one per event, because a few letters of a title say nothing.
/// The day list under or beside the grid names the events of the chosen day.
/// Adapts to any window size: what does not fit is clipped, nothing overflows.
class MonthView extends ConsumerWidget {
  const MonthView({super.key, required this.onOpen, required this.onMore});
  final OpenOccurrence onOpen;
  final void Function(DateTime day) onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(visibleMonthProvider);
    final selected = ref.watch(selectedDayProvider);
    final occ = ref.watch(monthOccurrencesProvider).value ?? const {};
    final cells = monthGrid(month);
    final today = ref.watch(todayProvider);
    final scheme = Theme.of(context).colorScheme;
    final names = [
      for (var i = 0; i < 7; i++)
        DateFormat.E('hu').format(DateTime(2024, 1, 1 + i)),
    ];
    return Column(
      children: [
        Row(
          children: [
            for (final n in names)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Center(
                    child: Text(
                      n,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              for (var w = 0; w < 6; w++)
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < 7; i++)
                        Expanded(
                          child: _DayCell(
                            day: cells[w * 7 + i],
                            inMonth: cells[w * 7 + i].month == month.month,
                            selected: cells[w * 7 + i] == selected,
                            today: _isToday(cells[w * 7 + i], today),
                            items: occ[cells[w * 7 + i]] ?? const [],
                            scheme: scheme,
                            onTapDay: () => ref
                                .read(selectedDayProvider.notifier)
                                .set(cells[w * 7 + i]),
                            onOpen: onOpen,
                            onMore: onMore,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static bool _isToday(DateTime d, DateTime now) =>
      d.year == now.year && d.month == now.month && d.day == now.day;
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.items,
    required this.scheme,
    required this.onTapDay,
    required this.onOpen,
    required this.onMore,
  });

  final DateTime day;
  final bool inMonth, selected, today;
  final List<Occurrence> items;
  final ColorScheme scheme;
  final VoidCallback onTapDay;
  final OpenOccurrence onOpen;
  final void Function(DateTime) onMore;

  static const double _head = 26, _line = 18;

  /// A cell at least this wide has room for "18:00 " before the title.
  static const double _timeFromWidth = 92;

  @override
  Widget build(BuildContext context) {
    // All-day first, then by start time.
    final sorted = [...items]
      ..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.startUtc.compareTo(b.startUtc);
      });
    return Semantics(
      label: '${day.year}. ${day.month}. ${day.day}., ${items.length} esemény',
      button: true,
      child: InkWell(
        onTap: onTapDay,
        child: Container(
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: .55)
                : null,
            border: Border.all(
              color: today
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: .5),
              width: today ? 1.6 : 0.6,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              // a narrow cell: dots instead of text bars
              final dots = c.maxWidth < Breakpoints.dotCell;
              // padding (4) + header (22) are fixed; the rest holds 18 px rows
              final fit = dots
                  ? 0
                  : ((c.maxHeight - 4 - (_head - 4)) / _line).floor().clamp(
                      0,
                      12,
                    );
              final overflow = sorted.length > fit;
              // keep one row for the "+N további" link when needed
              final shown = fit == 0 ? 0 : (overflow ? fit - 1 : sorted.length);
              final hidden = fit == 0 ? 0 : sorted.length - shown;
              // the time before the title only where it leaves room for it
              final showTime = c.maxWidth >= _timeFromWidth;
              // A cell too short for its content clips it instead of
              // overflowing (a small window, a large text size).
              return ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(3, 2, 3, 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: _head - 4,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
                              decoration: today
                                  ? BoxDecoration(
                                      color: scheme.primary,
                                      borderRadius: BorderRadius.circular(10),
                                    )
                                  : null,
                              child: Text(
                                !dots && fit == 0 && sorted.isNotEmpty
                                    ? '${day.day} •'
                                    : '${day.day}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: today
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: today
                                      ? scheme.onPrimary
                                      : (inMonth
                                            ? scheme.onSurface
                                            : scheme.outline),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (dots)
                          _Dots(items: sorted, scheme: scheme)
                        else
                          for (final o in sorted.take(shown))
                            _Chip(
                              o: o,
                              day: day,
                              onOpen: onOpen,
                              showTime: showTime,
                            ),
                        if (hidden > 0)
                          SizedBox(
                            height: _line,
                            child: InkWell(
                              onTap: () => onMore(day),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 3),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '+$hidden további',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One coloured dot per event (the first few, then "+N"), for a narrow cell.
class _Dots extends StatelessWidget {
  const _Dots({required this.items, required this.scheme});
  final List<Occurrence> items;
  final ColorScheme scheme;

  static const _max = 4;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final more = items.length > _max ? items.length - (_max - 1) : 0;
    final shown = more > 0 ? _max - 1 : items.length;
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(left: 2, top: 1),
        child: Wrap(
          key: const Key('month-dots'),
          spacing: 2,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final o in items.take(shown))
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: eventColor(o.colorId),
                  shape: BoxShape.circle,
                ),
              ),
            if (more > 0)
              Text(
                '+$more',
                style: TextStyle(
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.o,
    required this.day,
    required this.onOpen,
    required this.showTime,
  });
  final Occurrence o;
  final DateTime day;
  final OpenOccurrence onOpen;

  /// Whether the start time goes before the title (it does not in a cell too
  /// narrow to show more than a few letters).
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final bg = eventColor(o.colorId);
    final fg = onEventColor(bg);
    final startsToday =
        o.allDay ||
        dateOnly(toWallClock(o.tzid ?? defaultTz, o.startUtc)) == day;
    final time = (showTime && !o.allDay && startsToday)
        ? '${fmtTime(toWallClock(o.tzid ?? defaultTz, o.startUtc))} '
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: SizedBox(
        height: 17,
        child: Material(
          color: o.allDay ? bg : bg.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onOpen(o),
            child: Row(
              children: [
                if (!o.allDay) Container(width: 3, color: bg),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '$time${o.title.isEmpty ? '(nincs cím)' : o.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.1,
                        color: o.allDay
                            ? fg
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
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
