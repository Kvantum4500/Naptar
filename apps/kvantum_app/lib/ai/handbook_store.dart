import 'package:flutter/services.dart' show rootBundle;
import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';

/// The handbook files (the assistant's rules, profile and relationships).
const handbookFiles = <(String id, String title)>[
  ('rules', 'Kemény szabályok'),
  ('profile', 'Profil'),
  ('relations', 'Összefüggések'),
  ('calendar-semantics', 'Naptár-jelentések'),
  ('output-format', 'Kimeneti formátum'),
  ('learned', 'Tanult szokások'),
];

/// Default texts ship inside the app; the user's edited copies are synced
/// through Drive like tasks (record kind `handbook`). A blank edit means
/// "back to the default".
class HandbookStore {
  HandbookStore(
    this.records, {
    Future<String> Function(String assetPath)? loader,
  }) : _loader = loader ?? rootBundle.loadString;
  final RecordRepository records;
  final Future<String> Function(String assetPath) _loader;

  Future<String> defaultOf(String id) => _loader('assets/handbook/$id.md');

  Future<String?> _custom(String id) async {
    final r = await records.get(kindHandbook, id);
    if (r == null || r.deleted) return null;
    final t = r['text'];
    return (t is String && t.trim().isNotEmpty) ? t : null;
  }

  Future<bool> isCustomized(String id) async => await _custom(id) != null;

  Future<String> textOf(String id) async =>
      await _custom(id) ?? await defaultOf(id);

  Future<void> save(String id, String text) async {
    assert(handbookFiles.any((f) => f.$1 == id));
    await records.edit(kindHandbook, id, {'text': text, 'deleted': false});
  }

  /// Drops the user's copy; the bundled default applies again.
  Future<void> reset(String id) =>
      records.edit(kindHandbook, id, {'text': '', 'deleted': false});

  /// All files as one block for the system prompt.
  Future<String> combined() async {
    final b = StringBuffer();
    for (final (id, title) in handbookFiles) {
      b.writeln('### $title');
      b.writeln((await textOf(id)).trim());
      b.writeln();
    }
    return b.toString().trim();
  }
}
