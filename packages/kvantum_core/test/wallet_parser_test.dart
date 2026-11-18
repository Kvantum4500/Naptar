import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

WalletParse p(String title, String text) =>
    parseWalletNotification(title: title, text: text);

void main() {
  group('amounts', () {
    test('forint formats', () {
      expect(parseHufNumber('3 490'), 3490);
      expect(parseHufNumber('3 490'), 3490);
      expect(parseHufNumber('3490'), 3490);
      expect(parseHufNumber('3.490'), 3490);
      expect(parseHufNumber('3,490'), 3490);
      expect(parseHufNumber('3,490.00'), 3490);
      expect(parseHufNumber('3.490,00'), 3490);
      expect(parseHufNumber('1 234,56'), 1235);
      expect(parseHufNumber('1,234,567'), 1234567);
      expect(parseHufNumber('12.5'), 13);
    });

    test('nothing sensible gives null', () {
      expect(parseHufNumber(''), isNull);
      expect(parseHufNumber('0'), isNull);
      expect(parseHufNumber('abc'), isNull);
      expect(parseHufNumber('99999999999999'), isNull);
    });
  });

  group('payments', () {
    test('merchant in the title, amount in the text', () {
      final r = p('SPAR', '3 490 Ft · Mastercard •••• 1234');
      expect(r.outcome, WalletOutcome.payment);
      expect(r.amount, 3490);
      expect(r.kind, FinKind.expense);
      expect(r.merchant, 'SPAR');
    });

    test('Hungarian sentence with the shop in it', () {
      final r = p(
        'Google Wallet',
        'Fizetés: 12 990 Ft a(z) Decathlon üzletben',
      );
      expect(r.amount, 12990);
      expect(r.merchant, 'Decathlon');
    });

    test('English wording and a currency prefix', () {
      final r = p('Google Wallet', 'You paid HUF 3,490.00 to SPAR');
      expect(r.amount, 3490);
      expect(r.merchant, 'SPAR');
    });

    test('amount then dash then merchant', () {
      final r = p('Fizetés', '3490 HUF – MOL');
      expect(r.amount, 3490);
      expect(r.merchant, 'MOL');
    });

    test('a labelled merchant', () {
      final r = p(
        'Tranzakció',
        'Összeg: 4 500 Ft, Kereskedő: Lidl Magyarország',
      );
      expect(r.amount, 4500);
      expect(r.merchant, 'Lidl Magyarország');
    });

    test('refunds are income', () {
      final r = p('Zara', 'Visszatérítés: 5 000 Ft');
      expect(r.kind, FinKind.income);
      expect(r.amount, 5000);
      expect(r.merchant, 'Zara');
    });

    test('an unknown shop name stays empty instead of being invented', () {
      final r = p('Google Wallet', '3 490 Ft');
      expect(r.outcome, WalletOutcome.payment);
      expect(r.amount, 3490);
      expect(r.merchant, '');
    });

    test('card digits never end up in the merchant', () {
      final r = p('Google Wallet', 'Fizetés 2 000 Ft - Tesco ••••1234');
      expect(r.amount, 2000);
      expect(r.merchant.contains('1234'), isFalse);
      expect(r.merchant, 'Tesco');
    });
  });

  group('everything else', () {
    test('no amount: ignored', () {
      expect(
        p('Google Wallet', 'Új ajánlat érhető el a közeledben').outcome,
        WalletOutcome.ignored,
      );
      expect(p('', '').outcome, WalletOutcome.ignored);
      expect(
        p('Wallet', 'Add hozzá a kártyádat').outcome,
        WalletOutcome.ignored,
      );
    });

    test('other currencies are recognised but not booked', () {
      expect(p('Amazon', '12,99 EUR').outcome, WalletOutcome.foreignCurrency);
      expect(
        p('Shop', 'You paid \$12.99').outcome,
        WalletOutcome.foreignCurrency,
      );
      expect(p('Shop', '€ 5').outcome, WalletOutcome.foreignCurrency);
    });

    test('forint wins when both appear', () {
      final r = p('Booking', '12,99 EUR (5 200 Ft)');
      expect(r.outcome, WalletOutcome.payment);
      expect(r.amount, 5200);
    });

    test('long and hostile text stays bounded', () {
      final r = p('A' * 500, '3 490 Ft ${'x' * 1000}');
      expect(r.merchant.length, lessThanOrEqualTo(40));
      expect(
        p('<script>', '1 000 Ft').merchant.contains('<script>'),
        isTrue,
        reason: 'sanitising is done when it is shown or sent, not here',
      );
    });
  });

  group('masking and keys', () {
    test('card digits and long numbers are hidden', () {
      expect(maskSensitive('Mastercard •••• 1234'), contains('••••'));
      expect(maskSensitive('Mastercard •••• 1234').contains('1234'), isFalse);
      expect(maskSensitive('végződésű 5678 kártya').contains('5678'), isFalse);
      expect(maskSensitive('card 4321').contains('4321'), isFalse);
      expect(
        maskSensitive('szám 1234567890123456').contains('1234567890'),
        isFalse,
      );
    });

    test('grouped and compact card, account and phone numbers are hidden', () {
      for (final s in [
        '1234 5678 9012 3456',
        '1234-5678-9012-3456',
        'HU42 1177 3016 1111 1018 0000 0000',
        'HU42117730161111101800000000',
        '11773016-11111018-00000000',
        '+36 30 123 4567',
      ]) {
        final out = maskSensitive('szám: $s vége');
        expect(RegExp(r'\d{4}').hasMatch(out), isFalse, reason: '$s -> $out');
      }
    });

    test('the other usual wordings for the last four digits are hidden', () {
      for (final s in [
        'Kártya vége: 1234',
        'ending in 1234',
        'Visa …1234',
        'Visa ·1234',
        'Mastercard **1234',
      ]) {
        expect(maskSensitive(s).contains('1234'), isFalse, reason: s);
      }
    });

    test('big amounts and dates survive', () {
      expect(maskSensitive('12 345 678 Ft'), '12 345 678 Ft');
      expect(maskSensitive('1 234 567,89 Ft'), '1 234 567,89 Ft');
      expect(maskSensitive('2026-11-08 14:32'), '2026-11-08 14:32');
    });

    test('amounts survive the masking', () {
      expect(maskSensitive('Fizetés 3490 Ft'), 'Fizetés 3490 Ft');
      expect(maskSensitive('12 990 Ft'), '12 990 Ft');
    });

    test('merchant keys ignore case and punctuation', () {
      expect(merchantKey('SPAR Kft.'), merchantKey('spar  kft'));
      expect(merchantKey('Tesco'), isNot(merchantKey('Lidl')));
      expect(merchantKey(''), '');
    });
  });
}
