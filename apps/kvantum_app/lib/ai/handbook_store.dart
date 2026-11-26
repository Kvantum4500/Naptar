import 'package:flutter/services.dart' show rootBundle;
import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';
import 'handbook_legacy.dart';

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
/// The most characters of one handbook file that go into the prompt. The files
/// the program ships are about a thousand; what the user writes stays whole in
/// the editor, but a record that came from the Drive could be anything (a
/// forged or an enormous one), and the prompt - and what it costs - must not
/// follow it.
const handbookPromptMaxChars = 12000;

/// [body] at most [handbookPromptMaxChars] long, with a mark where it was cut
/// (never cutting a surrogate pair in two).
String boundedHandbook(String body) {
  if (body.length <= handbookPromptMaxChars) return body;
  var cut = handbookPromptMaxChars;
  final last = body.codeUnitAt(cut - 1);
  if (last >= 0xD800 && last <= 0xDBFF) cut--;
  return '${body.substring(0, cut)}…';
}

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
    if (t is! String || t.trim().isEmpty) return null;
    // A copy that is just a retired default was never edited by the user:
    // the current default applies.
    if (isLegacyHandbookDefault(id, t)) return null;
    return t;
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

  /// The `- ` lines of "Tanult szokások".
  Future<List<String>> learnedRules() async => [
    for (final l in (await textOf('learned')).split('\n'))
      if (l.startsWith('- ')) l.substring(2).trim(),
  ];

  /// The sports the user agreed are easy for them (the marked lines of
  /// "Tanult szokások", see [lightRuleText]). Deleting a line takes it back.
  Future<Set<String>> lightSports() async =>
      lightSportsFrom(await learnedRules());

  /// Writes the user's "yes, that is easy for me" to "Tanult szokások".
  Future<bool> agreeLight(String sport) {
    assert(isSportKey(sport));
    return appendLearned(lightRuleText(sport));
  }

  /// Adds one habit the user confirmed to "Tanult szokások". Returns false
  /// when it is empty or already there. Keeps at most [maxRules] (oldest go).
  Future<bool> appendLearned(String rule, {int maxRules = 30}) async {
    final clean = sanitizeText(rule, max: 200).trim();
    if (clean.isEmpty) return false;
    final lines = [
      for (final l in (await textOf('learned')).split('\n'))
        if (!l.startsWith('(üres')) l,
    ];
    final has = lines.any(
      (l) =>
          l.startsWith('- ') &&
          l.substring(2).trim().toLowerCase() == clean.toLowerCase(),
    );
    if (has) return false;
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    lines.add('- $clean');
    var bullets = lines.where((l) => l.startsWith('- ')).length;
    while (bullets > maxRules) {
      lines.removeAt(lines.indexWhere((l) => l.startsWith('- ')));
      bullets--;
    }
    await save('learned', '${lines.join('\n')}\n');
    return true;
  }

  /// The files as one block for the system prompt, without the template lines
  /// and decoration that only help while editing ([compactHandbook]); a file
  /// with nothing left is left out altogether. With [only] just those files
  /// (by id) are included: a request that deletes an event does not need the
  /// training rules. With [skip] those files are left out (the budget guard
  /// drops the learned habits first).
  Future<String> combined({Set<String>? only, Set<String>? skip}) async {
    final b = StringBuffer();
    for (final (id, title) in handbookFiles) {
      if (only != null && !only.contains(id)) continue;
      if (skip != null && skip.contains(id)) continue;
      final body = boundedHandbook(compactHandbook(await textOf(id)));
      if (body.isEmpty) continue;
      b.writeln('## $title');
      b.writeln(body);
    }
    return b.toString().trim();
  }
}
