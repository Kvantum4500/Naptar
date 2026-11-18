import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';
import 'journal_draft_store.dart';
import 'photo_files.dart';

/// How long a picture nobody refers to is left alone before it is removed: the
/// entry may be being written (the picture is in the file before the entry is
/// saved), or a deletion may be taken back.
const orphanPhotoGrace = Duration(days: 2);

/// The daily tidying of the picture folder: a picture that no entry of the
/// diary and no draft refers to, and that is older than [orphanPhotoGrace], is
/// removed. It never touches a file that is not named like ours.
class PhotoSweep {
  const PhotoSweep({
    required this.files,
    required this.records,
    required this.drafts,
    this.grace = orphanPhotoGrace,
  });

  final PhotoFiles files;
  final RecordRepository records;
  final JournalDraftStore drafts;
  final Duration grace;

  /// Removes what is due; returns how many pictures went.
  Future<int> run(DateTime now) async {
    final stored = await files.list();
    if (stored.isEmpty) return 0;
    final wanted = <String>{
      for (final e in journalEntries(await records.all(kindJournal)))
        for (final p in e.photos) p.fileName,
      ...?(await drafts.load())?.photos.map((p) => p.fileName),
    };
    var removed = 0;
    for (final f in stored) {
      if (wanted.contains(f.name)) continue;
      if (now.difference(f.modified) < grace) continue;
      await files.delete(f.name);
      removed++;
    }
    return removed;
  }
}
