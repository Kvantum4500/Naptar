import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';

/// Where the unsaved start of a new entry is kept: on this device only (in the
/// settings table, not as a record: it is not synced, not in the backup, and
/// the assistant never sees it). The editor puts it there before the gallery
/// opens and when the app goes to the background, because the system may
/// close an app that has been left; the next new entry offers to go on.
const journalDraftKey = 'journal.draft';

class JournalDraftStore {
  const JournalDraftStore(this._repo);

  final RecordRepository _repo;

  /// The draft, or null (there is none, or what is there is no draft).
  Future<JournalDraft?> load() async =>
      JournalDraft.decode(await _repo.meta(journalDraftKey));

  /// Keeps [draft]; one with nothing in it is no draft (it clears).
  Future<void> save(JournalDraft draft) async {
    if (draft.isEmpty) return clear();
    await _repo.setMeta(journalDraftKey, draft.encode());
  }

  Future<void> clear() => _repo.setMeta(journalDraftKey, null);
}
