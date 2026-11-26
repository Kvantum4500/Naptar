import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';
import 'journal_draft_store.dart';
import 'photo_files.dart';

/// How long a picture nobody refers to is left alone before it is removed: the
/// entry may be being written (the picture is in the file before the entry is
/// saved), or a deletion may be taken back.
const orphanPhotoGrace = Duration(days: 2);

/// How long the half-written file of a picture is left alone: a write takes
/// seconds, so what is older than this is the leftover of one that was cut short
/// (the app was closed or killed between writing the file and moving it).
const leftoverPhotoGrace = Duration(hours: 1);

/// The daily tidying of the picture folder: a picture that no entry of the
/// diary and no draft refers to, and that is older than [orphanPhotoGrace], is
/// removed; so is the half-written file of a write that was cut short, once it
/// is older than [leftoverPhotoGrace]. It never touches a file that is not named
/// like ours.
class PhotoSweep {
  const PhotoSweep({
    required this.files,
    required this.records,
    required this.drafts,
    this.grace = orphanPhotoGrace,
    this.leftoverGrace = leftoverPhotoGrace,
  });

  final PhotoFiles files;
  final RecordRepository records;
  final JournalDraftStore drafts;
  final Duration grace;
  final Duration leftoverGrace;

  /// Removes what is due; returns how many files went.
  Future<int> run(DateTime now) async {
    var removed = 0;
    final stored = await files.list();
    if (stored.isNotEmpty) {
      final wanted = <String>{
        for (final e in journalEntries(await records.all(kindJournal)))
          for (final p in e.photos) p.fileName,
        ...?(await drafts.load())?.photos.map((p) => p.fileName),
      };
      for (final f in stored) {
        if (wanted.contains(f.name)) continue;
        if (now.difference(f.modified) < grace) continue;
        await files.delete(f.name);
        removed++;
      }
    }
    for (final f in await files.listLeftovers()) {
      if (now.difference(f.modified) < leftoverGrace) continue;
      await files.deleteLeftover(f.name);
      removed++;
    }
    return removed;
  }
}
