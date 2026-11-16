import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:kvantum_app/journal/photo_import.dart';
import 'package:kvantum_app/journal/photo_picker.dart';
import 'package:kvantum_app/journal/photo_pipeline.dart';

/// A real, tiny JPEG (4 x 3 pixels) for the places where a picture is stored.
final Uint8List tinyJpeg = img.encodeJpg(img.Image(width: 4, height: 3));

/// A real picture with colour in it (a diagonal gradient, 3:2), for the scenes
/// that are looked at: every [seed] gives its own colour, so a row of them can
/// be told apart.
Uint8List colorfulJpeg(int seed, {int width = 96, int height = 64}) {
  final image = img.Image(width: width, height: height);
  final hue = (seed * 47) % 360;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final t = (x + y) / (width + height);
      final (r, g, b) = _hsv(hue + 60 * t, 0.55 + 0.3 * t, 0.95 - 0.35 * t);
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return img.encodeJpg(image, quality: 85);
}

(int, int, int) _hsv(double hue, double s, double v) {
  final h = (hue % 360) / 60;
  final c = v * s;
  final x = c * (1 - ((h % 2) - 1).abs());
  final (r, g, b) = switch (h.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  final m = v - c;
  int ch(double n) => ((n + m) * 255).round().clamp(0, 255);
  return (ch(r), ch(g), ch(b));
}

/// A chooser of pictures that needs no dialog: it gives [next] (the files the
/// user "chose"), and counts how often it was asked.
class FakePicker implements PhotoPicker {
  List<PickedPhoto> next = const [];
  int calls = 0;

  /// Thrown instead of choosing, when set (a chooser that cannot open).
  Object? failWith;

  @override
  Future<List<PickedPhoto>> pick() async {
    calls++;
    final f = failWith;
    if (f != null) throw f;
    return next;
  }
}

/// A file the user "chose": its [name] only matters for its ending.
PickedPhoto chosen(String name, {int? size, int first = 1}) => PickedPhoto(
  name: name,
  size: size,
  read: () async => Uint8List.fromList([first, 2, 3, 4]),
);

/// What makes a picture of a file in the tests that have no use for the engine:
/// a tiny JPEG at the size the file's first byte says (a file that starts with
/// 0 is no picture).
Future<ProcessedPhoto?> fakeProcessor(Uint8List source) async {
  if (source.isEmpty || source.first == 0) return null;
  return ProcessedPhoto(tinyJpeg, 1200, 800);
}
