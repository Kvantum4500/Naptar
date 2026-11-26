/// From the rows of a bank's CSV file to the transactions they stand for: what
/// is read, what cannot be (and why), a stable identity for each row so that
/// the same file read twice adds nothing, and the rows that look like
/// something already in the books.
library;

import 'bank_mapping.dart';
import 'finance.dart';
import 'finance_currency.dart';
import 'text_safety.dart';

/// Why a row of the file is not imported.
enum ImportProblem {
  noDate,
  noAmount,
  zeroAmount,
  tooSmall,
  tooBig,
  bothSides,
  noDirection,
  unknownCurrency,
  missingRate,
}

String importProblemText(ImportProblem p) => switch (p) {
  ImportProblem.noDate => 'a dátum nem olvasható',
  ImportProblem.noAmount => 'az összeg nem olvasható',
  ImportProblem.zeroAmount => 'az összeg nulla',
  ImportProblem.tooSmall => 'forintban nem érné el az 1 Ft-ot',
  ImportProblem.tooBig => 'túl nagy összeg',
  ImportProblem.bothSides => 'terhelés és jóváírás is van a sorban',
  ImportProblem.noDirection => 'nem ismerhető fel, hogy kiadás vagy bevétel',
  ImportProblem.unknownCurrency => 'ismeretlen pénznem',
  ImportProblem.missingRate => 'nincs megadva az árfolyam',
};

class ImportIssue {
  const ImportIssue(this.rowNumber, this.problem, {this.currency});

  /// The place of the row in the file, counting from 1 (the header is a row).
  final int rowNumber;
  final ImportProblem problem;

  /// For [ImportProblem.missingRate]: the currency that wants a rate.
  final String? currency;

  @override
  String toString() => 'ImportIssue($rowNumber, $problem, $currency)';
}

/// A transaction the file says.
class ImportRow {
  const ImportRow({
    required this.rowNumber,
    required this.id,
    required this.date,
    required this.kind,
    required this.amount,
    this.foreign,
    this.merchant = '',
    this.note = '',
  });

  final int rowNumber;

  /// The same for the same row of the same file, whatever the rate typed for it
  /// or the order of the others: "imp-" and a hash of what the row says, and
  /// which of the identical rows it is.
  final String id;
  final DateTime date;
  final FinKind kind;

  /// Whole forints; for a row in another currency, what the rate makes of it.
  final int amount;
  final FinForeign? foreign;
  final String merchant;
  final String note;

  FinTx toTx({required String categoryId}) => FinTx(
    id: id,
    date: date,
    amount: amount,
    kind: kind,
    categoryId: categoryId,
    merchant: merchant,
    note: note,
    source: FinSource.imported,
    foreign: foreign,
  );
}

class BankImportPlan {
  const BankImportPlan(this.rows, this.issues, this.rateWanted);

  final List<ImportRow> rows;
  final List<ImportIssue> issues;

  /// The currencies of rows that wait for a rate.
  final Set<String> rateWanted;
}

String _clean(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ');
  return t.length > max ? t.substring(0, max).trimRight() : t;
}

