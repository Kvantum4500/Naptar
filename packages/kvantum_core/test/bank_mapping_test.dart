import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);

void main() {
  group('reading a date', () {
    void date(String text, DateTime? expected, [DateOrder o = DateOrder.dmy]) =>
        expect(parseBankDate(text, o), expected, reason: '"$text" ($o)');

    test('year first', () {
      date('2026-11-13', d(2026, 11, 13));
      date('2026.11.13', d(2026, 11, 13));
      date('2026.11.13.', d(2026, 11, 13));
      date('2026. 11. 13.', d(2026, 11, 13));
      date('2026/11/13', d(2026, 11, 13));
      date('2026-1-3', d(2026, 1, 3));
      date(' 2026-11-13 ', d(2026, 11, 13));
    });

    test('a time after the date is left out', () {
      date('2026-11-13 14:22:11', d(2026, 11, 13));
      date('2026-11-13T14:22:11Z', d(2026, 11, 13));
      date('2026.11.13. 14:22', d(2026, 11, 13));
      date('13.11.2026 14:22', d(2026, 11, 13));
    });

    test('day first, and month first when told so', () {
      date('13.11.2026', d(2026, 11, 13));
      date('13/11/2026', d(2026, 11, 13));
      date('13-11-2026', d(2026, 11, 13));
      date('3.4.2026', d(2026, 4, 3));
      date('3.4.2026', d(2026, 3, 4), DateOrder.mdy);
      date('11/13/2026', d(2026, 11, 13), DateOrder.mdy);
      date('11/13/2026', null);
      date('13/11/2026', null, DateOrder.mdy);
      // (year first is year first whatever the order says)
      date('2026-11-03', d(2026, 11, 3), DateOrder.mdy);
      date('2026-11-03', d(2026, 11, 3), DateOrder.ymd);
      date('3.4.2026', d(2026, 4, 3), DateOrder.ymd);
    });

    test('a year of two digits', () {
      date('13.11.26', d(2026, 11, 13));
      date('13.11.69', d(2069, 11, 13));
      date('13.11.70', d(1970, 11, 13));
      date('13.11.99', d(1999, 11, 13));
      date('11/13/26', d(2026, 11, 13), DateOrder.mdy);
    });

    test('eight digits are a date', () {
      date('20261113', d(2026, 11, 13));
      date('20261301', null);
      date('2026111', null);
      date('202611133', null);
    });

    test('the days of the month are the days of that month', () {
      date('2026-02-28', d(2026, 2, 28));
      date('2026-02-29', null);
      date('2028-02-29', d(2028, 2, 29));
      date('2026-04-31', null);
      date('2026-12-31', d(2026, 12, 31));
      date('2026-13-01', null);
      date('2026-00-10', null);
      date('2026-10-00', null);
    });

    test('the years that can be: 1970 to 2100', () {
      date('1970-01-01', d(1970, 1, 1));
      date('1969-12-31', null);
      date('2100-12-31', d(2100, 12, 31));
      date('2101-01-01', null);
    });

    test('a date has to be at the start', () {
      date('ref 2026-11-13', null);
      date('x20261113', null);
      date('Dátum: 13.11.2026', null);
    });

    test('day first with spaces round the points', () {
      date('13. 11. 2026.', d(2026, 11, 13));
      date('13 . 11 . 2026', d(2026, 11, 13));
    });

    test('what is not a date', () {
      for (final bad in ['', ' ', 'abc', 'Dátum', '13', '2026', '12.2026']) {
        date(bad, null);
      }
      // (a number longer than the day or the year)
      date('2026-11-135', null);
      date('133.11.2026', null);
      date('13.11.20267', null);
    });
  });

  group('the order of the numbers in dates', () {
    test('year first when they are written so', () {
      expect(guessDateOrder(['2026.11.13', '2026.11.14']), DateOrder.ymd);
      expect(guessDateOrder(['20261113']), DateOrder.ymd);
      // (one is enough, and it wins over the rest)
      expect(guessDateOrder(['13.11.2026', '2026-11-13']), DateOrder.ymd);
    });

    test('day first, month first, and day first when it cannot be told', () {
      expect(guessDateOrder(['13.11.2026', '01.02.2026']), DateOrder.dmy);
      expect(guessDateOrder(['11/13/2026', '02/01/2026']), DateOrder.mdy);
      expect(guessDateOrder(['01/02/2026', '03/04/2026']), DateOrder.dmy);
      // (one of each: no telling, so day first)
      expect(guessDateOrder(['13/11/2026', '11/13/2026']), DateOrder.dmy);
      expect(guessDateOrder(const []), DateOrder.dmy);
      expect(guessDateOrder(['', 'x']), DateOrder.dmy);
      // (spaces round a sample do not matter)
      expect(guessDateOrder([' 2026-11-13 ']), DateOrder.ymd);
      expect(guessDateOrder([' 11/13/2026 ']), DateOrder.mdy);
      // (a month is up to 12, a day above it)
      expect(guessDateOrder(['12/13/2026']), DateOrder.mdy);
      expect(guessDateOrder(['01/12/2026']), DateOrder.dmy);
      // (a second number of 12 is a month)
      expect(guessDateOrder(['12/12/2026']), DateOrder.dmy);
      expect(guessDateOrder(['01/13/2026']), DateOrder.mdy);
      expect(guessDateOrder(['13/01/2026']), DateOrder.dmy);
    });
  });

  group('what a cell holds', () {
    test('an amount', () {
      for (final yes in [
        '12',
        '-12',
        '+12',
        '12,50',
        '12.50',
        '1 234,50',
        '1 234,50',
        "1'234.50",
        '-4 500 Ft',
        '4 500 HUF',
        '12,40 EUR',
        '€ 12,40',
        '\$12.40',
        '-12,40 €',
        '(12,50)',
        '−5',
        '–5',
        '‒5',
        '12 345,00 Ft.',
        '12,40 \$',
        '12,40 £',
        '£ 12,40',
        '£12',
        '- 5',
        '\t12 345\t',
        '12 EUR ',
      ]) {
        expect(looksLikeAmount(yes), isTrue, reason: yes);
      }
    });

    test('not an amount', () {
      for (final no in [
        '',
        ' ',
        'abc',
        'Spar',
        '2026-11-13',
        '12345678-12345678-12345678',
        '12/11/2026',
        'x12',
        '-',
        '(',
        '12 34a5',
        '12 EUR 34',
        '12,40 EURO',
        '12 345 forint',
      ]) {
        expect(looksLikeAmount(no), isFalse, reason: no);
      }
    });

    test('a direction', () {
      for (final out in [
        'Terhelés',
        'terheles',
        'Debit',
        'D',
        'd',
        'Kiadás',
        'Kifizetés',
        'ki',
      ]) {
        expect(directionOf(out), FinKind.expense, reason: out);
      }
      for (final inn in [
        'Jóváírás',
        'jovairas',
        'Credit',
        'C',
        'c',
        'Bevétel',
        'Befizetés',
        'be',
        'Beérkező',
      ]) {
        expect(directionOf(inn), FinKind.income, reason: inn);
      }
      // (spaces round it do not matter)
      expect(directionOf(' D '), FinKind.expense);
      expect(directionOf(' ki '), FinKind.expense);
      expect(directionOf(' C '), FinKind.income);
      expect(directionOf(' be '), FinKind.income);
      for (final none in [
        '',
        ' ',
        'Kártyavásárlás',
        'x',
        'dd',
        'átutalás',
        'Fizetés',
      ]) {
        expect(directionOf(none), isNull, reason: none);
      }
    });

    test('a currency', () {
      for (final huf in ['', ' ', 'HUF', 'huf', 'Ft', 'FT', ' forint ']) {
        expect(currencyOf(huf), isNull, reason: huf);
      }
      expect(currencyOf('EUR'), 'EUR');
      expect(currencyOf(' usd '), 'USD');
      for (final bad in ['xx', 'EURO', '12', '€', 'AB1']) {
        expect(currencyOf(bad), badCurrency, reason: bad);
      }
    });
  });

  group('the header row', () {
    test('words of the header are the fields they name', () {
      expect(headerFields('Dátum'), {BankField.date});
      expect(headerFields('Könyvelés dátuma'), {BankField.date});
      expect(headerFields('Összeg'), {BankField.amount});
      expect(headerFields('Amount'), {BankField.amount});
      expect(headerFields('Partner neve'), {BankField.merchant});
      expect(headerFields('Közlemény'), {BankField.note});
      expect(headerFields('Pénznem'), {BankField.currency});
      expect(headerFields('Terhelés'), {BankField.debit});
      expect(headerFields('Jóváírás'), {BankField.credit});
      expect(headerFields('Tranzakció típusa'), {BankField.direction});
      expect(headerFields(''), isEmpty);
      expect(headerFields('Egyenleg'), isEmpty);
      expect(headerFields('2026.11.13'), isEmpty);
    });

    test('a header with both sides in it is a direction, not either', () {
      expect(headerFields('Terhelés/Jóváírás'), {BankField.direction});
      expect(headerFields('Debit/Credit'), {BankField.direction});
    });

    test('an account number or an identifier is no name and no message', () {
      expect(headerFields('Partner számlaszáma'), isEmpty);
      expect(headerFields('Partner IBAN'), isEmpty);
      expect(headerFields('Tranzakció azonosító'), isEmpty);
      expect(headerFields('Megjegyzés BIC'), isEmpty);
      expect(headerFields('Swift'), isEmpty);
      expect(headerFields('Számla szama'), isEmpty);
    });

    test(
      'the header row is the first with the words of two fields or more',
      () {
        final rows = [
          ['Számlakivonat', '', ''],
          ['Számla: 1234', '', ''],
          ['Dátum', 'Partner', 'Összeg'],
          ['2026.11.13', 'Spar', '-4500'],
        ];
        expect(findHeaderRow(rows), 2);
      },
    );

    test('no row like that, no header', () {
      expect(
        findHeaderRow([
          ['2026.11.13', 'Spar', '-4500'],
          ['2026.11.14', 'Lidl', '-1200'],
        ]),
        -1,
      );
      expect(findHeaderRow(const []), -1);
      // (one field alone is not a header)
      expect(
        findHeaderRow([
          ['Dátum', 'x'],
          ['1', '2'],
        ]),
        -1,
      );
    });

    test('a cell that names two fields names one', () {
      expect(headerFields('Description'), {BankField.merchant, BankField.note});
      expect(
        findHeaderRow([
          ['Description', 'x'],
          ['1', '2'],
        ]),
        -1,
      );
      expect(
        findHeaderRow([
          ['Description', 'Dátum'],
          ['1', '2'],
        ]),
        0,
      );
    });

    test(
      'a header of two fields is a header; the twentieth row is the last',
      () {
        expect(
          findHeaderRow([
            ['Dátum', 'Összeg'],
            ['x', 'y'],
          ]),
          0,
        );
        List<List<String>> after(int n) => [
          for (var i = 0; i < n; i++) ['x', 'y'],
          ['Dátum', 'Összeg'],
        ];
        expect(findHeaderRow(after(19)), 19);
        expect(findHeaderRow(after(20)), -1);
      },
    );

    test('the best of them, the first of equals, among the first rows', () {
      expect(
        findHeaderRow([
          ['Dátum', 'Összeg'],
          ['Dátum', 'Összeg', 'Partner'],
          ['Dátum', 'Összeg', 'Partner'],
        ]),
        1,
      );
      final far = List.generate(30, (_) => ['x', 'y']);
      far.add(['Dátum', 'Összeg']);
      expect(findHeaderRow(far), -1);
      expect(findHeaderRow(far, scan: 40), 30);
    });
  });

  group('guessing the columns', () {
    // (shapes that banks plausibly use; none of them is a real export)
    test('a signed amount, a partner, a message, a currency', () {
      final m = guessMapping(
        [
          'Számlaszám',
          'Könyvelés dátuma',
          'Értéknap',
          'Tranzakció típusa',
          'Partner neve',
          'Partner számlaszáma',
          'Közlemény',
          'Összeg',
          'Devizanem',
        ],
        [
          [
            '1234',
            '2026.11.13',
            '2026.11.14',
            'Kártyavásárlás',
            'SPAR',
            '9876',
            'Vásárlás',
            '-4 500,00',
            'HUF',
          ],
          [
            '1234',
            '2026.11.15',
            '2026.11.15',
            'Átutalás',
            'Munkahely',
            '5555',
            'Fizetés',
            '300 000,00',
            'HUF',
          ],
        ],
      );
      expect(m[BankField.date], 1);
      expect(m[BankField.amount], 7);
      expect(m[BankField.merchant], 4);
      expect(m[BankField.note], 6);
      expect(m[BankField.currency], 8);
      expect(m[BankField.direction], isNull);
      expect(m.hasPair, isFalse);
      expect(m.usable, isTrue);
      expect(m.dateOrder, DateOrder.ymd);
      expect(m.invertSign, isFalse);
    });

    test('money out and money in in two columns', () {
      final m = guessMapping(
        [
          'Tranzakció dátuma',
          'Értéknap',
          'Terhelés',
          'Jóváírás',
          'Partner neve',
          'Közlemény',
        ],
        [
          ['13.11.2026', '13.11.2026', '4 500', '', 'SPAR', ''],
          ['15.11.2026', '15.11.2026', '', '300 000', 'Munkahely', 'Fizetés'],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m[BankField.debit], 2);
      expect(m[BankField.credit], 3);
      expect(m[BankField.amount], isNull);
      expect(m.hasPair, isTrue);
      expect(m.usable, isTrue);
      expect(m[BankField.merchant], 4);
      expect(m[BankField.note], 5);
      expect(m.dateOrder, DateOrder.dmy);
    });

    test('an English file: the completed date, one description', () {
      final m = guessMapping(
        [
          'Type',
          'Product',
          'Started Date',
          'Completed Date',
          'Description',
          'Amount',
          'Fee',
          'Currency',
          'State',
          'Balance',
        ],
        [
          [
            'CARD_PAYMENT',
            'Current',
            '2026-11-13 10:00:00',
            '2026-11-13 10:05:00',
            'Spar Wien',
            '-12.40',
            '0.00',
            'EUR',
            'COMPLETED',
            '100.00',
          ],
        ],
      );
      expect(m[BankField.date], 3);
      expect(m[BankField.amount], 5);
      expect(m[BankField.merchant], 4);
      expect(m[BankField.note], isNull);
      expect(m[BankField.currency], 7);
      expect(m[BankField.direction], isNull);
      expect(m.dateOrder, DateOrder.ymd);
    });

    test('a direction column, when the amounts have no sign', () {
      final m = guessMapping(
        ['Dátum', 'Összeg', 'Terhelés/Jóváírás', 'Partner'],
        [
          ['2026.11.13', '4 500', 'Terhelés', 'SPAR'],
          ['2026.11.15', '300 000', 'Jóváírás', 'Munkahely'],
        ],
      );
      expect(m[BankField.direction], 2);
      expect(m[BankField.amount], 1);
    });

    test(
      '...but not when they have, or when the column names no direction',
      () {
        final signed = guessMapping(
          ['Dátum', 'Összeg', 'Típus'],
          [
            ['2026.11.13', '-4 500', 'D'],
            ['2026.11.15', '300 000', 'C'],
          ],
        );
        expect(signed[BankField.direction], isNull);
        final words = guessMapping(
          ['Dátum', 'Összeg', 'Típus'],
          [
            ['2026.11.13', '4 500', 'Kártyavásárlás'],
            ['2026.11.15', '300 000', 'Átutalás'],
          ],
        );
        expect(words[BankField.direction], isNull);
      },
    );

    test('a lone debit or credit column is no pair', () {
      final m = guessMapping(
        ['Dátum', 'Terhelés', 'Összeg'],
        [
          ['2026.11.13', '4 500', '4 500'],
        ],
      );
      expect(m.hasPair, isFalse);
      expect(m[BankField.debit], isNull);
      expect(m[BankField.credit], isNull);
      expect(m[BankField.amount], 2);
    });

    test('a column is taken for one field only', () {
      final m = guessMapping(
        ['Dátum', 'Leírás', 'Összeg'],
        [
          ['2026.11.13', 'Spar', '-4500'],
        ],
      );
      expect(m[BankField.merchant], 1);
      expect(m[BankField.note], isNull);
      expect(m.columns.values.toSet(), hasLength(m.columns.length));
    });

    test('no header: the cells tell', () {
      final m = guessMapping(const [], [
        ['x', '13.11.2026', 'Spar Kft.', '-4 500'],
        ['x', '14.11.2026', 'Lidl Kft.', '-1 200'],
        ['x', '15.11.2026', 'Munkahely', '300 000'],
      ]);
      expect(m[BankField.date], 1);
      expect(m[BankField.amount], 3);
      // (the first free column with words in it is the merchant: the "x" one)
      expect(m[BankField.merchant], 0);
      expect(m.dateOrder, DateOrder.dmy);
    });

    test('a header that is wrong is overruled by the cells', () {
      final m = guessMapping(
        ['Dátum', 'Név', 'Összeg', 'Valami'],
        [
          ['Spar', 'x', 'abc', '2026-11-13'],
          ['Lidl', 'y', 'def', '2026-11-14'],
        ],
      );
      expect(m[BankField.date], 3);
      expect(m[BankField.amount], isNull);
    });

    test('dates that are month first are dates all the same', () {
      final m = guessMapping(
        ['Date', 'Amount'],
        [
          ['11/13/2026', '-4500'],
          ['11/14/2026', '-1200'],
          ['11/15/2026', '300000'],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m.dateOrder, DateOrder.mdy);
      final headerless = guessMapping(const [], [
        ['11/13/2026', '-4500'],
        ['11/14/2026', '-1200'],
      ]);
      expect(headerless[BankField.date], 0);
      expect(headerless[BankField.amount], 1);
    });

    test('a header with spaces round the words is read all the same', () {
      final m = guessMapping(
        ['  Dátum ', ' Partner neve', 'Összeg  '],
        [
          ['2026-11-13', 'Spar', '-4500'],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m[BankField.merchant], 1);
      expect(m[BankField.amount], 2);
    });

    test('a header and no rows: the cells have not said yes', () {
      final m = guessMapping(['Dátum', 'Összeg'], const []);
      expect(m.usable, isFalse);
      expect(m[BankField.date], isNull);
      expect(m[BankField.amount], isNull);
    });

    test('a column of money out alone is free for the amount', () {
      final m = guessMapping(
        ['Dátum', 'Terhelés összege'],
        [
          ['2026-11-13', '4 500'],
        ],
      );
      expect(m[BankField.amount], 1);
      expect(m[BankField.debit], isNull);
    });

    test('a header column that holds no dates is free for the amount', () {
      final m = guessMapping(
        ['Dátum', 'Valami'],
        [
          ['-4500', '2026-11-13'],
          ['-1200', '2026-11-14'],
        ],
      );
      expect(m[BankField.date], 1);
      expect(m[BankField.amount], 0);
    });

    test('half of the cells are enough for a column the header names', () {
      final m = guessMapping(
        ['Dátum', 'Összeg'],
        [
          ['2026-11-13', '100'],
          ['x', 'abc'],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m[BankField.amount], 1);
      final less = guessMapping(
        ['Dátum', 'Összeg'],
        [
          ['2026-11-13', '100'],
          ['x', 'abc'],
          ['y', 'def'],
        ],
      );
      expect(less[BankField.date], isNull);
      expect(less[BankField.amount], isNull);
    });

    test('four cells in five are enough for a column no header names', () {
      final four = guessMapping(const [], [
        ['2026-11-13', '100'],
        ['2026-11-14', '200'],
        ['2026-11-15', '300'],
        ['2026-11-16', '400'],
        ['x', 'abc'],
      ]);
      expect(four[BankField.date], 0);
      expect(four[BankField.amount], 1);
      final three = guessMapping(const [], [
        ['2026-11-13', '100'],
        ['2026-11-14', '200'],
        ['2026-11-15', '300'],
        ['x', 'abc'],
        ['y', 'def'],
      ]);
      expect(three[BankField.date], isNull);
      expect(three[BankField.amount], isNull);
    });

    test('a direction column wants four cells in five that name one', () {
      List<List<String>> rows(String last) => [
        ['2026-11-13', '100', 'Terhelés'],
        ['2026-11-14', '200', 'Jóváírás'],
        ['2026-11-15', '300', 'Terhelés'],
        ['2026-11-16', '400', 'Terhelés'],
        ['2026-11-17', '500', last],
      ];
      final header = ['Dátum', 'Összeg', 'Típus'];
      expect(guessMapping(header, rows('x'))[BankField.direction], 2);
      final three = rows('x')..[3][2] = 'y';
      expect(guessMapping(header, three)[BankField.direction], isNull);
    });

    test('a name for the merchant from the cells: half of them words', () {
      final m = guessMapping(
        ['Dátum', 'Összeg', 'Valami'],
        [
          ['2026-11-13', '100', 'Spar'],
          ['2026-11-14', '200', '300'],
        ],
      );
      expect(m[BankField.merchant], 2);
      final less = guessMapping(
        ['Dátum', 'Összeg', 'Valami'],
        [
          ['2026-11-13', '100', 'Spar'],
          ['2026-11-14', '200', '300'],
          ['2026-11-15', '300', '400'],
        ],
      );
      expect(less[BankField.merchant], isNull);
    });

    test('a header that is right is kept even if few cells agree', () {
      final m = guessMapping(
        ['Dátum', 'Összeg'],
        [
          ['2026.11.13', '-4500'],
          ['Záró egyenleg', ''],
          ['', ''],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m[BankField.amount], 1);
    });

    test('nothing to go by: nothing is guessed', () {
      final m = guessMapping(const [], const []);
      expect(m.columns, isEmpty);
      expect(m.usable, isFalse);
      expect(m.dateOrder, DateOrder.dmy);
      final one = guessMapping(
        ['A'],
        [
          ['x'],
        ],
      );
      expect(one.usable, isFalse);
    });

    test('rows of unequal length do no harm', () {
      final m = guessMapping(
        ['Dátum', 'Partner', 'Összeg'],
        [
          ['2026.11.13', 'Spar'],
          ['2026.11.14', 'Lidl', '-1200'],
          const [],
        ],
      );
      expect(m[BankField.date], 0);
      expect(m[BankField.amount], 2);
    });
  });

  group('a mapping kept for the next time', () {
    test('it is written and read back', () {
      final m = BankMapping(
        columns: {
          BankField.date: 1,
          BankField.amount: 4,
          BankField.merchant: 2,
        },
        invertSign: true,
        dateOrder: DateOrder.mdy,
      );
      final back = BankMapping.fromJson(m.toJson(), 6)!;
      expect(back.columns, m.columns);
      expect(back.invertSign, isTrue);
      expect(back.dateOrder, DateOrder.mdy);
    });

    test('it is written with the names of the fields', () {
      final m = BankMapping(
        columns: {BankField.date: 1, BankField.debit: 3},
        invertSign: true,
        dateOrder: DateOrder.ymd,
      );
      expect(m.toJson(), {
        'date': 1,
        'debit': 3,
        'invert': true,
        'order': 'ymd',
      });
      expect(BankMapping().toJson(), {'invert': false, 'order': 'dmy'});
    });

    test('it fits the file or it is nothing', () {
      final j = {'date': 0, 'amount': 5, 'invert': false, 'order': 'dmy'};
      expect(BankMapping.fromJson(j, 6), isNotNull);
      // (a column that the file does not have)
      expect(BankMapping.fromJson(j, 5), isNull);
      expect(BankMapping.fromJson({'date': -1}, 5), isNull);
      expect(BankMapping.fromJson({'date': 0}, 5)![BankField.date], 0);
      expect(BankMapping.fromJson({'date': 4}, 5)![BankField.date], 4);
      expect(BankMapping.fromJson({'date': 5}, 5), isNull);
      expect(BankMapping.fromJson({'date': 1.5}, 5), isNull);
      expect(BankMapping.fromJson({'date': 'x'}, 5), isNull);
      // (two fields in one column)
      expect(BankMapping.fromJson({'date': 1, 'amount': 1}, 5), isNull);
      expect(BankMapping.fromJson('x', 5), isNull);
      expect(BankMapping.fromJson(null, 5), isNull);
    });

    test('a damaged order is day first, a missing flag is no inversion', () {
      final m = BankMapping.fromJson({'date': 0, 'order': 'zzz'}, 3)!;
      expect(m.dateOrder, DateOrder.dmy);
      expect(m.invertSign, isFalse);
      final ok = BankMapping.fromJson({'date': 0, 'order': 'mdy'}, 3)!;
      expect(ok.dateOrder, DateOrder.mdy);
      expect(
        BankMapping.fromJson({'date': 0, 'invert': 'yes'}, 3)!.invertSign,
        isFalse,
      );
    });

    test('the header names the file: the same words in the same order', () {
      expect(
        headerSignature(['Dátum', ' Összeg ']),
        headerSignature(['dátum', 'ÖSSZEG']),
      );
      expect(
        headerSignature(['Dátum', 'Összeg']),
        isNot(headerSignature(['Összeg', 'Dátum'])),
      );
      expect(headerSignature(['Dátum', 'Összeg']), 'datum|osszeg');
    });
  });

  group('the mapping object', () {
    test('a column is set and let go', () {
      final m = BankMapping();
      expect(m.usable, isFalse);
      m[BankField.date] = 0;
      expect(m.usable, isFalse);
      m[BankField.amount] = 1;
      expect(m.usable, isTrue);
      m[BankField.amount] = null;
      expect(m.usable, isFalse);
      m[BankField.debit] = 1;
      m[BankField.credit] = 2;
      expect(m.usable, isTrue);
      expect(m.hasPair, isTrue);
      m[BankField.credit] = null;
      expect(m.hasPair, isFalse);
      expect(m.usable, isFalse);
    });

    test('a copy is its own', () {
      final m = BankMapping(
        columns: {BankField.date: 0},
        invertSign: true,
        dateOrder: DateOrder.mdy,
      );
      final c = m.copy();
      expect(c.invertSign, isTrue);
      expect(c.dateOrder, DateOrder.mdy);
      c[BankField.amount] = 3;
      c.invertSign = false;
      expect(m.columns, {BankField.date: 0});
      expect(m.invertSign, isTrue);
      expect(c.columns, {BankField.date: 0, BankField.amount: 3});
    });
  });
}
