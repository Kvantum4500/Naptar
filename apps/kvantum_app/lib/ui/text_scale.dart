import 'package:flutter/widgets.dart';

/// Sizes that follow the text size the user chose in the system settings (up
/// to 200 % and more): a row made for 11-point text must be as tall as the
/// same text is at 22 points.
extension TextScaleContext on BuildContext {
  /// [size], a font size made for the normal text size, as the user's text
  /// size makes it. (The scaler may be non-linear: ask it, do not multiply.)
  double scaled(double size) => MediaQuery.textScalerOf(this).scale(size);

  /// How much larger than normal the text is (1 = normal), kept between [min]
  /// and [max]. For a height made for text at the normal size: multiply it.
  double textFactor({double min = 1, double max = double.infinity}) =>
      (scaled(14) / 14).clamp(min, max);
}

/// The width [text] takes on one line in [style] at the user's text size (to
/// decide whether two things fit side by side).
double textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The most the labels of a dense grid (the day names of the week view, the
/// hours down its side) grow with the text size: they sit in columns a phone
/// makes 44 pixels wide. Everything that can wrap or scroll keeps growing.
const double kGridLabelMaxScale = 1.3;

/// [child] with the text size capped at [kGridLabelMaxScale].
class GridLabelScale extends StatelessWidget {
  const GridLabelScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: kGridLabelMaxScale,
    child: child,
  );
}
