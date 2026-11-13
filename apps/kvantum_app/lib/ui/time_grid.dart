import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'a11y.dart';
import 'day_utils.dart';
import 'format.dart';
import 'layout.dart';
import 'month_view.dart' show OpenOccurrence;
import 'palette.dart';
import 'text_scale.dart';

/// The height of an hour at the normal text size.
const double kHourHeight = 56;

/// The height of an hour at the user's text size: it grows with the text (up to
/// 1.6 times) so that an hour-long event still holds its title and its time.
double hourHeightOf(BuildContext context) =>
    kHourHeight * context.textFactor(max: 1.6);
const double _labelWidth = 52;

/// Week / day view with an hour scale. [days] are floating dates (1 or 7).
class TimeGrid extends ConsumerStatefulWidget {
  const TimeGrid({
    super.key,
    required this.days,
    required this.range,
    required this.onOpen,
    required this.onCreateAt,
    this.onDayTap,
    this.showDayHeader = true,
  });

  final List<DateTime> days;
  final DayRange range;
  final OpenOccurrence onOpen;

  /// Floating wall-clock start (15 min snapped) of an empty slot the user tapped.
  final void Function(DateTime wallStart) onCreateAt;
  final void Function(DateTime day)? onDayTap;

  /// The weekday/number header is hidden when the grid is embedded under a
  /// panel title that already names the day.
  final bool showDayHeader;

  @override
  ConsumerState<TimeGrid> createState() => _TimeGridState();
}

class _TimeGridState extends ConsumerState<TimeGrid> {
  final _scroll = ScrollController();
  Timer? _tick;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    // Keeps the "now" line current.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // (the app's clock, so that "today" here agrees with the other views and a
  // test can set the day)
  DateTime _nowWall() =>
      toWallClock(defaultTz, ref.read(appClockProvider)().toUtc());

  void _initialScroll() {
    if (_positioned || !_scroll.hasClients) return;
    _positioned = true;
    final now = _nowWall();
    final showsToday = widget.days.contains(dateOnly(now));
    final focusMin = showsToday ? now.hour * 60 + now.minute : 7 * 60;
    final target = (focusMin / 60 - 1) * hourHeightOf(context);
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final occ =
        ref.watch(rangeOccurrencesProvider(widget.range)).value ?? const {};
    final scheme = Theme.of(context).colorScheme;
    final today = dateOnly(_nowWall());
    final hourH = hourHeightOf(context);
    // The header holds a day name and a number; its labels grow with the text
    // size up to a cap (see GridLabelScale), and so does the room for them.
    final capped = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: kGridLabelMaxScale);
    final headerH = math.max(
      52.0,
      capped.scale(12) * 1.34 + 2 + capped.scale(16) * 1.2 + 4 + 8,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialScroll());

    final allDay = <DateTime, List<Occurrence>>{
      for (final d in widget.days)
        d: [...(occ[d] ?? const []).where((o) => o.allDay)],
    };
    final maxAllDay = allDay.values.fold<int>(
      0,
      (m, l) => l.length > m ? l.length : m,
    );

