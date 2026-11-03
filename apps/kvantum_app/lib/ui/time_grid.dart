import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'day_utils.dart';
import 'format.dart';
import 'layout.dart';
import 'month_view.dart' show OpenOccurrence;
import 'palette.dart';

const double kHourHeight = 56;
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
  });

  final List<DateTime> days;
  final DayRange range;
  final OpenOccurrence onOpen;

  /// Floating wall-clock start (15 min snapped) of an empty slot the user tapped.
  final void Function(DateTime wallStart) onCreateAt;
  final void Function(DateTime day)? onDayTap;

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

  DateTime _nowWall() => toWallClock(defaultTz, DateTime.now().toUtc());

  void _initialScroll() {
    if (_positioned || !_scroll.hasClients) return;
    _positioned = true;
    final now = _nowWall();
    final showsToday = widget.days.contains(dateOnly(now));
    final focusMin = showsToday ? now.hour * 60 + now.minute : 7 * 60;
    final target = (focusMin / 60 - 1) * kHourHeight;
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final occ =
        ref.watch(rangeOccurrencesProvider(widget.range)).value ?? const {};
    final scheme = Theme.of(context).colorScheme;
    final today = dateOnly(_nowWall());
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
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: _labelWidth),
                  for (final d in widget.days)
                    SizedBox(
                      width: colW,
                      child: InkWell(
                        onTap: widget.onDayTap == null
                            ? null
                            : () => widget.onDayTap!(d),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              DateFormat.E('hu')
                                  .format(DateTime(d.year, d.month, d.day)),
                              style: Theme.of(context).textTheme.labelMedium,
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
                                      borderRadius: BorderRadius.circular(12),
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
                ],
              ),
            ),
            // ---- all-day strip
            if (maxAllDay > 0)
              Container(
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
                        child: Text(
                          'egész nap',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 10),
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
                                _AllDayBar(o: o, onOpen: widget.onOpen),
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
            // ---- scrollable hour grid
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                child: SizedBox(
                  height: 24 * kHourHeight,
                  child: Row(
                    children: [
                      SizedBox(
                        width: _labelWidth,
                        child: Stack(
                          children: [
                            for (var h = 1; h < 24; h++)
                              Positioned(
                                top: h * kHourHeight - 7,
                                right: 6,
                                child: Text(
                                  '${h.toString().padLeft(2, '0')}:00',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.outline,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (final d in widget.days)
                        SizedBox(
                          width: colW,
                          child: _DayColumn(
                            day: d,
                            width: colW,
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
  const _AllDayBar({required this.o, required this.onOpen});
  final Occurrence o;
  final OpenOccurrence onOpen;
  @override
  Widget build(BuildContext context) {
    final bg = eventColor(o.colorId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: SizedBox(
        height: 18,
        width: double.infinity,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            onTap: () => onOpen(o),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
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
    required this.items,
    required this.nowWall,
    required this.onOpen,
    required this.onCreateAt,
  });

  final DateTime day;
  final double width;
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
        final min = snapMinutes(d.localPosition.dy / kHourHeight * 60);
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
                top: h * kHourHeight,
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
                    (nowWall!.hour * 60 + nowWall!.minute) / 60 * kHourHeight -
                    1,
                left: 0,
                right: 0,
                child: Container(height: 2, color: scheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, Placed<Occurrence> p) {
    final o = p.item.data;
    final bg = eventColor(o.colorId);
    final top = p.item.startMin / 60 * kHourHeight;
    final h =
        ((p.item.endMin - p.item.startMin).clamp(20, 24 * 60)) /
        60 *
        kHourHeight;
    final colW = (width - 3) / p.columns;
    final tz = o.tzid ?? defaultTz;
    final s = toWallClock(tz, o.startUtc), e = toWallClock(tz, o.endUtc);
    return Positioned(
      top: top,
      left: 1.5 + p.column * colW,
      width: colW - 1.5,
      height: h - 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(o),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  o.title.isEmpty ? '(nincs cím)' : o.title,
                  maxLines: h > 40 ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: onEventColor(bg),
                  ),
                ),
                if (h > 34)
                  Text(
                    '${fmtTime(s)}–${fmtTime(e)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: onEventColor(bg).withValues(alpha: .85),
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
