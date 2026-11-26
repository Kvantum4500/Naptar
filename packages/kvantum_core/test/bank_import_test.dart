import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);

/// date, merchant, note, amount, currency
BankMapping signed({
  bool invert = false,
  DateOrder order = DateOrder.ymd,
  bool currency = false,
}) => BankMapping(
  columns: {
    BankField.date: 0,
    BankField.merchant: 1,
    BankField.note: 2,
    BankField.amount: 3,
    if (currency) BankField.currency: 4,
  },
  invertSign: invert,
  dateOrder: order,
);

BankImportPlan plan(
  List<List<String>> rows, {
  BankMapping? mapping,
  Map<String, double> rates = const {},
  int first = 1,
}) => planBankImport(
  rows,
  mapping ?? signed(),
  rates: rates,
  firstRowNumber: first,
);

List<String> ids(BankImportPlan p) => [for (final r in p.rows) r.id];

void main() {
  group('a signed amount', () {
    test('minus is an expense, plus an income, in whole forints', () {
      final p = plan([
        ['2026-11-13', 'Spar', 'bevásárlás', '-4 500,00'],
        ['2026-11-15', 'Munkahely', 'fizetés', '300 000'],
      ]);
      expect(p.issues, isEmpty);
      expect(p.rows, hasLength(2));
      final a = p.rows[0], b = p.rows[1];
      expect(a.date, d(2026, 11, 13));
      expect(a.kind, FinKind.expense);
      expect(a.amount, 4500);
      expect(a.merchant, 'Spar');
      expect(a.note, 'bevásárlás');
      expect(a.foreign, isNull);
      expect(a.rowNumber, 1);
      expect(b.kind, FinKind.income);
      expect(b.amount, 300000);
      expect(b.rowNumber, 2);
    });

    test('forints are rounded, halves up', () {
      final p = plan([
        ['2026-11-13', 'a', '', '-4 500,49'],
        ['2026-11-13', 'b', '', '-4 500,50'],
        ['2026-11-13', 'c', '', '4 500,50'],
      ]);
      expect(p.rows.map((r) => r.amount), [4500, 4501, 4501]);
    });

    test('the signs of a bank that lists what was spent as plus', () {
      final p = plan([
        ['2026-11-13', 'Spar', '', '4 500'],
        ['2026-11-15', 'Munkahely', '', '-300 000'],
      ], mapping: signed(invert: true));
      expect(p.rows[0].kind, FinKind.expense);
      expect(p.rows[1].kind, FinKind.income);
      expect(p.rows[0].amount, 4500);
    });

    test('the other kinds of minus and brackets', () {
      final p = plan([
        ['2026-11-13', 'a', '', '−4 500'],
        ['2026-11-13', 'b', '', '(1 200)'],
        ['2026-11-13', 'c', '', '-300 Ft'],
      ]);
      expect(p.rows.map((r) => r.kind), everyElement(FinKind.expense));
      expect(p.rows.map((r) => r.amount), [4500, 1200, 300]);
    });

    test('a date in the order the mapping says', () {
      final p = plan([
        ['03/04/2026', 'a', '', '-100'],
      ], mapping: signed(order: DateOrder.mdy));
      expect(p.rows.single.date, d(2026, 3, 4));
      final q = plan([
        ['03/04/2026', 'a', '', '-100'],
      ], mapping: signed(order: DateOrder.dmy));
      expect(q.rows.single.date, d(2026, 4, 3));
    });
  });

  group('money out and money in', () {
    BankMapping pair() => BankMapping(
      columns: {
        BankField.date: 0,
        BankField.merchant: 1,
        BankField.debit: 2,
        BankField.credit: 3,
      },
      dateOrder: DateOrder.ymd,
    );

    test('the one that is filled says what it is', () {
      final p = plan([
        ['2026-11-13', 'Spar', '4 500', ''],
        ['2026-11-15', 'Munkahely', '', '300 000'],
        ['2026-11-16', 'Bolt', '-1 200', ''],
      ], mapping: pair());
      expect(p.issues, isEmpty);
      expect(p.rows.map((r) => r.kind), [
        FinKind.expense,
        FinKind.income,
        FinKind.expense,
      ]);
      expect(p.rows.map((r) => r.amount), [4500, 300000, 1200]);
    });

    test('the signs are not turned round when there are two columns', () {
      final inverted = pair()..invertSign = true;
      final p = plan([
        ['2026-11-13', 'a', '100', ''],
        ['2026-11-13', 'b', '', '200'],
      ], mapping: inverted);
      expect(p.rows.map((r) => r.kind), [FinKind.expense, FinKind.income]);
    });

    test('both filled, none, or a zero', () {
      final p = plan([
        ['2026-11-13', 'a', '100', '200'],
        ['2026-11-13', 'b', '', ''],
        ['2026-11-13', 'c', '0', ''],
        ['2026-11-13', 'd', '', '0,00'],
        ['2026-11-13', 'e', 'abc', ''],
        // (a zero on one side and an amount on the other is that amount)
        ['2026-11-13', 'f', '0', '700'],
        ['2026-11-13', 'g', '800', '0'],
      ], mapping: pair());
      expect(p.issues.map((i) => (i.rowNumber, i.problem)), [
        (1, ImportProblem.bothSides),
        (2, ImportProblem.noAmount),
        (3, ImportProblem.zeroAmount),
        (4, ImportProblem.zeroAmount),
        (5, ImportProblem.noAmount),
      ]);
      expect(p.rows.map((r) => (r.kind, r.amount)), [
        (FinKind.income, 700),
        (FinKind.expense, 800),
      ]);
    });
  });

  group('an amount with the direction in a column of its own', () {
    BankMapping withDirection({bool invert = false}) => BankMapping(
      columns: {
        BankField.date: 0,
        BankField.merchant: 1,
        BankField.amount: 3,
        BankField.direction: 2,
      },
      invertSign: invert,
      dateOrder: DateOrder.ymd,
    );

    test('the words say it, and the sign of the amount does not matter', () {
      final p = plan([
        ['2026-11-13', 'Spar', 'Terhelés', '4 500'],
        ['2026-11-15', 'Munkahely', 'Jóváírás', '300 000'],
        ['2026-11-16', 'Bolt', 'Terhelés', '-1 200'],
        ['2026-11-17', 'Coop', 'D', '700'],
      ], mapping: withDirection());
      expect(p.rows.map((r) => r.kind), [
        FinKind.expense,
        FinKind.income,
        FinKind.expense,
        FinKind.expense,
      ]);
      expect(p.rows.map((r) => r.amount), [4500, 300000, 1200, 700]);
    });

    test('a word that names none is a row that cannot be read', () {
      final p = plan([
        ['2026-11-13', 'Spar', 'Átutalás', '4 500'],
        ['2026-11-13', 'Spar', '', '4 500'],
      ], mapping: withDirection());
      expect(p.rows, isEmpty);
      expect(p.issues.map((i) => i.problem), [
        ImportProblem.noDirection,
        ImportProblem.noDirection,
      ]);
    });

    test('inverted, the direction is turned round', () {
      final p = plan([
        ['2026-11-13', 'Spar', 'Terhelés', '4 500'],
      ], mapping: withDirection(invert: true));
      expect(p.rows.single.kind, FinKind.income);
    });
  });

  group('rows that cannot be read, and why', () {
    test('a row with an amount and no date is a row that cannot be read', () {
      final p = plan([
        ['', 'a', '', '-100'],
        ['', 'b', '', ''],
      ]);
      expect(p.rows, isEmpty);
      expect(p.issues.map((i) => (i.rowNumber, i.problem)), [
        (1, ImportProblem.noDate),
      ]);
    });

    test('a row with nothing in it is no row', () {
      final p = plan([
        ['', '', '', ''],
        ['  ', '', '', ' '],
        const [],
        ['2026-11-13', 'a', '', '-100'],
      ]);
      expect(p.rows, hasLength(1));
      expect(p.issues, isEmpty);
    });

    test(
      'no date, no amount, a zero, an amount that is too small or too big',
      () {
        final p = plan([
          ['Záró egyenleg', '', '', '123 456'],
          ['x', '', '', ''],
          ['2026-11-13', 'a', '', ''],
          ['2026-11-13', 'b', '', 'abc'],
          ['2026-11-13', 'c', '', '0'],
          ['2026-11-13', 'd', '', '-0,00'],
          ['2026-11-13', 'e', '', '-0,40'],
          ['2026-11-13', 'f', '', '-999 999 999 999'],
          ['2026-11-13', 'g', '', '-100 000 000 000'],
          ['2026-11-13', 'h', '', '-99 999 999 999'],
          ['2026-11-13', 'i', '', '-0,50'],
          ['2026-11-13', 'j', '', '-100 000 000 001'],
        ]);
        expect(p.issues.map((i) => (i.rowNumber, i.problem)), [
          (1, ImportProblem.noDate),
          (2, ImportProblem.noDate),
          (3, ImportProblem.noAmount),
          (4, ImportProblem.noAmount),
          (5, ImportProblem.zeroAmount),
          (6, ImportProblem.zeroAmount),
          (7, ImportProblem.tooSmall),
          (8, ImportProblem.tooBig),
          (12, ImportProblem.tooBig),
        ]);
        // (a hundred billion is the most; half a forint is a forint)
        expect(p.rows.map((r) => r.merchant), ['g', 'h', 'i']);
        expect(p.rows.map((r) => r.amount), [100000000000, 99999999999, 1]);
      },
    );

    test('a row is told by its place in the file', () {
      final p = plan([
        ['2026-11-13', 'a', '', '-100'],
        ['nem dátum', 'b', '', '-100'],
      ], first: 7);
      expect(p.rows.single.rowNumber, 7);
      expect(p.issues.single.rowNumber, 8);
    });

    test('a row shorter than the mapping has empty cells', () {
      final p = plan([
        ['2026-11-13', 'a'],
        ['2026-11-13'],
      ]);
      expect(p.rows, isEmpty);
      expect(p.issues.map((i) => i.problem), [
        ImportProblem.noAmount,
        ImportProblem.noAmount,
      ]);
    });

    test('every problem has words', () {
      for (final p in ImportProblem.values) {
        expect(importProblemText(p), isNotEmpty, reason: '$p');
      }
      expect({
        for (final p in ImportProblem.values) importProblemText(p),
      }, hasLength(ImportProblem.values.length));
    });
  });

  group('another currency', () {
    test('with a rate: what was paid, and the forints it was worth', () {
      final p = plan(
        [
          ['2026-11-13', 'Spar Wien', '', '-12,40', 'EUR'],
          ['2026-11-14', 'Vissza', '', '5,00', 'eur'],
        ],
        mapping: signed(currency: true),
        rates: {'EUR': 399.5},
      );
      expect(p.issues, isEmpty);
      expect(p.rateWanted, isEmpty);
      final a = p.rows[0];
      expect(a.kind, FinKind.expense);
      expect(a.amount, 4954);
      expect(
        a.foreign,
        const FinForeign(currency: 'EUR', cents: 1240, rate: 399.5),
      );
      final b = p.rows[1];
      expect(b.kind, FinKind.income);
      expect(b.amount, 1998);
      expect(b.foreign!.cents, 500);
    });

    test('without a rate the row waits and the currency is asked for', () {
      final p = plan(
        [
          ['2026-11-13', 'Spar Wien', '', '-12,40', 'EUR'],
          ['2026-11-13', 'Lidl', '', '-3 000', 'HUF'],
          ['2026-11-14', 'Tesco', '', '-5,00', 'GBP'],
          ['2026-11-14', 'Aldi', '', '-6,00', 'EUR'],
        ],
        mapping: signed(currency: true),
        rates: {'GBP': 450},
      );
      expect(p.rows.map((r) => r.merchant), ['Lidl', 'Tesco']);
      expect(p.rows[1].foreign!.currency, 'GBP');
      expect(p.rows[1].foreign!.rate, 450);
      expect(p.rateWanted, {'EUR'});
      expect(p.issues.map((i) => (i.rowNumber, i.problem, i.currency)), [
        (1, ImportProblem.missingRate, 'EUR'),
        (4, ImportProblem.missingRate, 'EUR'),
      ]);
    });

    test('the forint, whatever it is called, needs no rate', () {
      final p = plan([
        ['2026-11-13', 'a', '', '-100', 'HUF'],
        ['2026-11-13', 'b', '', '-100', 'Ft'],
        ['2026-11-13', 'c', '', '-100', ''],
        ['2026-11-13', 'd', '', '-100', 'forint'],
      ], mapping: signed(currency: true));
      expect(p.rows, hasLength(4));
      expect(p.rows.map((r) => r.foreign), everyElement(isNull));
      expect(p.rateWanted, isEmpty);
    });

    test('a currency that is none', () {
      final p = plan([
        ['2026-11-13', 'a', '', '-100', 'EURO'],
        ['2026-11-13', 'b', '', '-100', '€'],
      ], mapping: signed(currency: true));
      expect(p.rows, isEmpty);
      expect(p.issues.map((i) => i.problem), [
        ImportProblem.unknownCurrency,
        ImportProblem.unknownCurrency,
      ]);
    });

    test('a column of currencies that is not mapped means forints', () {
      final p = plan([
        ['2026-11-13', 'a', '', '-100', 'EUR'],
      ]);
      expect(p.rows.single.foreign, isNull);
      expect(p.rows.single.amount, 100);
    });

    test('the amounts that cannot be: under a forint, over what fits', () {
      final p = plan(
        [
          ['2026-11-13', 'a', '', '-0,01', 'EUR'],
          ['2026-11-13', 'b', '', '-99 999 999 999,99', 'EUR'],
          ['2026-11-13', 'c', '', '-9 999 999 999,99', 'EUR'],
        ],
        mapping: signed(currency: true),
        rates: {'EUR': 0.01},
      );
      expect(p.issues.map((i) => (i.rowNumber, i.problem)), [
        (1, ImportProblem.tooSmall),
        (2, ImportProblem.tooBig),
      ]);
      expect(p.rows.single.merchant, 'c');
      expect(p.rows.single.amount, 100000000);
    });

    test(
      'the most of an amount in a currency is let in, a cent more is not',
      () {
        final p = plan(
          [
            ['2026-11-13', 'a', '', '-10 000 000 000,00', 'EUR'],
            ['2026-11-13', 'b', '', '-10 000 000 000,01', 'EUR'],
          ],
          mapping: signed(currency: true),
          rates: {'EUR': 0.0001},
        );
        expect(p.rows.map((r) => r.merchant), ['a']);
        expect(p.rows.single.foreign!.cents, 1000000000000);
        expect(p.issues.single.rowNumber, 2);
        expect(p.issues.single.problem, ImportProblem.tooBig);
      },
    );

    test('a rate that makes too many forints', () {
      final p = plan(
        [
          ['2026-11-13', 'a', '', '-9 999 999 999,99', 'EUR'],
        ],
        mapping: signed(currency: true),
        rates: {'EUR': 100000},
      );
      expect(p.rows, isEmpty);
      expect(p.issues.single.problem, ImportProblem.tooBig);
    });
  });

  group('who a row is', () {
    final file = [
      ['2026-11-13', 'Spar', 'bevásárlás', '-4 500'],
      ['2026-11-14', 'Lidl', '', '-1 200'],
      ['2026-11-15', 'Munkahely', 'fizetés', '300 000'],
    ];

    test('the same file read twice is the same transactions', () {
      expect(ids(plan(file)), ids(plan(file)));
      expect(ids(plan(file)).toSet(), hasLength(3));
    });

    test(
      'the id is made of "imp-", a hash and a count; fit for a file name',
      () {
        for (final id in ids(plan(file))) {
          expect(id, matches(RegExp(r'^imp-[0-9a-f]{16}-0$')));
          expect(id.length, lessThanOrEqualTo(100));
        }
      },
    );

    test('a row has its id wherever it stands in the file', () {
      final swapped = [file[2], file[0], file[1]];
      expect(ids(plan(swapped)).toSet(), ids(plan(file)).toSet());
      final shorter = [file[1], file[2]];
      expect(ids(plan(shorter)).toSet(), {
        ids(plan(file))[1],
        ids(plan(file))[2],
      });
    });

    test('identical rows are told apart by their count, in file order', () {
      final p = plan([
        ['2026-11-13', 'Kávé', '', '-800'],
        ['2026-11-13', 'Kávé', '', '-800'],
        ['2026-11-13', 'Kávé', '', '-800'],
        ['2026-11-13', 'Kávé', '', '-900'],
      ]);
      final i = ids(p);
      expect(i.toSet(), hasLength(4));
      expect(i[0].endsWith('-0'), isTrue);
      expect(i[1].endsWith('-1'), isTrue);
      expect(i[2].endsWith('-2'), isTrue);
      expect(i[3].endsWith('-0'), isTrue);
      expect(
        i[0].substring(0, i[0].length - 2),
        i[1].substring(0, i[1].length - 2),
      );
    });

    test('a later file that goes on from an earlier one keeps its ids', () {
      final first = plan([
        ['2026-11-13', 'Kávé', '', '-800'],
      ]);
      final second = plan([
        ['2026-11-13', 'Kávé', '', '-800'],
        ['2026-11-13', 'Kávé', '', '-800'],
      ]);
      expect(ids(second).first, ids(first).single);
      expect(ids(second).toSet(), hasLength(2));
    });

    test('case, accents and spaces in the words do not make another row', () {
      final a = plan([
        ['2026-11-13', 'SPÁR  Kft.', 'Bevásárlás', '-4 500'],
      ]);
      final b = plan([
        ['2026-11-13', 'spar kft.', 'bevasarlas', '-4 500'],
      ]);
      expect(ids(a), ids(b));
    });

    test('anything else that differs makes another row', () {
      final base = ids(
        plan([
          ['2026-11-13', 'Spar', 'a', '-4 500'],
        ]),
      ).single;
      for (final other in [
        ['2026-11-14', 'Spar', 'a', '-4 500'],
        ['2026-11-13', 'Lidl', 'a', '-4 500'],
        ['2026-11-13', 'Spar', 'b', '-4 500'],
        ['2026-11-13', 'Spar', 'a', '-4 501'],
        ['2026-11-13', 'Spar', 'a', '4 500'],
      ]) {
        expect(ids(plan([other])).single, isNot(base), reason: '$other');
      }
    });

    test('the rate typed for a foreign row does not change who it is', () {
      final rows = [
        ['2026-11-13', 'Spar Wien', '', '-12,40', 'EUR'],
      ];
      final a = plan(
        rows,
        mapping: signed(currency: true),
        rates: {'EUR': 399.5},
      );
      final b = plan(
        rows,
        mapping: signed(currency: true),
        rates: {'EUR': 400},
      );
      expect(ids(a), ids(b));
      // (but the currency is part of it)
      final c = plan(
        [
          ['2026-11-13', 'Spar Wien', '', '-12,40', 'USD'],
        ],
        mapping: signed(currency: true),
        rates: {'USD': 399.5},
      );
      expect(ids(c), isNot(ids(a)));
      // (and so is the forint)
      final f = plan([
        ['2026-11-13', 'Spar Wien', '', '-12,40', 'HUF'],
      ], mapping: signed(currency: true));
      expect(ids(f), isNot(ids(a)));
    });

    test(
      'the ids of known rows are what they were: they must never change',
      () {
        // (a file read again after an update of the program must find its rows
        // in the books under the same ids)
        final p = plan(
          [
            ['2026-03-05', 'Spar', 'bevásárlás', '-4 500', 'HUF'],
            ['2026-11-15', 'Munkahely', 'fizetés', '300 000', ''],
            ['2026-11-13', 'Spar Wien', '', '-12,40', 'EUR'],
            ['2026-11-13', 'Spar Wien', '', '-12,40', 'EUR'],
          ],
          mapping: signed(currency: true),
          rates: {'EUR': 399.5},
        );
        expect(ids(p), [
          'imp-cc4109898dba93ed-0',
          'imp-7ed548a01ed86b59-0',
          'imp-e9e52bbbce98c6a4-0',
          'imp-e9e52bbbce98c6a4-1',
        ]);
      },
    );

    test(
      'every id has its sixteen hex digits, and both halves tell rows apart',
      () {
        final p = plan([
          for (var i = 1; i <= 400; i++) ['2026-11-13', 'Spar', '', '-$i'],
        ]);
        final all = ids(p);
        expect(all.toSet(), hasLength(400));
        for (final id in all) {
          expect(id, matches(RegExp(r'^imp-[0-9a-f]{16}-0$')));
        }
        expect({for (final id in all) id.substring(4, 12)}, hasLength(400));
        expect({for (final id in all) id.substring(12, 20)}, hasLength(400));
      },
    );

    test('words are cleaned and cut to what a transaction holds', () {
      final long = 'x' * 300;
      final p = plan([
        [
          '2026-11-13',
          '  Spar \n  Magyarország   Kft.  ',
          '  hosszú   $long',
          '-100',
        ],
        ['2026-11-13', 'y' * 90, '', '-100'],
      ]);
      expect(p.rows[0].merchant, 'Spar Magyarország Kft.');
      expect(p.rows[0].note, startsWith('hosszú xxx'));
      expect(p.rows[0].note.length, 200);
      expect(p.rows[1].merchant.length, 80);
    });

    test('a cut that ends in a space leaves it out', () {
      final p = plan([
        ['2026-11-13', '${'a' * 79} bcd', '', '-100'],
      ]);
      expect(p.rows.single.merchant, 'a' * 79);
    });
  });

  test('the fingerprint of a text is fixed for good', () {
    // (the first half is the FNV-1a of the text: "abc" is 1a47e90b)
    expect(fingerprint(''), '811c9dc59747b28c');
    expect(fingerprint('abc'), '1a47e90b56a7757c');
    expect(fingerprint('Spar'), '97a818656d489964');
    expect(fingerprint('árvíztűrő'), 'ba6f1f31efb342d8');
    expect(fingerprint('abc'), fingerprint('abc'));
    expect(fingerprint('abd'), isNot(fingerprint('abc')));
  });

  test('a row becomes a transaction of the import', () {
    final p = plan(
      [
        ['2026-11-13', 'Spar Wien', 'jegyzet', '-12,40', 'EUR'],
      ],
      mapping: signed(currency: true),
      rates: {'EUR': 399.5},
    );
    final t = p.rows.single.toTx(categoryId: 'cat-food');
    expect(t.id, p.rows.single.id);
    expect(t.source, FinSource.imported);
    expect(t.categoryId, 'cat-food');
    expect(t.amount, 4954);
    expect(t.kind, FinKind.expense);
    expect(t.merchant, 'Spar Wien');
    expect(t.note, 'jegyzet');
    expect(t.date, d(2026, 11, 13));
    expect(t.foreign!.currency, 'EUR');
    expect(t.deleted, isFalse);
    final income = plan([
      ['2026-11-13', 'Munkahely', '', '5 000'],
    ]).rows.single.toTx(categoryId: 'cat-salary');
    expect(income.kind, FinKind.income);
    expect(income.categoryId, 'cat-salary');
    // (and travels as any other: an old reader takes it for a manual one)
    final back = FinTx.fromJson(t.toJson())!;
    expect(back.source, FinSource.imported);
    final old = Map<String, Object?>.from(t.toJson())
      ..['src'] = 'something new';
    expect(FinTx.fromJson(old)!.source, FinSource.manual);
  });

  group('rows that are in the books already', () {
    ImportRow row(
      String id,
      DateTime date,
      int amount, {
      FinKind kind = FinKind.expense,
      FinForeign? foreign,
    }) => ImportRow(
      rowNumber: 1,
      id: id,
      date: date,
      kind: kind,
      amount: amount,
      foreign: foreign,
    );

    FinTx tx(
      String id,
      DateTime date,
      int amount, {
      FinKind kind = FinKind.expense,
      FinSource source = FinSource.manual,
      bool deleted = false,
      FinForeign? foreign,
    }) => FinTx(
      id: id,
      date: date,
      amount: amount,
      kind: kind,
      source: source,
      deleted: deleted,
      foreign: foreign,
    );

    test('a row that was imported before is known, even if deleted since', () {
      final r = findDuplicates(
        [
          row('imp-a', d(2026, 11, 13), 100),
          row('imp-b', d(2026, 11, 13), 200),
        ],
        {'imp-a'},
        const [],
      );
      expect(r.known, {'imp-a'});
      expect(r.similar, isEmpty);
    });

    test('the same kind and amount near the date is a likely duplicate', () {
      final t = tx('m1', d(2026, 11, 14), 4500);
      final r = findDuplicates(
        [row('imp-a', d(2026, 11, 13), 4500)],
        const {},
        [t],
      );
      expect(r.similar['imp-a'], t);
      expect(r.known, isEmpty);
    });

    test('three days apart still is, four is not', () {
      final r3 = findDuplicates(
        [row('r', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 16), 100)],
      );
      expect(r3.similar, hasLength(1));
      final r3b = findDuplicates(
        [row('r', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 10), 100)],
      );
      expect(r3b.similar, hasLength(1));
      final r4 = findDuplicates(
        [row('r', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 17), 100)],
      );
      expect(r4.similar, isEmpty);
      final wider = findDuplicates(
        [row('r', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 17), 100)],
        days: 5,
      );
      expect(wider.similar, hasLength(1));
      final none = findDuplicates(
        [row('r', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 14), 100)],
        days: 0,
      );
      expect(none.similar, isEmpty);
    });

    test('another amount or another kind is not', () {
      final r = findDuplicates(
        [
          row('a', d(2026, 11, 13), 100),
          row('b', d(2026, 11, 13), 100, kind: FinKind.income),
        ],
        const {},
        [
          tx('m1', d(2026, 11, 13), 101),
          tx('m2', d(2026, 11, 13), 100, kind: FinKind.income),
        ],
      );
      expect(r.similar.keys, ['b']);
    });

    test(
      'a deleted transaction and one from an earlier import are left alone',
      () {
        final r = findDuplicates(
          [row('a', d(2026, 11, 13), 100)],
          const {},
          [
            tx('m1', d(2026, 11, 13), 100, deleted: true),
            tx('m2', d(2026, 11, 13), 100, source: FinSource.imported),
          ],
        );
        expect(r.similar, isEmpty);
      },
    );

    test('two as near as each other: the first of them', () {
      final first = tx('first', d(2026, 11, 12), 100);
      final second = tx('second', d(2026, 11, 14), 100);
      final r = findDuplicates(
        [row('a', d(2026, 11, 13), 100)],
        const {},
        [first, second],
      );
      expect(r.similar['a'], first);
    });

    test('a transaction before the row counts as much as one after it', () {
      final before = findDuplicates(
        [row('a', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 9), 100)],
      );
      expect(before.similar, isEmpty);
      final close = findDuplicates(
        [row('a', d(2026, 11, 13), 100)],
        const {},
        [tx('m', d(2026, 11, 10), 100)],
      );
      expect(close.similar, hasLength(1));
    });

    test('the transaction of a Wallet notification counts, too', () {
      final r = findDuplicates(
        [row('a', d(2026, 11, 13), 100)],
        const {},
        [tx('w', d(2026, 11, 13), 100, source: FinSource.wallet)],
      );
      expect(r.similar.keys, ['a']);
    });

    test('the nearest in date is the one, and each stands for one row', () {
      final near = tx('near', d(2026, 11, 13), 100);
      final far = tx('far', d(2026, 11, 15), 100);
      final r = findDuplicates(
        [row('a', d(2026, 11, 13), 100), row('b', d(2026, 11, 14), 100)],
        const {},
        [far, near],
      );
      expect(r.similar['a'], near);
      expect(r.similar['b'], far);
      final single = findDuplicates(
        [row('a', d(2026, 11, 13), 100), row('b', d(2026, 11, 13), 100)],
        const {},
        [near],
      );
      expect(single.similar.keys, ['a']);
    });

    test(
      'a row in another currency is the same when what was paid is the same',
      () {
        const eur = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
        final r = findDuplicates(
          [row('a', d(2026, 11, 13), 4954, foreign: eur)],
          const {},
          [
            // (the books have it at another rate, so at other forints)
            tx(
              'm',
              d(2026, 11, 13),
              4960,
              foreign: const FinForeign(
                currency: 'EUR',
                cents: 1240,
                rate: 400,
              ),
            ),
          ],
        );
        expect(r.similar.keys, ['a']);
        final other = findDuplicates(
          [row('a', d(2026, 11, 13), 4954, foreign: eur)],
          const {},
          [
            tx(
              'm',
              d(2026, 11, 13),
              4960,
              foreign: const FinForeign(
                currency: 'USD',
                cents: 1240,
                rate: 400,
              ),
            ),
            tx(
              'n',
              d(2026, 11, 13),
              4961,
              foreign: const FinForeign(
                currency: 'EUR',
                cents: 1241,
                rate: 400,
              ),
            ),
          ],
        );
        expect(other.similar, isEmpty);
      },
    );

    test('of equally near ones the first in the books is taken, however '
        'they match', () {
      const eur = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
      final r = findDuplicates(
        [row('a', d(2026, 11, 13), 4954, foreign: eur)],
        const {},
        [
          // (these two are left out, and must not take the place of the others)
          tx('gone', d(2026, 11, 13), 4954, deleted: true),
          tx('imp', d(2026, 11, 13), 4954, source: FinSource.imported),
          // (this one matches by what was paid in, the next by the forints)
          tx(
            'first',
            d(2026, 11, 14),
            4960,
            foreign: const FinForeign(currency: 'EUR', cents: 1240, rate: 400),
          ),
          tx('second', d(2026, 11, 12), 4954),
        ],
      );
      expect(r.similar['a']!.id, 'first');
    });

    test(
      'what was paid in is matched in its own currency, for an income too',
      () {
        const usd = FinForeign(currency: 'USD', cents: 5000, rate: 350);
        final r = findDuplicates(
          [
            row(
              'a',
              d(2026, 11, 13),
              17500,
              kind: FinKind.income,
              foreign: usd,
            ),
          ],
          const {},
          [
            tx(
              'm',
              d(2026, 11, 13),
              17600,
              kind: FinKind.income,
              foreign: const FinForeign(
                currency: 'USD',
                cents: 5000,
                rate: 352,
              ),
            ),
          ],
        );
        expect(r.similar['a']?.id, 'm');
      },
    );

    test('a row that is known is not looked for among the others', () {
      final r = findDuplicates(
        [row('imp-a', d(2026, 11, 13), 100)],
        {'imp-a'},
        [tx('m', d(2026, 11, 13), 100)],
      );
      expect(r.known, {'imp-a'});
      expect(r.similar, isEmpty);
    });
  });
}