    return LayoutBuilder(
      builder: (context, c) {
        final colW = (c.maxWidth - _labelWidth) / widget.days.length;
        return Column(
          children: [
            // ---- day headers
            if (widget.showDayHeader)
              SizedBox(
                height: headerH,
                child: GridLabelScale(
                  child: Row(
                    children: [
                      const SizedBox(width: _labelWidth),
                      for (final d in widget.days)
                        SizedBox(
                          width: colW,
                          child: Semantics(
                            container: true,
                            button: widget.onDayTap != null,
                            label: d == today
                                ? '${spokenDay(d)}, ma'
                                : spokenDay(d),
                            child: InkWell(
                              onTap: widget.onDayTap == null
                                  ? null
                                  : () => widget.onDayTap!(d),
                              // (the words are in the label above)
                              child: ExcludeSemantics(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      DateFormat.E('hu').format(
                                        DateTime(d.year, d.month, d.day),
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                    const SizedBox(height: 2),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: d == today
                                          ? BoxDecoration(
                                              color: scheme.primary,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            )
                                          : null,
                                      child: Text(
                                        '${d.day}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: d == today
                                              ? scheme.onPrimary
                                              : scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            // ---- all-day strip
            // (in a short space - a small window, large text, a day panel
            // under a month - it takes at most half of what the header
            // leaves, and scrolls: the hours below are never squeezed out)
            if (maxAllDay > 0)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(
                    0.0,
                    (c.maxHeight - (widget.showDayHeader ? headerH : 0)) / 2,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: scheme.outlineVariant),
                        bottom: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: _labelWidth,
                          child: const Padding(
                            padding: EdgeInsets.only(top: 6, right: 6),
                            child: GridLabelScale(
                              child: Text(
                                'egész nap',
                                textAlign: TextAlign.right,
                                style: TextStyle(fontSize: 10),
                              ),
                            ),
                          ),
                        ),
                        for (final d in widget.days)
                          SizedBox(
                            width: colW,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 2,
                                horizontal: 1,
                              ),
                              child: Column(
                                children: [
                                  for (final o in allDay[d]!.take(3))
                                    _AllDayBar(
                                      o: o,
                                      day: d,
                                      onOpen: widget.onOpen,
                                    ),
                                  if (allDay[d]!.length > 3)
                                    Text(
                                      '+${allDay[d]!.length - 3} további',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.primary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            // ---- scrollable hour grid
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                child: SizedBox(
                  height: 24 * hourH,
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: GridLabelScale(
                          child: SizedBox(
                            width: _labelWidth,
                            child: Stack(
                              children: [
                                for (var h = 1; h < 24; h++)
                                  Positioned(
                                    top: h * hourH - 7,
                                    right: 6,
                                    child: Text(
                                      '${h.toString().padLeft(2, '0')}:00',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      for (final d in widget.days)
                        SizedBox(
                          width: colW,
                          child: _DayColumn(
                            day: d,
                            width: colW,
                            hourHeight: hourH,
                            items: (occ[d] ?? const [])
                                .where((o) => !o.allDay)
                                .toList(),
                            nowWall: d == today ? _nowWall() : null,
                            onOpen: widget.onOpen,
                            onCreateAt: widget.onCreateAt,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AllDayBar extends StatelessWidget {
  const _AllDayBar({required this.o, required this.day, required this.onOpen});
  final Occurrence o;
  final DateTime day;
  final OpenOccurrence onOpen;
  @override
  Widget build(BuildContext context) {
    final bg = eventColor(o.colorId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Semantics(
        container: true,
        button: true,
        label: spokenEvent(o, day, withDay: true),
        child: SizedBox(
          height: 18 * context.textFactor(),
          width: double.infinity,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: () => onOpen(o),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ExcludeSemantics(
                  child: Text(
                    o.title.isEmpty ? '(nincs cím)' : o.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: onEventColor(bg)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wall-clock minutes of [o] inside [day], clipped to the day (DST-safe: the
/// grid is positioned by wall-clock time, like every other calendar).
DayItem<Occurrence>? dayItemFor(
  Occurrence o,
  DateTime day, {
  String tz = defaultTz,
}) {
  final s = toWallClock(o.tzid ?? tz, o.startUtc);
  final e = toWallClock(o.tzid ?? tz, o.endUtc);
  final next = day.add(const Duration(days: 1));
  if (!e.isAfter(day) && e != s) return null;
  if (!s.isBefore(next)) return null;
  final sm = s.isBefore(day) ? 0 : s.difference(day).inMinutes;
  final em = e.isAfter(next) ? 24 * 60 : e.difference(day).inMinutes;
  return DayItem(o, sm.clamp(0, 24 * 60), em.clamp(0, 24 * 60));
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.width,
    required this.hourHeight,
    required this.items,
    required this.nowWall,
    required this.onOpen,
    required this.onCreateAt,
  });

  final DateTime day;
  final double width;
  final double hourHeight;
  final List<Occurrence> items;
  final DateTime? nowWall;
  final OpenOccurrence onOpen;
  final void Function(DateTime) onCreateAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placed = layoutDay<Occurrence>([
      for (final o in items) ?dayItemFor(o, day),
    ]);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final min = snapMinutes(d.localPosition.dy / hourHeight * 60);
        onCreateAt(day.add(Duration(minutes: min)));
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .6),
            ),
          ),
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var h = 1; h < 24; h++)
              Positioned(
                top: h * hourHeight,
                left: 0,
                right: 0,
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: scheme.outlineVariant.withValues(alpha: .6),
                ),
              ),
            for (final p in placed) _block(context, p),
            if (nowWall != null)
              Positioned(
                top:
                    (nowWall!.hour * 60 + nowWall!.minute) / 60 * hourHeight -
                    1,
                left: 0,
                right: 0,
                // Only a marker: a tap or drag goes through to the event (or the
                // empty hour) under it. Without this, the 2 pixels of the line
                // swallowed the tap whenever it lay over an event's title.
                child: IgnorePointer(
                  key: const Key('now-line'),
                  child: Container(height: 2, color: scheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, Placed<Occurrence> p) {
    final o = p.item.data;
    final bg = eventColor(o.colorId);
    // What fits is decided by the height of the lines at the user's text size
    // (an hour-long block holds a two-line title and the time; a 45-minute one
    // two lines; a half-hour one a line), never by a guess.
    final titleH = context.scaled(_titleSize) * _lineHeight;
    final timeH = context.scaled(_timeSize) * _lineHeight;
    final top = p.item.startMin / 60 * hourHeight;
    final h = math.max(
      ((p.item.endMin - p.item.startMin).clamp(20, 24 * 60)) / 60 * hourHeight,
      // (a short event is still tall enough for one line of its title)
      titleH + _padding + 1,
    );
    final inner = h - 1 - _padding;
    final titleLines = (inner / titleH).floor().clamp(1, 2);
    final colW = (width - 3) / p.columns;
    // "10:00–11:00" is about six times its font size wide: in a narrower
    // block (a week on a phone) it would break into pieces, so it is left out
    final timeW = context.scaled(_timeSize) * 6.2;
    final showTime =
        inner >= titleLines * titleH + timeH && colW - 1.5 - 8 >= timeW;
    final tz = o.tzid ?? defaultTz;
    final s = toWallClock(tz, o.startUtc), e = toWallClock(tz, o.endUtc);
    return Positioned(
      top: top,
      left: 1.5 + p.column * colW,
      width: colW - 1.5,
      height: h - 1,
      child: Semantics(
        container: true,
        button: true,
        label: spokenEvent(o, day, withDay: true),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(5),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onOpen(o),
            child: ExcludeSemantics(
              // (a safety net: what does not fit is cut off, not reported)
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          o.title.isEmpty ? '(nincs cím)' : o.title,
                          maxLines: titleLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: _titleSize,
                            height: _lineHeight,
                            fontWeight: FontWeight.w600,
                            color: onEventColor(bg),
                          ),
                        ),
                        if (showTime)
                          Text(
                            '${fmtTime(s)}–${fmtTime(e)}',
                            style: TextStyle(
                              fontSize: _timeSize,
                              height: _lineHeight,
                              color: onEventColor(bg),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const double _titleSize = 12, _timeSize = 10, _lineHeight = 1.2;
  static const double _padding = 4;
}
