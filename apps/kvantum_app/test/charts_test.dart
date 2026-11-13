import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/charts.dart';
import 'package:kvantum_core/kvantum_core.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

void main() {
  group('the room of a picture', () {
    test('the plot is the picture without the margins of the labels', () {
      final r = plotRect(const Size(300, 200));
      expect(r, const Rect.fromLTRB(34, 10, 292, 176));
    });

    test(
      'a picture too small for its margins has an empty plot, not a wrong one',
      () {
        final r = plotRect(const Size(20, 10));
        expect(r.width, 0);
        expect(r.height, 0);
        expect(r.left, lessThanOrEqualTo(r.right));
        expect(r.top, lessThanOrEqualTo(r.bottom));
      },
    );
  });

  group('the top of a scale of minutes', () {
    test('at least two hours, then the next full hour', () {
      expect(niceMinutesMax(0), 120);
      expect(niceMinutesMax(90), 120);
      expect(niceMinutesMax(120), 120);
      expect(niceMinutesMax(121), 180);
      expect(niceMinutesMax(165), 180);
      expect(niceMinutesMax(180), 180);
      expect(niceMinutesMax(181), 240);
    });
  });

  group('the top of a scale of forints', () {
    test(
      '1, 1.5, 2, 3, 4, 5, 6 or 8 times a power of ten, at least 10 000',
      () {
        expect(niceMoneyMax(0), 10000);
        expect(niceMoneyMax(-5), 10000);
        expect(niceMoneyMax(9999), 10000);
        expect(niceMoneyMax(10000), 10000);
        expect(niceMoneyMax(10001), 15000);
        expect(niceMoneyMax(15000), 15000);
        expect(niceMoneyMax(15001), 20000);
        expect(niceMoneyMax(20000), 20000);
        expect(niceMoneyMax(20001), 30000);
        expect(niceMoneyMax(30000), 30000);
        expect(niceMoneyMax(30001), 40000);
        expect(niceMoneyMax(40000), 40000);
        expect(niceMoneyMax(40001), 50000);
        expect(niceMoneyMax(50000), 50000);
        expect(niceMoneyMax(50001), 60000);
        expect(niceMoneyMax(60000), 60000);
        expect(niceMoneyMax(60001), 80000);
        expect(niceMoneyMax(80000), 80000);
        expect(niceMoneyMax(80001), 100000);
        expect(niceMoneyMax(99999), 100000);
        expect(niceMoneyMax(100001), 150000);
        expect(niceMoneyMax(124990), 150000);
        expect(niceMoneyMax(254098), 300000);
        expect(niceMoneyMax(300000), 300000);
        expect(niceMoneyMax(500001), 600000);
        expect(niceMoneyMax(800001), 1000000);
        expect(niceMoneyMax(2400000), 3000000);
        expect(niceMoneyMax(1000000000), 1000000000);
      },
    );

    test(
      'it holds the largest, and the tallest bar fills two thirds of it',
      () {
        const steps = {10, 15, 20, 30, 40, 50, 60, 80};
        var before = 0;
        for (var v = 10001; v < 20000000; v += 997) {
          final top = niceMoneyMax(v);
          expect(top, greaterThanOrEqualTo(v), reason: 'holds $v');
          expect(v / top, greaterThanOrEqualTo(2 / 3), reason: 'fills for $v');
          expect(top, greaterThanOrEqualTo(before), reason: 'never smaller');
          before = top;
          // (a round number: 10, 15, … 80 times a power of ten)
          var power = top;
          while (!steps.contains(power) && power % 10 == 0) {
            power ~/= 10;
          }
          expect(steps.contains(power), isTrue, reason: '$top is round');
        }
      },
    );
  });

  group('the room for the labels of a bar chart', () {
    const style = TextStyle(fontSize: 11, color: Colors.black);

    double measured(
      String text, [
      TextScaler scaler = TextScaler.noScaling,
      TextStyle textStyle = style,
    ]) {
      final p = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    test('a label is as wide as it is drawn, in its style and text size', () {
      expect(
        labelWidth('500 e Ft', style, TextScaler.noScaling),
        closeTo(measured('500 e Ft'), 0.01),
      );
      expect(
        labelWidth('500 e Ft', style, TextScaler.noScaling),
        greaterThan(labelWidth('5', style, TextScaler.noScaling)),
      );
      // (the test font is as wide as it is tall: a bigger style, a wider label)
      expect(
        labelWidth(
          '500 e Ft',
          style.copyWith(fontSize: 17),
          TextScaler.noScaling,
        ),
        closeTo(
          measured(
            '500 e Ft',
            TextScaler.noScaling,
            style.copyWith(fontSize: 17),
          ),
          0.01,
        ),
      );
      expect(
        labelWidth('500 e Ft', style, const TextScaler.linear(1.3)),
        closeTo(measured('500 e Ft', const TextScaler.linear(1.3)), 0.01),
      );
      expect(
        labelWidth('500 e Ft', style, const TextScaler.linear(1.3)),
        greaterThan(labelWidth('500 e Ft', style, TextScaler.noScaling)),
      );
    });

    test('the margin holds the label, its gap and a little air', () {
      expect(barLabelGap, 4);
      expect(plotLeftFor(50), 56);
      expect(plotLeftFor(88), 94);
      expect(plotLeftFor(100.5), 106.5);
    });

    test('but it is never less than the usual margin', () {
      expect(defaultPlotLeft, 34);
      expect(plotLeftFor(0), 34);
      expect(plotLeftFor(11), 34);
      expect(plotLeftFor(28), 34);
      expect(plotLeftFor(28.5), 34.5);
    });

    test(
      'the usual margin is the one of a plot that is not told otherwise',
      () {
        expect(plotRect(const Size(300, 200)).left, defaultPlotLeft);
        expect(plotRect(const Size(300, 200), left: 70).left, 70);
      },
    );
  });

  group('the bars', () {
    const plot = Rect.fromLTWH(0, 0, 400, 100);

    test('one slot each, standing on the bottom, as tall as their share', () {
      final bars = barRects(plot, const [0, 30, 60, 120], 120);
      expect(bars, hasLength(4));
      expect(bars[0].height, 0);
      expect(bars[1].height, 25);
      expect(bars[2].height, 50);
      expect(bars[3].height, 100);
      for (final b in bars) {
        expect(b.bottom, 100);
      }
    });

    test('each bar is centred in its slot and narrower than it', () {
      final bars = barRects(plot, const [10, 10, 10, 10], 10);
      expect(bars[0].width, closeTo(70, 1e-9));
      expect(bars[0].left, closeTo(15, 1e-9));
      expect(bars[1].left, closeTo(115, 1e-9));
      expect(bars[3].right, closeTo(385, 1e-9));
      final wide = barRects(plot, const [10, 10, 10, 10], 10, gap: 0);
      expect(wide[0].width, 100);
    });

    test('a value above the top is cut to it, one below zero is nothing', () {
      final bars = barRects(plot, const [500, -40], 100);
      expect(bars[0].height, 100);
      expect(bars[1].height, 0);
    });

    test('no values, no bars; a top of zero is no height', () {
      expect(barRects(plot, const [], 100), isEmpty);
      expect(barRects(plot, const [5, 6], 0).map((b) => b.height), [0, 0]);
    });
  });

  group('days and values across the plot', () {
    const plot = Rect.fromLTWH(10, 20, 200, 100);

    test('the first day is at the left, the last at the right', () {
      final from = d(2026, 11, 1), to = d(2026, 11, 11);
      expect(dayX(plot, from, from, to), 10);
      expect(dayX(plot, d(2026, 11, 6), from, to), 110);
      expect(dayX(plot, to, from, to), 210);
    });

    test('a day outside is put on the nearest edge', () {
      final from = d(2026, 11, 1), to = d(2026, 11, 11);
      expect(dayX(plot, d(2026, 10, 1), from, to), 10);
      expect(dayX(plot, d(2026, 12, 1), from, to), 210);
    });

    test('a chart of a single day has it in the middle', () {
      final day = d(2026, 11, 1);
      expect(dayX(plot, day, day, day), 110);
    });

    test(
      'values go up the plot: the least at the bottom, the most at the top',
      () {
        expect(valueY(plot, 1, 1, 5), 120);
        expect(valueY(plot, 5, 1, 5), 20);
        expect(valueY(plot, 3, 1, 5), 70);
        expect(valueY(plot, 0, 1, 5), 120);
        expect(valueY(plot, 9, 1, 5), 20);
      },
    );

    test('a scale with no width puts everything in the middle', () {
      expect(valueY(plot, 3, 3, 3), 70);
    });
  });

  group('the markers', () {
    test('four shapes, four icons', () {
      expect(LineMarker.values, hasLength(4));
      expect({for (final m in LineMarker.values) m.icon}, hasLength(4));
    });
  });

  group('the words of a chart', () {
    final plot = plotRect(const Size(300, 150));

    test('a label is what it says, where it is, and on which side', () {
      const a = ChartLabel('2 óra', Offset(30, 10), right: true);
      const same = ChartLabel('2 óra', Offset(30, 10), right: true);
      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(const ChartLabel('3 óra', Offset(30, 10), right: true)));
      expect(a, isNot(const ChartLabel('2 óra', Offset(31, 10), right: true)));
      expect(a, isNot(const ChartLabel('2 óra', Offset(30, 11), right: true)));
      expect(a, isNot(const ChartLabel('2 óra', Offset(30, 10))));
      // (also for a set of labels: the other side is another label)
      expect(
        a.hashCode,
        isNot(const ChartLabel('2 óra', Offset(30, 10)).hashCode),
      );
      expect(const ChartLabel('x', Offset.zero).right, isFalse);
    });

    test(
      'a scale is marked at every whole number from its first to its last',
      () {
        expect(scaleValues(1, 5), [1, 2, 3, 4, 5]);
        expect(scaleValues(0, 2), [0, 1, 2]);
        expect(scaleValues(3, 3), [3]);
        expect(scaleValues(0.6, 4.4), [1, 2, 3, 4]);
      },
    );

    test(
      'a bar chart: the top of the scale and 0 at the left, the ends below',
      () {
        expect(
          barLabels(
            plot,
            maxLabel: '2 óra',
            firstLabel: '11.02.',
            lastLabel: 'ez a hét',
          ),
          [
            ChartLabel('2 óra', Offset(plot.left - 4, plot.top), right: true),
            ChartLabel('0', Offset(plot.left - 4, plot.bottom), right: true),
            ChartLabel('11.02.', Offset(plot.left, plot.bottom + 12)),
            ChartLabel(
              'ez a hét',
              Offset(plot.right, plot.bottom + 12),
              right: true,
            ),
          ],
        );
      },
    );

    test(
      'a line chart: a number for each value of the scale, the ends below',
      () {
        expect(
          lineLabels(
            plot,
            min: 1,
            max: 5,
            firstLabel: '11.01.',
            lastLabel: 'ma',
          ),
          [
            for (var v = 1; v <= 5; v++)
              ChartLabel(
                '$v',
                Offset(plot.left - 6, valueY(plot, v.toDouble(), 1, 5)),
                right: true,
              ),
            ChartLabel('11.01.', Offset(plot.left, plot.bottom + 12)),
            ChartLabel('ma', Offset(plot.right, plot.bottom + 12), right: true),
          ],
        );
        expect(
          lineLabels(
            plot,
            min: 0,
            max: 2,
            firstLabel: 'a',
            lastLabel: 'b',
          ).map((l) => l.text),
          ['0', '1', '2', 'a', 'b'],
        );
      },
    );
  });

  group('the painters', () {
    void paintOn(CustomPainter p, [Size size = const Size(320, 180)]) {
      final recorder = ui.PictureRecorder();
      p.paint(Canvas(recorder), size);
      recorder.endRecording().dispose();
    }

    const style = TextStyle(fontSize: 11, color: Colors.black);
    BarChartPainter bars({
      List<double> values = const [30, 0, 90],
      double maxValue = 120,
      Color color = Colors.indigo,
    }) => BarChartPainter(
      values: values,
      maxValue: maxValue,
      barColor: color,
      gridColor: Colors.grey,
      labelStyle: style,
      textScaler: TextScaler.noScaling,
      maxLabel: '2 óra',
      firstLabel: '11.02.',
      lastLabel: 'ez a hét',
    );

    LineChartPainter lines({
      List<LineSeries> series = const [],
      DateTime? to,
    }) => LineChartPainter(
      series: series,
      from: d(2026, 11, 1),
      to: to ?? d(2026, 11, 11),
      gridColor: Colors.grey,
      labelStyle: style,
      textScaler: TextScaler.noScaling,
      firstLabel: '11.01.',
      lastLabel: 'ma',
    );

    LineSeries series(LineMarker m, List<DayValue> line, {bool all = false}) =>
        LineSeries(
          label: 'x',
          color: Colors.indigo,
          marker: m,
          dots: line,
          line: line,
          markAll: all,
        );

    test('bars draw with nothing, with zeros, with one value', () {
      paintOn(bars(values: const []));
      paintOn(bars(values: const [0, 0, 0]));
      paintOn(bars(values: const [60]));
      paintOn(bars(maxValue: 0));
    });

    test('bars draw in a picture too small for the labels', () {
      paintOn(bars(), const Size(10, 10));
      paintOn(bars(), Size.zero);
    });

    test(
      'a bar chart is repainted when what it shows changes, not otherwise',
      () {
        final a = bars();
        expect(a.shouldRepaint(bars()), isFalse);
        expect(a.shouldRepaint(bars(values: const [30, 0, 91])), isTrue);
        expect(a.shouldRepaint(bars(maxValue: 180)), isTrue);
        expect(a.shouldRepaint(bars(color: Colors.red)), isTrue);
      },
    );

    test('lines draw with nothing, with one point, with every shape', () {
      paintOn(lines());
      for (final m in LineMarker.values) {
        paintOn(
          lines(
            series: [
              series(m, [DayValue(d(2026, 11, 5), 3)]),
            ],
          ),
        );
        paintOn(
          lines(
            series: [
              series(m, [
                DayValue(d(2026, 11, 2), 2),
                DayValue(d(2026, 11, 6), 4),
                DayValue(d(2026, 11, 11), 3),
              ], all: true),
            ],
          ),
        );
      }
    });

    test('lines draw for a single day and in a picture too small', () {
      paintOn(
        lines(
          to: d(2026, 11, 1),
          series: [
            series(LineMarker.circle, [DayValue(d(2026, 11, 1), 3)]),
          ],
        ),
      );
      paintOn(lines(), const Size(10, 10));
    });

    test('a line chart is repainted when its range or labels change', () {
      final a = lines();
      expect(a.shouldRepaint(lines()), isFalse);
      expect(a.shouldRepaint(lines(to: d(2026, 11, 12))), isTrue);
    });
  });

  group('repainting follows every thing a painter draws', () {
    const style = TextStyle(fontSize: 11, color: Colors.black);

    BarChartPainter bar({
      List<double>? values,
      double maxValue = 120,
      Color barColor = Colors.indigo,
      Color grid = Colors.grey,
      TextStyle label = style,
      TextScaler scaler = TextScaler.noScaling,
      String max = '2 óra',
      String first = '11.02.',
      String last = 'ez a hét',
      double plotLeft = defaultPlotLeft,
    }) => BarChartPainter(
      values: values ?? [30, 0, 90],
      maxValue: maxValue,
      barColor: barColor,
      gridColor: grid,
      labelStyle: label,
      textScaler: scaler,
      maxLabel: max,
      firstLabel: first,
      lastLabel: last,
      plotLeft: plotLeft,
    );

    test(
      'a bar chart: the same things, however they are held, are not new',
      () {
        expect(bar().shouldRepaint(bar()), isFalse);
        // the same numbers in another list are the same picture
        expect(bar(values: [30, 0, 90]).shouldRepaint(bar()), isFalse);
      },
    );

    test('a bar chart is repainted for each thing it draws', () {
      final a = bar();
      expect(a.shouldRepaint(bar(values: [30, 0])), isTrue);
      expect(a.shouldRepaint(bar(values: [30, 1, 90])), isTrue);
      expect(a.shouldRepaint(bar(maxValue: 180)), isTrue);
      expect(a.shouldRepaint(bar(barColor: Colors.red)), isTrue);
      expect(a.shouldRepaint(bar(grid: Colors.red)), isTrue);
      expect(a.shouldRepaint(bar(label: style.copyWith(fontSize: 12))), isTrue);
      expect(
        a.shouldRepaint(bar(scaler: const TextScaler.linear(1.3))),
        isTrue,
      );
      expect(a.shouldRepaint(bar(max: '3 óra')), isTrue);
      expect(a.shouldRepaint(bar(first: '11.09.')), isTrue);
      expect(a.shouldRepaint(bar(last: 'most')), isTrue);
      expect(a.shouldRepaint(bar(plotLeft: 50)), isTrue);
    });

    LineChartPainter line({
      List<LineSeries>? series,
      DateTime? from,
      DateTime? to,
      Color grid = Colors.grey,
      TextStyle label = style,
      TextScaler scaler = TextScaler.noScaling,
      String first = '11.01.',
      String last = 'ma',
      double min = 1,
      double max = 5,
    }) => LineChartPainter(
      series: series ?? const [],
      from: from ?? d(2026, 11, 1),
      to: to ?? d(2026, 11, 11),
      gridColor: grid,
      labelStyle: label,
      textScaler: scaler,
      firstLabel: first,
      lastLabel: last,
      min: min,
      max: max,
    );

    test('a line chart is repainted for each thing it draws', () {
      final a = line();
      expect(a.shouldRepaint(line()), isFalse);
      expect(a.shouldRepaint(line(from: d(2026, 11, 2))), isTrue);
      expect(a.shouldRepaint(line(to: d(2026, 11, 12))), isTrue);
      expect(a.shouldRepaint(line(grid: Colors.red)), isTrue);
      expect(
        a.shouldRepaint(line(label: style.copyWith(fontSize: 12))),
        isTrue,
      );
      expect(
        a.shouldRepaint(line(scaler: const TextScaler.linear(1.3))),
        isTrue,
      );
      expect(a.shouldRepaint(line(first: '11.02.')), isTrue);
      expect(a.shouldRepaint(line(last: 'most')), isTrue);
      expect(a.shouldRepaint(line(min: 0)), isTrue);
      expect(a.shouldRepaint(line(max: 6)), isTrue);
    });

    test('a line chart is repainted when it is given other series', () {
      final one = [
        LineSeries(
          label: 'x',
          color: Colors.indigo,
          marker: LineMarker.circle,
          dots: const [],
          line: [DayValue(d(2026, 11, 5), 3)],
        ),
      ];
      expect(line(series: one).shouldRepaint(line(series: one)), isFalse);
      expect(line(series: one).shouldRepaint(line(series: [...one])), isTrue);
    });
  });

  // What a painter puts on the canvas, call by call. The test font draws every
  // letter as the same box, so the picture cannot say what the labels say;
  // the calls can: where each label is, how long it is, in what colour a line
  // or a bar is, and in what order everything is drawn.
  group('what the painters draw', () {
    const size = Size(300, 150);
    const blue = Color(0xFF1565C0);
    const red = Color(0xFFC62828);
    const grey = Color(0xFF9E9E9E);
    const style = TextStyle(fontSize: 11, color: Colors.black);
    final plot = plotRect(size);

    List<Invocation> record(CustomPainter p, [Size s = size]) {
      final canvas = TestRecordingCanvas();
      p.paint(canvas, s);
      return [for (final r in canvas.invocations) r.invocation];
    }

    List<Invocation> only(List<Invocation> calls, Symbol name) => [
      for (final c in calls)
        if (c.memberName == name) c,
    ];

    Size textSize(
      String text, [
      TextScaler scaler = TextScaler.noScaling,
      TextStyle textStyle = style,
    ]) {
      final p = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final s = p.size;
      p.dispose();
      return s;
    }

    /// The label [text] is drawn with its middle at height `at.dy`, starting at
    /// `at.dx` (or ending there, if [right]).
    void expectText(
      Invocation call,
      String text,
      Offset at, {
      bool right = false,
      TextScaler scaler = TextScaler.noScaling,
      TextStyle textStyle = style,
    }) {
      final box = textSize(text, scaler, textStyle);
      final paragraph = call.positionalArguments[0] as ui.Paragraph;
      final offset = call.positionalArguments[1] as Offset;
      expect(
        paragraph.longestLine,
        closeTo(box.width, 0.01),
        reason: 'the length of "$text"',
      );
      expect(
        offset.dx,
        closeTo(right ? at.dx - box.width : at.dx, 0.01),
        reason: 'where "$text" starts',
      );
      expect(
        offset.dy,
        closeTo(at.dy - box.height / 2, 0.01),
        reason: 'how high "$text" is',
      );
    }

    void expectLine(Invocation call, Offset from, Offset to, Color color) {
      expect(call.positionalArguments[0], from);
      expect(call.positionalArguments[1], to);
      final paint = call.positionalArguments[2] as Paint;
      expect(paint.color, isSameColorAs(color));
      expect(paint.strokeWidth, 1);
    }

    void expectRect(Rect actual, Rect expected, {String? reason}) {
      expect(actual.left, closeTo(expected.left, 0.01), reason: reason);
      expect(actual.top, closeTo(expected.top, 0.01), reason: reason);
      expect(actual.right, closeTo(expected.right, 0.01), reason: reason);
      expect(actual.bottom, closeTo(expected.bottom, 0.01), reason: reason);
    }

    /// The path goes through [points] in this order (and back to the first, if
    /// [closed]).
    void expectPath(Path path, List<Offset> points, {bool closed = false}) {
      final metrics = path.computeMetrics().toList();
      expect(metrics, hasLength(1));
      final metric = metrics.single;
      expect(metric.isClosed, closed);
      final along = [...points, if (closed) points.first];
      var travelled = 0.0;
      for (var i = 0; i < along.length; i++) {
        if (i > 0) travelled += (along[i] - along[i - 1]).distance;
        final at = metric
            .getTangentForOffset(math.min(travelled, metric.length))!
            .position;
        expect(at.dx, closeTo(along[i].dx, 0.01), reason: 'x of point $i');
        expect(at.dy, closeTo(along[i].dy, 0.01), reason: 'y of point $i');
      }
      expect(metric.length, closeTo(travelled, 0.01));
    }

    BarChartPainter bars({
      List<double> values = const [30, 0, 90],
      double maxValue = 120,
      Color color = blue,
      TextScaler scaler = TextScaler.noScaling,
      TextStyle labelStyle = style,
      double plotLeft = defaultPlotLeft,
    }) => BarChartPainter(
      values: values,
      maxValue: maxValue,
      barColor: color,
      gridColor: grey,
      labelStyle: labelStyle,
      textScaler: scaler,
      maxLabel: '2 óra',
      firstLabel: '11.02.',
      lastLabel: 'ez a hét',
      plotLeft: plotLeft,
    );

    group('bars', () {
      test('the grid: the bottom, the middle and the top of the scale', () {
        final lines = only(record(bars()), #drawLine);
        expect(lines, hasLength(3));
        final ys = [plot.bottom, plot.bottom - plot.height / 2, plot.top];
        for (var i = 0; i < 3; i++) {
          expectLine(
            lines[i],
            Offset(plot.left, ys[i]),
            Offset(plot.right, ys[i]),
            grey,
          );
        }
      });

      test('the labels: the top of the scale, 0, and the two ends', () {
        final texts = only(record(bars()), #drawParagraph);
        expect(texts, hasLength(4));
        expectText(
          texts[0],
          '2 óra',
          Offset(plot.left - 4, plot.top),
          right: true,
        );
        expectText(
          texts[1],
          '0',
          Offset(plot.left - 4, plot.bottom),
          right: true,
        );
        expectText(texts[2], '11.02.', Offset(plot.left, plot.bottom + 12));
        expectText(
          texts[3],
          'ez a hét',
          Offset(plot.right, plot.bottom + 12),
          right: true,
        );
      });

      test('the labels follow the text scale', () {
        const scaler = TextScaler.linear(1.5);
        final texts = only(record(bars(scaler: scaler)), #drawParagraph);
        expectText(
          texts[0],
          '2 óra',
          Offset(plot.left - 4, plot.top),
          right: true,
          scaler: scaler,
        );
        expectText(
          texts[2],
          '11.02.',
          Offset(plot.left, plot.bottom + 12),
          scaler: scaler,
        );
      });

      test('the labels are in the style they were given', () {
        const big = TextStyle(fontSize: 17, color: Colors.black);
        final texts = only(record(bars(labelStyle: big)), #drawParagraph);
        expectText(
          texts[0],
          '2 óra',
          Offset(plot.left - 4, plot.top),
          right: true,
          textStyle: big,
        );
        expectText(
          texts[3],
          'ez a hét',
          Offset(plot.right, plot.bottom + 12),
          right: true,
          textStyle: big,
        );
      });

      test('a bar is rounded at the top only, where barRects puts it', () {
        final values = [30.0, 0.0, 90.0];
        final rrects = only(record(bars(values: values)), #drawRRect);
        final rects = barRects(plot, values, 120);
        // a bar of nothing is not drawn
        expect(rrects, hasLength(2));
        for (final (i, at) in [0, 2].indexed) {
          final drawn = rrects[i].positionalArguments[0] as RRect;
          expect(
            drawn,
            RRect.fromRectAndCorners(
              rects[at],
              topLeft: const Radius.circular(3),
              topRight: const Radius.circular(3),
            ),
          );
          expect(
            (rrects[i].positionalArguments[1] as Paint).color,
            isSameColorAs(blue),
          );
        }
      });

      test('the bars have the colour they were given', () {
        final rrects = only(record(bars(color: red)), #drawRRect);
        expect(rrects, isNotEmpty);
        for (final r in rrects) {
          expect((r.positionalArguments[1] as Paint).color, isSameColorAs(red));
        }
      });

      test('the scale decides how tall they are', () {
        final rrects = only(
          record(bars(values: const [60], maxValue: 240)),
          #drawRRect,
        );
        final drawn = rrects.single.positionalArguments[0] as RRect;
        expect(drawn.height, closeTo(plot.height / 4, 0.01));
        expect(drawn.bottom, closeTo(plot.bottom, 0.01));
        // no scale, no bars
        expect(only(record(bars(maxValue: 0)), #drawRRect), isEmpty);
      });

      test('it draws in the room it is given, not in a fixed one', () {
        const other = Size(200, 100);
        final area = plotRect(other);
        final lines = only(record(bars(), other), #drawLine);
        expectLine(
          lines.first,
          Offset(area.left, area.bottom),
          Offset(area.right, area.bottom),
          grey,
        );
        final rrects = only(record(bars(), other), #drawRRect);
        final first = rrects.first.positionalArguments[0] as RRect;
        expect(
          first.left,
          closeTo(barRects(area, [30, 0, 90], 120)[0].left, 0.01),
        );
      });

      test('the margin at the left is the one it is given', () {
        final area = plotRect(size, left: 80);
        final calls = record(bars(plotLeft: 80));
        final lines = only(calls, #drawLine);
        expect(lines, hasLength(3));
        for (final line in lines) {
          expect((line.positionalArguments[0] as Offset).dx, 80);
          expect((line.positionalArguments[1] as Offset).dx, area.right);
        }
        final rrects = only(calls, #drawRRect);
        final first = rrects.first.positionalArguments[0] as RRect;
        expect(
          first.left,
          closeTo(barRects(area, [30, 0, 90], 120)[0].left, 0.01),
        );
        final texts = only(calls, #drawParagraph);
        expectText(texts[0], '2 óra', Offset(80 - 4, area.top), right: true);
        expectText(texts[1], '0', Offset(80 - 4, area.bottom), right: true);
        expectText(texts[2], '11.02.', Offset(80, area.bottom + 12));
        expectText(
          texts[3],
          'ez a hét',
          Offset(area.right, area.bottom + 12),
          right: true,
        );
      });

      test('a margin wider than the picture leaves an empty plot, no more', () {
        final calls = record(bars(plotLeft: 500));
        for (final line in only(calls, #drawLine)) {
          expect((line.positionalArguments[0] as Offset).dx, 500);
          expect((line.positionalArguments[1] as Offset).dx, 500);
        }
        for (final bar in only(calls, #drawRRect)) {
          expect((bar.positionalArguments[0] as RRect).width, 0);
        }
      });

      test('first the grid, then the bars, then the words', () {
        const wanted = [#drawLine, #drawParagraph, #drawRRect];
        final seen = [
          for (final c in record(bars()))
            if (wanted.contains(c.memberName)) c.memberName,
        ];
        expect(seen, [
          #drawLine,
          #drawLine,
          #drawLine,
          #drawRRect,
          #drawRRect,
          #drawParagraph,
          #drawParagraph,
          #drawParagraph,
          #drawParagraph,
        ]);
      });
    });

    LineSeries series({
      List<DayValue> line = const [],
      List<DayValue> dots = const [],
      LineMarker marker = LineMarker.circle,
      bool all = false,
      Color color = blue,
    }) => LineSeries(
      label: 'x',
      color: color,
      marker: marker,
      dots: dots,
      line: line,
      markAll: all,
    );

    LineChartPainter chart(
      List<LineSeries> all, {
      double min = 1,
      double max = 5,
      TextScaler scaler = TextScaler.noScaling,
      TextStyle labelStyle = style,
    }) => LineChartPainter(
      series: all,
      from: d(2026, 11, 1),
      to: d(2026, 11, 11),
      gridColor: grey,
      labelStyle: labelStyle,
      textScaler: scaler,
      firstLabel: '11.01.',
      lastLabel: 'ma',
      min: min,
      max: max,
    );

    Offset where(DayValue p, {double min = 1, double max = 5}) => Offset(
      dayX(plot, p.day, d(2026, 11, 1), d(2026, 11, 11)),
      valueY(plot, p.value, min, max),
    );

    final threePoints = [
      DayValue(d(2026, 11, 1), 1),
      DayValue(d(2026, 11, 6), 5),
      DayValue(d(2026, 11, 11), 3),
    ];

    group('lines', () {
      test(
        'the scale: a line and a number for 1 … 5, the least at the bottom',
        () {
          final calls = record(chart(const []));
          final lines = only(calls, #drawLine);
          final texts = only(calls, #drawParagraph);
          expect(lines, hasLength(5));
          expect(texts, hasLength(7));
          for (var v = 1; v <= 5; v++) {
            final y = valueY(plot, v.toDouble(), 1, 5);
            expectLine(
              lines[v - 1],
              Offset(plot.left, y),
              Offset(plot.right, y),
              grey,
            );
            expectText(
              texts[v - 1],
              '$v',
              Offset(plot.left - 6, y),
              right: true,
            );
          }
          expectText(texts[5], '11.01.', Offset(plot.left, plot.bottom + 12));
          expectText(
            texts[6],
            'ma',
            Offset(plot.right, plot.bottom + 12),
            right: true,
          );
        },
      );

      test('another scale has its own lines and numbers', () {
        final calls = record(chart(const [], min: 0, max: 2));
        final lines = only(calls, #drawLine);
        final texts = only(calls, #drawParagraph);
        expect(lines, hasLength(3));
        for (var v = 0; v <= 2; v++) {
          final y = valueY(plot, v.toDouble(), 0, 2);
          expectLine(
            lines[v],
            Offset(plot.left, y),
            Offset(plot.right, y),
            grey,
          );
          expectText(texts[v], '$v', Offset(plot.left - 6, y), right: true);
        }
      });

      test('first the grid, then the series, then the words', () {
        final calls = record(chart([series(line: threePoints)]));
        const wanted = [#drawLine, #drawPath, #drawCircle, #drawParagraph];
        final seen = [
          for (final c in calls)
            if (wanted.contains(c.memberName)) c.memberName,
        ];
        expect(seen, [
          for (var i = 0; i < 5; i++) #drawLine,
          #drawPath,
          #drawCircle,
          for (var i = 0; i < 7; i++) #drawParagraph,
        ]);
      });

      test('the labels are in the style they were given', () {
        const big = TextStyle(fontSize: 17, color: Colors.black);
        final texts = only(
          record(chart(const [], labelStyle: big)),
          #drawParagraph,
        );
        expectText(
          texts[0],
          '1',
          Offset(plot.left - 6, valueY(plot, 1, 1, 5)),
          right: true,
          textStyle: big,
        );
        expectText(
          texts[6],
          'ma',
          Offset(plot.right, plot.bottom + 12),
          right: true,
          textStyle: big,
        );
      });

      test('the labels follow the text scale', () {
        const scaler = TextScaler.linear(1.5);
        final texts = only(
          record(chart(const [], scaler: scaler)),
          #drawParagraph,
        );
        expectText(
          texts[0],
          '1',
          Offset(plot.left - 6, valueY(plot, 1, 1, 5)),
          right: true,
          scaler: scaler,
        );
        expectText(
          texts[5],
          '11.01.',
          Offset(plot.left, plot.bottom + 12),
          scaler: scaler,
        );
      });

      test('a line goes through its points in order, stroked and round', () {
        final calls = record(chart([series(line: threePoints)]));
        final paths = only(calls, #drawPath);
        // the marker of the last point is a circle, so this is the only path
        expect(paths, hasLength(1));
        expectPath(paths.single.positionalArguments[0] as Path, [
          for (final p in threePoints) where(p),
        ]);
        final paint = paths.single.positionalArguments[1] as Paint;
        expect(paint.style, PaintingStyle.stroke);
        expect(paint.strokeWidth, 2.5);
        expect(paint.strokeJoin, StrokeJoin.round);
        expect(paint.strokeCap, StrokeCap.round);
        expect(paint.color, isSameColorAs(blue));
      });

      test(
        'only the last point of a line is marked, in the colour of the line',
        () {
          final circles = only(
            record(chart([series(line: threePoints)])),
            #drawCircle,
          );
          expect(circles, hasLength(1));
          expect(
            circles.single.positionalArguments[0],
            where(threePoints.last),
          );
          expect(circles.single.positionalArguments[1], 5.0);
          expect(
            (circles.single.positionalArguments[2] as Paint).color,
            isSameColorAs(blue),
          );
        },
      );

      test('every point is marked when the series asks for it', () {
        final circles = only(
          record(chart([series(line: threePoints, all: true)])),
          #drawCircle,
        );
        expect(circles, hasLength(3));
        for (var i = 0; i < 3; i++) {
          expect(circles[i].positionalArguments[0], where(threePoints[i]));
          expect(circles[i].positionalArguments[1], 5.0);
        }
      });

      test(
        'the single values are small, faint dots, drawn before the line',
        () {
          final dots = [
            DayValue(d(2026, 11, 3), 2),
            DayValue(d(2026, 11, 8), 4),
          ];
          final calls = record(chart([series(line: threePoints, dots: dots)]));
          final shapes = [
            for (final c in calls)
              if (c.memberName == #drawCircle || c.memberName == #drawPath) c,
          ];
          // two dots, the line, the marker of its last point
          expect(shapes.map((c) => c.memberName), [
            #drawCircle,
            #drawCircle,
            #drawPath,
            #drawCircle,
          ]);
          for (var i = 0; i < 2; i++) {
            expect(shapes[i].positionalArguments[0], where(dots[i]));
            expect(shapes[i].positionalArguments[1], 2.2);
            final paint = shapes[i].positionalArguments[2] as Paint;
            expect(paint.color, isSameColorAs(blue.withValues(alpha: 0.35)));
          }
          expect(shapes[3].positionalArguments[1], 5.0);
          expect(
            (shapes[3].positionalArguments[2] as Paint).color,
            isSameColorAs(blue),
          );
        },
      );

      test('a series with dots only draws no line and no marker', () {
        final dots = [DayValue(d(2026, 11, 3), 2), DayValue(d(2026, 11, 8), 4)];
        final calls = record(chart([series(dots: dots)]));
        expect(only(calls, #drawPath), isEmpty);
        final circles = only(calls, #drawCircle);
        expect(circles, hasLength(2));
        for (final c in circles) {
          expect(c.positionalArguments[1], 2.2);
        }
      });

      test('each series in its own colour, in the order given', () {
        final other = [
          DayValue(d(2026, 11, 2), 4),
          DayValue(d(2026, 11, 9), 2),
        ];
        final calls = record(
          chart([
            series(line: threePoints),
            series(line: other, color: red, marker: LineMarker.square),
          ]),
        );
        final paths = only(calls, #drawPath);
        expect(paths, hasLength(2));
        expect(
          (paths[0].positionalArguments[1] as Paint).color,
          isSameColorAs(blue),
        );
        expect(
          (paths[1].positionalArguments[1] as Paint).color,
          isSameColorAs(red),
        );
        expectPath(paths[1].positionalArguments[0] as Path, [
          for (final p in other) where(p),
        ]);
        // the square of the second series: its last point, in its colour
        final squares = only(calls, #drawRect);
        expect(squares, hasLength(1));
        expect(
          (squares.single.positionalArguments[1] as Paint).color,
          isSameColorAs(red),
        );
      });

      test(
        'a point outside the range is put on the edge, not off the picture',
        () {
          final out = [
            DayValue(d(2026, 10, 20), 9),
            DayValue(d(2026, 12, 1), -4),
          ];
          final paths = only(record(chart([series(line: out)])), #drawPath);
          final bounds = (paths.single.positionalArguments[0] as Path)
              .getBounds();
          expectRect(bounds, plot);
        },
      );

      test('one day on its own is drawn in the middle', () {
        final day = DayValue(d(2026, 11, 1), 3);
        final painter = LineChartPainter(
          series: [
            series(line: [day]),
          ],
          from: d(2026, 11, 1),
          to: d(2026, 11, 1),
          gridColor: grey,
          labelStyle: style,
          textScaler: TextScaler.noScaling,
          firstLabel: 'ma',
          lastLabel: 'ma',
        );
        final circle = only(record(painter), #drawCircle).single;
        expect(
          circle.positionalArguments[0],
          Offset(plot.center.dx, valueY(plot, 3, 1, 5)),
        );
      });
    });

    group('the shapes that tell the lines apart', () {
      final end = DayValue(d(2026, 11, 11), 3);
      final two = [DayValue(d(2026, 11, 1), 3), end];
      final c = where(end);

      List<Invocation> mark(LineMarker m) =>
          record(chart([series(line: two, marker: m)]));

      test('a circle', () {
        final circles = only(mark(LineMarker.circle), #drawCircle);
        expect(circles, hasLength(1));
        expect(circles.single.positionalArguments[0], c);
        expect(circles.single.positionalArguments[1], 5.0);
      });

      test('a square, a little smaller than the circle is wide', () {
        final calls = mark(LineMarker.square);
        expect(only(calls, #drawCircle), isEmpty);
        final squares = only(calls, #drawRect);
        expect(squares, hasLength(1));
        expectRect(
          squares.single.positionalArguments[0] as Rect,
          Rect.fromCircle(center: c, radius: 4.5),
        );
        expect(
          (squares.single.positionalArguments[1] as Paint).color,
          isSameColorAs(blue),
        );
      });

      test('a triangle with its point up and a wide, low foot', () {
        final calls = mark(LineMarker.triangle);
        expect(only(calls, #drawCircle), isEmpty);
        final paths = only(calls, #drawPath);
        // the line, then the marker
        expect(paths, hasLength(2));
        expectPath(paths.last.positionalArguments[0] as Path, [
          Offset(c.dx, c.dy - 5),
          Offset(c.dx + 5, c.dy + 4),
          Offset(c.dx - 5, c.dy + 4),
        ], closed: true);
        expect(
          (paths.last.positionalArguments[1] as Paint).color,
          isSameColorAs(blue),
        );
      });

      test('a diamond', () {
        final calls = mark(LineMarker.diamond);
        expect(only(calls, #drawCircle), isEmpty);
        final paths = only(calls, #drawPath);
        expect(paths, hasLength(2));
        expectPath(paths.last.positionalArguments[0] as Path, [
          Offset(c.dx, c.dy - 5),
          Offset(c.dx + 5, c.dy),
          Offset(c.dx, c.dy + 5),
          Offset(c.dx - 5, c.dy),
        ], closed: true);
        expect(
          (paths.last.positionalArguments[1] as Paint).color,
          isSameColorAs(blue),
        );
      });

      test('the shapes are drawn with the colour of their own series', () {
        for (final m in LineMarker.values) {
          final calls = record(
            chart([series(line: two, marker: m, color: red)]),
          );
          final marks = [
            for (final call in calls)
              if (call.memberName == #drawCircle ||
                  call.memberName == #drawRect ||
                  call.memberName == #drawPath)
                call,
          ];
          expect(marks, isNotEmpty);
          for (final call in marks) {
            final paint = call.positionalArguments.last as Paint;
            expect(paint.color, isSameColorAs(red), reason: '$m');
          }
        }
      });
    });
  });

  group('the chart widgets', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

    Future<void> show(WidgetTester tester, Widget chart, {double scale = 1}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(colorScheme: scheme),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(body: chart),
              ),
            ),
          ),
        );

    // (the height is only passed when one is asked for: the default is tested)
    BarChart bar({double? height}) => height == null
        ? const BarChart(
            values: [30, 0, 90],
            maxValue: 120,
            maxLabel: '2 óra',
            firstLabel: '11.02.',
            lastLabel: 'ez a hét',
            semanticLabel: 'Heti edzésidő: sok',
          )
        : BarChart(
            values: const [30, 0, 90],
            maxValue: 120,
            maxLabel: '2 óra',
            firstLabel: '11.02.',
            lastLabel: 'ez a hét',
            semanticLabel: 'Heti edzésidő: sok',
            height: height,
          );

    LineChart line({double? height}) => height == null
        ? LineChart(
            series: const [],
            from: d(2026, 11, 1),
            to: d(2026, 11, 11),
            firstLabel: '11.01.',
            lastLabel: 'ma',
            semanticLabel: 'Hangulat: jó',
          )
        : LineChart(
            series: const [],
            from: d(2026, 11, 1),
            to: d(2026, 11, 11),
            firstLabel: '11.01.',
            lastLabel: 'ma',
            semanticLabel: 'Hangulat: jó',
            height: height,
          );

    CustomPaint paintOf(WidgetTester tester, Type chart) => tester.widget(
      find.descendant(
        of: find.byType(chart),
        matching: find.byType(CustomPaint),
      ),
    );

    testWidgets('a bar chart takes its colours and its type from the theme', (
      tester,
    ) async {
      await show(tester, bar());
      final painter = paintOf(tester, BarChart).painter! as BarChartPainter;
      expect(painter.barColor, scheme.primary);
      expect(painter.gridColor, scheme.outlineVariant);
      expect(painter.labelStyle.color, scheme.onSurfaceVariant);
      final base = Theme.of(tester.element(find.byType(BarChart)))
          .textTheme
          .labelSmall!;
      expect(painter.labelStyle.fontSize, base.fontSize);
      expect(painter.values, const [30, 0, 90]);
      expect(painter.maxValue, 120);
      expect(painter.maxLabel, '2 óra');
      expect(painter.firstLabel, '11.02.');
      expect(painter.lastLabel, 'ez a hét');
    });

    testWidgets('a line chart takes its colours and its type from the theme', (
      tester,
    ) async {
      await show(tester, line());
      final painter = paintOf(tester, LineChart).painter! as LineChartPainter;
      expect(painter.gridColor, scheme.outlineVariant);
      expect(painter.labelStyle.color, scheme.onSurfaceVariant);
      final base = Theme.of(tester.element(find.byType(LineChart)))
          .textTheme
          .labelSmall!;
      expect(painter.labelStyle.fontSize, base.fontSize);
      expect(painter.from, d(2026, 11, 1));
      expect(painter.to, d(2026, 11, 11));
      expect(painter.firstLabel, '11.01.');
      expect(painter.lastLabel, 'ma');
    });

    testWidgets('a bar chart can have a colour of its own', (tester) async {
      await show(
        tester,
        const BarChart(
          values: [1],
          maxValue: 2,
          maxLabel: 'a',
          firstLabel: 'b',
          lastLabel: 'c',
          semanticLabel: 'd',
          color: Colors.red,
        ),
      );
      final painter = paintOf(tester, BarChart).painter! as BarChartPainter;
      expect(painter.barColor, Colors.red);
    });

    testWidgets(
      'a bar chart leaves the room its top label needs, at any size',
      (tester) async {
        for (final scale in [1.0, 1.3, 2.0]) {
          await show(
            tester,
            const BarChart(
              values: [1],
              maxValue: 2,
              maxLabel: '1500 e Ft',
              firstLabel: '2025.12.',
              lastLabel: 'ez a hónap',
              semanticLabel: 'd',
            ),
            scale: scale,
          );
          final picture = find.descendant(
            of: find.byType(BarChart),
            matching: find.byType(CustomPaint),
          );
          final painter = paintOf(tester, BarChart).painter! as BarChartPainter;
          final wide = labelWidth(
            '1500 e Ft',
            painter.labelStyle,
            painter.textScaler,
          );
          expect(painter.plotLeft, plotLeftFor(wide), reason: 'scale $scale');
          expect(painter.plotLeft, greaterThan(defaultPlotLeft));
          // nothing it draws is cut off at an edge of the picture
          final width = tester.getSize(picture).width;
          final canvas = TestRecordingCanvas();
          painter.paint(canvas, tester.getSize(picture));
          var words = 0;
          for (final call in canvas.invocations) {
            if (call.invocation.memberName != #drawParagraph) continue;
            words++;
            final paragraph =
                call.invocation.positionalArguments[0] as ui.Paragraph;
            final at = call.invocation.positionalArguments[1] as Offset;
            expect(
              at.dx,
              greaterThanOrEqualTo(0),
              reason: 'left, scale $scale',
            );
            expect(
              at.dx + paragraph.longestLine,
              lessThanOrEqualTo(width + 0.01),
              reason: 'right, scale $scale',
            );
          }
          expect(words, 4);
        }
      },
    );

    testWidgets('a short label keeps the usual margin', (tester) async {
      await show(
        tester,
        const BarChart(
          values: [1],
          maxValue: 2,
          maxLabel: 'a',
          firstLabel: 'b',
          lastLabel: 'c',
          semanticLabel: 'd',
        ),
      );
      final painter = paintOf(tester, BarChart).painter! as BarChartPainter;
      expect(painter.plotLeft, defaultPlotLeft);
    });

    testWidgets('the picture is as wide as the room and as tall as asked', (
      tester,
    ) async {
      await show(tester, bar());
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(BarChart),
            matching: find.byType(CustomPaint),
          ),
        ),
        const Size(800, 170),
      );
      await show(tester, bar(height: 120));
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(BarChart),
            matching: find.byType(CustomPaint),
          ),
        ),
        const Size(800, 120),
      );
      await show(tester, line());
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(LineChart),
            matching: find.byType(CustomPaint),
          ),
        ),
        const Size(800, 190),
      );
      await show(tester, line(height: 100));
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(LineChart),
            matching: find.byType(CustomPaint),
          ),
        ),
        const Size(800, 100),
      );
    });

    testWidgets('the labels follow the system text size, but only up to 1.3×', (
      tester,
    ) async {
      for (final (scale, drawn) in [(1.0, 10.0), (1.2, 12.0), (2.0, 13.0)]) {
        await show(tester, bar(), scale: scale);
        final b = paintOf(tester, BarChart).painter! as BarChartPainter;
        expect(
          b.textScaler.scale(10),
          closeTo(drawn, 1e-9),
          reason: 'bars $scale',
        );
        await show(tester, line(), scale: scale);
        final l = paintOf(tester, LineChart).painter! as LineChartPainter;
        expect(
          l.textScaler.scale(10),
          closeTo(drawn, 1e-9),
          reason: 'lines $scale',
        );
      }
    });

    testWidgets('a screen reader gets the words, as a picture', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, bar());
      expect(
        tester.getSemantics(find.byType(BarChart)),
        matchesSemantics(label: 'Heti edzésidő: sok', isImage: true),
      );
      await show(tester, line());
      expect(
        tester.getSemantics(find.byType(LineChart)),
        matchesSemantics(label: 'Hangulat: jó', isImage: true),
      );
      handle.dispose();
    });
  });
}
