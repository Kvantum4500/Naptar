/// The handbook as it goes into the prompt: without what only helps the user
/// while editing it. Dropped are the blank lines, the file's own `# ` title
/// (the caller prints the title), the "(üres …)" marker and the template lines
/// that have no value yet (`- Sérülések, korlátok:` or `- Célok: (pl. …)`).
/// A label line is kept when indented lines follow it (then it has a value).
String compactHandbook(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    final t = line.trimLeft();
    if (t.isEmpty || t.startsWith('# ') || t.startsWith('(üres')) continue;
    if (_placeholderField.hasMatch(line)) continue;
    if (_emptyField.hasMatch(line) && !_continues(lines, i)) continue;
    out.add(line);
  }
  return out.join('\n');
}

/// True when the next non-blank line is indented (a value under the label).
bool _continues(List<String> lines, int i) {
  for (var j = i + 1; j < lines.length; j++) {
    final next = lines[j];
    if (next.trim().isEmpty) continue;
    return next.startsWith(' ') || next.startsWith('\t');
  }
  return false;
}

/// "- Label:" with nothing after the colon.
final _emptyField = RegExp(r'^\s*[-*]\s*[^:\n]{1,60}:\s*$');

/// "- Label: (placeholder)" — the whole value is one parenthesised hint.
final _placeholderField = RegExp(r'^\s*[-*]\s*[^:\n]{1,60}:\s*\([^()]*\)\s*$');
