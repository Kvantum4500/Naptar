import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

FinTx spend(
  String id,
  String cat,
  int amount, {
  int month = 11,
  int day = 10,
  FinKind kind = FinKind.expense,
  bool deleted = false,
}) => FinTx(
  id: id,
  date: floating(2026, month, day),
  amount: amount,
  kind: kind,
  categoryId: cat,
  deleted: deleted,
);

FinTx rec(String rule, String cat, int amount, {int month = 11}) =>
    spend(recurringTxId(rule, 2026, month), cat, amount, month: month, day: 1);

FinBudget budget(String cat, int limit, {bool deleted = false}) =>
    FinBudget(categoryId: cat, limit: limit, deleted: deleted);

BudgetAlertPlan plan(
  List<FinTx> txs,
  List<FinBudget> budgets, {
  BudgetMemory memory = const {},
  int month = 11,
}) => planBudgetAlerts(
  txs: txs,
  budgets: budgets,
  year: 2026,
  month: month,
  memory: memory,
);

String name(String id) => switch (id) {
  'food' => 'Étel',
  'fun' => 'Szórakozás',
  'home' => 'Lakás',
  _ => id,
};

BudgetAlert alert(String cat, BudgetLevel level, int spent, int limit) =>
    BudgetAlert(categoryId: cat, level: level, spent: spent, limit: limit);

