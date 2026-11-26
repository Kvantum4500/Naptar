/// Money in another currency, kept beside the forints it was worth.
///
/// A transaction in euros is stored with the forint amount it was changed to
/// (so every sum, budget and chart goes on counting in forints), and with what
/// it was paid in and the rate that was used. The rate is what the user typed
/// or the bank's: nothing here asks the net for one.
library;

/// The currencies the editor offers first, with their names.
const commonCurrencies = <(String, String)>[
  ('EUR', 'euró'),
  ('USD', 'amerikai dollár'),
  ('GBP', 'angol font'),
  ('CHF', 'svájci frank'),
  ('PLN', 'lengyel zloty'),
  ('CZK', 'cseh korona'),
  ('RON', 'román lej'),
  ('SEK', 'svéd korona'),
  ('NOK', 'norvég korona'),
  ('DKK', 'dán korona'),
  ('RSD', 'szerb dinár'),
  ('TRY', 'török líra'),
  ('JPY', 'japán jen'),
];

/// "eur " -> "EUR"; null when it is not a three-letter code or is the forint.
String? normalizeCurrency(String text) {
  final code = text.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(code) || code == 'HUF') return null;
  return code;
}

/// The most that is kept of an amount in a currency (hundredths of a unit) and
/// of a rate (forints for one unit).
const maxForeignCents = 1000000000000;
const maxRate = 100000.0;

/// What a transaction was paid in, when that was not forints.
class FinForeign {
  const FinForeign({
    required this.currency,
    required this.cents,
    required this.rate,
  });

  /// Three capital letters, never "HUF".
  final String currency;

  /// The amount in the currency, in hundredths: 12,40 EUR is 1240.
  final int cents;

  /// Forints for one unit of the currency: 399,5.
  final double rate;

  /// The forints this is worth.
  int get forints => forintsFor(cents, rate);

  Map<String, Object?> toJson() => {'cur': currency, 'c': cents, 'r': rate};

  /// Null when the record is unusable: the transaction then goes on as one in
  /// plain forints.
  static FinForeign? fromJson(Object? j) {
    if (j is! Map) return null;
    final cur = j['cur'];
    final c = j['c'];
    final r = j['r'];
    if (cur is! String || normalizeCurrency(cur) != cur) return null;
    if (c is! num || !c.isFinite || c is double && c != c.roundToDouble()) {
      return null;
    }
    if (r is! num || !r.isFinite) return null;
    final cents = c.toInt();
    if (cents <= 0 || cents > maxForeignCents) return null;
    final rate = r.toDouble();
    if (rate <= 0 || rate > maxRate) return null;
    return FinForeign(currency: cur, cents: cents, rate: rate);
  }

  @override
  bool operator ==(Object other) =>
      other is FinForeign &&
      other.currency == currency &&
      other.cents == cents &&
      other.rate == rate;

  @override
  int get hashCode => Object.hash(currency, cents, rate);

  @override
  String toString() => 'FinForeign($currency, $cents, $rate)';
}

/// The forints that [cents] of a currency are worth at [rate] (forints for one
/// unit), to the nearest forint.
int forintsFor(int cents, double rate) => (cents * rate / 100).round();

// ---------------------------------------------------------------- reading

/// What a typed number is made of: its sign, the digits before the decimal
/// separator and the digits after it.
typedef _Parts = ({bool negative, String whole, String fraction});

