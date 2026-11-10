// The escapes below use the `\u{...}` form on purpose: the characters are
// invisible or look like markup, so they must stay readable in the source.

/// Zero-width, bidirectional-formatting, BOM, soft-hyphen and Unicode tag
/// characters (general category Cf): invisible, so they can hide text.
final _invisible = RegExp(r'\p{Cf}', unicode: true);

/// C0/C1 control characters (incl. NEL) and line/paragraph separators.
final _controls = RegExp(
  r'[\u{0}-\u{1F}\u{7F}-\u{9F}\u{2028}\u{2029}]',
  unicode: true,
);

/// Markup characters, including the full-width and look-alike angle brackets
/// that could imitate our own `<adat>` delimiters.
final _brackets = RegExp(
  r'[<>`\u{FF1C}\u{FF1E}\u{2039}\u{203A}\u{27E8}\u{27E9}\u{3008}\u{3009}\u{276E}\u{276F}\u{FE64}\u{FE65}]',
  unicode: true,
);

/// Makes free text safe to hand to the model as DATA: no control, invisible or
/// bidirectional-formatting characters, no markup that could imitate our own
/// delimiters, bounded length (never cutting a surrogate pair in two).
String sanitizeText(String s, {int max = 80}) {
  final clean = s
      .replaceAll(_invisible, '')
      .replaceAll(_controls, ' ')
      .replaceAll(_brackets, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.length <= max) return clean;
  var cut = max;
  if (cut > 0) {
    final last = clean.codeUnitAt(cut - 1);
    // a lone high surrogate is invalid UTF-16 and some servers reject the JSON
    if (last >= 0xD800 && last <= 0xDBFF) cut--;
  }
  return '${clean.substring(0, cut)}…';
}

/// An identifier handed to the model: only characters that cannot carry text.
String safeId(String id, {int max = 64}) {
  final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9_.:\-]'), '');
  return clean.length > max ? clean.substring(0, max) : clean;
}
