/// Which column of a bank's CSV file holds what, and how a cell is read.
///
/// No bank's layout is assumed: the columns are guessed from the words of the
/// header (Hungarian and English) and from what the cells hold, and the guess
/// is only where the user starts from.
library;

import 'finance.dart';
import 'finance_currency.dart';
import 'text_safety.dart';

/// What a column can hold.
enum BankField {
  date,
  amount,
  debit,
  credit,
  direction,
  merchant,
  note,
  currency,
}

/// The order of the numbers in a date such as 13.11.2026 or 11/13/2026.
enum DateOrder { ymd, dmy, mdy }

/// The columns of a file (as indexes into a row), and how its signs and dates
/// are to be read.
class BankMapping {
  BankMapping({
    Map<BankField, int>? columns,
    this.invertSign = false,
    this.dateOrder = DateOrder.dmy,
  }) : columns = {...?columns};

  /// The column of each field that has one.
  final Map<BankField, int> columns;

  /// A positive amount is an expense (some banks list what was spent as plus).
  bool invertSign;

  DateOrder dateOrder;

  int? operator [](BankField field) => columns[field];

  void operator []=(BankField field, int? index) {
    if (index == null) {
      columns.remove(field);
    } else {
      columns[field] = index;
    }
  }

  /// The money is in one column (signed, or with a direction column) or in two
  /// (what went out, what came in).
  bool get hasPair =>
      columns.containsKey(BankField.debit) &&
      columns.containsKey(BankField.credit);

  /// A date and an amount are there: enough to read the rows.
  bool get usable =>
      columns.containsKey(BankField.date) &&
      (columns.containsKey(BankField.amount) || hasPair);

  BankMapping copy() => BankMapping(
    columns: columns,
    invertSign: invertSign,
    dateOrder: dateOrder,
  );

  Map<String, Object?> toJson() => {
    for (final e in columns.entries) e.key.name: e.value,
    'invert': invertSign,
    'order': dateOrder.name,
  };

  /// Null when [j] is not a mapping that fits a file of [width] columns.
  static BankMapping? fromJson(Object? j, int width) {
    if (j is! Map) return null;
    final columns = <BankField, int>{};
    for (final f in BankField.values) {
      final v = j[f.name];
      if (v == null) continue;
      if (v is! int || v < 0 || v >= width) return null;
      columns[f] = v;
    }
    if (columns.values.toSet().length != columns.length) return null;
    final order = DateOrder.values.where((o) => o.name == j['order']);
    return BankMapping(
      columns: columns,
      invertSign: j['invert'] == true,
      dateOrder: order.isEmpty ? DateOrder.dmy : order.first,
    );
  }
}

// ---------------------------------------------------------------- the header

/// The words of a header cell (without accents, lower case) by which a column
/// is known, the most telling first.
const _words = <BankField, List<String>>{
  BankField.date: [
    'tranzakcio datuma',
    'tranzakcio ideje',
    'vasarlas datuma',
    'teljesites',
    'transaction date',
    'completed date',
    'booking date',
    'posting date',
    'konyveles',
    'datum',
    'date',
    'ertekn',
  ],
  BankField.debit: [
    'terheles',
    'debit',
    'kiadas',
    'money out',
    'paid out',
    'fizetett',
    'kifizetes',
  ],
  BankField.credit: [
    'jovairas',
    'credit',
    'bevetel',
    'money in',
    'paid in',
    'befizetes',
  ],
  BankField.amount: [
    'tranzakcio osszege',
    'osszeg',
    'amount',
    'forgalom',
    'sum',
  ],
  BankField.currency: ['penznem', 'devizanem', 'deviza', 'currency', 'valuta'],
  BankField.merchant: [
    'partner neve',
    'partner',
    'kedvezmenyezett',
    'fizeto',
    'payee',
    'merchant',
    'counterparty',
    'vevo',
    'elado',
    'uzlet',
    'megnevezes',
    'description',
    'leiras',
    'name',
    'nev',
  ],
  BankField.note: [
    'kozlemeny',
    'megjegyzes',
    'note',
    'reference',
    'referencia',
    'info',
    'description',
    'leiras',
  ],
  BankField.direction: [
    'terheles/jovairas',
    'jovairas/terheles',
    'debit/credit',
    'tipus',
    'type',
    'irany',
    'jelleg',
  ],
};

/// A header with one of these words is an account number or an identifier, not
/// a name or a message.
const _notText = [
  'szamlaszam',
  'szamla szama',
  'iban',
  'bic',
  'swift',
  'azonosit',
];

bool _wordMatches(BankField field, String folded, String word) {
  if (!folded.contains(word)) return false;
  if (field == BankField.merchant || field == BankField.note) {
    for (final bad in _notText) {
      if (folded.contains(bad)) return false;
    }
  }
  return true;
}