String _hex(int n) => (n & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

/// A short identity of [s]: 16 hex digits, two 32-bit hashes (FNV-1a, and a
/// second one with another multiplier). It must never change: the ids of the
/// rows of a bank file, and the columns remembered for a bank, are made of it.
///
/// The integers of the Dart VM wrap round at 64 bits, and the low 32 bits of a
/// product depend on the low 32 bits of its factors, so the first hash needs its
/// mask at the end only.
String fingerprint(String s) {
  var a = 0x811C9DC5, b = 0x9747B28C;
  for (final u in s.codeUnits) {
    a = (a ^ u) * 0x01000193;
    b = ((b ^ u) * 0x85EBCA6B) & 0xFFFFFFFF;
    b ^= b >> 13;
  }
  return _hex(a) + _hex(b);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Reads the data [rows] of a file (the header row and anything above it left
/// out) as [mapping] says. [rates] are the forints for one unit of each foreign
/// currency the user has given a rate for; a row in another currency without
/// one waits ([BankImportPlan.rateWanted]). [firstRowNumber] is the place in the
/// file of the first of [rows].
BankImportPlan planBankImport(
  List<List<String>> rows,
  BankMapping mapping, {
  Map<String, double> rates = const {},
  int firstRowNumber = 1,
}) {
  final out = <ImportRow>[];
  final issues = <ImportIssue>[];
  final wanted = <String>{};
  final seen = <String, int>{};

  String cell(List<String> r, BankField f) {
    final i = mapping[f];
    return i == null || i >= r.length ? '' : r[i].trim();
  }

  for (var n = 0; n < rows.length; n++) {
    final r = rows[n];
    final rowNumber = firstRowNumber + n;
    final dateText = cell(r, BankField.date);
    final texts = [
      cell(r, BankField.amount),
      cell(r, BankField.debit),
      cell(r, BankField.credit),
    ];
    if (dateText.isEmpty && texts.every((t) => t.isEmpty)) continue;

    final date = parseBankDate(dateText, mapping.dateOrder);
    if (date == null) {
      issues.add(ImportIssue(rowNumber, ImportProblem.noDate));
      continue;
    }

    // the amount, its sign and its direction
    int? cents;
    FinKind? kind;
    if (mapping.hasPair) {
      final out0 = parseCents(texts[1]), in0 = parseCents(texts[2]);
      final outAmount = out0 == null || out0 == 0 ? null : out0.abs();
      final inAmount = in0 == null || in0 == 0 ? null : in0.abs();
      if (outAmount != null && inAmount != null) {
        issues.add(ImportIssue(rowNumber, ImportProblem.bothSides));
        continue;
      }
      cents = outAmount ?? inAmount;
      kind = outAmount != null ? FinKind.expense : FinKind.income;
      if (cents == null) {
        issues.add(
          ImportIssue(
            rowNumber,
            out0 == 0 || in0 == 0
                ? ImportProblem.zeroAmount
                : ImportProblem.noAmount,
          ),
        );
        continue;
      }
    } else {
      final signed = parseCents(texts[0]);
      if (signed == null) {
        issues.add(ImportIssue(rowNumber, ImportProblem.noAmount));
        continue;
      }
      if (signed == 0) {
        issues.add(ImportIssue(rowNumber, ImportProblem.zeroAmount));
        continue;
      }
      cents = signed.abs();
      if (mapping[BankField.direction] != null) {
        kind = directionOf(cell(r, BankField.direction));
        if (kind == null) {
          issues.add(ImportIssue(rowNumber, ImportProblem.noDirection));
          continue;
        }
      } else {
        kind = signed < 0 ? FinKind.expense : FinKind.income;
      }
      if (mapping.invertSign) {
        kind = kind == FinKind.expense ? FinKind.income : FinKind.expense;
      }
    }

    // the currency, and the forints
    final code = currencyOf(cell(r, BankField.currency));
    if (code == badCurrency) {
      issues.add(ImportIssue(rowNumber, ImportProblem.unknownCurrency));
      continue;
    }
    int amount;
    FinForeign? foreign;
    if (code == null) {
      amount = (cents / 100).round();
    } else {
      final rate = rates[code];
      if (rate == null) {
        wanted.add(code);
        issues.add(
          ImportIssue(rowNumber, ImportProblem.missingRate, currency: code),
        );
        continue;
      }
      if (cents > maxForeignCents) {
        issues.add(ImportIssue(rowNumber, ImportProblem.tooBig));
        continue;
      }
      foreign = FinForeign(currency: code, cents: cents, rate: rate);
      amount = foreign.forints;
    }
    if (amount < 1) {
      issues.add(ImportIssue(rowNumber, ImportProblem.tooSmall));
      continue;
    }
    if (amount > 100000000000) {
      issues.add(ImportIssue(rowNumber, ImportProblem.tooBig));
      continue;
    }

    // who it is
    final merchant = _clean(cell(r, BankField.merchant), 80);
    final note = _clean(cell(r, BankField.note), 200);
    final key = [
      _ymd(date),
      kind.name,
      cents,
      code ?? 'HUF',
      foldHu(merchant),
      foldHu(note),
    ].join('|');
    final which = seen[key] ?? 0;
    seen[key] = which + 1;
    out.add(
      ImportRow(
        rowNumber: rowNumber,
        id: 'imp-${fingerprint(key)}-$which',
        date: date,
        kind: kind,
        amount: amount,
        foreign: foreign,
        merchant: merchant,
        note: note,
      ),
    );
  }
  return BankImportPlan(out, issues, wanted);
}

// ---------------------------------------------------------------- duplicates

class DuplicateReport {
  const DuplicateReport(this.known, this.similar);

  /// Rows already in the books (imported before, even if deleted since).
  final Set<String> known;

  /// Rows that look like a transaction typed by hand or taken from a Wallet
  /// notification: row id to that transaction.
  final Map<String, FinTx> similar;
}

/// Which of [rows] are in the books already ([knownIds] are the ids of every
/// transaction there is, deleted ones included) and which look like one that is
/// ([existing], the live ones): the same kind and amount, and a date within
/// [days] days of the row (a card payment is booked a day or three later). A
/// transaction stands for one row only.
DuplicateReport findDuplicates(
  List<ImportRow> rows,
  Set<String> knownIds,
  List<FinTx> existing, {
  int days = 3,
}) {
  // What could be taken for a row is looked up by its kind and amount, not
  // found by going over all the transactions for every row (a statement of
  // 20 000 rows against as many transactions would take seconds).
  final live = [
    for (final t in existing)
      if (!t.deleted && t.source != FinSource.imported) t,
  ];
  final byAmount = <(FinKind, int), List<int>>{};
  final byForeign = <(FinKind, String, int), List<int>>{};
  for (var i = 0; i < live.length; i++) {
    final t = live[i];
    (byAmount[(t.kind, t.amount)] ??= []).add(i);
    final f = t.foreign;
    if (f != null) (byForeign[(t.kind, f.currency, f.cents)] ??= []).add(i);
  }
  final known = <String>{};
  final similar = <String, FinTx>{};
  final claimed = <String>{};
  for (final row in rows) {
    if (knownIds.contains(row.id)) {
      known.add(row.id);
      continue;
    }
    final f = row.foreign;
    // (in the order of the transactions: of the nearest, the first is the one)
    final candidates = <int>{
      ...?byAmount[(row.kind, row.amount)],
      if (f != null) ...?byForeign[(row.kind, f.currency, f.cents)],
    }.toList()..sort();
    FinTx? best;
    var bestGap = days + 1;
    for (final i in candidates) {
      final t = live[i];
      if (claimed.contains(t.id)) continue;
      final gap = t.date.difference(row.date).inDays.abs();
      if (gap < bestGap) {
        best = t;
        bestGap = gap;
      }
    }
    if (best != null) {
      similar[row.id] = best;
      claimed.add(best.id);
    }
  }
  return DuplicateReport(known, similar);
}
