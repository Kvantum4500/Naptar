import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const nb = ' ';

void main() {
  group('a currency code', () {
    test('three letters, in capitals, never the forint', () {
      expect(normalizeCurrency('eur'), 'EUR');
      expect(normalizeCurrency(' usd '), 'USD');
      expect(normalizeCurrency('Chf'), 'CHF');
      expect(normalizeCurrency('HUF'), isNull);
      expect(normalizeCurrency('huf'), isNull);
      for (final bad in ['', ' ', 'EU', 'EURO', '€', '123', 'E1R', 'E R']) {
        expect(normalizeCurrency(bad), isNull, reason: '"$bad"');
      }
    });

    test('the common ones are three-letter codes without the forint', () {
      expect(commonCurrencies.first.$1, 'EUR');
      expect(commonCurrencies.map((c) => c.$1).toSet(), hasLength(13));
      for (final (code, name) in commonCurrencies) {
        expect(normalizeCurrency(code), code);
        expect(name, isNotEmpty);
      }
      expect(commonCurrencies.any((c) => c.$1 == 'HUF'), isFalse);
    });
  });

  group('reading a typed amount', () {
    void cents(String text, int? expected) =>
        expect(parseCents(text), expected, reason: '"$text"');

    test('a decimal comma or a decimal point', () {
      cents('12,40', 1240);
      cents('12.40', 1240);
      cents('12,4', 1240);
      cents('12', 1200);
      cents('0,5', 50);
      cents(',5', 50);
      cents('.5', 50);
      cents('0,05', 5);
      cents('0,00', 0);
      cents('7,00', 700);
    });

    test('thousands separators of every kind', () {
      cents('1 234,5', 123450);
      cents('1${nb}234,50', 123450);
      cents("1'234.50", 123450);
      cents('1.234,50', 123450);
      cents('1,234.50', 123450);
      cents('1.234.567', 123456700);
      cents('1,234,567.8', 123456780);
      cents('1 234 567', 123456700);
      // (a separator that is there more than once is never a decimal one)
      cents('12.34.56', 12345600);
      cents('1,2,3', 12300);
    });

    test('a separator with three digits after it is a thousands separator', () {
      cents('1.234', 123400);
      cents('12,345', 1234500);
      cents('100,000', 10000000);
      // (but not after a whole part of nothing)
      cents('0,125', 13);
      cents(',125', 13);
      cents('.500', 50);
    });

    test('more than two decimals are rounded, halves up', () {
      cents('0,994', 99);
      cents('0,995', 100);
      cents('12,3456', 1235);
      cents('1.234,567', 123457);
      cents('1,234.564', 123456);
      cents('12,3449', 1234);
    });

    test('signs: a minus, the typographic ones, brackets', () {
      cents('-5', -500);
      cents('−5,50', -550);
      cents('–7', -700);
      cents('(12,50)', -1250);
      cents('+5', 500);
      cents('- 5', -500);
      cents('\u20127', -700); // a figure dash
    });

    test('a bracket alone is not a sign', () {
      cents('(12,50', 1250);
      cents('12,50)', 1250);
      cents('(12,50) Ft', 1250);
    });

    test('a minus after the number is not its sign', () {
      cents('12-', 1200);
      cents('12,50 Ft -', 1250);
    });

    test('words and signs of a currency are left out', () {
      cents('5 EUR', 500);
      cents('€ 12,40', 1240);
      cents('12,40 Ft', 1240);
      cents('Ft 12', 1200);
      cents('USD 1 234,5', 123450);
      cents('-12,50 €', -1250);
      cents('12,40 Ft.', 1240);
    });

    test('what is not a number is not one', () {
      for (final bad in ['', ' ', 'abc', '-', ',', '.', '€', '()', '..']) {
        cents(bad, null);
      }
      // (more than twelve digits before the decimal point)
      cents('1234567890123', null);
      cents('123456789012', 12345678901200);
    });
  });

  group('reading a typed rate', () {
    void rate(String text, double? expected) =>
        expect(parseRate(text), expected, reason: '"$text"');

    test('to four decimals', () {
      rate('399,5', 399.5);
      rate('400', 400.0);
      rate('401.2345', 401.2345);
      rate('401,23456', 401.2346);
      rate('401,23454', 401.2345);
      // (a half is rounded up)
      rate('401,23455', 401.2346);
      rate('1,00005', 1.0001);
      rate('1,00004', 1.0);
      rate('1 234,5', 1234.5);
      rate('400 Ft', 400.0);
      rate('0,0001', 0.0001);
      rate('0,5', 0.5);
    });

    test('a lone separator is a decimal one, whatever follows it', () {
      rate('2,512', 2.512);
      rate('2.512', 2.512);
      rate('399,123', 399.123);
      rate('399,500', 399.5);
      rate('1,234', 1.234);
      rate('100,000', 100.0);
      rate('0,125', 0.125);
      rate(',125', 0.125);
      // (spaces, and the last of two kinds of separator, are as in an amount)
      rate('1 234', 1234.0);
      rate('1 234,567', 1234.567);
      rate('1.234,567', 1234.567);
      rate('1,234.567', 1234.567);
      // (a separator that is there more than once is a thousands one)
      rate('1,234,5', 12345.0);
      rate('12.34.5', 12345.0);
    });

    test('what is written reads back as it was', () {
      for (final r in [
        0.0001,
        0.001,
        0.5,
        2.512,
        3.4,
        16.25,
        399.5,
        399.123,
        400.0,
        1234.567,
        99999.9999,
        100000.0,
      ]) {
        expect(parseRate(formatRate(r)), r, reason: formatRate(r));
      }
    });

    test('positive, and not more than a hundred thousand', () {
      rate('0', null);
      rate('0,00001', null);
      rate('-5', null);
      rate('(5)', null);
      rate('−5', null);
      rate('x', null);
      rate('', null);
      rate('100000', 100000.0);
      rate('100000,0001', null);
      rate('100001', null);
    });
  });

  group('what an amount is worth', () {
    test('forints for the cents of a currency, to the nearest forint', () {
      expect(forintsFor(1240, 399.5), 4954); // 4953,8
      expect(forintsFor(100, 400), 400);
      expect(forintsFor(1, 400), 4);
      expect(forintsFor(1, 10), 0);
      expect(forintsFor(50, 3), 2); // 1,5
      expect(forintsFor(49, 3), 1); // 1,47
      expect(forintsFor(123456, 1), 1235); // 1234,56
    });
  });

  group('writing an amount', () {
    test('in a text field: no grouping, a decimal comma, no ,00', () {
      expect(plainCents(1240), '12,40');
      expect(plainCents(1200), '12');
      expect(plainCents(5), '0,05');
      expect(plainCents(50), '0,50');
      expect(plainCents(0), '0');
      expect(plainCents(-150), '-1,50');
      expect(plainCents(123456), '1234,56');
    });

    test('with its currency: grouped with non-breaking spaces', () {
      expect(formatForeign(1240, 'EUR'), '12,40${nb}EUR');
      expect(formatForeign(1200, 'EUR'), '12${nb}EUR');
      expect(formatForeign(123450, 'EUR'), '1${nb}234,50${nb}EUR');
      expect(formatForeign(5, 'USD'), '0,05${nb}USD');
      expect(formatForeign(100000000, 'JPY'), '1${nb}000${nb}000${nb}JPY');
      expect(formatForeign(100000, 'EUR'), '1${nb}000${nb}EUR');
      expect(formatForeign(99900, 'EUR'), '999${nb}EUR');
      expect(formatForeign(-1240, 'EUR'), '-12,40${nb}EUR');
    });

    test('a rate: a decimal comma, up to four decimals', () {
      expect(formatRate(399.5), '399,5');
      expect(formatRate(400.0), '400');
      expect(formatRate(401.2345), '401,2345');
      expect(formatRate(0.5), '0,5');
      expect(formatRate(399.50001), '399,5');
      expect(formatRate(1234.5), '1234,5');
      expect(formatRate(100000), '100000');
      expect(formatRate(10.0), '10');
    });

    test('a transaction in words: what it was paid in and the rate', () {
      const f = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
      expect(foreignLine(f), '12,40${nb}EUR · 399,5${nb}Ft/EUR');
    });
  });

  group('what a transaction was paid in', () {
    const f = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);

    test('it is worth forints', () {
      expect(f.forints, 4954);
    });

    test('it is stored with three short keys', () {
      expect(f.toJson(), {'cur': 'EUR', 'c': 1240, 'r': 399.5});
      expect(FinForeign.fromJson(f.toJson()), f);
    });

    test('the same values are the same, others are not', () {
      const same = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
      expect(f, same);
      expect(f.hashCode, same.hashCode);
      expect(
        f,
        isNot(const FinForeign(currency: 'USD', cents: 1240, rate: 399.5)),
      );
      expect(
        f,
        isNot(const FinForeign(currency: 'EUR', cents: 1241, rate: 399.5)),
      );
      expect(
        f,
        isNot(const FinForeign(currency: 'EUR', cents: 1240, rate: 399.6)),
      );
      expect(f.toString(), contains('EUR'));
    });

    test('a number may come as a whole number or as a whole decimal', () {
      expect(
        FinForeign.fromJson({'cur': 'EUR', 'c': 1240.0, 'r': 400}),
        const FinForeign(currency: 'EUR', cents: 1240, rate: 400),
      );
    });

    test('what cannot be used is not a foreign amount', () {
      Map<String, Object?> j({
        Object? cur = 'EUR',
        Object? c = 1240,
        Object? r = 399.5,
      }) => {'cur': cur, 'c': c, 'r': r};
      expect(FinForeign.fromJson(j()), isNotNull);
      expect(FinForeign.fromJson(null), isNull);
      expect(FinForeign.fromJson('EUR'), isNull);
      expect(FinForeign.fromJson(<String, Object?>{}), isNull);
      expect(FinForeign.fromJson(j(cur: 'eur')), isNull);
      expect(FinForeign.fromJson(j(cur: 'HUF')), isNull);
      expect(FinForeign.fromJson(j(cur: 'EU')), isNull);
      expect(FinForeign.fromJson(j(cur: 5)), isNull);
      expect(FinForeign.fromJson(j(cur: null)), isNull);
      expect(FinForeign.fromJson(j(c: 0)), isNull);
      expect(FinForeign.fromJson(j(c: -5)), isNull);
      expect(FinForeign.fromJson(j(c: 12.5)), isNull);
      expect(FinForeign.fromJson(j(c: '1240')), isNull);
      expect(FinForeign.fromJson(j(c: double.nan)), isNull);
      expect(FinForeign.fromJson(j(c: double.infinity)), isNull);
      expect(FinForeign.fromJson(j(c: maxForeignCents)), isNotNull);
      expect(FinForeign.fromJson(j(c: maxForeignCents + 1)), isNull);
      expect(FinForeign.fromJson(j(r: 0)), isNull);
      expect(FinForeign.fromJson(j(r: -1)), isNull);
      expect(FinForeign.fromJson(j(r: '400')), isNull);
      expect(FinForeign.fromJson(j(r: double.nan)), isNull);
      expect(FinForeign.fromJson(j(r: double.infinity)), isNull);
      expect(FinForeign.fromJson(j(r: maxRate)), isNotNull);
      expect(FinForeign.fromJson(j(r: maxRate + 1)), isNull);
      expect(FinForeign.fromJson(j(c: null)), isNull);
      expect(FinForeign.fromJson(j(r: null)), isNull);
    });
  });

  group('a transaction in another currency', () {
    FinTx tx({FinForeign? foreign}) => FinTx(
      id: 'a',
      date: floating(2026, 11, 3),
      amount: 4954,
      kind: FinKind.expense,
      merchant: 'Spar Wien',
      foreign: foreign,
    );
    const f = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);

    test('in plain forints it has no foreign part, and none is written', () {
      expect(tx().foreign, isNull);
      expect(tx().toJson().containsKey('fx'), isFalse);
      expect(FinTx.fromJson(tx().toJson())!.foreign, isNull);
    });

    test('the foreign part is written and read back', () {
      final json = tx(foreign: f).toJson();
      expect(json['fx'], {'cur': 'EUR', 'c': 1240, 'r': 399.5});
      expect(json['amount'], 4954);
      final back = FinTx.fromJson(json)!;
      expect(back.foreign, f);
      expect(back.amount, 4954);
      expect(back.merchant, 'Spar Wien');
    });

    test('a record that was never written with it reads without one', () {
      final json = tx().toJson()..['fx'] = null;
      expect(FinTx.fromJson(json)!.foreign, isNull);
    });

    test('a foreign part that cannot be used leaves a plain transaction', () {
      final json = tx(foreign: f).toJson()
        ..['fx'] = {'cur': 'EUR', 'c': 0, 'r': 400};
      final back = FinTx.fromJson(json)!;
      expect(back, isNotNull);
      expect(back.foreign, isNull);
      expect(back.amount, 4954);
    });

    test('a copy keeps it, replaces it, or lets go of it', () {
      final a = tx(foreign: f);
      expect(a.copyWith(note: 'x').foreign, f);
      const g = FinForeign(currency: 'USD', cents: 500, rate: 380);
      expect(a.copyWith(foreign: g).foreign, g);
      expect(a.copyWith(clearForeign: true).foreign, isNull);
      expect(a.copyWith(clearForeign: true, foreign: g).foreign, isNull);
      expect(tx().copyWith(foreign: f).foreign, f);
      expect(tx().copyWith(amount: 5).foreign, isNull);
    });

    test('it counts in forints like any other', () {
      final all = [
        tx(foreign: f),
        FinTx(
          id: 'b',
          date: floating(2026, 11, 4),
          amount: 1000,
          kind: FinKind.expense,
        ),
      ];
      final s = monthSummary(all, 2026, 11);
      expect(s.expense, 5954);
    });
  });
}
