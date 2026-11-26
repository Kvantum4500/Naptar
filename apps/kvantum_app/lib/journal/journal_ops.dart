import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';

/// What the app does to the diary: every entry is a record of its own, and
/// every change has a way back (a deletion is the usual marker, which
/// "Visszavonás" takes off again).
class JournalOps {
  JournalOps(this._repo, {this.onChanged});

  final RecordRepository _repo;

  /// Told after every change (the app asks the sync to run).
  final void Function()? onChanged;

  Future<T> _write<T>(Future<T> Function() body) async {
    final result = await _repo.db.transaction(body);
    onChanged?.call();
    return result;
  }

  /// Saves [entry]: a new one is made, an old one changed. Only a part that
  /// changed is stamped anew (a title changed here and a text changed on
  /// another device both stay).
  Future<void> save(JournalEntry entry) =>
      _write(() => _repo.edit(kindJournal, entry.id, entry.fields));

  /// Deletes the entry (the record stays, as a marker).
  Future<void> delete(String id) => _write(() => _repo.delete(kindJournal, id));

  /// Takes a deletion back; false when the entry is not deleted (any more).
  Future<bool> restore(String id) =>
      _write(() => _repo.undelete(kindJournal, id));
}
