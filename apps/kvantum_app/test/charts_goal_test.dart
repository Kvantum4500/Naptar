import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/charts.dart';

/// The goal line of a bar chart (8th round: the food and fluid log): where it
/// goes, how it is drawn, and that a bar above it is marked by a shape and not
/// by colour alone.
void main() {
  const size = Size(300, 150);
  const grey = Color(0xFF9E9E9E);
  const blue = Color(0xFF1565C0);
  const dark = Color(0xFF424242);
  const red = Color(0xFFB3261E);
  const style = TextStyle(fontSize: 11, color: Colors.black);
  final plot = plotRect(size);

  group('the top of a scale of counts', () {
    test('is 1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten', () {
      expect(niceCountMax(0), 1000);
      expect(niceCountMax(1000), 1000);
      expect(niceCountMax(1001), 1500);
      expect(niceCountMax(1500), 1500);
      expect(niceCountMax(1501), 2000);
      expect(niceCountMax(2000), 2000);
      expect(niceCountMax(2001), 2500);
      expect(niceCountMax(2500), 2500);
      expect(niceCountMax(2501), 3000);
      expect(niceCountMax(3001), 4000);
      expect(niceCountMax(4001), 5000);
      expect(niceCountMax(5001), 6000);
      expect(niceCountMax(6001), 8000);
      expect(niceCountMax(8000), 8000);
      expect(niceCountMax(8001), 10000);
      expect(niceCountMax(12000), 15000);
    });

    test('lets the tallest bar fill at least two thirds of the picture', () {
      for (var n = 1; n < 30000; n += 37) {
        final top = niceCountMax(n);
        expect(top, greaterThanOrEqualTo(n));
        if (n >= 1000) {
          expect(n / top, greaterThanOrEqualTo(0.62), reason: '$n');
        }
      }
    });
  });

  group('where the goal is', () {
    test('its height on the plot, on a scale from 0 to the top', () {
      expect(
        goalY(plot, 60, 120),
        closeTo(plot.bottom - plot.height / 2, 0.01),
      );
      expect(goalY(plot, 120, 120), closeTo(plot.top, 0.01));
      expect(
        goalY(plot, 30, 120),
        closeTo(plot.bottom - plot.height / 4, 0.01),
      );
    });

    test('a goal above the top is held at the top', () {
      expect(goalY(plot, 500, 120), closeTo(plot.top, 0.01));
    });

    test('no goal, or a goal of nothing, is no line', () {
      expect(goalY(plot, null, 120), isNull);
      expect(goalY(plot, 0, 120), isNull);
      expect(goalY(plot, -5, 120), isNull);
    });

    test('its label is in the strip over the plot, at the right end', () {
      final p = barPlotRect(size, withGoalLabel: true);
      final l = goalLabelAt(p, 'cél 2 200');
      expect(l.text, 'cél 2 200');
      expect(l.right, isTrue);
      expect(l.at, Offset(p.right, p.top - 10 - goalStrip / 2));
      expect(l.at.dy, closeTo(9, 0.01), reason: 'the middle of the strip');
    });

    test('the plot is lower by the strip when a label is to be written', () {
      final usual = plotRect(size);
      expect(barPlotRect(size), usual);
      final p = barPlotRect(size, withGoalLabel: true);
      expect(p.top, usual.top + goalStrip);
      expect(
        (p.left, p.right, p.bottom),
        (usual.left, usual.right, usual.bottom),
      );
      expect(barPlotRect(size, left: 50, withGoalLabel: true).left, 50);
      expect(barPlotRect(size, left: 50).left, 50);
    });

    test('the little stroke before the label ends 6 before its letters', () {
      final p = barPlotRect(size, withGoalLabel: true);
      final dashes = goalKeySegments(p, 80);
      expect(dashes, hasLength(3));
      expect(dashes.last.$2, closeTo(p.right - 80 - 6, 0.01));
      expect(dashes.first.$1, closeTo(p.right - 80 - 6 - 24, 0.01));
    });
  });

  group('the dashes', () {
    test('are 6 long with 4 between, the last one cut at the end', () {
      expect(dashSegments(0, 30), [(0.0, 6.0), (10.0, 16.0), (20.0, 26.0)]);
      expect(dashSegments(0, 24), [(0.0, 6.0), (10.0, 16.0), (20.0, 24.0)]);
    });

    test('start where the line starts, and none begins at the end', () {
      expect(dashSegments(34, 292).first, (34.0, 40.0));
      expect(dashSegments(34, 292).last, (284.0, 290.0));
      expect(dashSegments(0, 10).length, 1);
      expect(dashSegments(5, 5), isEmpty);
      expect(dashSegments(10, 5), isEmpty);
    });

    test('the size of the dash and the gap can be given', () {
      expect(dashSegments(0, 10, dash: 2, gap: 3), [(0.0, 2.0), (5.0, 7.0)]);
    });
  });

  group('the bars above the goal', () {
    test('are told by their index', () {
      expect(overGoal([10, 70, 60, 61, 0], 60), [1, 3]);
      expect(overGoal([1, 2], 5), isEmpty);
      expect(overGoal(const [], 5), isEmpty);
    });

    test('a bar that just reaches it is not above it', () {
      expect(overGoal([60], 60), isEmpty);
    });

    test('without a goal none is', () {
      expect(overGoal([100, 200], null), isEmpty);
    });

    test('get a little arrow over them, pointing up', () {
      final bar = const Rect.fromLTWH(100, 40, 10, 86);
      final m = overMarker(bar);
      expect(m, [
        const Offset(101.5, 37),
        const Offset(108.5, 37),
        const Offset(105, 31),
      ]);
      expect(m[2].dy, lessThan(m[0].dy), reason: 'the tip is the top');
    });
  });

  group('what the painter draws', () {
    List<Invocation> record(CustomPainter p, [Size s = size]) {
      final canvas = TestRecordingCanvas();
      p.paint(canvas, s);
      return [for (final r in canvas.invocations) r.invocation];
    }

    List<Invocation> only(List<Invocation> calls, Symbol name) => [
      for (final c in calls)
        if (c.memberName == name) c,
    ];

    BarChartPainter bars({
      List<double> values = const [30, 0, 90],
      double maxValue = 120,
      double? goal,
      String? goalLabel,
      TextScaler scaler = TextScaler.noScaling,
    }) => BarChartPainter(
      values: values,
      maxValue: maxValue,
      barColor: blue,
      gridColor: grey,
      labelStyle: style,
      textScaler: scaler,
      maxLabel: '2 000',
      firstLabel: '11.02.',
      lastLabel: 'ma',
      goal: goal,
      goalLabel: goalLabel,
      goalColor: dark,
      overColor: red,
    );

    test('with no goal nothing but bars, grid and words is drawn', () {
      final calls = record(bars());
      expect(only(calls, #drawPath), isEmpty);
      expect(only(calls, #drawLine), hasLength(3));
      expect(only(calls, #drawParagraph), hasLength(4));
    });

    test('a goal of nothing draws nothing either', () {
      final calls = record(bars(goal: 0, goalLabel: 'cél'));
      expect(only(calls, #drawPath), isEmpty);
      expect(only(calls, #drawParagraph), hasLength(4));
      // (and leaves no strip for a label that is not written: the grid is
      // where it is without a goal)
      List<List<Object?>> lines(List<Invocation> c) => [
        for (final l in only(c, #drawLine))
          l.positionalArguments.take(2).toList(),
      ];
      expect(lines(calls), lines(record(bars())));
    });

    test('a goal is one dashed line across the plot, as a stroke', () {
      final calls = record(bars(goal: 100, values: [30, 0, 90]));
      final paths = only(calls, #drawPath);
      expect(paths, hasLength(1), reason: 'no bar is above it: no arrows');
      final path = paths.single.positionalArguments[0] as Path;
      final paint = paths.single.positionalArguments[1] as Paint;
      expect(paint.color, isSameColorAs(dark));
      expect(paint.style, PaintingStyle.stroke);
      expect(paint.strokeWidth, 1.5);
      final dashes = dashSegments(plot.left, plot.right);
      final metrics = path.computeMetrics().toList();
      expect(metrics, hasLength(dashes.length));
      final y = goalY(plot, 100, 120)!;
      final box = path.getBounds();
      expect(box.left, closeTo(plot.left, 0.01));
      expect(box.right, closeTo(dashes.last.$2, 0.01));
      expect(box.top, closeTo(y, 0.01));
      expect(box.bottom, closeTo(y, 0.01));
      for (var i = 0; i < dashes.length; i++) {
        final (from, to) = dashes[i];
        expect(metrics[i].length, closeTo(to - from, 0.01), reason: 'dash $i');
        expect(
          metrics[i].getTangentForOffset(0)!.position.dx,
          closeTo(from, 0.01),
          reason: 'dash $i starts',
        );
      }
    });

    test('the goal line is above the grid and the bars, not under them', () {
      final names = [for (final c in record(bars(goal: 60))) c.memberName];
      // (three bars, two of them with a height: those are the rounded rects)
      expect(names.where((n) => n == #drawRRect), hasLength(2));
      expect(names.lastIndexOf(#drawRRect), lessThan(names.indexOf(#drawPath)));
      expect(names.lastIndexOf(#drawLine), lessThan(names.indexOf(#drawPath)));
    });

    test('a bar above the goal gets an arrow, in its own colour', () {
      final calls = record(bars(goal: 60, values: [30, 0, 90]));
      final paths = only(calls, #drawPath);
      expect(paths, hasLength(2));
      final arrow = paths[1].positionalArguments[0] as Path;
      final paint = paths[1].positionalArguments[1] as Paint;
      expect(paint.color, isSameColorAs(red));
      expect(paint.style, PaintingStyle.fill);
      final slot = barRects(plot, const [30, 0, 90], 120)[2];
      final tip = overMarker(slot);
      final box = arrow.getBounds();
      expect(box.left, closeTo(tip[0].dx, 0.01));
      expect(box.right, closeTo(tip[1].dx, 0.01));
      expect(box.top, closeTo(tip[2].dy, 0.01));
      expect(box.bottom, closeTo(tip[0].dy, 0.01));
      expect(arrow.computeMetrics().single.isClosed, isTrue);
    });

    test('every bar above the goal has its arrow, in one drawing', () {
      final calls = record(bars(goal: 20, values: [30, 0, 90, 10, 25]));
      final paths = only(calls, #drawPath);
      expect(paths, hasLength(2));
      final arrows = (paths[1].positionalArguments[0] as Path)
          .computeMetrics()
          .toList();
      expect(arrows, hasLength(3), reason: 'bars 0, 2 and 4');
    });

    test(
      'the goal label is drawn in the strip, with a key stroke before it',
      () {
        final calls = record(bars(goal: 100, goalLabel: 'cél 2 200'));
        final p = barPlotRect(size, withGoalLabel: true);
        final texts = only(calls, #drawParagraph);
        expect(texts, hasLength(5));
        // (the goal's label comes first: it is part of the goal's drawing)
        final painter = TextPainter(
          text: const TextSpan(text: 'cél 2 200', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final at = goalLabelAt(p, 'cél 2 200').at;
        final offset = texts[0].positionalArguments[1] as Offset;
        expect(offset.dx, closeTo(at.dx - painter.width, 0.01));
        expect(offset.dy, closeTo(at.dy - painter.height / 2, 0.01));
        // the stroke: dashes at the height of the label, ending before it
        final paths = only(calls, #drawPath);
        expect(paths, hasLength(2), reason: 'the line and the key stroke');
        final key = paths.last.positionalArguments[0] as Path;
        final paint = paths.last.positionalArguments[1] as Paint;
        expect(paint.color, isSameColorAs(dark));
        expect(paint.style, PaintingStyle.stroke);
        final box = key.getBounds();
        expect(box.top, closeTo(at.dy, 0.01));
        expect(box.bottom, closeTo(at.dy, 0.01));
        expect(box.right, closeTo(at.dx - painter.width - 6, 0.01));
        expect(
          key.computeMetrics().length,
          goalKeySegments(p, painter.width).length,
        );
        painter.dispose();
      },
    );

    test('the strip lowers the grid and the bars under it', () {
      final withLabel = record(bars(goal: 100, goalLabel: 'cél'));
      final p = barPlotRect(size, withGoalLabel: true);
      final lines = only(withLabel, #drawLine);
      expect(lines, hasLength(3));
      expect(lines.first.positionalArguments[0], Offset(p.left, p.bottom));
      expect(lines.last.positionalArguments[0], Offset(p.left, p.top));
      expect(p.top, plot.top + goalStrip);
      // (without a label the plot is the usual one)
      final plain = only(record(bars(goal: 100)), #drawLine);
      expect(plain.last.positionalArguments[0], Offset(plot.left, plot.top));
    });

    test('the arrows of the bars over the goal are not under the label', () {
      // (the label is above the plot, the arrows stay in it: even the tallest
      // bar's arrow, which rises 9 above the plot's edge, is under the strip)
      final p = barPlotRect(size, withGoalLabel: true);
      final tallest = overMarker(barRects(p, const [120.0], 120).single);
      final label = goalLabelAt(p, 'cél');
      expect(tallest[2].dy, greaterThan(label.at.dy + 7));
    });

    test('a label with no goal is not drawn', () {
      final calls = record(bars(goalLabel: 'cél 2 200'));
      expect(only(calls, #drawParagraph), hasLength(4));
      expect(only(calls, #drawPath), isEmpty);
    });

    test('a goal with no label has its line, no strip and no extra words', () {
      final calls = record(bars(goal: 100));
      expect(only(calls, #drawPath), hasLength(1));
      expect(only(calls, #drawParagraph), hasLength(4));
    });
  });

  group('repainting follows the goal', () {
    BarChartPainter p({
      double? goal,
      String? label,
      Color goalColor = dark,
      Color overColor = red,
    }) => BarChartPainter(
      values: const [30, 0, 90],
      maxValue: 120,
      barColor: blue,
      gridColor: grey,
      labelStyle: style,
      textScaler: TextScaler.noScaling,
      maxLabel: '2 000',
      firstLabel: 'a',
      lastLabel: 'b',
      goal: goal,
      goalLabel: label,
      goalColor: goalColor,
      overColor: overColor,
    );

    test('the same goal is not new', () {
      expect(
        p(goal: 60, label: 'x').shouldRepaint(p(goal: 60, label: 'x')),
        isFalse,
      );
      expect(p().shouldRepaint(p()), isFalse);
    });

    test('each thing the goal draws is a reason to repaint', () {
      final a = p(goal: 60, label: 'x');
      expect(a.shouldRepaint(p(goal: 61, label: 'x')), isTrue);
      expect(a.shouldRepaint(p(label: 'x')), isTrue);
      expect(a.shouldRepaint(p(goal: 60, label: 'y')), isTrue);
      expect(a.shouldRepaint(p(goal: 60)), isTrue);
      expect(a.shouldRepaint(p(goal: 60, label: 'x', goalColor: red)), isTrue);
      expect(a.shouldRepaint(p(goal: 60, label: 'x', overColor: blue)), isTrue);
    });
  });

  group('the widget', () {
    Widget host(Widget chart, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: SizedBox(width: 320, child: chart)),
    );

    BarChartPainter painterOf(WidgetTester tester) {
      final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
      return paints.map((c) => c.painter).whereType<BarChartPainter>().single;
    }

    testWidgets('passes the goal, its label and the theme colours on', (
      tester,
    ) async {
      final theme = ThemeData(colorScheme: const ColorScheme.light());
      await tester.pumpWidget(
        host(
          const BarChart(
            values: [100, 2600, 300],
            maxValue: 3000,
            maxLabel: '3 000',
            firstLabel: 'a',
            lastLabel: 'b',
            semanticLabel: 'Kalória',
            goal: 2200,
            goalLabel: 'cél 2 200',
          ),
          theme: theme,
        ),
      );
      final painter = painterOf(tester);
      expect(painter.goal, 2200);
      expect(painter.goalLabel, 'cél 2 200');
      expect(painter.goalColor, theme.colorScheme.onSurfaceVariant);
      expect(painter.overColor, theme.colorScheme.error);
    });

    testWidgets('without a goal has none', (tester) async {
      await tester.pumpWidget(
        host(
          const BarChart(
            values: [1, 2],
            maxValue: 3,
            maxLabel: '3',
            firstLabel: 'a',
            lastLabel: 'b',
            semanticLabel: 'x',
          ),
        ),
      );
      expect(painterOf(tester).goal, isNull);
      expect(painterOf(tester).goalLabel, isNull);
    });
  });
}
