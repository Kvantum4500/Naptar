part of '../quick_entry.dart';

/// The line, with the parts already understood blanked out.
class _Src {
  _Src(this.original)
    : _f = _fold(original).codeUnits.toList(),
      _used = List.filled(original.length, false);

  final String original;
  final List<int> _f;
  final List<bool> _used;

  String get text => String.fromCharCodes(_f);

  RegExpMatch? find(String pattern) => RegExp(pattern).firstMatch(text);

  /// Blanks [m] (or a part of the line) so that nothing matches it again.
  void take(int start, int end) {
    for (var i = start; i < end; i++) {
      _f[i] = 32;
      _used[i] = true;
    }
  }

  void takeMatch(RegExpMatch m) => take(m.start, m.end);

  /// What is left of the original, the gaps as single spaces.
  String get rest {
    final b = StringBuffer();
    for (var i = 0; i < original.length; i++) {
      b.write(_used[i] ? ' ' : original[i]);
    }
    return b.toString();
  }

  /// The word (folded) that ends right before [index], or ''.
  String wordBefore(int index) {
    var e = index;
    while (e > 0 && _f[e - 1] == 32) {
      e--;
    }
    var s = e;
    while (s > 0 && _f[s - 1] != 32) {
      s--;
    }
    return String.fromCharCodes(_f.sublist(s, e));
  }

  int wordBeforeStart(int index) {
    var e = index;
    while (e > 0 && _f[e - 1] == 32) {
      e--;
    }
    var s = e;
    while (s > 0 && _f[s - 1] != 32) {
      s--;
    }
    return s;
  }

  /// The word (folded) that starts right after [index], or ''.
  String wordAfter(int index) {
    var s = index;
    while (s < _f.length && _f[s] == 32) {
      s++;
    }
    var e = s;
    while (e < _f.length && _f[e] != 32) {
      e++;
    }
    return String.fromCharCodes(_f.sublist(s, e));
  }

  int wordAfterEnd(int index) {
    var s = index;
    while (s < _f.length && _f[s] == 32) {
      s++;
    }
    var e = s;
    while (e < _f.length && _f[e] != 32) {
      e++;
    }
    return e;
  }
}
