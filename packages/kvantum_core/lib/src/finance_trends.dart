/// How the money went over the months: totals per calendar month, the average
/// month, the biggest expense categories, and the lines that say it in words.
///
/// Everything here is arithmetic on the transactions that are on the device;
/// a month with nothing in it is there with zeros (a gap is something to see),
/// but it is not counted as a month of "no spending" in the average.
library;

import 'finance.dart';

/// One calendar month of the money log.
class MonthTotal {
  const MonthTotal({
    required this.year,
    required this.month,
    this.income = 0,
    this.expense = 0,
  });

  final int year;
  final int month;
  final int income;
  final int expense;

  int get balance => income - expense;

  /// Nothing came in and nothing went out.
  bool get isEmpty => income == 0 && expense == 0;
}

/// The last [months] calendar months (1 … 60) up to the one that holds
/// [today], oldest first. A month without a transaction is there, with zeros.
/// Deleted transactions are ignored.
List<MonthTotal> monthlyTotals(
  Iterable<FinTx> txs, {
  required DateTime today,
  int months = 12,
}) {
  final n = months.clamp(1, 60);
  final first = today.year * 12 + today.month - 1 - (n - 1);
  final income = List<int>.filled(n, 0);
  final expense = List<int>.filled(n, 0);
  for (final t in txs) {
    if (t.deleted) continue;
    final i = t.date.year * 12 + t.date.month - 1 - first;
    if (i < 0 || i >= n) continue;
    if (t.kind == FinKind.income) {
      income[i] += t.amount;
    } else {
      expense[i] += t.amount;
    }
  }
  return [
    for (var i = 0; i < n; i++)
      MonthTotal(
        year: (first + i) ~/ 12,
        month: (first + i) % 12 + 1,
        income: income[i],
        expense: expense[i],
      ),
  ];
}

/// The average month, in whole forints.
class MonthAverage {
  const MonthAverage({
    required this.months,
    required this.income,
    required this.expense,
  });

  /// How many complete months it is the average of.
  final int months;
  final int income;
  final int expense;
}

/// The average of the complete months in [totals] that have anything in them
/// (the last entry is the month that is still going on, so it is left out; a
/// month with nothing was most likely not written down, so it is not counted as
/// a month of no spending). Null when there is no such month.
MonthAverage? averageMonth(List<MonthTotal> totals) {
  if (totals.isEmpty) return null;
  final used = [
    for (final m in totals.sublist(0, totals.length - 1))
      if (!m.isEmpty) m,
  ];
  if (used.isEmpty) return null;
  var income = 0, expense = 0;
  for (final m in used) {
    income += m.income;
    expense += m.expense;
  }
  return MonthAverage(
    months: used.length,
    income: (income / used.length).round(),
    expense: (expense / used.length).round(),
  );
}

/// The expense categories of the last [months] months (the same window as
/// [monthlyTotals]) with the most spent, biggest first: category id and the
/// sum. Ties are put in the order of the ids.
List<MapEntry<String, int>> topExpenseCategories(
  Iterable<FinTx> txs, {
  required DateTime today,
  int months = 12,
  int limit = 3,
}) {
  final n = months.clamp(1, 60);
  final first = today.year * 12 + today.month - 1 - (n - 1);
  final last = today.year * 12 + today.month - 1;
  final sums = <String, int>{};
  for (final t in txs) {
    if (t.deleted || t.kind != FinKind.expense) continue;
    final i = t.date.year * 12 + t.date.month - 1;
    if (i < first || i > last) continue;
    sums[t.categoryId] = (sums[t.categoryId] ?? 0) + t.amount;
  }
  final out = sums.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return out.take(limit).toList();
}

/// Everything the trend page draws and says.
class TrendData {
  const TrendData({
    required this.totals,
    required this.average,
    required this.top,
    required this.summary,
  });

  /// The months, oldest first; the last is the month that holds today.
  final List<MonthTotal> totals;
  final MonthAverage? average;

  /// The categories with the most spent.
  final List<MapEntry<String, int>> top;

  /// The lines of words.
  final List<String> summary;

  /// Whether there is anything to draw.
  bool get hasData => totals.any((m) => !m.isEmpty);
}

/// The trend of the last [months] months. [categoryName] turns a category id
/// into the name shown.
TrendData buildTrend(
  Iterable<FinTx> txs, {
  required DateTime today,
  int months = 12,
  required String Function(String categoryId) categoryName,
}) {
  final list = txs.toList();
  final totals = monthlyTotals(list, today: today, months: months);
  final average = averageMonth(totals);
  final top = topExpenseCategories(list, today: today, months: months);
  final lines = <String>[];
  if (totals.any((m) => !m.isEmpty)) {
    var income = 0, expense = 0;
    for (final m in totals) {
      income += m.income;
      expense += m.expense;
    }
    lines.add(
      'Az elmúlt ${totals.length} hónap: kiadás ${formatHuf(expense)}, '
      'bevétel ${formatHuf(income)}, egyenleg ${formatHuf(income - expense)}.',
    );
    if (average != null) {
      lines.add(
        'Egy átlagos hónap (az elmúlt ${average.months} teljes hónapból): '
        'kiadás ${formatHuf(average.expense)}, '
        'bevétel ${formatHuf(average.income)}.',
      );
    }
    final now = totals.last;
    lines.add(
      'Ebben a hónapban eddig: kiadás ${formatHuf(now.expense)}, '
      'bevétel ${formatHuf(now.income)}.',
    );
    if (top.isNotEmpty) {
      lines.add(
        'A legtöbbet erre költötted: '
        '${top.map((e) => '${categoryName(e.key)} (${formatHuf(e.value)})').join(', ')}.',
      );
    }
  }
  return TrendData(totals: totals, average: average, top: top, summary: lines);
}
