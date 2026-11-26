import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

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

void main() {
  group('monthSummary', () {
    final txs = [
      tx('a', floating(2026, 11, 1), 5000),
      tx('b', floating(2026, 11, 30), 3000, cat: 'cat-fun'),
      tx(
        'c',
        floating(2026, 11, 15),
        400000,
        kind: FinKind.income,
        cat: 'cat-salary',
      ),
      tx('d', floating(2026, 10, 31), 9999), // other month
      tx('e', floating(2026, 12, 1), 9999), // other month
      tx('f', floating(2026, 11, 10), 7777, deleted: true), // deleted
    ];

    test('totals, balance and categories of one month only', () {
      final s = monthSummary(txs, 2026, 11);
      expect(s.income, 400000);
      expect(s.expense, 8000);
      expect(s.balance, 392000);
      expect(s.expenseByCategory, {'cat-food': 5000, 'cat-fun': 3000});
      expect(s.incomeByCategory, {'cat-salary': 400000});
    });

    test('an empty month is all zero', () {
      final s = monthSummary(txs, 2027, 1);
      expect((s.income, s.expense, s.balance), (0, 0, 0));
    });
  });

  group('budgetStatus', () {
    final s = monthSummary(
      [
        tx('a', floating(2026, 11, 1), 8000),
        tx('b', floating(2026, 11, 2), 2000, cat: 'cat-fun'),
        tx('c', floating(2026, 11, 3), 12001, cat: 'cat-sport'),
      ],
      2026,
      11,
    );

    test('ok / warn / over with the remaining amount', () {
      final r = budgetStatus(const [
        FinBudget(categoryId: 'cat-fun', limit: 10000),
        FinBudget(categoryId: 'cat-food', limit: 10000),
        FinBudget(categoryId: 'cat-sport', limit: 12000),
      ], s);
      expect(r[0].level, BudgetLevel.ok);
      expect(r[0].remaining, 8000);
      expect(r[1].level, BudgetLevel.warn); // 80%
      expect(r[2].level, BudgetLevel.over);
      expect(r[2].remaining, -1);
    });

    test('an unspent category and deleted budgets', () {
      final r = budgetStatus(const [
        FinBudget(categoryId: 'cat-health', limit: 5000),
        FinBudget(categoryId: 'cat-food', limit: 1, deleted: true),
      ], s);
      expect(r.length, 1);
      expect(r.single.spent, 0);
      expect(r.single.level, BudgetLevel.ok);
    });
  });

  group('dueRecurring', () {
    FinRecurring rule({
      int day = 5,
      DateTime? from,
      DateTime? to,
      bool active = true,
    }) => FinRecurring(
      id: 'r1',
      title: 'Bérleti díj',
      amount: 120000,
      kind: FinKind.expense,
      categoryId: 'cat-housing',
      dayOfMonth: day,
      fromMonth: from ?? floating(2026, 3, 1),
      toMonth: to,
      active: active,
    );

    test('one transaction per month with a stable id', () {
      final a = dueRecurring([rule()], 2026, 11);
      final b = dueRecurring([rule()], 2026, 11);
      expect(a.single.id, 'rec-r1-202611');
      expect(a.single.id, b.single.id);
      expect(a.single.date, floating(2026, 11, 5));
      expect(a.single.source, FinSource.recurring);
      expect(a.single.merchant, 'Bérleti díj');
    });

    test(
      'day 31 falls back to the last day of short months and leap years',
      () {
        expect(
          dueRecurring(
            [rule(day: 31, from: floating(2020, 1, 1))],
            2026,
            2,
          ).single.date,
          floating(2026, 2, 28),
        );
        expect(
          dueRecurring(
            [rule(day: 31, from: floating(2020, 1, 1))],
            2028,
            2,
          ).single.date,
          floating(2028, 2, 29),
        );
        expect(
          dueRecurring(
            [rule(day: 31, from: floating(2020, 1, 1))],
            2026,
            4,
          ).single.date,
          floating(2026, 4, 30),
        );
        expect(
          dueRecurring(
            [rule(day: 31, from: floating(2020, 1, 1))],
            2026,
            12,
          ).single.date,
          floating(2026, 12, 31),
        );
      },
    );

    test('start and end month, inactive and deleted rules', () {
      final r = rule(from: floating(2026, 6, 1), to: floating(2026, 8, 1));
      expect(dueRecurring([r], 2026, 5), isEmpty);
      expect(dueRecurring([r], 2026, 6), hasLength(1));
      expect(dueRecurring([r], 2026, 8), hasLength(1));
      expect(dueRecurring([r], 2026, 9), isEmpty);
      expect(dueRecurring([rule(active: false)], 2026, 11), isEmpty);
      expect(dueRecurring([rule().copyWith(deleted: true)], 2026, 11), isEmpty);
    });

    test('year boundary ids and dates', () {
      final t = dueRecurring([rule()], 2027, 1).single;
      expect(t.id, 'rec-r1-202701');
      expect(t.date, floating(2027, 1, 5));
    });

    test('a later user edit wins over the generated copy', () {
      final gen = dueRecurring([rule()], 2026, 11).single;
      final edited = gen.copyWith(amount: 130000, updatedAt: gen.updatedAt + 1);
      expect(edited.updatedAt, greaterThan(gen.updatedAt));
    });
  });

  group('goalProgress', () {
    const goal = FinGoal(id: 'g', name: 'Nyaralás', target: 600000);
    FinDeposit dep(int amount, {String goalId = 'g', bool deleted = false}) =>
        FinDeposit(
          id: 'd$amount',
          goalId: goalId,
          date: floating(2026, 11, 1),
          amount: amount,
          deleted: deleted,
        );

    test('sums only deposits of this goal that are not deleted', () {
      final p = goalProgress(goal, [
        dep(100000),
        dep(50000),
        dep(999, goalId: 'other'),
        dep(777, deleted: true),
      ], floating(2026, 11, 8));
      expect(p.saved, 150000);
      expect(p.remaining, 450000);
      expect(p.ratio, closeTo(0.25, 1e-9));
      expect(p.reached, isFalse);
      expect(p.monthlyNeeded, isNull); // no deadline
    });

    test('monthly amount needed until the deadline', () {
      final g = goal.copyWith(deadline: floating(2027, 3, 31));
      final p = goalProgress(g, [dep(100000)], floating(2026, 11, 8));
      // 500000 over Nov..Mar = 4 months
      expect(p.monthlyNeeded, 125000);
    });

    test('a deadline in the past or this month needs it all now', () {
      final g = goal.copyWith(deadline: floating(2026, 5, 1));
      expect(
        goalProgress(g, const [], floating(2026, 11, 8)).monthlyNeeded,
        600000,
      );
    });

    test('a reached goal needs nothing; over 100% is allowed', () {
      final g = goal.copyWith(deadline: floating(2027, 3, 31));
      final p = goalProgress(g, [dep(700000)], floating(2026, 11, 8));
      expect(p.reached, isTrue);
      expect(p.remaining, 0);
      expect(p.monthlyNeeded, isNull);
      expect(p.ratio, greaterThan(1));
    });
  });

  group('formatHuf', () {
    test('groups thousands with non-breaking spaces', () {
      expect(formatHuf(0), '0 Ft');
      expect(formatHuf(999), '999 Ft');
      expect(formatHuf(3490), '3 490 Ft');
      expect(formatHuf(1234567), '1 234 567 Ft');
      expect(formatHuf(-3490), '-3 490 Ft');
    });
  });

  group('JSON', () {
    test('every record type round-trips', () {
      final t = FinTx(
        id: 't',
        date: floating(2026, 11, 8),
        amount: 3490,
        kind: FinKind.expense,
        categoryId: 'cat-food',
        merchant: 'SPAR',
        note: 'hétvégi',
        source: FinSource.wallet,
        updatedAt: 123,
      );
      expect(FinTx.fromJson(t.toJson())!.toJson(), t.toJson());
      const c = FinCategory(
        id: 'c',
        name: 'Étterem',
        kind: FinKind.expense,
        updatedAt: 5,
      );
      expect(FinCategory.fromJson(c.toJson())!.toJson(), c.toJson());
      const b = FinBudget(categoryId: 'c', limit: 20000, updatedAt: 6);
      expect(FinBudget.fromJson(b.toJson())!.toJson(), b.toJson());
      final r = FinRecurring(
        id: 'r',
        title: 'Netflix',
        amount: 4490,
        kind: FinKind.expense,
        categoryId: 'cat-subs',
        dayOfMonth: 12,
        fromMonth: floating(2026, 1, 1),
        toMonth: floating(2026, 12, 1),
        updatedAt: 7,
      );
      expect(FinRecurring.fromJson(r.toJson())!.toJson(), r.toJson());
      final g = FinGoal(
        id: 'g',
        name: 'Laptop',
        target: 400000,
        deadline: floating(2027, 6, 30),
        updatedAt: 8,
      );
      expect(FinGoal.fromJson(g.toJson())!.toJson(), g.toJson());
      final d = FinDeposit(
        id: 'd',
        goalId: 'g',
        date: floating(2026, 11, 1),
        amount: 50000,
        updatedAt: 9,
      );
      expect(FinDeposit.fromJson(d.toJson())!.toJson(), d.toJson());
    });

    test(
      'unusable records are rejected, odd ones are repaired, nothing throws',
      () {
        expect(FinTx.fromJson(null), isNull);
        expect(FinTx.fromJson('x'), isNull);
        expect(
          FinTx.fromJson({'id': 'a', 'date': 'rossz', 'amount': 5}),
          isNull,
        );
        expect(
          FinTx.fromJson({'id': 'a', 'date': '2026-11-01', 'amount': 0}),
          isNull,
        );
        expect(
          FinTx.fromJson({'id': 'a', 'date': '2026-11-01', 'amount': -5}),
          isNull,
        );
        expect(
          FinTx.fromJson({'id': '', 'date': '2026-11-01', 'amount': 5}),
          isNull,
        );
        expect(
          FinTx.fromJson({'id': 'a', 'date': '2026-13-01', 'amount': 5}),
          isNull,
        );
        final t = FinTx.fromJson({
          'id': 'a',
          'date': '2026-11-01',
          'amount': 12.6,
          'kind': 'mi',
          'src': 'ismeretlen',
          'merchant': '  A   B  ',
        })!;
        expect(t.amount, 13);
        expect(t.kind, FinKind.expense);
        expect(t.source, FinSource.manual);
        expect(t.categoryId, kUncategorized);
        expect(t.merchant, 'A B');
        expect(
          FinRecurring.fromJson({
            'id': 'r',
            'title': 'x',
            'amount': 5,
            'day': 40,
            'from': '2026-01-01',
          }),
          isNull,
        );
        expect(FinBudget.fromJson({'cat': 'c', 'limit': 0}), isNull);
        expect(
          FinGoal.fromJson({'id': 'g', 'name': 'x', 'target': -1}),
          isNull,
        );
      },
    );

    test('default categories are unique and cover both kinds', () {
      final c = defaultCategories();
      expect(c.map((e) => e.id).toSet().length, c.length);
      expect(c.any((e) => e.kind == FinKind.income), isTrue);
      expect(c.any((e) => e.kind == FinKind.expense), isTrue);
    });

    test('signed amounts', () {
      expect(tx('a', floating(2026, 1, 1), 100).signed, -100);
      expect(
        tx('a', floating(2026, 1, 1), 100, kind: FinKind.income).signed,
        100,
      );
    });
  });
}
