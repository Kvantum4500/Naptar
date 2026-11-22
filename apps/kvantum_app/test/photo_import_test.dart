import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/journal/photo_import.dart';
import 'package:kvantum_app/journal/photo_pipeline.dart';
import 'package:kvantum_core/kvantum_core.dart';

/// Taking the chosen pictures into the diary (8th round): each becomes a file
/// of its own with an id for a name, what cannot be converted is told (9th
/// round: it is never kept as the file it was), and nothing of the original
/// file's name goes anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPhotoFiles files;
  late MemoryDiagSink sink;
  late DiagLog log;
  var n = 0;
  var reads = 0;

  Future<ProcessedPhoto?> fakeProcess(Uint8List source) async {
    // (a file whose first byte is 0 is no picture)
    if (source.isEmpty || source.first == 0) return null;
    return ProcessedPhoto(
      Uint8List.fromList([0xFF, 0xD8, source.first]),
      800,
      600,
    );
  }

  PickedPhoto pick(String name, {int first = 1, int? size, int length = 10}) =>
      PickedPhoto(
        name: name,
        size: size,
        read: () async {
          reads++;
          return Uint8List.fromList([first, ...List.filled(length - 1, 7)]);
        },
      );

  PhotoImporter importer({PhotoProcessor? processor}) => PhotoImporter(
    files: files,
    processor: processor ?? fakeProcess,
    newId: () => 'id${++n}',
    log: log,
  );

  setUp(() {
    files = MemoryPhotoFiles();
    sink = MemoryDiagSink();
    log = DiagLog()..attach(sink);
    n = 0;
    reads = 0;
  });

  Future<String> logText() async {
    await log.flush();
    return sink.lines.join('\n');
  }

  group('the pictures that are taken in', () {
    test(
      'each is a file named by a new id, with its size in the reference',
      () async {
        final r = await importer().import([
          pick('a.jpg', first: 5),
          pick('b.png', first: 6),
        ], room: 12);
        expect(r.added.map((p) => p.fileName), ['id1.jpg', 'id2.jpg']);
        expect(
          r.added.first,
          const PhotoRef(id: 'id1', width: 800, height: 600, bytes: 3),
        );
        expect(files.names, containsAll(['id1.jpg', 'id2.jpg']));
        expect(await files.read('id1.jpg'), [0xFF, 0xD8, 5]);
        expect(r.hasProblems, isFalse);
        expect(r.notice, isNull);
      },
    );

    test('keep the order they were chosen in', () async {
      final r = await importer().import([
        for (var i = 1; i <= 5; i++) pick('x$i.jpg', first: i),
      ], room: 12);
      expect(
        [for (final p in r.added) (await files.read(p.fileName))![2]].length,
        5,
      );
      expect(
        [for (final p in r.added) p.id],
        ['id1', 'id2', 'id3', 'id4', 'id5'],
      );
    });

    test(
      'are not more than there is room for; the rest is not even read',
      () async {
        final r = await importer().import([
          for (var i = 0; i < 5; i++) pick('p$i.jpg'),
        ], room: 2);
        expect(r.added, hasLength(2));
        expect(reads, 2);
        expect(r.problems[PhotoProblem.tooMany], 3);
        expect(
          r.notice,
          'Egy bejegyzéshez legföljebb 12 kép tartozhat, 3 kimaradt.',
        );
      },
    );

    test('with no room at all take nothing in', () async {
      final r = await importer().import([pick('p.jpg')], room: 0);
      expect(r.added, isEmpty);
      expect(reads, 0);
      expect(files.names, isEmpty);
    });

    test('that are too big by what the picker said are not read', () async {
      final r = await importer().import([
        pick('big.jpg', size: maxPhotoSourceBytes + 1),
      ], room: 12);
      expect(r.added, isEmpty);
      expect(reads, 0);
      expect(r.problems[PhotoProblem.tooBig], 1);
      expect(r.notice, '1 kép túl nagy (legfeljebb 40 MB).');
    });

    test('that are too big when they are read are left out too', () async {
      final big = PickedPhoto(
        name: 'big.jpg',
        read: () async => Uint8List(maxPhotoSourceBytes + 1)..[0] = 1,
      );
      final r = await importer().import([big], room: 12);
      expect(r.problems[PhotoProblem.tooBig], 1);
      expect(files.names, isEmpty);
    });

    test('that cannot be read are told of, the others go on', () async {
      final broken = PickedPhoto(
        name: 'x.jpg',
        read: () => throw const FileSystemException(
          'nem olvasható',
          '/tmp/titkos/x.jpg',
        ),
      );
      final r = await importer().import([broken, pick('ok.jpg')], room: 12);
      expect(r.added.single.id, 'id1');
      expect(r.problems[PhotoProblem.unreadable], 1);
      expect(r.notice, '1 képet nem sikerült beolvasni.');
    });

    test('that are no pictures are told of', () async {
      final r = await importer().import([
        pick('a.jpg', first: 0),
        pick('b.txt', first: 0),
        pick('c', first: 0),
      ], room: 12);
      expect(r.added, isEmpty);
      expect(r.problems[PhotoProblem.notAPicture], 3);
      expect(r.notice, '3 fájl nem kép, vagy ezen az eszközön nem olvasható.');
      expect(files.names, isEmpty);
    });

    test('of a kind this device cannot convert (HEIC) are not taken in as they were', () async {
      // (a copy would carry the place and the time of the shot, could not be
      // shown here and could not go to the other devices)
      final r = await importer().import([
        pick('IMG_1.HEIC', first: 0, length: 50),
        pick('b.heif', first: 0),
        pick('ok.jpg'),
      ], room: 12);
      expect(r.added.map((p) => p.fileName), ['id3.jpg']);
      expect(r.problems, {PhotoProblem.heic: 2});
      expect(files.names.toList(), ['id3.jpg']);
      expect(
        r.notice,
        '2 HEIC/HEIF kép ezen az eszközön nem alakítható át, ezért kimaradt. '
        'Mentsd el JPEG vagy PNG formátumban, és azt add hozzá.',
      );
      expect(r.hasProblems, isTrue);
    });

    test(
      'of a kind that should be readable but is not are no pictures',
      () async {
        final r = await importer().import([
          pick('x.jpg', first: 0),
          pick('y.png', first: 0),
          pick('z.webp', first: 0),
        ], room: 12);
        expect(r.added, isEmpty);
        expect(r.problems, {PhotoProblem.notAPicture: 3});
        expect(files.names, isEmpty);
      },
    );

    test('a HEIC that a device can read is a picture like any other', () async {
      // (a phone has the decoder: what comes out is a JPEG, the ending of the
      // file it came from is gone)
      final r = await importer().import([
        pick('IMG_2.HEIC', first: 5),
      ], room: 12);
      expect(r.added.map((p) => p.fileName), ['id1.jpg']);
      expect(r.problems, isEmpty);
      expect(r.notice, isNull);
    });

    test('that the processor fails on with an error are no pictures', () async {
      final r = await importer(processor: (_) => throw StateError('baj'))
          .import([pick('x.jpg')], room: 12);
      expect(r.added, isEmpty);
      expect(r.problems[PhotoProblem.notAPicture], 1);
    });
  });

  group('when the device cannot keep them', () {
    test('a full disk is told in words, and no reference is made', () async {
      files.failWrite = const FileSystemException(
        'tele',
        '/x',
        OSError('No space left on device', 28),
      );
      final r = await importer().import([pick('a.jpg')], room: 12);
      expect(r.added, isEmpty);
      expect(r.problems[PhotoProblem.diskFull], 1);
      expect(r.notice, 'Nincs elég hely az eszközön, 1 kép nem került be.');
    });

    test('Windows says the same with another number', () async {
      files.failWrite = const FileSystemException(
        'tele',
        r'C:\x',
        OSError('disk full', 112),
      );
      final r = await importer().import([pick('a.jpg')], room: 12);
      expect(r.problems[PhotoProblem.diskFull], 1);
    });

    test('another trouble with writing is told differently', () async {
      files.failWrite = const FileSystemException(
        'nem',
        '/x',
        OSError('denied', 13),
      );
      final r = await importer().import([
        pick('a.jpg'),
        pick('b.jpg'),
      ], room: 12);
      expect(r.problems[PhotoProblem.notSaved], 2);
      expect(r.notice, '2 képet nem sikerült elmenteni.');
    });
  });

  group('what is told and what is not', () {
    test(
      'nothing of the name or the place of a file reaches the log',
      () async {
        final broken = PickedPhoto(
          name: 'Titkos nyaralás.jpg',
          read: () => throw const FileSystemException(
            'nem olvasható',
            '/storage/emulated/0/DCIM/Titkos nyaralás.jpg',
          ),
        );
        files.failWrite = const FileSystemException(
          'tele',
          '/data/user/0/app/Titkos nyaralás.jpg',
          OSError('full', 28),
        );
        await importer().import([
          broken,
          pick('Titkos kép.jpg'),
          pick('Titkos mappa.heic', first: 0),
        ], room: 12);
        final text = await logText();
        expect(text, isNotEmpty);
        expect(text.toLowerCase(), isNot(contains('titkos')));
        expect(text, isNot(contains('/storage')));
        expect(text, isNot(contains('DCIM')));
        expect(text, contains('photo.read_failed'));
        expect(text, contains('photo.disk_full'));
      },
    );

    test(
      'nothing of the name of a file is the name of the stored one',
      () async {
        await importer().import([
          pick('../../etc/passwd.jpg'),
          pick('a b/c.jpg'),
        ], room: 12);
        for (final name in files.names) {
          expect(isPhotoFileName(name), isTrue, reason: name);
          expect(name, startsWith('id'));
        }
      },
    );

    test(
      'a round that went well says nothing, one that did not says it all',
      () async {
        final r = await importer().import([
          pick('big.jpg', size: maxPhotoSourceBytes + 1),
          pick('a.jpg', first: 0),
          pick('ok.jpg'),
        ], room: 12);
        expect(r.added, hasLength(1));
        expect(
          r.notice,
          '1 kép túl nagy (legfeljebb 40 MB); 1 fájl nem kép, vagy ezen az eszközön nem olvasható.',
        );
      },
    );

    test(
      'the way out of a HEIC file is said last, in a sentence of its own',
      () async {
        final r = await importer().import([
          pick('a.heic', first: 0),
          pick('big.jpg', size: maxPhotoSourceBytes + 1),
          pick('b.txt', first: 0),
        ], room: 12);
        expect(
          r.notice,
          '1 kép túl nagy (legfeljebb 40 MB); '
          '1 fájl nem kép, vagy ezen az eszközön nem olvasható; '
          '1 HEIC/HEIF kép ezen az eszközön nem alakítható át, ezért kimaradt. '
          'Mentsd el JPEG vagy PNG formátumban, és azt add hozzá.',
        );
      },
    );
  });

  group('with the real engine', () {
    Uint8List png(int w, int h) {
      final image = img.Image(width: w, height: h);
      for (final px in image) {
        px
          ..r = 30
          ..g = 120
          ..b = 200;
      }
      return img.encodePng(image);
    }

    test(
      'a picture is made smaller, stored as a JPEG and written down',
      () async {
        final r = await PhotoImporter(files: files, newId: () => 'real1')
            .import([
              PickedPhoto(
                name: 'IMG_0001.png',
                read: () async => png(2400, 1200),
              ),
            ], room: 12);
        final p = r.added.single;
        expect((p.width, p.height), (1600, 800));
        final stored = await files.read('real1.jpg');
        expect(stored, isNotNull);
        expect(p.bytes, stored!.length);
        final back = img.decodeJpg(stored)!;
        expect((back.width, back.height), (1600, 800));
      },
    );

    test('a file that is no picture is no picture', () async {
      final r = await PhotoImporter(files: files).import([
        PickedPhoto(
          name: 'jegyzet.jpg',
          read: () async => Uint8List.fromList('szöveg'.codeUnits),
        ),
      ], room: 12);
      expect(r.added, isEmpty);
      expect(r.problems[PhotoProblem.notAPicture], 1);
    });
  });
}
