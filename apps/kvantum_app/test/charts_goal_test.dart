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

    test('its label is at the right end, above the line', () {
      final l = goalLabelAt(plot, 80, 'cél 2 200');
      expect(l.text, 'cél 2 200');
      expect(l.right, isTrue);
      expect(l.at, Offset(plot.right, 72));
    });

    test('and under the line when it is so near the top', () {
      final l = goalLabelAt(plot, plot.top, 'cél');
      expect(l.at, Offset(plot.right, plot.top + 8));
      expect(goalLabelAt(plot, plot.top + 3, 'cél').at.dy, plot.top + 11);
      expect(goalLabelAt(plot, plot.top + 22, 'cél').at.dy, plot.top + 14);
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

    test('the goal label is drawn at the right end of the line', () {
      final calls = record(bars(goal: 60, goalLabel: 'cél 2 200'));
      final texts = only(calls, #drawParagraph);
      expect(texts, hasLength(5));
      // (the goal's label comes first: it is part of the goal's drawing)
      final p = TextPainter(
        text: const TextSpan(text: 'cél 2 200', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = goalLabelAt(plot, goalY(plot, 60, 120)!, 'cél 2 200').at;
      final offset = texts[0].positionalArguments[1] as Offset;
      expect(offset.dx, closeTo(at.dx - p.width, 0.01));
      expect(offset.dy, closeTo(at.dy - p.height / 2, 0.01));
      p.dispose();
    });

    test('a label with no goal is not drawn', () {
      final calls = record(bars(goalLabel: 'cél 2 200'));
      expect(only(calls, #drawParagraph), hasLength(4));
    });

    test('a goal with no label has its line and no extra words', () {
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
