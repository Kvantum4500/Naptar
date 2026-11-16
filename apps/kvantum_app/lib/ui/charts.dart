import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:kvantum_core/kvantum_core.dart' show DayValue;

// The two charts of the progress page, drawn by hand (no package). What goes
// where is plain arithmetic in the functions at the top, so it can be tested
// without drawing; the painters only follow it. A chart is a picture: what it
// says is also said in words (the semantic label and the table of data under
// the charts), and no meaning rests on colour alone.

/// The usual margin at the left of a plot (it holds a short label, a number).
const double defaultPlotLeft = 34;

/// The gap between a label at the left of a bar chart and the plot.
const double barLabelGap = 4;

/// The rectangle the data is drawn in: the picture of [size] without the
/// margins that hold the labels.
Rect plotRect(
  Size size, {
  double left = defaultPlotLeft,
  double right = 8,
  double top = 10,
  double bottom = 24,
}) => Rect.fromLTRB(
  left,
  top,
  math.max(left, size.width - right),
  math.max(top, size.height - bottom),
);

/// A round upper end for a scale of minutes: the next full hour (at least
/// two, so that one short workout does not fill the picture).
int niceMinutesMax(int largest) => math.max(120, ((largest + 59) ~/ 60) * 60);

/// A round upper end for a scale of forints: 1, 1.5, 2, 3, 4, 5, 6 or 8 times a
/// power of ten (at least 10 000), the first of them that holds [largest]. The
/// steps are close enough for the tallest bar to fill at least two thirds of
/// the picture (with 1, 2 and 5 only it could be half).
int niceMoneyMax(int largest) {
  for (var step = 10000; ; step *= 10) {
    for (final tenths in const [10, 15, 20, 30, 40, 50, 60, 80]) {
      final top = step * tenths ~/ 10;
      if (top >= largest) return top;
    }
  }
}

/// A round upper end for a scale of a count (calories, millilitres): 1, 1.5,
/// 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten (at least 1000), the first of
/// them that holds [largest].
int niceCountMax(int largest) {
  for (var step = 1000; ; step *= 10) {
    for (final tenths in const [10, 15, 20, 25, 30, 40, 50, 60, 80]) {
      final top = step * tenths ~/ 10;
      if (top >= largest) return top;
    }
  }
}

/// The height of the line of a goal on the plot of a bar chart that runs from
/// 0 to [max]; null when there is no goal.
double? goalY(Rect plot, double? goal, double max) =>
    goal == null || goal <= 0 ? null : valueY(plot, goal, 0, max);

/// The label of the goal line: at the right end, just above the line, or just
/// under it when the line is so near the top of the picture that the label
/// would be cut off.
ChartLabel goalLabelAt(Rect plot, double y, String text) => ChartLabel(
  text,
  Offset(plot.right, y - 8 < plot.top - 4 ? y + 8 : y - 8),
  right: true,
);

/// The dashes of a line from [from] to [to] (x), each [dash] long with a [gap]
/// between; the last one is cut at [to].
List<(double, double)> dashSegments(
  double from,
  double to, {
  double dash = 6,
  double gap = 4,
}) {
  final out = <(double, double)>[];
  for (var x = from; x < to; x += dash + gap) {
    out.add((x, math.min(x + dash, to)));
  }
  return out;
}

/// The indexes of the bars that are above the goal (none without a goal).
List<int> overGoal(List<double> values, double? goal) => goal == null
    ? const []
    : [
        for (var i = 0; i < values.length; i++)
          if (values[i] > goal) i,
      ];

/// The corners of the little arrow over a bar that is above the goal: it points
/// up, its base 3 above the bar and its tip 9.
List<Offset> overMarker(Rect bar) => [
  Offset(bar.center.dx - 3.5, bar.top - 3),
  Offset(bar.center.dx + 3.5, bar.top - 3),
  Offset(bar.center.dx, bar.top - 9),
];

