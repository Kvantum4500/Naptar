import 'dart:io';
import 'dart:typed_data';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../diag/diag_log.dart';
import 'photo_files.dart';
import 'photo_pipeline.dart';

/// A file the user chose. Only the ending of its name is ever looked at: the
/// name itself (and the folder it was in) does not get into the diary, the
/// log or a record.
class PickedPhoto {
  const PickedPhoto({required this.name, required this.read, this.size});

  final String name;

  /// The bytes of the file (read when it is its turn, one picture at a time).
  final Future<Uint8List> Function() read;

  /// How big the file is, if the picker said so (a file that is too big is not
  /// read at all).
  final int? size;
}

/// Why a picture did not get into the diary.
enum PhotoProblem {
  /// Bigger than [maxPhotoSourceBytes].
  tooBig,

  /// The file could not be read.
  unreadable,

  /// Not a picture, or a kind this device cannot read.
  notAPicture,

  /// The entry has as many pictures as it can have.
  tooMany,

  /// No room on the device.
  diskFull,

  /// The picture was made but could not be saved.
  notSaved,

  /// A HEIC / HEIF file, which this device has no decoder for (Windows has
  /// none). It is not taken in as the file it is: what the diary keeps is
  /// always a JPEG without the data of the camera.
  heic,
}

/// What a round of choosing made.
class PhotoImportResult {
  const PhotoImportResult(this.added, {this.problems = const {}});

  /// The pictures that are in the diary now, in the order they were chosen.
  final List<PhotoRef> added;

  /// How many files each problem hit.
  final Map<PhotoProblem, int> problems;

  bool get hasProblems => problems.isNotEmpty;

  /// What to tell the user, in a sentence or two; null when all went well.
  String? get notice {
    final parts = <String>[];
    void add(PhotoProblem p, String Function(int n) say) {
      final n = problems[p];
      if (n != null && n > 0) parts.add(say(n));
    }

    add(PhotoProblem.tooBig, (n) => '$n kép túl nagy (legfeljebb 40 MB)');
    add(PhotoProblem.unreadable, (n) => '$n képet nem sikerült beolvasni');
    add(
      PhotoProblem.notAPicture,
      (n) => '$n fájl nem kép, vagy ezen az eszközön nem olvasható',
    );
    add(
      PhotoProblem.tooMany,
      (n) =>
          'egy bejegyzéshez legföljebb $maxJournalPhotos kép tartozhat, '
          '$n kimaradt',
    );
    add(
      PhotoProblem.diskFull,
      (n) => 'nincs elég hely az eszközön, $n kép nem került be',
    );
    add(PhotoProblem.notSaved, (n) => '$n képet nem sikerült elmenteni');
    // (last: it is two sentences, and the second says what to do)
    add(
      PhotoProblem.heic,
      (n) =>
          '$n HEIC/HEIF kép ezen az eszközön nem alakítható át, ezért '
          'kimaradt. Mentsd el JPEG vagy PNG formátumban, és azt add hozzá',
    );
    if (parts.isEmpty) return null;
    final text = parts.join('; ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }
}

/// What the log is told of a problem with a picture: a code and nothing else.
/// (The error the system gives carries the name and the folder of the file.)
class PhotoImportError implements Exception {
  const PhotoImportError(this.code);
  final String code;

  @override
  String toString() => code;
}

/// Takes the chosen files into the diary: each is read, made smaller and
/// written as a JPEG without the data of the camera, under a new id. A file
/// this device cannot convert (HEIC on Windows) is not taken in: a copy of it
/// would carry the place and the time of the shot, could not be shown here and
/// could not travel to the other devices. Nothing but a code goes to the log.
class PhotoImporter {
  PhotoImporter({
    required this.files,
    PhotoProcessor? processor,
    String Function()? newId,
    this.log,
  }) : _process = processor ?? processPhoto,
       _newId = newId ?? (() => const Uuid().v4());

  final PhotoFiles files;
  final PhotoProcessor _process;
  final String Function() _newId;
  final DiagLog? log;

  /// The endings of the kinds that the phones decode and others may not: a
  /// file of one of these that cannot be converted is told apart from a file
  /// that is no picture (the way out is another format).
  static const _heicEndings = {'heic', 'heif'};

  /// Takes in at most [room] of [picked], in order.
  Future<PhotoImportResult> import(
    List<PickedPhoto> picked, {
    required int room,
  }) async {
    final added = <PhotoRef>[];
    final problems = <PhotoProblem, int>{};
    void hit(PhotoProblem p) => problems[p] = (problems[p] ?? 0) + 1;

    for (final file in picked) {
      if (added.length >= room) {
        hit(PhotoProblem.tooMany);
        continue;
      }
      if ((file.size ?? 0) > maxPhotoSourceBytes) {
        hit(PhotoProblem.tooBig);
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await file.read();
      } catch (_) {
        log?.error(
          'journal',
          'photo.read_failed',
          const PhotoImportError('read'),
        );
        hit(PhotoProblem.unreadable);
        continue;
      }
      if (bytes.length > maxPhotoSourceBytes) {
        hit(PhotoProblem.tooBig);
        continue;
      }
      final id = _newId();
      ProcessedPhoto? made;
      try {
        made = await _process(bytes);
      } catch (_) {
        made = null;
      }
      if (made == null) {
        final ext = p.extension(file.name).toLowerCase().replaceFirst('.', '');
        if (_heicEndings.contains(ext)) {
          log?.info('journal', 'photo.heic_unsupported');
          hit(PhotoProblem.heic);
        } else {
          log?.error(
            'journal',
            'photo.decode_failed',
            const PhotoImportError('decode'),
          );
          hit(PhotoProblem.notAPicture);
        }
        continue;
      }
      final name = '$id.jpg';
      final ref = PhotoRef(
        id: id,
        width: made.width,
        height: made.height,
        bytes: made.jpeg.length,
      );
      try {
        await files.write(name, made.jpeg);
      } catch (e) {
        final full = _isDiskFull(e);
        log?.error(
          'journal',
          full ? 'photo.disk_full' : 'photo.write_failed',
          PhotoImportError(full ? 'disk_full' : 'write'),
        );
        hit(full ? PhotoProblem.diskFull : PhotoProblem.notSaved);
        continue;
      }
      added.add(ref);
    }
    return PhotoImportResult(added, problems: problems);
  }
}

/// Whether [e] says that the device is full (ENOSPC on Linux and Android,
/// ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL on Windows).
bool _isDiskFull(Object e) {
  if (e is! FileSystemException) return false;
  final code = e.osError?.errorCode;
  return code == 28 || code == 112 || code == 39;
}
