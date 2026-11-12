// Cleaning of text that may end up in the diagnostics log, or in a report the
// user copies out of the app. Nothing here is trusted to be free of personal
// data, so the rule is: keep the kind of thing that went wrong, drop the rest.

/// A service message without anything that looks like a key, bounded. [key] is
/// the key in use: it is removed wherever it appears, whatever it looks like.
String redactSecrets(String message, {String? key, int max = 400}) {
  var m = message;
  if (key != null && key.length >= 6) m = m.replaceAll(key, '[kulcs]');
  final clean = m
      .replaceAll(RegExp(r'(sk-|gsk_|AIza)[0-9A-Za-z_\-]{10,}'), '[kulcs]')
      .replaceAll(
        RegExp(r'Bearer\s+[0-9A-Za-z._\-]{10,}', caseSensitive: false),
        'Bearer [kulcs]',
      )
      .replaceAll(RegExp(r'\b[0-9A-Za-z]{32,}\b'), '[kulcs]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.length > max ? '${clean.substring(0, max)}…' : clean;
}

final _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');
final _urlQuery = RegExp("(https?://[^\\s?#'\"<>)]+)[?#][^\\s'\"<>)]*");
final _homeDir = RegExp(
  r'(\b[A-Za-z]:[\\/]+Users[\\/]+|/Users/|/home/)[^\\/\s)'
  "'"
  r'"]+',
  caseSensitive: false,
);
final _longNumber = RegExp(r'\d{6,}');

/// [s] without e-mail addresses, the query part of web addresses (tokens
/// travel there), user names inside file paths and long digit runs (account,
/// card and phone numbers).
String redactPersonal(String s) => s
    .replaceAll(_email, '[e-mail]')
    .replaceAllMapped(_urlQuery, (m) => m[1]!)
    .replaceAllMapped(_homeDir, (m) => '${m[1]}[felhasználó]')
    .replaceAll(_longNumber, '[szám]');

/// "No limit" for the first cleaning step; the caller cuts the length.
const _wide = 100000;

/// [s] without secrets and personal data ([redactSecrets] first, then
/// [redactPersonal]), at most [max] characters.
String redactAll(String s, {int max = 160}) {
  final clean = redactPersonal(redactSecrets(s, max: _wide));
  return clean.length > max ? '${clean.substring(0, max)}…' : clean;
}

/// Where an error text turns into a statement with its parameters (the
/// database errors carry the SQL and the values), which can hold a title or an
/// amount.
const _cutMarkers = [
  'SQL:',
  'Causing statement',
  'Parameters',
  'parameters',
  ' statement:',
];

/// What may be written about [error]: its type and the first line of its
/// message, without secrets and personal data, at most [max] characters.
/// Never the whole message: it may quote what the user typed.
String safeErrorText(Object error, {int max = 160}) {
  final type = error.runtimeType.toString();
  var s = error.toString().split('\n').first;
  for (final m in _cutMarkers) {
    final i = s.indexOf(m);
    if (i >= 0) s = s.substring(0, i);
  }
  if (s.startsWith('$type:')) s = s.substring(type.length + 1);
  // secrets first: the digit rule of [redactPersonal] would break up a key
  s = redactPersonal(redactSecrets(s, max: _wide));
  if (s.length > max) s = '${s.substring(0, max)}…';
  return s.isEmpty ? type : '$type: $s';
}

/// The first few frames of [stack] on one line: code locations only.
String safeStackText(StackTrace stack, {int frames = 6, int perFrame = 110}) {
  final lines = stack
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(frames)
      .map((l) => l.length > perFrame ? '${l.substring(0, perFrame)}…' : l);
  return redactPersonal(lines.join(' | '));
}
