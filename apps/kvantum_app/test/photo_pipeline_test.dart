import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kvantum_app/journal/photo_pipeline.dart';

/// A picture of a phone, made up: a JPEG of [w] x [h] with a gradient (and,
/// when asked, a maker's name and a turn the way the camera writes them).
Uint8List jpegOf(int w, int h, {int? orientation, String? make}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, 128);
    }
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  if (make != null) image.exif.imageIfd.make = make;
  return img.encodeJpg(image, quality: 90);
}

bool contains(Uint8List bytes, String text) {
  final needle = text.codeUnits;
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

/// The picture engine of the test (the decoders of the framework) needs the
/// real event loop, not the fake one of a widget test: these are plain tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the size a picture is made', () {
    test('has the longer side at most 1600, the ratio kept', () {
      expect(photoTargetSize(3000, 2000), (width: 1600, height: 1067));
      expect(photoTargetSize(2000, 3000), (width: 1067, height: 1600));
      expect(photoTargetSize(4000, 4000), (width: 1600, height: 1600));
      expect(photoTargetSize(12000, 100), (width: 1600, height: 13));
    });

    test('is the size it has when that is smaller: nothing is made bigger', () {
      expect(photoTargetSize(800, 600), (width: 800, height: 600));
      expect(photoTargetSize(1600, 1200), (width: 1600, height: 1200));
      expect(photoTargetSize(1, 1), (width: 1, height: 1));
    });

    test('is never less than a pixel', () {
      final s = photoTargetSize(30000, 1);
      expect(s.width, 1600);
      expect(s.height, 1);
    });
  });

  group('a picture made of a file', () {
    test('a big one is made smaller, as a JPEG', () async {
      final made = await processPhoto(jpegOf(3000, 2000));
      expect(made, isNotNull);
      expect((made!.width, made.height), (1600, 1067));
      // (FFD8: the start of a JPEG)
      expect(made.jpeg.sublist(0, 2), [0xFF, 0xD8]);
      final back = img.decodeJpg(made.jpeg)!;
      expect((back.width, back.height), (1600, 1067));
    });

    test('a portrait one has its longer side at 1600 as well', () async {
      final made = await processPhoto(jpegOf(2000, 3000));
      expect((made!.width, made.height), (1067, 1600));
    });

    test('a small one stays as small as it was', () async {
      final made = await processPhoto(jpegOf(200, 100));
      expect((made!.width, made.height), (200, 100));
    });

    test(
      'a picture a phone holds on its side is turned the right way',
      () async {
        // (stored 400 x 200, "turn it a quarter": it is a portrait picture)
        final made = await processPhoto(jpegOf(400, 200, orientation: 6));
        expect((made!.width, made.height), (200, 400));
      },
    );

    test('the data of the camera does not go along', () async {
      final source = jpegOf(300, 200, make: 'TitkosTelefon', orientation: 1);
      expect(
        contains(source, 'TitkosTelefon'),
        isTrue,
        reason: 'the test file',
      );
      final made = await processPhoto(source);
      expect(contains(made!.jpeg, 'TitkosTelefon'), isFalse);
      expect(contains(made.jpeg, 'Exif'), isFalse);
      expect(img.decodeJpg(made.jpeg)!.exif.isEmpty, isTrue);
    });

    test('a PNG is taken, and what is see-through becomes white', () async {
      final png = img.Image(width: 60, height: 40, numChannels: 4);
      for (final px in png) {
        px
          ..r = 255
          ..g = 0
          ..b = 0
          ..a = 0;
      }
      final made = await processPhoto(img.encodePng(png));
      expect(made, isNotNull);
      final back = img.decodeJpg(made!.jpeg)!;
      final px = back.getPixel(30, 20);
      expect(px.r, greaterThan(240));
      expect(px.g, greaterThan(240));
      expect(px.b, greaterThan(240));
    });

    test('a solid colour keeps its colour', () async {
      final png = img.Image(width: 64, height: 64);
      for (final px in png) {
        px
          ..r = 200
          ..g = 30
          ..b = 30;
      }
      final made = await processPhoto(img.encodePng(png));
      final px = img.decodeJpg(made!.jpeg)!.getPixel(32, 32);
      expect(px.r, closeTo(200, 12));
      expect(px.g, closeTo(30, 12));
      expect(px.b, closeTo(30, 12));
    });

    test('bytes that are no picture give nothing, and no error', () async {
      expect(await processPhoto(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(await processPhoto(Uint8List(0)), isNull);
      expect(
        await processPhoto(Uint8List.fromList('ez egy szöveg'.codeUnits)),
        isNull,
      );
    });

    test(
      'a file cut short gives nothing or something, never an error',
      () async {
        final whole = jpegOf(800, 600);
        final cut = Uint8List.sublistView(whole, 0, whole.length ~/ 3);
        // (what the decoder makes of half a file is its own business: the call
        // must come back, with a picture or without)
        await processPhoto(cut);
      },
    );
  });

  group('the JPEG of raw pixels', () {
    test('lays a half see-through pixel on white', () {
      // premultiplied: red at half is (128, 0, 0, 128)
      final rgba = Uint8List.fromList([128, 0, 0, 128, 128, 0, 0, 128]);
      final jpeg = encodeJpegFromRgba(rgba, 2, 1);
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      // (the buffer itself now says what the picture is: opaque, red on white)
      expect(rgba[3], 255);
      expect(rgba[0], 255);
      expect(rgba[1], 127);
    });

    test('leaves an opaque pixel as it is', () {
      final rgba = Uint8List.fromList([10, 20, 30, 255]);
      encodeJpegFromRgba(rgba, 1, 1);
      expect(rgba, [10, 20, 30, 255]);
    });
  });
}