/// Reads "12,40", "12.40", "1 234,5", "1.234,50", "1,234.50", "-5 Ft",
/// "(12,50)" and the like.
///
/// What is not a digit or a separator is left out (a currency sign or a word).
/// When both "." and "," are there, the one that comes last is the decimal
/// separator; when there is only one kind, it is a decimal separator if it is
/// there once and is followed by one or two digits (or by three after a
/// whole part of 0), and a thousands separator otherwise ("1.234" is 1234, and
/// so is "12,345" 12345). A space, a non-breaking space and an apostrophe are
/// always thousands separators.
///
/// With [loneIsDecimal] a separator that is there once is always the decimal
/// one (a rate has decimals of its own: "2,512" is 2.512).
_Parts? _split(String text, {bool loneIsDecimal = false}) {
  var t = text.trim();
  if (t.isEmpty) return null;
  var negative = false;
  if (t.startsWith('(') && t.endsWith(')')) negative = true;
  // (a minus sign, the one of typography and the dashes)
  if (RegExp(r'^[^0-9]*[-−–‒]').hasMatch(t)) negative = true;
  t = t.replaceAll(RegExp(r'[^0-9.,]'), '');
  // (a trailing separator is a full stop after the number; what is left of
  // nothing but separators is nothing)
  t = t.replaceAll(RegExp(r'[.,]+$'), '');
  if (t.isEmpty) return null;
  final dot = t.lastIndexOf('.'), comma = t.lastIndexOf(',');
  String? decimal;
  if (dot >= 0 && comma >= 0) {
    decimal = dot > comma ? '.' : ',';
  } else if (dot >= 0 || comma >= 0) {
    final sep = dot >= 0 ? '.' : ',';
    final parts = t.split(sep);
    if (parts.length == 2) {
      final after = parts[1], before = parts[0];
      if (loneIsDecimal ||
          after.length != 3 ||
          before == '0' ||
          before.isEmpty) {
        decimal = sep;
      }
    }
  }
  String whole, fraction;
  if (decimal == null) {
    whole = t.replaceAll(RegExp(r'[.,]'), '');
    fraction = '';
  } else {
    final i = t.lastIndexOf(decimal);
    whole = t.substring(0, i).replaceAll(RegExp(r'[.,]'), '');
    fraction = t.substring(i + 1).replaceAll(RegExp(r'[.,]'), '');
  }
  if (whole.isEmpty) whole = '0';
  if (whole.length > 12) return null;
  return (negative: negative, whole: whole, fraction: fraction);
}

/// A typed amount in hundredths: "12,40" is 1240, "-5" is -500. Null when it is
/// not a number. More than two decimals are rounded (half up).
int? parseCents(String text) {
  final p = _split(text);
  if (p == null) return null;
  final f = p.fraction.padRight(3, '0');
  var cents = int.parse(p.whole) * 100 + int.parse(f.substring(0, 2));
  if (int.parse(f[2]) >= 5) cents += 1;
  return p.negative ? -cents : cents;
}

/// A typed rate ("399,5", "401.2345", "2,512"), to four decimals; null when it
/// is not a positive number or is more than [maxRate]. A "," or a "." that is
/// there once is the decimal separator whatever follows it (spaces group the
/// thousands), so that what [formatRate] writes reads back as it was.
double? parseRate(String text) {
  final p = _split(text, loneIsDecimal: true);
  if (p == null || p.negative) return null;
  final f = p.fraction.padRight(5, '0');
  var tenThousandths =
      int.parse(p.whole) * 10000 + int.parse(f.substring(0, 4));
  if (int.parse(f[4]) >= 5) tenThousandths += 1;
  final rate = tenThousandths / 10000;
  return rate > 0 && rate <= maxRate ? rate : null;
}

// ---------------------------------------------------------------- writing

String _group(int n) {
  final digits = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(' ');
    b.write(digits[i]);
  }
  return b.toString();
}

/// 1240 -> "12,40", 1200 -> "12" (no thousands grouping: for a text field).
String plainCents(int cents) {
  final a = cents.abs();
  final frac = a % 100;
  final body = frac == 0
      ? '${a ~/ 100}'
      : '${a ~/ 100},${frac.toString().padLeft(2, '0')}';
  return cents < 0 ? '-$body' : body;
}

/// 123450 -> "1 234,50 EUR" (non-breaking spaces), 1200 -> "12 EUR".
String formatForeign(int cents, String currency) {
  final a = cents.abs();
  final frac = a % 100;
  final body = frac == 0
      ? _group(a ~/ 100)
      : '${_group(a ~/ 100)},${frac.toString().padLeft(2, '0')}';
  return '${cents < 0 ? '-' : ''}$body\u00A0$currency';
}

/// 399.5 -> "399,5", 400 -> "400", 401.2345 -> "401,2345".
String formatRate(double rate) {
  var s = rate.toStringAsFixed(4);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s.replaceAll('.', ',');
}

/// "12,40 EUR · 399,5 Ft/EUR" (non-breaking spaces): what a transaction was
/// paid in.
String foreignLine(FinForeign f) =>
    '${formatForeign(f.cents, f.currency)} · '
    '${formatRate(f.rate)}\u00A0Ft/${f.currency}';
