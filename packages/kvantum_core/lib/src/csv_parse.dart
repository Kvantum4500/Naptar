/// Reading a delimited text file (CSV) the way spreadsheets and banks write it:
/// a delimiter that is a semicolon, a tab, a comma or a bar; cells in quotes
/// that may hold the delimiter, a line break or a quote written twice.
library;

/// The delimiters that are tried, in the order in which one wins a tie.
const csvDelimiters = [';', '\t', ',', '|'];

/// The delimiter of [text]: the one that cuts the first thirty lines that have
/// any of them into the same number of cells most often (and, then, into the
/// most cells). A delimiter in quotes does not count. A text with none of them
/// has the semicolon.
String detectDelimiter(String text) {
  const limit = 30;
  final lines = <Map<String, int>>[];
  var counts = {for (final d in csvDelimiters) d: 0};
  var inQuotes = false;
  void endLine() {
    if (counts.values.any((n) => n > 0)) lines.add(counts);
    counts = {for (final d in csvDelimiters) d: 0};
  }

  for (var i = 0; i < text.length && lines.length < limit; i++) {
    final c = text[i];
    if (c == '"') {
      inQuotes = !inQuotes;
    } else if (inQuotes) {
      continue;
    } else if (c == '\n' || c == '\r') {
      endLine();
    } else if (counts.containsKey(c)) {
      counts[c] = counts[c]! + 1;
    }
  }
  endLine();

  var best = csvDelimiters.first;
  var bestLines = 0, bestCount = 0;
  for (final d in csvDelimiters) {
    final freq = <int, int>{};
    for (final line in lines) {
      final n = line[d]!;
      if (n > 0) freq[n] = (freq[n] ?? 0) + 1;
    }
    for (final e in freq.entries) {
      if (e.value > bestLines || (e.value == bestLines && e.key > bestCount)) {
        best = d;
        bestLines = e.value;
        bestCount = e.key;
      }
    }
  }
  return best;
}

/// The rows of [text] as lists of cells, split at [delimiter]. A blank line is
/// no row. At most [maxRows] rows are read (the rest is left unread).
List<List<String>> parseCsv(
  String text,
  String delimiter, {
  int maxRows = 100000,
}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    final blank = row.length == 1 && row.first.trim().isEmpty;
    if (!blank) rows.add(row);
    row = <String>[];
  }

  final start = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
  for (var i = start; i < text.length && rows.length < maxRows; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c != '"') {
        cell.write(c);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        inQuotes = false;
      }
    } else if (c == '"' && cell.toString().trim().isEmpty) {
      // (a quote that starts a cell; one in the middle of a cell is just a quote)
      cell.clear();
      inQuotes = true;
    } else if (c == delimiter) {
      endCell();
    } else if (c == '\r' || c == '\n') {
      // (a CR LF ends a line and then an empty one, which is no row)
      endRow();
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
