/// The money log as a CSV for a spreadsheet.
///
/// Made for the way Hungarian spreadsheets open a file: the cells are
/// separated by `;`, the text is UTF-8 with a byte-order mark, the lines end
/// with CR LF, the date is `2026-11-13`, and the amount is a plain whole
/// number (an expense is negative).
library;

import 'finance.dart';

/// The first line of the file.
const finCsvHeader = [
  'Dátum',
  'Típus',
  'Összeg (Ft)',
  'Kategória',
  'Kereskedő',
  'Megjegyzés',
  'Forrás',
];

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${_two(d.month)}-${_two(d.day)}';

/// One cell of text. A spreadsheet runs a cell that starts with `=`, `+`, `-`
/// or `@` as a formula (and a merchant name is text somebody else wrote), so
/// such a cell gets an apostrophe in front; a cell with the separator, a quote
/// or a line break is put in quotes.
String csvCell(String text) {
  var t = text;
  if (t.isNotEmpty && '=+-@\t\r'.contains(t[0])) t = "'$t";
  if (t.contains(';') ||
      t.contains('"') ||
      t.contains('\n') ||
      t.contains('\r')) {
    t = '"${t.replaceAll('"', '""')}"';
  }
  return t;
}

String _source(FinSource s) => switch (s) {
  FinSource.manual => 'kézi',
  FinSource.wallet => 'Wallet',
  FinSource.recurring => 'ismétlődő',
};

/// The transactions of [txs] from [from] to [to] (both days included; both
/// optional), oldest first, as a CSV. Deleted transactions are left out.
/// [categoryName] turns a category id into the name shown.
String exportTxCsv(
  Iterable<FinTx> txs, {
  required String Function(String categoryId) categoryName,
  DateTime? from,
  DateTime? to,
}) {
  final first = from == null
      ? null
      : DateTime.utc(from.year, from.month, from.day);
  final last = to == null ? null : DateTime.utc(to.year, to.month, to.day);
  final list =
      [
        for (final t in txs)
          if (!t.deleted &&
              (first == null || !t.date.isBefore(first)) &&
              (last == null || !t.date.isAfter(last)))
            t,
      ]..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
  final b = StringBuffer('\uFEFF')
    ..write(finCsvHeader.join(';'))
    ..write('\r\n');
  for (final t in list) {
    b
      ..write(
        [
          _date(t.date),
          t.kind == FinKind.income ? 'Bevétel' : 'Kiadás',
          '${t.signed}',
          csvCell(categoryName(t.categoryId)),
          csvCell(t.merchant),
          csvCell(t.note),
          _source(t.source),
        ].join(';'),
      )
      ..write('\r\n');
  }
  return b.toString();
}