/// How wide [text] is when it is drawn in [style] at the text size [scaler]
/// gives.
double labelWidth(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The margin at the left of a bar chart whose label of the top of the scale is
/// [labelWidth] wide: room for the label, its gap to the plot and a little air
/// at the edge of the picture, but never less than the usual margin (a label
/// of "500 e Ft" is wider than that, and would be cut off at the edge).
double plotLeftFor(double labelWidth) =>
    math.max(defaultPlotLeft, labelWidth + barLabelGap + 2);

/// The bars of [values] (0 … [maxValue]) in equal slots across [plot], each
/// bar [gap] of its slot narrower than the slot and standing on the bottom of
/// the plot. A value above the maximum is cut to it; nothing is below zero.
List<Rect> barRects(
  Rect plot,
  List<double> values,
  double maxValue, {
  double gap = 0.3,
}) {
  if (values.isEmpty) return const [];
  final slot = plot.width / values.length;
  final width = slot * (1 - gap);
  return [
    for (var i = 0; i < values.length; i++)
      () {
        final share = maxValue <= 0
            ? 0.0
            : (values[i] / maxValue).clamp(0.0, 1.0);
        final h = plot.height * share;
        final left = plot.left + slot * i + (slot - width) / 2;
        return Rect.fromLTWH(left, plot.bottom - h, width, h);
      }(),
  ];
}

/// Where a day is across the plot, for a chart that runs from [from] to [to];
/// a chart of one day has it in the middle.
double dayX(Rect plot, DateTime day, DateTime from, DateTime to) {
  final span = to.difference(from).inDays;
  if (span <= 0) return plot.center.dx;
  final at = day.difference(from).inDays.clamp(0, span);
  return plot.left + plot.width * at / span;
}

/// Where a value is up the plot, on a scale from [min] to [max].
double valueY(Rect plot, double value, double min, double max) {
  if (max <= min) return plot.center.dy;
  final share = ((value - min) / (max - min)).clamp(0.0, 1.0);
  return plot.bottom - plot.height * share;
}

// ---------------------------------------------------------------- labels

/// One word of a chart: [text], with its vertical middle at `at.dy`, starting
/// at `at.dx` (or ending there, when [right]).
class ChartLabel {
  const ChartLabel(this.text, this.at, {this.right = false});

  final String text;
  final Offset at;
  final bool right;

  @override
  bool operator ==(Object other) =>
      other is ChartLabel &&
      other.text == text &&
      other.at == at &&
      other.right == right;

  @override
  int get hashCode => Object.hash(text, at, right);

  @override
  String toString() => 'ChartLabel("$text", $at${right ? ', right' : ''})';
}

/// The values a scale from [min] to [max] is marked at: every whole number
/// from the first to the last (1 … 5 for the answers of a check-in).
List<double> scaleValues(double min, double max) => [
  for (var v = min.round(); v <= max.round(); v++) v.toDouble(),
];

/// The words around a bar chart: the top of the scale and the 0 at its left,
/// the first week and the last under the bars.
List<ChartLabel> barLabels(
  Rect plot, {
  required String maxLabel,
  required String firstLabel,
  required String lastLabel,
}) => [
  ChartLabel(maxLabel, Offset(plot.left - barLabelGap, plot.top), right: true),
  ChartLabel('0', Offset(plot.left - barLabelGap, plot.bottom), right: true),
  ChartLabel(firstLabel, Offset(plot.left, plot.bottom + 12)),
  ChartLabel(lastLabel, Offset(plot.right, plot.bottom + 12), right: true),
];

/// The words around a line chart: the scale at the left (a number for each of
/// its values), the first day and the last under the lines.
List<ChartLabel> lineLabels(
  Rect plot, {
  required double min,
  required double max,
  required String firstLabel,
  required String lastLabel,
}) => [
  for (final v in scaleValues(min, max))
    ChartLabel(
      '${v.round()}',
      Offset(plot.left - 6, valueY(plot, v, min, max)),
      right: true,
    ),
  ChartLabel(firstLabel, Offset(plot.left, plot.bottom + 12)),
  ChartLabel(lastLabel, Offset(plot.right, plot.bottom + 12), right: true),
];

// ---------------------------------------------------------------- markers

/// The shape that marks a series, so that two lines differ by more than their
/// colour.
enum LineMarker {
  circle(Icons.circle),
  square(Icons.square),
  triangle(Icons.change_history),
  diamond(Icons.diamond);

  const LineMarker(this.icon);

  /// The same shape as an icon (for the legend).
  final IconData icon;
}

/// One line of a line chart.
class LineSeries {
  const LineSeries({
    required this.label,
    required this.color,
    required this.marker,
    required this.dots,
    required this.line,
    this.markAll = false,
  });

  final String label;
  final Color color;
  final LineMarker marker;

  /// The single values (small, faint) …
  final List<DayValue> dots;

  /// … and the line drawn through these (its last point is marked).
  final List<DayValue> line;

  /// A marker at every point of the line, not only at the last (for a line of
  /// a few points).
  final bool markAll;
}

// ---------------------------------------------------------------- painting

void _paintLabel(
  Canvas canvas,
  ChartLabel label,
  TextStyle style,
  TextScaler scaler,
) {
  final painter = TextPainter(
    text: TextSpan(text: label.text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final dx = label.right ? label.at.dx - painter.width : label.at.dx;
  painter.paint(canvas, Offset(dx, label.at.dy - painter.height / 2));
}

/// Bars on a scale from 0 to [maxValue]; the last bar is the week that is not
/// over yet.
class BarChartPainter extends CustomPainter {
  const BarChartPainter({
    required this.values,
    required this.maxValue,
    required this.barColor,
    required this.gridColor,
    required this.labelStyle,
    required this.textScaler,
    required this.maxLabel,
    required this.firstLabel,
    required this.lastLabel,
    this.plotLeft = defaultPlotLeft,
    this.goal,
    this.goalLabel,
    this.goalColor = const Color(0xFF616161),
    this.overColor = const Color(0xFFB3261E),
  });

  final List<double> values;
  final double maxValue;
  final Color barColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final String maxLabel;
  final String firstLabel;
  final String lastLabel;

  /// The margin at the left, for the labels of the scale ([plotLeftFor]).
  final double plotLeft;

  /// A goal to draw as a dashed line across the plot (with [goalLabel] at its
  /// right end); a bar above it gets a little arrow over it, so that the
  /// difference is not told by colour alone. No goal, no line.
  final double? goal;
  final String? goalLabel;
  final Color goalColor;
  final Color overColor;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotRect(size, left: plotLeft);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final share in const [0.0, 0.5, 1.0]) {
      final y = plot.bottom - plot.height * share;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    final paint = Paint()..color = barColor;
    final rects = barRects(plot, values, maxValue);
    for (final bar in rects) {
      if (bar.height <= 0) continue;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          bar,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        paint,
      );
    }
    final goalAt = goalY(plot, goal, maxValue);
    if (goalAt != null) {
      final dashes = Path();
      for (final (from, to) in dashSegments(plot.left, plot.right)) {
        dashes
          ..moveTo(from, goalAt)
          ..lineTo(to, goalAt);
      }
      canvas.drawPath(
        dashes,
        Paint()
          ..color = goalColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final over = overGoal(values, goal);
      if (over.isNotEmpty) {
        final arrows = Path();
        for (final i in over) {
          final corners = overMarker(rects[i]);
          arrows
            ..moveTo(corners[0].dx, corners[0].dy)
            ..lineTo(corners[1].dx, corners[1].dy)
            ..lineTo(corners[2].dx, corners[2].dy)
            ..close();
        }
        canvas.drawPath(arrows, Paint()..color = overColor);
      }
      final text = goalLabel;
      if (text != null) {
        _paintLabel(
          canvas,
          goalLabelAt(plot, goalAt, text),
          labelStyle,
          textScaler,
        );
      }
    }
    for (final label in barLabels(
      plot,
      maxLabel: maxLabel,
      firstLabel: firstLabel,
      lastLabel: lastLabel,
    )) {
      _paintLabel(canvas, label, labelStyle, textScaler);
    }
  }

  @override
  bool shouldRepaint(BarChartPainter old) =>
      !listEquals(old.values, values) ||
      old.maxValue != maxValue ||
      old.barColor != barColor ||
      old.gridColor != gridColor ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      old.maxLabel != maxLabel ||
      old.firstLabel != firstLabel ||
      old.lastLabel != lastLabel ||
      old.plotLeft != plotLeft ||
      old.goal != goal ||
      old.goalLabel != goalLabel ||
      old.goalColor != goalColor ||
      old.overColor != overColor;
}

/// Lines on a scale from [min] to [max] (the answers of a check-in: 1 … 5).
class LineChartPainter extends CustomPainter {
  const LineChartPainter({
    required this.series,
    required this.from,
    required this.to,
    required this.gridColor,
    required this.labelStyle,
    required this.textScaler,
    required this.firstLabel,
    required this.lastLabel,
    this.min = 1,
    this.max = 5,
  });

  final List<LineSeries> series;
  final DateTime from;
  final DateTime to;
  final Color gridColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final String firstLabel;
  final String lastLabel;
  final double min;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotRect(size);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final v in scaleValues(min, max)) {
      final y = valueY(plot, v, min, max);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    for (final s in series) {
      Offset at(DayValue p) =>
          Offset(dayX(plot, p.day, from, to), valueY(plot, p.value, min, max));
      final dot = Paint()..color = s.color.withValues(alpha: 0.35);
      for (final p in s.dots) {
        canvas.drawCircle(at(p), 2.2, dot);
      }
      if (s.line.isEmpty) continue;
      final stroke = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path()..moveTo(at(s.line.first).dx, at(s.line.first).dy);
      for (final p in s.line.skip(1)) {
        path.lineTo(at(p).dx, at(p).dy);
      }
      canvas.drawPath(path, stroke);
      final fill = Paint()..color = s.color;
      for (final p in s.markAll ? s.line : [s.line.last]) {
        _marker(canvas, s.marker, at(p), fill);
      }
    }
    for (final label in lineLabels(
      plot,
      min: min,
      max: max,
      firstLabel: firstLabel,
      lastLabel: lastLabel,
    )) {
      _paintLabel(canvas, label, labelStyle, textScaler);
    }
  }

  static void _marker(Canvas canvas, LineMarker m, Offset c, Paint paint) {
    const r = 5.0;
    switch (m) {
      case LineMarker.circle:
        canvas.drawCircle(c, r, paint);
      case LineMarker.square:
        canvas.drawRect(Rect.fromCircle(center: c, radius: r - 0.5), paint);
      case LineMarker.triangle:
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - r)
            ..lineTo(c.dx + r, c.dy + r * 0.8)
            ..lineTo(c.dx - r, c.dy + r * 0.8)
            ..close(),
          paint,
        );
      case LineMarker.diamond:
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - r)
            ..lineTo(c.dx + r, c.dy)
            ..lineTo(c.dx, c.dy + r)
            ..lineTo(c.dx - r, c.dy)
            ..close(),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(LineChartPainter old) =>
      old.series != series ||
      old.from != from ||
      old.to != to ||
      old.gridColor != gridColor ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      old.firstLabel != firstLabel ||
      old.lastLabel != lastLabel ||
      old.min != min ||
      old.max != max;
}

