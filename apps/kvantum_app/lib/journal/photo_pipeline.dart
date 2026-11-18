import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// The longest side a picture has in the diary, in pixels (a bigger one is
/// made smaller; a smaller one stays as it is).
const photoLongSide = 1600;

/// How good the JPEG of the diary is (0-100): a photo of a phone, at this size,
/// takes a third to half a megabyte.
const photoJpegQuality = 85;

/// The largest file taken in at all (bytes). A bigger one is not read: it would
/// fill the memory of a phone, and the diary is no place for it.
const maxPhotoSourceBytes = 40 * 1024 * 1024;

/// A picture as it goes into the diary: a JPEG without any of the data the
/// camera wrote into the file (the place, the time, the make of the phone).
class ProcessedPhoto {
  const ProcessedPhoto(this.jpeg, this.width, this.height);
  final Uint8List jpeg;
  final int width;
  final int height;
}

/// What makes a picture of a file's bytes; null when the bytes are no picture
/// this device can read. (Replaced by tests that need no engine.)
typedef PhotoProcessor = Future<ProcessedPhoto?> Function(Uint8List source);

/// The side lengths a [width] x [height] picture is made, so that the longer
/// one is [longSide] at most (the picture is never made bigger).
({int width, int height}) photoTargetSize(
  int width,
  int height, {
  int longSide = photoLongSide,
}) {
  final scale = math.min(1.0, longSide / math.max(width, height));
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// Reads the picture with the engine of the app (the decoder of the phone: it
/// knows the formats of the phone, turns a photo the way it was held, and
/// reads a big file at a small size without filling the memory), makes it
/// smaller, and writes it as a JPEG in an isolate, so the screen does not
/// stand still. Returns null for bytes that are no picture.
Future<ProcessedPhoto?> processPhoto(Uint8List source) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(source);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 || descriptor.height <= 0) return null;
    final size = photoTargetSize(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: size.width,
      targetHeight: size.height,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final width = image.width;
    final height = image.height;
    final rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final jpeg = await Isolate.run(
      () => encodeJpegFromRgba(rgba, width, height),
    );
    return ProcessedPhoto(jpeg, width, height);
  } catch (_) {
    // (not a picture, or one this device cannot read: the caller decides what
    // is done with the file)
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// A JPEG of raw RGBA pixels (what the engine gives). A see-through pixel is
/// laid on white, as a JPEG has no see-through. Runs in an isolate.
Uint8List encodeJpegFromRgba(Uint8List rgba, int width, int height) {
  // (the engine's pixels are premultiplied: white behind them adds what is
  // missing of the colour)
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a == 255) continue;
    final rest = 255 - a;
    rgba[i] = math.min(255, rgba[i] + rest);
    rgba[i + 1] = math.min(255, rgba[i + 1] + rest);
    rgba[i + 2] = math.min(255, rgba[i + 2] + rest);
    rgba[i + 3] = 255;
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(
    image,
    quality: photoJpegQuality,
    chroma: img.JpegChroma.yuv420,
  );
}
