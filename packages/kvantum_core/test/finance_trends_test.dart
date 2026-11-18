import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

FinTx tx(
  String id,
  DateTime date,
  int amount, {
  FinKind kind = FinKind.expense,
  String cat = 'cat-food',
  bool deleted = false,
}) => FinTx(
  id: id,
  date: date,
  amount: amount,
  kind: kind,
  categoryId: cat,
  deleted: deleted,
);

String name(String id) => switch (id) {
  'cat-food' => 'Élelmiszer',
  'cat-health' => 'Egészség',
  'cat-fun' => 'Szórakozás',
  _ => id,
};

void main() {
  group('the months of the log', () {
    final today = d(2026, 11, 18);

    test('twelve months by default, oldest first, ending with this month', () {
      final t = monthlyTotals(const [], today: today);
      expect(t, hasLength(12));
      expect((t.first.year, t.first.month), (2025, 12));
      expect((t.last.year, t.last.month), (2026, 11));
      expect(t.every((m) => m.isEmpty), isTrue);
      for (var i = 1; i < t.length; i++) {
        expect(
          t[i].year * 12 + t[i].month,
          t[i - 1].year * 12 + t[i - 1].month + 1,
        );
      }
    });

    test(
      'a month is a calendar month: its first and its last day are in it',
      () {
        final t = monthlyTotals(
          [
            tx('a', d(2026, 10, 31), 100),
            tx('b', d(2026, 11, 1), 200),
            tx('c', d(2026, 11, 30), 300),
          ],
          today: today,
          months: 2,
        );
        expect(t.map((m) => m.expense), [100, 500]);
      },
    );

    test(
      'income and expense are told apart, the balance is their difference',
      () {
        final t = monthlyTotals(
          [
            tx('a', d(2026, 11, 3), 600, kind: FinKind.income),
            tx('a2', d(2026, 11, 3), 400, kind: FinKind.income),
            tx('b', d(2026, 11, 4), 300),
            tx('c', d(2026, 11, 5), 200),
          ],
          today: today,
          months: 1,
        ).single;
        expect(t.income, 1000);
        expect(t.expense, 500);
        expect(t.balance, 500);
        expect(t.isEmpty, isFalse);
      },
    );

    test('a month with only income, or only expense, is not empty', () {
      expect(
        const MonthTotal(year: 2026, month: 1, income: 1).isEmpty,
        isFalse,
      );
      expect(
        const MonthTotal(year: 2026, month: 1, expense: 1).isEmpty,
        isFalse,
      );
      expect(const MonthTotal(year: 2026, month: 1).isEmpty, isTrue);
    });

    test(
      'a deleted one, an older one and one of a later month are not there',
      () {
        final t = monthlyTotals(
          [
            tx('a', d(2026, 11, 3), 100, deleted: true),
            tx('b', d(2026, 8, 31), 200), // the month before the window
            tx('c', d(2026, 12, 1), 300), // next month
            tx('d', d(2026, 9, 1), 400),
          ],
          today: today,
          months: 3,
        );
        expect(t.map((m) => m.expense), [400, 0, 0]);
      },
    );

    test('the year turns', () {
      final t = monthlyTotals(
        [
          tx('a', d(2025, 11, 30), 1),
          tx('b', d(2025, 12, 1), 2),
          tx('c', d(2026, 1, 1), 3),
        ],
        today: d(2026, 1, 15),
        months: 3,
      );
      expect(t.map((m) => (m.year, m.month)), [
        (2025, 11),
        (2025, 12),
        (2026, 1),
      ]);
      expect(t.map((m) => m.expense), [1, 2, 3]);
    });

    test('the number of months is kept sensible', () {
      expect(monthlyTotals(const [], today: today, months: 0), hasLength(1));
      expect(monthlyTotals(const [], today: today, months: -5), hasLength(1));
      expect(monthlyTotals(const [], today: today, months: 99), hasLength(60));
      final longest = monthlyTotals(const [], today: today, months: 60);
      expect((longest.first.year, longest.first.month), (2021, 12));
      final one = monthlyTotals(const [], today: today, months: 1).single;
      expect((one.year, one.month), (2026, 11));
    });
  });

  group('the average month', () {
    MonthTotal m(int month, int expense, [int income = 0]) =>
        MonthTotal(year: 2026, month: month, income: income, expense: expense);

    test('one month is no average: it is still going on', () {
      expect(averageMonth([m(11, 500)]), isNull);
      expect(averageMonth(const []), isNull);
    });

    test('the month that is going on is left out', () {
      final a = averageMonth([
        m(9, 100, 10),
        m(10, 300, 30),
        m(11, 99999, 99999),
      ])!;
      expect(a.months, 2);
      expect(a.expense, 200);
      expect(a.income, 20);
    });

    test('a month with nothing in it is not a month of no spending', () {
      final a = averageMonth([
        m(7, 0),
        m(8, 300),
        m(9, 0),
        m(10, 100),
        m(11, 5),
      ])!;
      expect(a.months, 2);
      expect(a.expense, 200);
    });

    test('no complete month with anything in it: no average', () {
      expect(averageMonth([m(9, 0), m(10, 0), m(11, 500)]), isNull);
    });

    test('rounded to whole forints, halves up', () {
      final a = averageMonth([m(9, 100, 1), m(10, 101, 2), m(11, 0)])!;
      expect(a.expense, 101); // 100,5
      expect(a.income, 2); // 1,5
    });

    test('a third of a forint is not a forint', () {
      final a = averageMonth([
        m(8, 100, 100),
        m(9, 100, 100),
        m(10, 101, 101),
        m(11, 0),
      ])!;
      expect(a.months, 3);
      expect(a.expense, 100); // 100,33
      expect(a.income, 100);
      final b = averageMonth([
        m(9, 100, 100),
        m(10, 100, 100),
        m(11, 99, 99),
        m(12, 0),
      ])!;
      expect(b.expense, 100); // 99,67
      expect(b.income, 100);
    });

    test('two months are enough: the first is complete, the second is not', () {
      final a = averageMonth([m(10, 300, 30), m(11, 5, 5)])!;
      expect(a.months, 1);
      expect(a.expense, 300);
      expect(a.income, 30);
      // (and an empty first month leaves nothing to average)
      expect(averageMonth([m(10, 0), m(11, 5)]), isNull);
    });

    test('three months: the oldest of them is a month like the others', () {
      final a = averageMonth([m(9, 90, 9), m(10, 300, 30), m(11, 5, 5)])!;
      expect(a.months, 2);
      expect(a.expense, 195);
      expect(a.income, 20); // 19,5
    });
  });

  group('the categories that cost the most', () {
    final today = d(2026, 11, 18);

    test('biggest first, only expenses, only the window, none deleted', () {
      final top = topExpenseCategories(
        [
          tx('a', d(2026, 11, 2), 500, cat: 'cat-food'),
          tx('b', d(2026, 10, 2), 700, cat: 'cat-food'),
          tx('c', d(2026, 11, 3), 900, cat: 'cat-health'),
          tx(
            'd',
            d(2026, 11, 3),
            5000,
            kind: FinKind.income,
            cat: 'cat-salary',
          ),
          tx('e', d(2026, 11, 3), 5000, cat: 'cat-fun', deleted: true),
          tx('f', d(2026, 7, 31), 5000, cat: 'cat-fun'), // before the window
          tx('g', d(2026, 12, 1), 5000, cat: 'cat-fun'), // after it
        ],
        today: today,
        months: 2,
      );
      expect(top.map((e) => (e.key, e.value)), [
        ('cat-food', 1200),
        ('cat-health', 900),
      ]);
    });

    test('three by default, as many as asked', () {
      final txs = [
        tx('a', d(2026, 11, 2), 400, cat: 'c1'),
        tx('b', d(2026, 11, 2), 300, cat: 'c2'),
        tx('c', d(2026, 11, 2), 200, cat: 'c3'),
        tx('d', d(2026, 11, 2), 100, cat: 'c4'),
      ];
      expect(topExpenseCategories(txs, today: today).map((e) => e.key), [
        'c1',
        'c2',
        'c3',
      ]);
      expect(
        topExpenseCategories(txs, today: today, limit: 1).map((e) => e.key),
        ['c1'],
      );
      expect(topExpenseCategories(txs, today: today, limit: 10), hasLength(4));
    });

    test('a tie goes by the id, so the order never changes', () {
      final top = topExpenseCategories([
        tx('a', d(2026, 11, 2), 100, cat: 'b'),
        tx('b', d(2026, 11, 2), 100, cat: 'a'),
      ], today: today);
      expect(top.map((e) => e.key), ['a', 'b']);
    });

    test('the window is the same as the totals have', () {
      // the first month of a 12 month window is December of last year
      final txs = [tx('a', d(2025, 12, 1), 10), tx('b', d(2025, 11, 30), 20)];
      expect(topExpenseCategories(txs, today: today).single.value, 10);
      expect(
        topExpenseCategories(txs, today: today, months: 13).single.value,
        30,
      );
    });

    test('nothing, no categories', () {
      expect(topExpenseCategories(const [], today: today), isEmpty);
    });

    test('the number of months is kept sensible, as for the totals', () {
      final txs = [
        tx('a', d(2026, 11, 2), 1, cat: 'now'),
        tx('b', d(2026, 10, 2), 2, cat: 'before'),
        tx('c', d(2021, 12, 1), 4, cat: 'oldest'), // the first day of 60 months
        tx('d', d(2021, 11, 30), 8, cat: 'too-old'),
      ];
      Set<String> keys(int months) => topExpenseCategories(
        txs,
        today: today,
        months: months,
        limit: 10,
      ).map((e) => e.key).toSet();
      expect(keys(-5), {'now'});
      expect(keys(0), {'now'});
      expect(keys(1), {'now'});
      expect(keys(2), {'now', 'before'});
      expect(keys(59), {'now', 'before'});
      expect(keys(60), {'now', 'before', 'oldest'});
      expect(keys(99), {'now', 'before', 'oldest'});
    });
  });

  group('the trend in words', () {
    final today = d(2026, 11, 18);

    TrendData trend(List<FinTx> txs, {int months = 3}) =>
        buildTrend(txs, today: today, months: months, categoryName: name);

    test('nothing at all: no data, no lines', () {
      final t = trend(const []);
      expect(t.hasData, isFalse);
      expect(t.summary, isEmpty);
      expect(t.average, isNull);
      expect(t.top, isEmpty);
      expect(t.totals, hasLength(3));
    });

    test('the lines: the whole time, the average month, this month, the biggest', () {
      final t = trend([
        tx('a', d(2026, 9, 3), 60000, cat: 'cat-food'),
        tx('b', d(2026, 9, 4), 40000, cat: 'cat-fun'),
        tx('c', d(2026, 9, 5), 300000, kind: FinKind.income, cat: 'cat-salary'),
        tx('d', d(2026, 10, 3), 150000, cat: 'cat-food'),
        tx('e', d(2026, 10, 4), 50000, cat: 'cat-health'),
        tx(
          'f',
          d(2026, 10, 5),
          300000,
          kind: FinKind.income,
          cat: 'cat-salary',
        ),
        tx('g', d(2026, 11, 3), 50000, cat: 'cat-food'),
      ]);
      expect(t.hasData, isTrue);
      expect(t.summary, [
        'Az elmúlt 3 hónap: kiadás ${formatHuf(350000)}, bevétel ${formatHuf(600000)}, '
            'egyenleg ${formatHuf(250000)}.',
        'Egy átlagos hónap (az elmúlt 2 teljes hónapból): '
            'kiadás ${formatHuf(150000)}, bevétel ${formatHuf(300000)}.',
        'Ebben a hónapban eddig: kiadás ${formatHuf(50000)}, bevétel ${formatHuf(0)}.',
        'A legtöbbet erre költötted: Élelmiszer (${formatHuf(260000)}), '
            'Egészség (${formatHuf(50000)}), Szórakozás (${formatHuf(40000)}).',
      ]);
      expect(t.average!.months, 2);
      expect(t.top.map((e) => e.key), ['cat-food', 'cat-health', 'cat-fun']);
    });

    test('twelve months by default, and the top looks at the same months', () {
      final txs = [
        tx('a', d(2026, 11, 3), 1, cat: 'cat-food'),
        tx('b', d(2026, 6, 3), 5, cat: 'cat-fun'),
      ];
      final all = buildTrend(txs, today: today, categoryName: name);
      expect(all.totals, hasLength(12));
      expect(all.top.map((e) => e.key), ['cat-fun', 'cat-food']);
      // June is not in the last three months, so it is not in the top either
      final short = trend(txs);
      expect(short.totals, hasLength(3));
      expect(short.top.map((e) => e.key), ['cat-food']);
    });

    test('with only this month there is no average line', () {
      final t = trend([tx('a', d(2026, 11, 3), 1000)]);
      expect(t.average, isNull);
      expect(t.summary, hasLength(3));
      expect(t.summary.any((l) => l.startsWith('Egy átlagos hónap')), isFalse);
    });

    test('with only income there is no line about what was spent', () {
      final t = trend([tx('a', d(2026, 11, 3), 1000, kind: FinKind.income)]);
      expect(t.hasData, isTrue);
      expect(t.summary.any((l) => l.startsWith('A legtöbbet')), isFalse);
    });

    test('a negative balance has its minus sign', () {
      final t = trend([tx('a', d(2026, 11, 3), 1000)]);
      expect(t.summary.first, contains('egyenleg ${formatHuf(-1000)}'));
      expect(t.summary.first, contains('-'));
    });
  });

  group('a short amount for a chart', () {
    test('under a thousand: forints', () {
      expect(compactHuf(0), '0 Ft');
      expect(compactHuf(5), '5 Ft');
      expect(compactHuf(999), '999 Ft');
    });

    test('thousands: "e Ft", a decimal only when there is one', () {
      expect(compactHuf(1000), '1 e Ft');
      expect(compactHuf(1500), '1,5 e Ft');
      expect(compactHuf(20000), '20 e Ft');
      expect(compactHuf(250000), '250 e Ft');
      expect(compactHuf(1234), '1,2 e Ft');
      expect(compactHuf(999900), '999,9 e Ft');
    });

    test('millions: "M Ft"', () {
      expect(compactHuf(1000000), '1 M Ft');
      expect(compactHuf(1500000), '1,5 M Ft');
      expect(compactHuf(12000000), '12 M Ft');
      expect(compactHuf(1234567), '1,2 M Ft');
    });

    test('thousands are rounded to a tenth, not cut', () {
      expect(compactHuf(1250), '1,3 e Ft'); // 12,5 tenths
      expect(compactHuf(1949), '1,9 e Ft'); // 19,49
      expect(compactHuf(1951), '2 e Ft'); // 19,51
    });

    test('millions are rounded to a tenth, not cut', () {
      expect(compactHuf(1250000), '1,3 M Ft');
      expect(compactHuf(1949999), '1,9 M Ft');
      expect(compactHuf(1950000), '2 M Ft');
    });

    test('almost a million is a million, not "1000 e Ft"', () {
      expect(compactHuf(999949), '999,9 e Ft');
      expect(compactHuf(999950), '1 M Ft');
      expect(compactHuf(999999), '1 M Ft');
    });

    test('negative with a minus sign', () {
      expect(compactHuf(-500), '-500 Ft');
      expect(compactHuf(-20000), '-20 e Ft');
      expect(compactHuf(-1500000), '-1,5 M Ft');
    });
  });
}
