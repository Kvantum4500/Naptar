import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

FinTx tx(
  String id,
  DateTime date,
  int amount, {
  FinKind kind = FinKind.expense,
  String cat = 'cat-food',
  String merchant = '',
  String note = '',
  FinSource source = FinSource.manual,
  bool deleted = false,
  FinForeign? foreign,
}) => FinTx(
  id: id,
  date: date,
  amount: amount,
  kind: kind,
  categoryId: cat,
  merchant: merchant,
  note: note,
  source: source,
  deleted: deleted,
  foreign: foreign,
);

String name(String id) => id == 'cat-food' ? 'Élelmiszer' : id;

List<String> lines(String csv) => csv.split('\r\n');

void main() {
  group('the file', () {
    test('a byte-order mark, the header, and a CR LF after every line', () {
      final csv = exportTxCsv(const [], categoryName: name);
      expect(
        csv,
        '﻿Dátum;Típus;Összeg (Ft);Eredeti összeg;Pénznem;Árfolyam (Ft);'
        'Kategória;Kereskedő;Megjegyzés;Forrás\r\n',
      );
      expect(csv.startsWith('﻿'), isTrue);
      expect(finCsvHeader, hasLength(10));
    });

    test(
      'a row: ISO date, type, signed amount, category, merchant, note, source',
      () {
        final csv = exportTxCsv([
          tx(
            'a',
            d(2026, 11, 3),
            4500,
            merchant: 'Spar',
            note: 'hétvégi',
            source: FinSource.wallet,
          ),
          tx(
            'b',
            d(2026, 11, 5),
            300000,
            kind: FinKind.income,
            cat: 'cat-salary',
            merchant: 'Munkahely',
          ),
        ], categoryName: name);
        expect(lines(csv).skip(1).take(2), [
          '2026-11-03;Kiadás;-4500;;;;Élelmiszer;Spar;hétvégi;Wallet',
          '2026-11-05;Bevétel;300000;;;;cat-salary;Munkahely;;kézi',
        ]);
        expect(lines(csv).last, '');
      },
    );

    test('the date has its zeros', () {
      final csv = exportTxCsv([tx('a', d(2026, 3, 5), 1)], categoryName: name);
      expect(lines(csv)[1], startsWith('2026-03-05;'));
      // (an ISO year has four digits, whatever the year is)
      final old = exportTxCsv([tx('a', d(999, 1, 2), 1)], categoryName: name);
      expect(lines(old)[1], startsWith('0999-01-02;'));
    });

    test('a transaction in another currency: what it was paid in, signed', () {
      const eur = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
      final csv = exportTxCsv([
        tx('a', d(2026, 11, 3), 4954, merchant: 'Spar Wien', foreign: eur),
        tx(
          'b',
          d(2026, 11, 4),
          2000,
          kind: FinKind.income,
          merchant: 'Vissza',
          foreign: const FinForeign(currency: 'USD', cents: 500, rate: 400),
        ),
        tx(
          'c',
          d(2026, 11, 5),
          1000,
          foreign: const FinForeign(currency: 'EUR', cents: 250, rate: 400),
        ),
        tx('d', d(2026, 11, 6), 700),
      ], categoryName: name);
      expect(lines(csv).skip(1).take(4), [
        '2026-11-03;Kiadás;-4954;-12,40;EUR;399,5;Élelmiszer;Spar Wien;;kézi',
        '2026-11-04;Bevétel;2000;5;USD;400;Élelmiszer;Vissza;;kézi',
        '2026-11-05;Kiadás;-1000;-2,50;EUR;400;Élelmiszer;;;kézi',
        '2026-11-06;Kiadás;-700;;;;Élelmiszer;;;kézi',
      ]);
    });

    test('where it comes from, in words', () {
      final csv = exportTxCsv([
        tx('a', d(2026, 11, 1), 1, source: FinSource.manual),
        tx('b', d(2026, 11, 2), 1, source: FinSource.wallet),
        tx('c', d(2026, 11, 3), 1, source: FinSource.recurring),
      ], categoryName: name);
      expect(lines(csv).skip(1).take(3).map((l) => l.split(';').last), [
        'kézi',
        'Wallet',
        'ismétlődő',
      ]);
    });
  });

  group('which rows, in which order', () {
    final all = [
      tx('c', d(2026, 11, 5), 3),
      // (the later id first: the order of the input must not decide)
      tx('b', d(2026, 11, 1), 2),
      tx('a', d(2026, 11, 1), 1),
      tx('d', d(2026, 10, 30), 4),
      tx('x', d(2026, 11, 2), 9, deleted: true),
    ];

    List<String> amounts(String csv) => [
      for (final l in lines(csv).skip(1))
        if (l.isNotEmpty) l.split(';')[2],
    ];

    test('oldest first, a tie by the id, none deleted', () {
      expect(amounts(exportTxCsv(all, categoryName: name)), [
        '-4',
        '-1',
        '-2',
        '-3',
      ]);
    });

    test('from a day: that day is in', () {
      expect(
        amounts(exportTxCsv(all, categoryName: name, from: d(2026, 11, 1))),
        ['-1', '-2', '-3'],
      );
    });

    test('to a day: that day is in', () {
      expect(
        amounts(exportTxCsv(all, categoryName: name, to: d(2026, 11, 1))),
        ['-4', '-1', '-2'],
      );
    });

    test('from and to', () {
      expect(
        amounts(
          exportTxCsv(
            all,
            categoryName: name,
            from: d(2026, 11, 1),
            to: d(2026, 11, 1),
          ),
        ),
        ['-1', '-2'],
      );
      expect(
        amounts(exportTxCsv(all, categoryName: name, from: d(2026, 11, 6))),
        isEmpty,
      );
    });

    test('a time of day on the bounds does not matter', () {
      expect(
        amounts(
          exportTxCsv(
            all,
            categoryName: name,
            from: floating(2026, 11, 1, 23, 59),
            to: floating(2026, 11, 1, 0, 1),
          ),
        ),
        ['-1', '-2'],
      );
    });
  });

  group('a cell', () {
    test('plain text stays as it is', () {
      expect(csvCell('Spar'), 'Spar');
      expect(csvCell(''), '');
      expect(csvCell('Élelmiszer és ital'), 'Élelmiszer és ital');
      expect(csvCell('a-b'), 'a-b');
    });

    test('the separator, a quote or a line break puts it in quotes', () {
      expect(csvCell('a;b'), '"a;b"');
      expect(csvCell('say "hi"'), '"say ""hi"""');
      expect(csvCell('a\nb'), '"a\nb"');
      expect(csvCell('a\rb'), '"a\rb"');
      expect(csvCell('a,b'), 'a,b');
    });

    test(
      'a cell that a spreadsheet would run as a formula gets an apostrophe',
      () {
        expect(csvCell('=SUM(A1:A9)'), "'=SUM(A1:A9)");
        expect(csvCell('+36 30 123'), "'+36 30 123");
        expect(csvCell('-5'), "'-5");
        expect(csvCell('@mention'), "'@mention");
        expect(csvCell('\tcmd'), "'\tcmd");
        expect(csvCell('\rcmd'), '"\'\rcmd"');
      },
    );

    test('quotes and the apostrophe together', () {
      expect(csvCell('=A1;B1'), '"\'=A1;B1"');
    });

    test('an equals sign inside is nothing', () {
      expect(csvCell('a=b'), 'a=b');
    });
  });

  group('text from outside in the file', () {
    test('a merchant, a note and a category are all safe', () {
      final csv = exportTxCsv([
        tx(
          'a',
          d(2026, 11, 3),
          100,
          cat: '=cmd',
          merchant: '=HYPERLINK("x")',
          note: 'a;b',
        ),
      ], categoryName: (id) => id);
      expect(
        lines(csv)[1],
        '2026-11-03;Kiadás;-100;;;;\'=cmd;"\'=HYPERLINK(""x"")";"a;b";kézi',
      );
    });

    test('an amount is a number, never a text', () {
      final csv = exportTxCsv([
        tx('a', d(2026, 11, 3), 100),
      ], categoryName: name);
      expect(lines(csv)[1].split(';')[2], '-100');
    });
  });
}
