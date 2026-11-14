import 'finance.dart';

/// What a payment notification (e.g. from Google Wallet) is worth.
enum WalletOutcome {
  /// A forint amount was found: it becomes a transaction.
  payment,

  /// An amount in another currency: kept in the log only, never booked.
  foreignCurrency,

  /// No amount at all (offers, card set-up messages ...): dropped.
  ignored,
}

class WalletParse {
  const WalletParse(this.outcome, {this.amount, this.kind, this.merchant = ''});
  final WalletOutcome outcome;
  final int? amount;
  final FinKind? kind;
  final String merchant;
}

// number (with spaces / dots / commas) before or after a forint marker
final _numPart = r'\d[\d   .,]*\d|\d';
final _huf = RegExp(
  '(?:($_numPart)\\s*(?:Ft|HUF|forint)\\b)|(?:\\b(?:Ft|HUF)\\s*($_numPart))',
  caseSensitive: false,
);
final _foreign = RegExp(
  r'(?:\d[\d .,]*\s*(?:€|\$|£|EUR|USD|GBP|CHF|PLN|RON|CZK)\b)|(?:(?:€|\$|£|EUR|USD|GBP|CHF|PLN|RON|CZK)\s*\d)',
  caseSensitive: false,
);
final _incomeWords = RegExp(
  r'visszatérít|jóváír|jóváírás|refund|érkezett|kapott|received|visszatérül',
  caseSensitive: false,
);
final _generic = RegExp(
  r'^(google\s*)?(wallet|pay|fizetés|payment|tranzakció|transaction|értesítés|vásárlás)$',
  caseSensitive: false,
);
final _filler = RegExp(
  r'\b(fizetés|fizetve|fizettél|kártyával|kártya|mastercard|visa|maestro|vásárlás|tranzakció|jóváhagyva|jóváhagyott|approved|payment|paid|you|your|card|with|google|wallet|pay|összeg|visszatérítés|jóváírás|refund)\b',
  caseSensitive: false,
);

/// "3 490", "3.490", "3,490.00", "1 234,56" -> whole forints (rounded).
int? parseHufNumber(String raw) {
  final s = raw.replaceAll(RegExp(r'[\s  ]'), '');
  if (s.isEmpty) return null;
  final dot = s.lastIndexOf('.'), comma = s.lastIndexOf(',');
  double? v;
  if (dot >= 0 && comma >= 0) {
    final decimal = dot > comma ? '.' : ',';
    final thousands = decimal == '.' ? ',' : '.';
    v = double.tryParse(s.replaceAll(thousands, '').replaceAll(decimal, '.'));
  } else if (dot >= 0 || comma >= 0) {
    final sep = dot >= 0 ? '.' : ',';
    final parts = s.split(sep);
    final groups = parts.length - 1;
    final last = parts.last;
    if (groups > 1 || last.length == 3) {
      v = double.tryParse(parts.join()); // thousands separator
    } else {
      v = double.tryParse('${parts.first}.$last'); // decimal part
    }
  } else {
    v = double.tryParse(s);
  }
  if (v == null || !v.isFinite) return null;
  final n = v.round();
  return n > 0 && n <= 1000000000 ? n : null;
}

// the last four digits of a card, after the usual markers
final _cardTail = RegExp(
  r'((?:[*•·xX]{2,}\s*)|(?:[•·…]\s*)|(?:végződésű\s*)|(?:vége[:\s]+)|(?:ending in\s*)|(?:card\s+)|(?:kártya\s+))(\d{4})\b',
  caseSensitive: false,
);
// IBAN, written with or without spaces
final _iban = RegExp(r'\b[A-Za-z]{2}\d{2}(?: ?[A-Za-z0-9]{4}){3,8}\b');
// 11+ digits, even when grouped by spaces, dashes or dots: a card number, an
// account number or a phone number. A forint amount never has that many.
final _longGroups = RegExp(r'\d(?:[ \-.]?\d){10,}');

/// Hides what must never be stored or shown: card digits, IBANs, account and
/// phone numbers and any other long number.
String maskSensitive(String s) => s
    .replaceAllMapped(_cardTail, (m) => '${m[1]}••••')
    .replaceAll(_iban, '••••')
    .replaceAll(_longGroups, '••••')
    .replaceAll(RegExp(r'\d{8,}'), '••••');

String _cleanMerchant(String s) {
  var t = s
      .replaceAll(RegExp(r'[•·*]+\s*\d{0,4}'), ' ')
      .replaceAll(_filler, ' ')
      .replaceAll(RegExp(r'\ba\(z\)\s*', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\b\d{4,}\b'), ' ')
      .replaceAll(RegExp(r'[|–—:;,]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  t = t.replaceAll(RegExp(r'^[-\s.]+|[-\s.]+$'), '');
  return t.length > 40 ? t.substring(0, 40).trim() : t;
}

final _atPatterns = [
  RegExp(
    r'\ba\(z\)\s+(.+?)\s+(?:üzletben|helyen|boltban|webshopban|szolgáltatónál|nél)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'(?:itt|helyen|helyszín|kereskedő|merchant|at)\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  ),
  RegExp(r'\bto\s+(.+)$', caseSensitive: false),
  RegExp(r'(?:–|—|\s-\s)\s*([^–—]+)$'),
];

/// Reads a payment notification. Tolerant on purpose (the exact wording of
/// Wallet notifications varies); anything without a forint amount is ignored.
WalletParse parseWalletNotification({
  required String title,
  required String text,
}) {
  final whole = '$title\n$text';
  final m = _huf.firstMatch(whole);
  if (m == null) {
    return _foreign.hasMatch(whole)
        ? const WalletParse(WalletOutcome.foreignCurrency)
        : const WalletParse(WalletOutcome.ignored);
  }
  final amount = parseHufNumber(m[1] ?? m[2] ?? '');
  if (amount == null) return const WalletParse(WalletOutcome.ignored);

  final kind = _incomeWords.hasMatch(whole) ? FinKind.income : FinKind.expense;
  final rest = whole.replaceFirst(m[0]!, ' ');

  var merchant = '';
  for (final p in _atPatterns) {
    final pm = p.firstMatch(rest);
    final g = pm?[1];
    if (g != null) {
      merchant = _cleanMerchant(g);
      if (merchant.isNotEmpty) break;
    }
  }
  if (merchant.isEmpty) {
    final t = _cleanMerchant(title);
    if (t.isNotEmpty &&
        !_generic.hasMatch(title.trim()) &&
        !_generic.hasMatch(t)) {
      merchant = t;
    }
  }
  if (merchant.isEmpty) {
    merchant = _cleanMerchant(text.replaceFirst(m[0]!, ' '));
  }
  return WalletParse(
    WalletOutcome.payment,
    amount: amount,
    kind: kind,
    merchant: merchant,
  );
}

/// Key for remembering which category a merchant belongs to.
String merchantKey(String merchant) => merchant
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9áéíóöőúüű]+'), ' ')
    .trim();