void main() {
  group('the levels', () {
    final b = [budget('food', 10000)];

    test('close from 80 %, over only above the limit', () {
      void expectLevel(int spent, BudgetLevel? level) {
        final alerts = plan([spend('t', 'food', spent)], b).alerts;
        if (level == null) {
          expect(alerts, isEmpty, reason: '$spent');
        } else {
          expect(alerts.single.level, level, reason: '$spent');
          expect(alerts.single.spent, spent);
          expect(alerts.single.limit, 10000);
        }
      }

      expectLevel(0, null);
      expectLevel(7999, null);
      expectLevel(8000, BudgetLevel.warn);
      expectLevel(9999, BudgetLevel.warn);
      expectLevel(10000, BudgetLevel.warn); // exactly the limit is not over
      expectLevel(10001, BudgetLevel.over);
      expectLevel(50000, BudgetLevel.over);
    });

    test('always the level the budget screen shows', () {
      for (final limit in [1, 7, 10000, 123457]) {
        for (var spent = 0; spent <= limit * 2; spent += (limit ~/ 37) + 1) {
          final txs = [if (spent > 0) spend('t', 'food', spent)];
          final status = budgetStatus([
            budget('food', limit),
          ], monthSummary(txs, 2026, 11)).single;
          final alerts = plan(txs, [budget('food', limit)]).alerts;
          if (status.level == BudgetLevel.ok) {
            expect(alerts, isEmpty, reason: '$spent/$limit');
          } else {
            expect(alerts.single.level, status.level, reason: '$spent/$limit');
          }
        }
      }
    });

    test('only this month\'s expenses of categories with a budget count', () {
      final txs = [
        spend('a', 'food', 9000, month: 10), // last month
        spend('b', 'food', 9000, month: 12), // next month
        spend('c', 'food', 9000, kind: FinKind.income),
        spend('d', 'food', 9000, deleted: true),
        spend('e', 'fun', 50000), // no budget
        spend('f', 'food', 1000),
      ];
      expect(plan(txs, [budget('food', 10000)]).alerts, isEmpty);
      expect(
        plan(txs, [budget('food', 10000)], month: 10).alerts.single.spent,
        9000,
      );
    });

    test('a deleted budget watches nothing', () {
      expect(
        plan(
          [spend('a', 'food', 20000)],
          [budget('food', 10000, deleted: true)],
        ).alerts,
        isEmpty,
      );
    });
  });

  group('only a rise is news', () {
    final b = [budget('food', 10000)];
    final close = [spend('a', 'food', 8500)];
    final over = [spend('a', 'food', 12000)];

    test('first look: the level reached is told', () {
      final p = plan(close, b);
      expect(p.alerts, [alert('food', BudgetLevel.warn, 8500, 10000)]);
      expect(p.memory, {'food': BudgetLevel.warn});
    });

    test('the same level again is not', () {
      final p = plan(close, b, memory: {'food': BudgetLevel.warn});
      expect(p.alerts, isEmpty);
      expect(p.memory, {'food': BudgetLevel.warn});
      final q = plan(over, b, memory: {'food': BudgetLevel.over});
      expect(q.alerts, isEmpty);
      expect(q.memory, {'food': BudgetLevel.over});
    });

    test('close -> over is told, ok -> over straight away too', () {
      expect(
        plan(over, b, memory: {'food': BudgetLevel.warn}).alerts.single.level,
        BudgetLevel.over,
      );
      expect(plan(over, b).alerts.single.level, BudgetLevel.over);
    });

    test('a fall is not news, and the memory goes down with it', () {
      final p = plan(close, b, memory: {'food': BudgetLevel.over});
      expect(p.alerts, isEmpty);
      expect(p.memory, {'food': BudgetLevel.warn});
      final q = plan(const [], b, memory: {'food': BudgetLevel.over});
      expect(q.alerts, isEmpty);
      expect(q.memory, isEmpty);
    });

    test('so crossing again after a fall is news again', () {
      var memory = <String, BudgetLevel>{};
      var p = plan(close, b, memory: memory);
      expect(p.alerts, hasLength(1));
      memory = p.memory;

      // the expense is deleted
      p = plan([spend('a', 'food', 8500, deleted: true)], b, memory: memory);
      expect(p.alerts, isEmpty);
      expect(p.memory, isEmpty);
      memory = p.memory;

      // and comes back
      p = plan(close, b, memory: memory);
      expect(p.alerts, hasLength(1));
    });

    test('a raised limit makes the next crossing news', () {
      var p = plan(over, b, memory: {'food': BudgetLevel.over});
      expect(p.alerts, isEmpty);

      final raised = [budget('food', 20000)];
      p = plan(over, raised, memory: p.memory); // 12000 / 20000 = 60 %
      expect(p.alerts, isEmpty);
      expect(p.memory, isEmpty);

      p = plan([spend('a', 'food', 17000)], raised, memory: p.memory);
      expect(p.alerts.single.level, BudgetLevel.warn);
    });

    test('memory of a category that has no budget any more is dropped', () {
      final p = plan(
        close,
        b,
        memory: {'food': BudgetLevel.warn, 'fun': BudgetLevel.over},
      );
      expect(p.memory.keys, ['food']);
    });

    test('the plan does not touch the memory it was given', () {
      final memory = {'food': BudgetLevel.warn};
      plan(over, b, memory: memory);
      expect(memory, {'food': BudgetLevel.warn});
    });

    test('each category is judged on its own', () {
      final p = plan(
        [spend('a', 'food', 12000), spend('b', 'fun', 4000)],
        [budget('food', 10000), budget('fun', 5000)],
        memory: {'food': BudgetLevel.over},
      );
      expect(p.alerts.single.categoryId, 'fun');
      expect(p.memory, {'food': BudgetLevel.over, 'fun': BudgetLevel.warn});
    });
  });

  group('what the recurring rules cause is expected', () {
    test('the rent alone at the limit is no news', () {
      final p = plan([rec('rent', 'home', 150000)], [budget('home', 150000)]);
      expect(p.alerts, isEmpty);
      // ... but it is the level the memory holds
      expect(p.memory, {'home': BudgetLevel.warn});
    });

    test('spending on top of it is: over the limit by 5 000', () {
      final p = plan(
        [rec('rent', 'home', 150000), spend('a', 'home', 5000)],
        [budget('home', 150000)],
        memory: {'home': BudgetLevel.warn},
      );
      expect(p.alerts, [alert('home', BudgetLevel.over, 155000, 150000)]);
    });

    test('also with no memory yet: the rent is expected, the rest is news', () {
      final txs = [rec('rent', 'home', 150000), spend('a', 'home', 5000)];
      final p = plan(txs, [budget('home', 150000)]);
      expect(p.alerts.single.level, BudgetLevel.over);
    });

    test('close because of the rule, over because of the rest', () {
      // the rule is 80 % of the limit; nothing else is spent: no news
      expect(
        plan([rec('r', 'fun', 4000)], [budget('fun', 5000)]).alerts,
        isEmpty,
      );
      // 1 500 more: 110 % - over is news (close was expected)
      expect(
        plan(
          [rec('r', 'fun', 4000), spend('a', 'fun', 1500)],
          [budget('fun', 5000)],
        ).alerts.single.level,
        BudgetLevel.over,
      );
      // 100 more: still close, which the rule alone already caused: no news
      expect(
        plan(
          [rec('r', 'fun', 4000), spend('a', 'fun', 100)],
          [budget('fun', 5000)],
        ).alerts,
        isEmpty,
      );
    });

    test('below what the rule causes, spending is news on its own', () {
      // the rule alone is 60 %: fine; 30 % more makes 90 %: close
      final p = plan(
        [rec('r', 'fun', 3000), spend('a', 'fun', 1500)],
        [budget('fun', 5000)],
      );
      expect(p.alerts.single.level, BudgetLevel.warn);
    });

    test('a rule of another month expects nothing now', () {
      final p = plan(
        [rec('rent', 'home', 150000, month: 10)],
        [budget('home', 150000)],
        month: 11,
      );
      expect(p.alerts, isEmpty);
      // the same amount spent by hand in November is news
      final q = plan([spend('a', 'home', 150000)], [budget('home', 150000)]);
      expect(q.alerts.single.level, BudgetLevel.warn);
    });

    test('a deleted rule expects nothing', () {
      final txs = [
        spend(recurringTxId('rent', 2026, 11), 'home', 150000, deleted: true),
        spend('a', 'home', 160000),
      ];
      expect(plan(txs, [budget('home', 150000)]).alerts.single.spent, 160000);
    });

    test('the memory still counts when it is higher than the rule', () {
      final p = plan(
        [rec('r', 'fun', 4000), spend('a', 'fun', 1500)],
        [budget('fun', 5000)],
        memory: {'fun': BudgetLevel.over},
      );
      expect(p.alerts, isEmpty);
    });

    test('a manual id that merely looks similar is not a rule', () {
      // (the same amount, as a rule's, would be expected: a rule's rent alone
      // at the limit is no news, but this is)
      final p = plan(
        [spend('xrec-1', 'home', 150000)],
        [budget('home', 150000)],
      );
      expect(p.alerts.single.level, BudgetLevel.warn);
      final q = plan(
        [spend('Rec-2', 'home', 150000)],
        [budget('home', 150000)],
      );
      expect(q.alerts.single.level, BudgetLevel.warn);
    });

    test('the prefix is what recurringTxId makes', () {
      expect(recurringTxId('x', 2026, 3).startsWith(recurringTxPrefix), isTrue);
      expect(recurringTxPrefix, 'rec-');
    });
  });

  group('the order of the alerts', () {
    final budgets = [
      budget('a', 1000),
      budget('b', 1000),
      budget('c', 1000),
      budget('d', 1000),
      budget('e', 1000),
    ];

    test('over before close, then the furthest gone, then by id', () {
      final txs = [
        spend('1', 'a', 900), // close 90 %
        spend('2', 'b', 1200), // over 120 %
        spend('3', 'c', 850), // close 85 %
        spend('4', 'd', 1500), // over 150 %
        spend('5', 'e', 1200), // over 120 %
      ];
      expect(plan(txs, budgets).alerts.map((a) => a.categoryId), [
        'd',
        'b',
        'e',
        'a',
        'c',
      ]);
    });

    test('a limit of nothing is over at once, and told first', () {
      final p = plan(
        [spend('1', 'a', 5), spend('2', 'b', 950)],
        [budget('a', 0), budget('b', 1000)],
      );
      expect(p.alerts.map((a) => (a.categoryId, a.level)), [
        ('a', BudgetLevel.over),
        ('b', BudgetLevel.warn),
      ]);
    });

    test('the budgets\' own order does not matter', () {
      final txs = [spend('1', 'a', 900), spend('2', 'b', 1200)];
      expect(
        plan(txs, budgets.reversed.toList()).alerts.map((a) => a.categoryId),
        ['b', 'a'],
      );
    });
  });

  group('currentBudgetLevels', () {
    final b = [budget('food', 10000), budget('fun', 5000), budget('x', 100)];

    test('lists what is not fine, and nothing else', () {
      final levels = currentBudgetLevels(
        txs: [
          spend('a', 'food', 8000),
          spend('b', 'fun', 6000),
          spend('c', 'x', 10),
          spend('d', 'food', 99999, month: 10),
        ],
        budgets: b,
        year: 2026,
        month: 11,
      );
      expect(levels, {'food': BudgetLevel.warn, 'fun': BudgetLevel.over});
    });

    test('with it as the memory nothing is news', () {
      final txs = [spend('a', 'food', 8000), spend('b', 'fun', 6000)];
      final seeded = currentBudgetLevels(
        txs: txs,
        budgets: b,
        year: 2026,
        month: 11,
      );
      final p = plan(txs, b, memory: seeded);
      expect(p.alerts, isEmpty);
      expect(p.memory, seeded);
    });

    test('nothing at all when nothing is close', () {
      expect(
        currentBudgetLevels(txs: const [], budgets: b, year: 2026, month: 11),
        isEmpty,
      );
    });
  });

  group('the memory as text', () {
    test('nothing to remember is no text', () {
      expect(encodeBudgetMemory({}), isNull);
    });

    test('a fixed shape, sorted, 1 close and 2 over', () {
      expect(
        encodeBudgetMemory({'b': BudgetLevel.over, 'a': BudgetLevel.warn}),
        '{"a":1,"b":2}',
      );
    });

    test('it reads back what it wrote', () {
      final m = {
        'cat-food': BudgetLevel.warn,
        'cat-fun': BudgetLevel.over,
        'x y': BudgetLevel.warn,
      };
      expect(decodeBudgetMemory(encodeBudgetMemory(m)), m);
    });

    test('unreadable text is no memory, odd values are skipped', () {
      expect(decodeBudgetMemory(null), isEmpty);
      expect(decodeBudgetMemory(''), isEmpty);
      expect(decodeBudgetMemory('nem json'), isEmpty);
      expect(decodeBudgetMemory('[1,2]'), isEmpty);
      expect(decodeBudgetMemory('{"a":3,"b":"1","c":0,"d":null}'), isEmpty);
      expect(decodeBudgetMemory('{"a":1,"b":2,"c":0}'), {
        'a': BudgetLevel.warn,
        'b': BudgetLevel.over,
      });
    });

    test('the month key', () {
      expect(budgetMonthKey(2026, 3), '2026-03');
      expect(budgetMonthKey(2026, 11), '2026-11');
      expect(budgetMonthKey(999, 1), '999-01');
    });
  });

  group('BudgetAlert', () {
    test('percent is rounded down', () {
      expect(alert('a', BudgetLevel.warn, 7999, 10000).percent, 79);
      expect(alert('a', BudgetLevel.warn, 8000, 10000).percent, 80);
      expect(alert('a', BudgetLevel.warn, 8999, 10000).percent, 89);
      expect(alert('a', BudgetLevel.over, 10001, 10000).percent, 100);
      expect(alert('a', BudgetLevel.over, 25000, 10000).percent, 250);
    });

    test('a limit of nothing divides by nothing', () {
      expect(alert('a', BudgetLevel.over, 5, 0).percent, 0);
      expect(alert('a', BudgetLevel.over, 5, 0).ratio, 0);
      expect(alert('a', BudgetLevel.over, 5, -3).percent, 0);
    });

    test('ratio, equality, hash', () {
      expect(alert('a', BudgetLevel.warn, 5, 10).ratio, 0.5);
      final x = alert('a', BudgetLevel.warn, 5, 10);
      expect(x, alert('a', BudgetLevel.warn, 5, 10));
      expect(x.hashCode, alert('a', BudgetLevel.warn, 5, 10).hashCode);
      expect(x == alert('b', BudgetLevel.warn, 5, 10), isFalse);
      expect(x == alert('a', BudgetLevel.over, 5, 10), isFalse);
      expect(x == alert('a', BudgetLevel.warn, 6, 10), isFalse);
      expect(x == alert('a', BudgetLevel.warn, 5, 11), isFalse);
      expect(x.toString(), 'BudgetAlert(a, warn, 5/10)');
    });
  });

  group('the messages', () {
    test('one category close to its limit', () {
      final m = budgetAlertMessage(
        alert('food', BudgetLevel.warn, 42500, 50000),
        'Étel',
      );
      expect(m.key, 'food');
      expect(m.title, 'Költségkeret: Étel');
      expect(
        m.body,
        'A keret 85%-a elfogyott: 42\u00a0500\u00a0Ft / 50\u00a0000\u00a0Ft.',
      );
    });

    test('one category over its limit', () {
      final m = budgetAlertMessage(
        alert('fun', BudgetLevel.over, 52300, 50000),
        'Szórakozás',
      );
      expect(m.title, 'Költségkeret: Szórakozás');
      expect(
        m.body,
        'Túllépted a keretet: 52\u00a0300\u00a0Ft / 50\u00a0000\u00a0Ft '
        '(+2\u00a0300\u00a0Ft).',
      );
    });

    test('exactly at the limit says 100 %', () {
      final m = budgetAlertMessage(
        alert('food', BudgetLevel.warn, 50000, 50000),
        'Étel',
      );
      expect(m.body, startsWith('A keret 100%-a elfogyott'));
    });

    test('up to three alerts are told one by one, in the order given', () {
      final alerts = [
        alert('fun', BudgetLevel.over, 6000, 5000),
        alert('food', BudgetLevel.warn, 8500, 10000),
        alert('home', BudgetLevel.warn, 9000, 10000),
      ];
      final ms = budgetAlertMessages(alerts, name);
      expect(ms.map((m) => m.key), ['fun', 'food', 'home']);
      expect(ms.map((m) => m.title), [
        'Költségkeret: Szórakozás',
        'Költségkeret: Étel',
        'Költségkeret: Lakás',
      ]);
    });

    test('more than three are one message', () {
      final alerts = [
        alert('fun', BudgetLevel.over, 6000, 5000),
        alert('food', BudgetLevel.warn, 8500, 10000),
        alert('home', BudgetLevel.warn, 9000, 10000),
        alert('c4', BudgetLevel.over, 2000, 1000),
      ];
      final ms = budgetAlertMessages(alerts, name);
      expect(ms, [
        const BudgetMessage(
          key: budgetSummaryKey,
          title: 'Költségkeret: 4 kategória',
          body:
              'Szórakozás: túllépve\n'
              'Étel: 85%\n'
              'Lakás: 90%\n'
              'c4: túllépve',
        ),
      ]);
    });

    test('a long list is cut with "and N more"', () {
      final alerts = [
        for (var i = 0; i < 9; i++)
          alert('c$i', BudgetLevel.warn, 900 + i, 1000),
      ];
      final body = budgetAlertMessages(alerts, name).single.body;
      final lines = body.split('\n');
      expect(lines, hasLength(7));
      expect(lines.first, 'c0: 90%');
      expect(lines[5], 'c5: 90%');
      expect(lines.last, '…és még 3');
    });

    test('exactly six are all listed, with no "more" line', () {
      final alerts = [
        for (var i = 0; i < 6; i++) alert('c$i', BudgetLevel.warn, 900, 1000),
      ];
      final lines = budgetAlertMessages(alerts, name).single.body.split('\n');
      expect(lines, hasLength(6));
      expect(lines.last, 'c5: 90%');
    });

    test('nothing to tell is no message', () {
      expect(budgetAlertMessages(const [], name), isEmpty);
    });

    test('messages compare by what they say', () {
      const a = BudgetMessage(key: 'k', title: 't', body: 'b');
      expect(a, const BudgetMessage(key: 'k', title: 't', body: 'b'));
      expect(
        a.hashCode,
        const BudgetMessage(key: 'k', title: 't', body: 'b').hashCode,
      );
      expect(
        a == const BudgetMessage(key: 'x', title: 't', body: 'b'),
        isFalse,
      );
      expect(
        a == const BudgetMessage(key: 'k', title: 'x', body: 'b'),
        isFalse,
      );
      expect(
        a == const BudgetMessage(key: 'k', title: 't', body: 'x'),
        isFalse,
      );
      expect(a.toString(), 'BudgetMessage(k, t, b)');
    });
  });
}