/// A header that names both what went out and what came in is a direction
/// column, not either of them.
bool _namesBothSides(String folded) =>
    _words[BankField.debit]!.any(folded.contains) &&
    _words[BankField.credit]!.any(folded.contains);

/// The fields a header cell can be taken for.
Set<BankField> headerFields(String header) {
  final folded = foldHu(header);
  final both = _namesBothSides(folded);
  return {
    for (final e in _words.entries)
      if (!(both && (e.key == BankField.debit || e.key == BankField.credit)))
        if (e.value.any((w) => _wordMatches(e.key, folded, w))) e.key,
  };
}

/// The index of the header row among the first rows of a file, or -1 when none
/// of them looks like one (a row with the words of at least two different
/// fields; the first of the best).
int findHeaderRow(List<List<String>> rows, {int scan = 20}) {
  var best = -1, bestScore = 1;
  for (var i = 0; i < rows.length && i < scan; i++) {
    final fields = <BankField>{};
    for (final cell in rows[i]) {
      // (a cell names one field, the first it can be taken for)
      fields.addAll(headerFields(cell).take(1));
    }
    if (fields.length > bestScore) {
      best = i;
      bestScore = fields.length;
    }
  }
  return best;
}

// ---------------------------------------------------------------- the cells

final _ymd = RegExp(r'^(\d{4})\s*[-./]\s*(\d{1,2})\s*[-./]\s*(\d{1,2})(?!\d)');
final _short = RegExp(
  r'^(\d{1,2})\s*[-./]\s*(\d{1,2})\s*[-./]\s*(\d{4}|\d{2})(?!\d)',
);
final _compact = RegExp(r'^(\d{4})(\d{2})(\d{2})$');

DateTime? _date(int y, int m, int d) {
  if (y < 1970 || y > 2100 || m < 1 || m > 12 || d < 1) return null;
  if (d > DateTime.utc(y, m + 1, 0).day) return null;
  return DateTime.utc(y, m, d);
}