// ---------------------------------------------------------------- widgets

/// A bar chart with its words: [semanticLabel] is what a screen reader says
/// in place of the picture.
class BarChart extends StatelessWidget {
  const BarChart({
    super.key,
    required this.values,
    required this.maxValue,
    required this.maxLabel,
    required this.firstLabel,
    required this.lastLabel,
    required this.semanticLabel,
    this.height = 170,
    this.color,
    this.goal,
    this.goalLabel,
  });

  final List<double> values;
  final double maxValue;
  final String maxLabel;
  final String firstLabel;
  final String lastLabel;
  final String semanticLabel;
  final double height;

  /// The colour of the bars; the primary colour of the theme when null.
  final Color? color;

  /// A goal drawn as a dashed line, with its label (see [BarChartPainter]).
  final double? goal;
  final String? goalLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final scaler = _chartScaler(context);
    return Semantics(
      container: true,
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: BarChartPainter(
              values: values,
              maxValue: maxValue,
              barColor: color ?? theme.colorScheme.primary,
              gridColor: theme.colorScheme.outlineVariant,
              labelStyle: style,
              textScaler: scaler,
              maxLabel: maxLabel,
              firstLabel: firstLabel,
              lastLabel: lastLabel,
              plotLeft: plotLeftFor(labelWidth(maxLabel, style, scaler)),
              goal: goal,
              goalLabel: goalLabel,
              goalColor: theme.colorScheme.onSurfaceVariant,
              overColor: theme.colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }
}

/// A line chart with its words.
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.series,
    required this.from,
    required this.to,
    required this.firstLabel,
    required this.lastLabel,
    required this.semanticLabel,
    this.height = 190,
  });

  final List<LineSeries> series;
  final DateTime from;
  final DateTime to;
  final String firstLabel;
  final String lastLabel;
  final String semanticLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: LineChartPainter(
              series: series,
              from: from,
              to: to,
              gridColor: theme.colorScheme.outlineVariant,
              labelStyle: (theme.textTheme.labelSmall ?? const TextStyle())
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
              textScaler: _chartScaler(context),
              firstLabel: firstLabel,
              lastLabel: lastLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// The labels of a chart follow the system text size up to 1.3 times: a
/// picture has no room to grow beyond that, and everything it says is in
/// words as well.
TextScaler _chartScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
