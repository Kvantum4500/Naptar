import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/journal/photo_import.dart';
import 'package:kvantum_app/journal/photo_pipeline.dart';
import 'package:kvantum_app/ui/journal/photo_widgets.dart'
    show thumbDecodeWidth;
import 'package:kvantum_core/kvantum_core.dart' show PhotoRef;
import 'package:uuid/uuid.dart';

/// The edges of the pictures of the diary that nothing held until the
/// deliberate breakage round of the 8th round: the exact quality and colours
/// of the JPEG, the limits of the files taken in to the byte, what the log is
/// told (codes, never names), what a full disk is, and how the folder keeps a
/// picture safe while it is written.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the JPEG of the diary', () {
    test('is the one of quality 85 with the chroma of a photo', () {
      const w = 40, h = 32;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          rgba[i] = (x * 6) % 256;
          rgba[i + 1] = (y * 8) % 256;
          rgba[i + 2] = (x * y * 3) % 256;
          rgba[i + 3] = 255;
        }
      }
      final expected = img.encodeJpg(
        img.Image.fromBytes(
          width: w,
          height: h,
          bytes: Uint8List.fromList(rgba).buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        ),
        quality: 85,
        chroma: img.JpegChroma.yuv420,
      );
      expect(encodeJpegFromRgba(rgba, w, h), expected);
    });

    test('has every see-through pixel laid on white', () {
      final jpeg = encodeJpegFromRgba(Uint8List(8 * 8 * 4), 8, 8);
      final back = img.decodeJpg(jpeg)!;
      for (final (x, y) in [(0, 0), (3, 5), (7, 7)]) {
        final px = back.getPixel(x, y);
        expect(
          [px.r, px.g, px.b].every((c) => c > 235),
          isTrue,
          reason: 'the pixel at $x, $y is $px',
        );
      }
    });

    test('lays the last pixel on white as well as the others', () {
      // (white all over; the last pixel, a quarter of a light grey, as the
      // engine gives it: only laying it on white makes it light)
      final rgba = Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 255);
      rgba.setRange(63 * 4, 64 * 4, [60, 60, 60, 64]);
      final px = img.decodeJpg(encodeJpegFromRgba(rgba, 8, 8))!.getPixel(7, 7);
      expect(px.r, greaterThan(235));
      expect(px.g, greaterThan(235));
      expect(px.b, greaterThan(235));
    });

    test(
      'mixes a half see-through colour with white as that colour looks',
      () async {
        final png = img.Image(width: 16, height: 16, numChannels: 4);
        for (final px in png) {
          px
            ..r = 100
            ..g = 200
            ..b = 50
            ..a = 128;
        }
        final made = await processPhoto(Uint8List.fromList(img.encodePng(png)));
        final px = img.decodeJpg(made!.jpeg)!.getPixel(8, 8);
        // 100 * 128/255 + 255 * 127/255 = 177, 227, 152 (a JPEG is not exact)
        expect(px.r, inInclusiveRange(165, 190));
        expect(px.g, inInclusiveRange(215, 240));
        expect(px.b, inInclusiveRange(140, 165));
      },
    );
  });

  group('the width a small picture is decoded at', () {
    PhotoRef shape(int w, int h) =>
        PhotoRef(id: 'a', width: w, height: h, bytes: 1);

    test('is the side of the square, but wider for a wide picture', () {
      // (the shorter side fills the square, so a wide one needs more width)
      expect(thumbDecodeWidth(shape(800, 800), 100), 100);
      expect(thumbDecodeWidth(shape(800, 1600), 100), 100);
      expect(thumbDecodeWidth(shape(1600, 800), 100), 200);
      expect(thumbDecodeWidth(shape(1200, 800), 100), 150);
    });

    test('is twice the side when the size of the picture is not known', () {
      expect(thumbDecodeWidth(shape(0, 800), 100), 200);
      expect(thumbDecodeWidth(shape(800, 0), 100), 200);
    });

    test('is rounded up, and never nothing', () {
      expect(thumbDecodeWidth(shape(1200, 800), 101), 152);
      expect(thumbDecodeWidth(shape(800, 800), 0), 1);
    });
  });

  group('the files that are taken in', () {
    late MemoryPhotoFiles files;
    late MemoryDiagSink sink;
    late DiagLog log;

    Future<ProcessedPhoto?> fakeProcess(Uint8List source) async {
      // (a file whose first byte is 0 is no picture)
      if (source.isEmpty || source.first == 0) return null;
      return ProcessedPhoto(Uint8List.fromList([0xFF, 0xD8, 1]), 800, 600);
    }

    PhotoImporter importer({String Function()? newId, bool withLog = true}) =>
        PhotoImporter(
          files: files,
          processor: fakeProcess,
          newId: newId,
          log: withLog ? log : null,
        );

    PickedPhoto pick(
      String name, {
      int? size,
      int first = 1,
      int length = 10,
    }) => PickedPhoto(
      name: name,
      size: size,
      read: () async =>
          Uint8List.fromList([first, ...List.filled(length - 1, 7)]),
    );

    Future<String> logText() async {
      await log.flush();
      return sink.lines.join('\n');
    }

    setUp(() {
      files = MemoryPhotoFiles();
      sink = MemoryDiagSink();
      log = DiagLog()..attach(sink);
    });

    test('a file the picker says is 10 MB is no problem', () async {
      final r = await importer().import([
        pick('big.jpg', size: 10 * 1024 * 1024),
      ], room: 5);
      expect(r.added, hasLength(1));
      expect(r.problems, isEmpty);
    });

    test(
      'a file of exactly 40 MB is taken, one byte more is not (picker)',
      () async {
        const limit = 40 * 1024 * 1024;
        final r = await importer().import([
          pick('a.jpg', size: limit),
          pick('b.jpg', size: limit + 1),
        ], room: 5);
        expect(r.added, hasLength(1));
        expect(r.problems, {PhotoProblem.tooBig: 1});
      },
    );

    test(
      'a file of exactly 40 MB is taken, one byte more is not (read)',
      () async {
        const limit = 40 * 1024 * 1024;
        PickedPhoto readOf(String name, int length) => PickedPhoto(
          name: name,
          read: () async => Uint8List(length)..[0] = 1,
        );
        final r = await importer().import([
          readOf('a.jpg', limit),
          readOf('b.jpg', limit + 1),
        ], room: 5);
        expect(r.added, hasLength(1));
        expect(r.problems, {PhotoProblem.tooBig: 1});
      },
    );

    test('a round with a problem of any kind is a thing to tell', () {
      expect(const PhotoImportResult([]).hasProblems, isFalse);
      for (final problem in PhotoProblem.values) {
        expect(
          PhotoImportResult([], problems: {problem: 1}).hasProblems,
          isTrue,
          reason: '$problem',
        );
      }
    });

    test('a HEIC file that cannot be converted is told to the log by a code, '
        'without its name', () async {
      final r = await importer().import([
        pick('Titkos-nyaralas.heic', first: 0),
      ], room: 5);
      expect(r.problems, {PhotoProblem.heic: 1});
      final text = await logText();
      expect(text, contains('photo.heic_unsupported'));
      expect(text, isNot(contains('photo.decode_failed')));
      expect(text, isNot(contains('Titkos')));
    });

    test(
      'a file that is no picture is told to the log, without its name',
      () async {
        final r = await importer().import([
          pick('Titkos-jegyzet.txt', first: 0),
        ], room: 5);
        expect(r.problems, {PhotoProblem.notAPicture: 1});
        final text = await logText();
        expect(text, contains('photo.decode_failed'));
        expect(text, isNot(contains('Titkos')));
      },
    );

    test(
      'a HEIC file is never written, so a write error cannot touch it',
      () async {
        files.failWrite = FileSystemException(
          'x',
          '/p',
          const OSError('io', 5),
        );
        final r = await importer().import([pick('a.heic', first: 0)], room: 5);
        expect(r.added, isEmpty);
        expect(r.problems, {PhotoProblem.heic: 1});
        expect(files.names, isEmpty);
      },
    );

    test('a full disk is told by its codes on Linux, Android and Windows', () async {
      for (final code in [28, 112, 39]) {
        files.failWrite = FileSystemException('x', '/p', OSError('full', code));
        final r = await importer().import([pick('a.jpg')], room: 5);
        expect(r.problems, {PhotoProblem.diskFull: 1}, reason: '$code');
      }
      // another code, and something that is no file error at all, are not that
      for (final other in <Object>[
        FileSystemException('x', '/p', const OSError('io', 38)),
        StateError('nem fájlhiba'),
      ]) {
        files.failWrite = other;
        final r = await importer().import([pick('a.jpg')], room: 5);
        expect(r.problems, {PhotoProblem.notSaved: 1}, reason: '$other');
      }
    });

    test(
      'the log gets the code of a write error, not what the system said',
      () async {
        files.failWrite = FileSystemException(
          'Titkos üzenet',
          '/home/titkos/mappa',
          const OSError('Titkos OS-hiba', 5),
        );
        await importer().import([pick('a.jpg')], room: 5);
        final text = await logText();
        expect(text, contains('photo.write_failed'));
        expect(text, isNot(contains('Titkos')));
        expect(text, isNot(contains('titkos')));
      },
    );

    test('pictures get an id of their own when nobody says which', () async {
      final r = await importer().import([
        pick('a.jpg'),
        pick('b.jpg'),
      ], room: 5);
      expect(r.added, hasLength(2));
      expect(r.added.first.id, isNot(r.added.last.id));
      expect(files.names, hasLength(2));
      expect(files.names.every(isPhotoFileName), isTrue);
    });
  });

  group('the folder of pictures', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('photo-edges');
    });
    tearDown(() => dir.delete(recursive: true));

    test('names only what is an id and a picture ending', () {
      expect(isPhotoFileName('abc-123_X.jpg'), isTrue);
      expect(isPhotoFileName('${const Uuid().v4()}.jpg'), isTrue);
      expect(isPhotoFileName('abc.jpg.tmp'), isFalse);
      expect(isPhotoFileName('abc.jpgx'), isFalse);
      expect(isPhotoFileName('../abc.jpg'), isFalse);
      expect(isPhotoFileName('a b.jpg'), isFalse);
      expect(isPhotoFileName('abc.txt'), isFalse);
    });

    test(
      'a picture is written under another name first: the old one is safe',
      () async {
        final files = DirPhotoFiles(dir);
        await files.write('a1.jpg', Uint8List.fromList([1, 2, 3]));
        // (the other name is taken by a folder: the new bytes cannot go there)
        await Directory('${dir.path}/a1.jpg.tmp').create();
        await expectLater(
          files.write('a1.jpg', Uint8List.fromList([9, 9])),
          throwsA(isA<FileSystemException>()),
        );
        expect(await files.read('a1.jpg'), [1, 2, 3]);
      },
    );

    test('tells when each picture was written, as the file says', () async {
      final files = DirPhotoFiles(dir);
      await files.write('a1.jpg', Uint8List.fromList([1]));
      final when = DateTime.utc(2026, 11, 1, 12);
      File('${dir.path}/a1.jpg').setLastModifiedSync(when);
      final listed = await files.list();
      expect(listed.single.name, 'a1.jpg');
      expect(listed.single.modified.toUtc(), when);
      expect(listed.single.size, 1);
    });

    test('tells the same of a half-written file, and lists it apart', () async {
      final files = DirPhotoFiles(dir);
      await files.write('a1.jpg', Uint8List.fromList([1]));
      File('${dir.path}/b2.jpg.tmp').writeAsBytesSync([7, 7, 7]);
      final when = DateTime.utc(2026, 11, 1, 12);
      File('${dir.path}/b2.jpg.tmp').setLastModifiedSync(when);
      final leftovers = await files.listLeftovers();
      expect(leftovers.single.name, 'b2.jpg.tmp');
      expect(leftovers.single.modified.toUtc(), when);
      expect(leftovers.single.size, 3);
      expect((await files.list()).single.name, 'a1.jpg');
    });

    test('a write that is cut short is what the sweep later finds', () async {
      // (the file a write puts down first is the very name the sweep looks for)
      final files = DirPhotoFiles(dir);
      await Directory('${dir.path}/a1.jpg').create(); // a folder is in the way
      await expectLater(
        files.write('a1.jpg', Uint8List.fromList([1])),
        throwsA(isA<FileSystemException>()),
      );
      // the failed write cleaned up after itself ...
      expect(await files.listLeftovers(), isEmpty);
      // ... and one that died without the chance to is found by its name
      File('${dir.path}/a1.jpg.tmp').writeAsBytesSync([1]);
      expect((await files.listLeftovers()).map((f) => f.name), ['a1.jpg.tmp']);
    });
  });
}