/// A date as a bank writes it: 2026-11-13, 2026.11.13., 2026. 11. 13., 13.11.2026,
/// 13/11/2026, 11/13/2026 (by [order]), 13.11.26, 20261113; a time after it is
/// left out. Null when it is not a date.
DateTime? parseBankDate(String text, DateOrder order) {
  final t = text.trim();
  var m = _ymd.firstMatch(t);
  if (m != null) {
    return _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
  m = _short.firstMatch(t);
  if (m != null) {
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    var y = int.parse(m[3]!);
    if (m[3]!.length == 2) y += y >= 70 ? 1900 : 2000;
    return order == DateOrder.mdy ? _date(y, a, b) : _date(y, b, a);
  }
  m = _compact.firstMatch(t);
  if (m != null) {
    return _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
  return null;
}

/// The order of the numbers in the dates of [samples]: year first when they
/// are written so, else month first when a second number is above 12 and a
/// first one never is, else day first.
DateOrder guessDateOrder(Iterable<String> samples) {
  var ymd = false, dayFirst = false, monthFirst = false;
  for (final s in samples) {
    final t = s.trim();
    if (_ymd.hasMatch(t) || _compact.hasMatch(t)) ymd = true;
    final m = _short.firstMatch(t);
    if (m == null) continue;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    if (a > 12) dayFirst = true;
    if (b > 12) monthFirst = true;
  }
  if (ymd) return DateOrder.ymd;
  if (monthFirst && !dayFirst) return DateOrder.mdy;
  return DateOrder.dmy;
}

final _amountLike = RegExp(r"^[-−–‒+(]?\s*\d[\d  '.,]*\)?$");

/// Whether a cell holds an amount: digits and separators, maybe a sign or
/// brackets, maybe a currency (a code or "Ft") after it.
bool looksLikeAmount(String cell) {
  var t = cell.trim();
  t = t.replaceFirst(RegExp(r'\s*(?:[A-Za-z]{2,3}\.?|€|\$|£)$'), '');
  t = t.replaceFirst(RegExp(r'^(?:€|\$|£)'), '');
  return _amountLike.hasMatch(t);
}

/// The direction a cell names: an expense ("Terhelés", "Debit", "D", "Kiadás")
/// or an income ("Jóváírás", "Credit", "C", "Bevétel"); null when it names none.
FinKind? directionOf(String cell) {
  final t = foldHu(cell).trim();
  if (t == 'd' ||
      t == 'ki' ||
      RegExp(r'terhel|debit|kiad|kifizet').hasMatch(t)) {
    return FinKind.expense;
  }
  if (t == 'c' ||
      t == 'be' ||
      RegExp(r'jovair|credit|bevet|befizet|beerkez').hasMatch(t)) {
    return FinKind.income;
  }
  return null;
}

// ---------------------------------------------------------------- the guess

/// Whether a cell holds a date, written day first or month first.
bool _isDate(String cell) =>
    parseBankDate(cell, DateOrder.dmy) != null ||
    parseBankDate(cell, DateOrder.mdy) != null;

bool _isWords(String cell) => !looksLikeAmount(cell) && !_isDate(cell);

double _share(Iterable<String> cells, bool Function(String) test) {
  var n = 0, ok = 0;
  for (final c in cells) {
    if (c.trim().isEmpty) continue;
    n++;
    if (test(c)) ok++;
  }
  return n == 0 ? 0 : ok / n;
}

/// A first guess at the columns of a file whose header row is [header] (empty
/// for a file without one) and whose data rows begin with [rows].
BankMapping guessMapping(List<String> header, List<List<String>> rows) {
  final sample = rows.take(50).toList();
  List<String> column(int i) => [
    for (final r in sample)
      if (i < r.length) r[i],
  ];
  final width = [
    header.length,
    for (final r in sample) r.length,
  ].fold<int>(0, (a, b) => a > b ? a : b);

  final folded = [for (final h in header) foldHu(h)];
  final used = <int>{};
  final m = BankMapping();

  int? pick(BankField field) {
    for (final word in _words[field]!) {
      for (var i = 0; i < folded.length; i++) {
        if (used.contains(i)) continue;
        if (_namesBothSides(folded[i]) &&
            (field == BankField.debit || field == BankField.credit)) {
          continue;
        }
        if (!_wordMatches(field, folded[i], word)) continue;
        used.add(i);
        return i;
      }
    }
    return null;
  }

  m[BankField.date] = pick(BankField.date);
  final debit = pick(BankField.debit), credit = pick(BankField.credit);
  if (debit != null && credit != null) {
    m[BankField.debit] = debit;
    m[BankField.credit] = credit;
  } else {
    // (one of the two alone is not a pair: let it be free again)
    if (debit != null) used.remove(debit);
    if (credit != null) used.remove(credit);
  }
  if (!m.hasPair) m[BankField.amount] = pick(BankField.amount);
  m[BankField.currency] = pick(BankField.currency);
  m[BankField.merchant] = pick(BankField.merchant);
  m[BankField.note] = pick(BankField.note);

  // what the header did not tell, or told wrongly, the cells tell
  final dateAt = m[BankField.date];
  if (dateAt == null || _share(column(dateAt), _isDate) < 0.5) {
    if (dateAt != null) used.remove(dateAt);
    m[BankField.date] = null;
    for (var i = 0; i < width; i++) {
      if (used.contains(i)) continue;
      if (_share(column(i), _isDate) >= 0.8) {
        m[BankField.date] = i;
        used.add(i);
        break;
      }
    }
  }
  if (!m.hasPair) {
    final amountAt = m[BankField.amount];
    if (amountAt == null || _share(column(amountAt), looksLikeAmount) < 0.5) {
      if (amountAt != null) used.remove(amountAt);
      m[BankField.amount] = null;
      for (var i = 0; i < width; i++) {
        if (used.contains(i)) continue;
        if (_share(column(i), looksLikeAmount) >= 0.8) {
          m[BankField.amount] = i;
          used.add(i);
          break;
        }
      }
    }
  }

  // a direction column, but only when the amounts have no sign of their own
  // and its cells do name directions
  final amountAt = m[BankField.amount];
  if (amountAt != null) {
    final signed = column(amountAt)
        .any((c) => RegExp(r'^[\s]*[-−–‒(]').hasMatch(c));
    if (!signed) {
      final at = pick(BankField.direction);
      if (at != null &&
          _share(column(at), (c) => directionOf(c) != null) >= 0.8) {
        m[BankField.direction] = at;
      }
    }
  }

  // a name for the merchant, if the header gave none: the first free column
  // that holds words
  if (m[BankField.merchant] == null) {
    for (var i = 0; i < width; i++) {
      if (used.contains(i)) continue;
      if (_share(column(i), _isWords) >= 0.5) {
        m[BankField.merchant] = i;
        break;
      }
    }
  }

  final dateCol = m[BankField.date];
  m.dateOrder = dateCol == null
      ? DateOrder.dmy
      : guessDateOrder(column(dateCol));
  return m;
}

/// A key of the header, to remember the columns chosen for a bank's file and
/// find them again the next time (the same words in the same order).
String headerSignature(List<String> header) =>
    header.map((h) => foldHu(h).trim()).join('|');

/// The currency a cell names: null for the forint (an empty cell, "HUF", "Ft",
/// "forint"), a code such as "EUR" for another, and [badCurrency] when it is
/// neither.
const badCurrency = '?';
String? currencyOf(String cell) {
  final t = cell.trim().toUpperCase();
  if (t.isEmpty || t == 'HUF' || t == 'FT' || t == 'FORINT') return null;
  return normalizeCurrency(t) ?? badCurrency;
}
