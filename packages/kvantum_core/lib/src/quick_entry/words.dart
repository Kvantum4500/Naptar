part of '../quick_entry.dart';

// What the parser knows about Hungarian: the names of the days and months, the
// number words, the parts of the day, and the plain text helpers (folding the
// accents, the object form of a weekday, what looks like a thing to do). Part of
// the library of [parseQuickEntry].

const _weekdayStems = [
  'hetfo',
  'kedd',
  'szerd',
  'csutortok',
  'pentek',
  'szombat',
  'vasarnap',
];
// The names of the days with the endings that mean "on / until / of that
// day" and no others: Szombathely is not a Saturday.
const _wd =
    '(?:hetfo(?:n|re|ig|tol|rol|i|k|kon|nek|vel)?'
    '|kedd(?:en|re|ig|tol|rol|i|ek|eken|nek|el)?'
    '|szerd(?:a|an|ara|aig|atol|arol|ai|ak|akon|anak|aval)?'
    '|csutortok(?:on|re|ig|tol|rol|i|ok|okon|nek|kel)?'
    '|pentek(?:en|re|ig|tol|rol|i|ek|eken|nek|kel)?'
    '|szombat(?:on|ra|ig|tol|rol|i|ok|okon|nak|tal)?'
    '|vasarnap(?:ra|ig|tol|rol|i|ok|okon|nak|pal)?)';
const _monthNames = [
  'januar',
  'februar',
  'marcius',
  'aprilis',
  'majus',
  'junius',
  'julius',
  'augusztus',
  'szeptember',
  'oktober',
  'november',
  'december',
];
const _monthAbbr = {
  'jan': 1,
  'febr': 2,
  'marc': 3,
  'apr': 4,
  'maj': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'szept': 9,
  'okt': 10,
  'nov': 11,
  'dec': 12,
};
const _numberWords = {
  'egy': 1,
  'ket': 2,
  'ketto': 2,
  'harom': 3,
  'negy': 4,
  'ot': 5,
  'hat': 6,
  'het': 7,
  'nyolc': 8,
  'kilenc': 9,
  'tiz': 10,
  'tizenegy': 11,
  'tizenketto': 12,
};
const _nw =
    '(?:egy|ketto|ket|harom|negy|ot|hat|het|nyolc|kilenc|tizenketto|tizenegy|tiz)';

int _wdOf(String foldedWord) {
  for (var i = 0; i < _weekdayStems.length; i++) {
    if (foldedWord.startsWith(_weekdayStems[i])) return i + 1;
  }
  throw ArgumentError('not a weekday: $foldedWord');
}

int _num(String s) => _numberWords[s] ?? int.parse(s);

/// Lower case and without accents, one character for one: positions in the
/// result are positions in [s].
String _fold(String s) {
  const from = 'áéíóöőúüűÁÉÍÓÖŐÚÜŰ';
  const to = 'aeiooouuuaeiooouuu';
  final out = <int>[];
  for (final c in s.codeUnits) {
    final i = from.indexOf(String.fromCharCode(c));
    if (i >= 0) {
      out.add(to.codeUnitAt(i));
    } else if (c >= 65 && c <= 90) {
      out.add(c + 32);
    } else {
      out.add(c);
    }
  }
  return String.fromCharCodes(out);
}

const _dayParts = {
  'reggel': 'am',
  'delelott': 'am',
  'hajnal': 'am',
  'hajnali': 'am',
  'de.': 'am',
  'du.': 'pm',
  'delutan': 'pm',
  'du': 'pm',
  'este': 'pm',
  'ejjel': 'night',
  'ejszaka': 'night',
};

/// The days with the ending that makes them the object of a sentence ("a
/// következő keddet vettem").
const _weekdayAccusative = [
  'hétfőt',
  'keddet',
  'szerdát',
  'csütörtököt',
  'pénteket',
  'szombatot',
  'vasárnapot',
];

/// A line without an hour but with a verb in it ("tejet venni") is a thing to
/// do, not a happening.
bool _looksLikeTodo(String text) {
  for (final w in text.split(RegExp(r'\s+'))) {
    final f = _fold(w).replaceAll(RegExp(r'[^a-z]'), '');
    if (f.length >= 5 && f.endsWith('ni')) return true;
  }
  return false;
}
