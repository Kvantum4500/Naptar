import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The words by which a column is known, from the most telling to the least:
/// a header made of each of them, and the order in which they win.
const _date = [
  'Tranzakció dátuma',
  'Tranzakció ideje',
  'Vásárlás dátuma',
  'Teljesítés',
  'Transaction Date',
  'Completed Date',
  'Booking Date',
  'Posting Date',
  'Könyvelés',
  'Dátum',
  'Date',
  'Értéknap',
];
const _amount = ['Tranzakció összege', 'Összeg', 'Amount', 'Forgalom', 'Sum'];
const _debit = [
  'Terhelés',
  'Debit',
  'Kiadás',
  'Money out',
  'Paid out',
  'Fizetett',
  'Kifizetés',
];
const _credit = [
  'Jóváírás',
  'Credit',
  'Bevétel',
  'Money in',
  'Paid in',
  'Befizetés',
];
const _currency = ['Pénznem', 'Devizanem', 'Deviza', 'Currency', 'Valuta'];
const _merchant = [
  'Partner neve',
  'Partner',
  'Kedvezményezett',
  'Fizető',
  'Payee',
  'Merchant',
  'Counterparty',
  'Vevő',
  'Eladó',
  'Üzlet',
  'Megnevezés',
  'Description',
  'Leírás',
  'Name',
  'Név',
];
const _note = [
  'Közlemény',
  'Megjegyzés',
  'Note',
  'Reference',
  'Referencia',
  'Info',
  'Description',
  'Leírás',
];
const _direction = [
  'Terhelés/Jóváírás',
  'Jóváírás/Terhelés',
  'Debit/Credit',
  'Típus',
  'Type',
  'Irány',
  'Jelleg',
];

/// Every pair: of two headers, the more telling is the one that is taken,
/// wherever it stands.
void _pairs(
  List<String> words,
  BankField field,
  BankMapping Function(List<String> header) guess, {
  List<String> before = const [],
  List<String> after = const [],
}) {
  for (var i = 0; i < words.length; i++) {
    for (var j = i + 1; j < words.length; j++) {
      test('"${words[i]}" before "${words[j]}"', () {
        final header = [...before, words[j], words[i], ...after];
        expect(
          guess(header)[field],
          before.length + 1,
          reason: header.join(' | '),
        );
        final turned = [...before, words[i], words[j], ...after];
        expect(guess(turned)[field], before.length, reason: turned.join(' | '));
      });
    }
  }
}

void main() {
  // (rows in which every cell is a date, an amount and a word at once is not
  // possible: each field is given the cells it wants)
  BankMapping dates(List<String> header) => guessMapping(header, [
    [for (final _ in header) '2026-11-13'],
  ]);
  BankMapping amounts(List<String> header) => guessMapping(header, [
    [for (final _ in header) '100'],
  ]);
  BankMapping words(List<String> header) => guessMapping(header, [
    [for (final _ in header) 'Spar'],
  ]);

  group('the date columns', () {
    for (final w in _date) {
      test('"$w" is a date', () {
        // (the first column holds dates, too: only the word tells which)
        expect(dates(['Zzz', w])[BankField.date], 1);
      });
    }
    _pairs(_date, BankField.date, dates);
  });

  group('the amount columns', () {
    for (final w in _amount) {
      test('"$w" is an amount', () {
        expect(amounts(['Zzz', w])[BankField.amount], 1);
      });
    }
    _pairs(_amount, BankField.amount, amounts);
  });

  group('money out and money in', () {
    for (final w in _debit) {
      test('"$w" is what went out', () {
        final m = words([w, 'Jóváírás']);
        expect(m[BankField.debit], 0);
        expect(m[BankField.credit], 1);
        expect(m.hasPair, isTrue);
      });
    }
    for (final w in _credit) {
      test('"$w" is what came in', () {
        final m = words(['Terhelés', w]);
        expect(m[BankField.debit], 0);
        expect(m[BankField.credit], 1);
      });
    }
    _pairs(_debit, BankField.debit, words, after: ['Jóváírás']);
    _pairs(_credit, BankField.credit, words, before: ['Terhelés']);
  });

  group('the currency columns', () {
    for (final w in _currency) {
      test('"$w" is a currency', () {
        expect(words([w])[BankField.currency], 0);
      });
    }
    _pairs(_currency, BankField.currency, words);
  });

  group('the merchant columns', () {
    for (final w in _merchant) {
      test('"$w" is a name', () {
        expect(words(['Zzz', w])[BankField.merchant], 1);
      });
    }
    _pairs(_merchant, BankField.merchant, words);
  });

  group('the note columns', () {
    for (final w in _note) {
      test('"$w" is a message', () {
        final m = words(['Partner neve', w]);
        expect(m[BankField.merchant], 0);
        expect(m[BankField.note], 1);
      });
    }
    _pairs(
      _note.where((w) => w != 'Description' && w != 'Leírás').toList(),
      BankField.note,
      words,
      before: ['Partner neve'],
    );
  });

  group('the direction columns', () {
    for (final w in _direction) {
      test('"$w" says which way the money went', () {
        final m = guessMapping(
          ['Dátum', 'Összeg', w],
          [
            ['2026-11-13', '4 500', 'Terhelés'],
            ['2026-11-14', '300 000', 'Jóváírás'],
          ],
        );
        expect(m[BankField.direction], 2);
        expect(m[BankField.amount], 1);
      });
    }
  });

  group('what is no name and no message', () {
    for (final w in [
      'Partner számlaszáma',
      'Partner számla száma',
      'Partner IBAN',
      'Partner BIC',
      'Partner SWIFT',
      'Partner azonosító',
    ]) {
      test('"$w"', () {
        expect(headerFields(w), isEmpty);
        // (with cells that are no words, the cells do not name it either)
        expect(amounts([w])[BankField.merchant], isNull);
      });
    }
    for (final w in [
      'Közlemény számlaszáma',
      'Közlemény IBAN',
      'Megjegyzés azonosító',
    ]) {
      test('"$w" is no message either', () {
        expect(headerFields(w), isEmpty);
      });
    }
    test('a date is a date whatever else the header says', () {
      expect(headerFields('Tranzakció azonosító és dátuma'), {BankField.date});
      expect(headerFields('Dátum IBAN'), {BankField.date});
    });

    test('but a plain name or message is one', () {
      expect(headerFields('Partner neve'), {BankField.merchant});
      expect(headerFields('Megjegyzés'), {BankField.note});
    });
  });
}
