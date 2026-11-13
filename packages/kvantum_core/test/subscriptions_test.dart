import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

int _n = 0;

FinTx tx(
  DateTime date,
  int amount, {
  String merchant = 'Netflix',
  FinKind kind = FinKind.expense,
  FinSource source = FinSource.wallet,
  String cat = 'cat-subs',
  bool deleted = false,
}) => FinTx(
  id: 't${_n++}',
  date: date,
  amount: amount,
  kind: kind,
  categoryId: cat,
  merchant: merchant,
  source: source,
  deleted: deleted,
);

/// [n] charges, [gap] days apart, the last one on [last].
List<FinTx> charges(
  int n,
  DateTime last, {
  int gap = 30,
  int amount = 4000,
  String merchant = 'Netflix',
}) => [
  for (var i = n - 1; i >= 0; i--)
    tx(last.subtract(Duration(days: gap * i)), amount, merchant: merchant),
];

void main() {
  final today = d(2026, 11, 18);

  group('the key of a merchant', () {
    test('lower case, no accents, only letters and digits', () {
      expect(subscriptionKey('Netflix.com'), 'netflix com');
      expect(subscriptionKey('  NETFLIX   COM '), 'netflix com');
      expect(subscriptionKey('Gyógyszertár'), 'gyogyszertar');
      expect(
        subscriptionKey('Árvíztűrő Tükörfúrógép'),
        'arvizturo tukorfurogep',
      );
    });

    test('a reference number on the statement line is not part of it', () {
      expect(subscriptionKey('SP * Spotify P3B1234'), 'sp spotify');
      expect(subscriptionKey('SP * Spotify X9Z7777'), 'sp spotify');
      expect(subscriptionKey('Tesco 1234'), 'tesco');
      expect(subscriptionKey('Tesco 1234'), subscriptionKey('Tesco 99'));
    });

    test('a word with a digit in it goes as a whole, not in pieces', () {
      expect(subscriptionKey('Netflix ab12cd'), 'netflix');
      expect(subscriptionKey('mol24 kut'), 'kut');
    });

    test('a single letter is not a word', () {
      expect(subscriptionKey('A Spotify'), 'spotify');
    });

    test('nothing left is an empty key', () {
      expect(subscriptionKey(''), '');
      expect(subscriptionKey('  '), '');
      expect(subscriptionKey('1234 5678'), '');
      expect(subscriptionKey('* - *'), '');
    });
  });

  group('a monthly subscription', () {
    test('three charges a month apart, the same amount', () {
      final s = detectSubscriptions(
        charges(3, d(2026, 11, 5)),
        today: today,
      ).single;
      expect(s.cadence, SubscriptionCadence.monthly);
      expect(s.name, 'Netflix');
      expect(s.key, 'netflix');
      expect(s.amount, 4000);
      expect(s.count, 3);
      expect(s.lastDate, d(2026, 11, 5));
      expect(s.nextDate, d(2026, 12, 5));
      expect(s.categoryId, 'cat-subs');
      expect(s.perMonth, 4000);
      expect(s.perYear, 48000);
    });

    test('one charge is no subscription, however fresh', () {
      expect(
        detectSubscriptions([tx(d(2026, 11, 5), 4000)], today: today),
        isEmpty,
      );
    });

    test('two charges are not enough for a month-to-month one', () {
      expect(
        detectSubscriptions(charges(2, d(2026, 11, 5)), today: today),
        isEmpty,
      );
    });

    test(
      'the next one is the same day of the next month, cut to its length',
      () {
        final s = detectSubscriptions([
          tx(d(2026, 9, 30), 100),
          tx(d(2026, 10, 31), 100),
          tx(d(2026, 11, 30), 100),
        ], today: d(2026, 12, 1)).single;
        expect(s.nextDate, d(2026, 12, 30));
        final feb = detectSubscriptions([
          tx(d(2025, 11, 30), 100),
          tx(d(2025, 12, 31), 100),
          tx(d(2026, 1, 31), 100),
        ], today: d(2026, 2, 5)).single;
        expect(feb.nextDate, d(2026, 2, 28));
        final leap = detectSubscriptions([
          tx(d(2023, 11, 30), 100),
          tx(d(2023, 12, 31), 100),
          tx(d(2024, 1, 31), 100),
        ], today: d(2024, 2, 5)).single;
        expect(leap.nextDate, d(2024, 2, 29));
      },
    );

    test('the next one is in the next year when the last is in December', () {
      final s = detectSubscriptions([
        tx(d(2026, 10, 15), 100),
        tx(d(2026, 11, 15), 100),
        tx(d(2026, 12, 15), 100),
      ], today: d(2026, 12, 20)).single;
      expect(s.nextDate, d(2027, 1, 15));
    });

    test('a charge may slide over a weekend: 24 to 38 days between them', () {
      for (final gap in [24, 38]) {
        expect(
          detectSubscriptions(
            charges(3, d(2026, 11, 5), gap: gap),
            today: today,
          ),
          hasLength(1),
          reason: '$gap',
        );
      }
      for (final gap in [23, 39]) {
        expect(
          detectSubscriptions(
            charges(3, d(2026, 11, 5), gap: gap),
            today: today,
          ),
          isEmpty,
          reason: '$gap',
        );
      }
    });

    test('one gap out of line spoils it', () {
      final txs = [
        tx(d(2026, 8, 5), 100),
        tx(d(2026, 9, 5), 100),
        tx(d(2026, 10, 25), 100), // 50 days
        tx(d(2026, 11, 25), 100),
      ];
      expect(detectSubscriptions(txs, today: d(2026, 11, 28)), isEmpty);
    });

    test('a shop that is visited every week is not a subscription', () {
      expect(
        detectSubscriptions(charges(6, d(2026, 11, 14), gap: 7), today: today),
        isEmpty,
      );
    });

    test('every charge on a different day of the month, but a month apart', () {
      final s = detectSubscriptions([
        tx(d(2026, 8, 3), 5000),
        tx(d(2026, 9, 5), 5000),
        tx(d(2026, 10, 2), 5000),
        tx(d(2026, 11, 4), 5000),
      ], today: today).single;
      expect(s.count, 4);
    });
  });

  group('the amount', () {
    test('a price rise is still the same subscription, and the latest price counts', () {
      final s = detectSubscriptions([
        tx(d(2026, 9, 5), 3000),
        tx(d(2026, 10, 5), 3000),
        tx(d(2026, 11, 5), 3400),
      ], today: today).single;
      expect(s.amount, 3400);
    });

    test('the dearest may be a quarter more than the cheapest, not more', () {
      List<FinTx> with_(int high) => [
        tx(d(2026, 9, 5), 8000),
        tx(d(2026, 10, 5), 8000),
        tx(d(2026, 11, 5), high),
      ];
      expect(detectSubscriptions(with_(10000), today: today), hasLength(1));
      expect(detectSubscriptions(with_(10001), today: today), isEmpty);
    });

    test('a bill that jumps around is not a subscription', () {
      expect(
        detectSubscriptions([
          tx(d(2026, 9, 5), 8000, merchant: 'MVM'),
          tx(d(2026, 10, 5), 21000, merchant: 'MVM'),
          tx(d(2026, 11, 5), 5000, merchant: 'MVM'),
        ], today: today),
        isEmpty,
      );
    });
  });

  group('a yearly subscription', () {
    test('two charges a year apart', () {
      final s = detectSubscriptions([
        tx(d(2025, 6, 10), 24000, merchant: 'Domain'),
        tx(d(2026, 6, 10), 24000, merchant: 'Domain'),
      ], today: today).single;
      expect(s.cadence, SubscriptionCadence.yearly);
      expect(s.perMonth, 2000);
      expect(s.perYear, 24000);
      expect(s.nextDate, d(2027, 6, 10));
    });

    test('a year is 350 to 380 days', () {
      for (final gap in [350, 380]) {
        final txs = [
          tx(
            d(2026, 6, 10).subtract(Duration(days: gap)),
            100,
            merchant: 'Domain',
          ),
          tx(d(2026, 6, 10), 100, merchant: 'Domain'),
        ];
        expect(
          detectSubscriptions(txs, today: today),
          hasLength(1),
          reason: '$gap',
        );
      }
      for (final gap in [349, 381]) {
        final txs = [
          tx(
            d(2026, 6, 10).subtract(Duration(days: gap)),
            100,
            merchant: 'Domain',
          ),
          tx(d(2026, 6, 10), 100, merchant: 'Domain'),
        ];
        expect(detectSubscriptions(txs, today: today), isEmpty, reason: '$gap');
      }
    });

    test('the cost per month is rounded', () {
      final s = detectSubscriptions([
        tx(d(2025, 6, 10), 10000, merchant: 'Domain'),
        tx(d(2026, 6, 10), 10000, merchant: 'Domain'),
      ], today: today).single;
      expect(s.perMonth, 833);
      // (halves and more are rounded up, not cut)
      final t = detectSubscriptions([
        tx(d(2025, 6, 10), 7999, merchant: 'Domain'),
        tx(d(2026, 6, 10), 7999, merchant: 'Domain'),
      ], today: today).single;
      expect(t.perMonth, 667); // 666,58
      expect(t.perYear, 7999);
    });

    test(
      'a yearly one that missed its year by more than a month has stopped',
      () {
        final txs = [
          tx(d(2024, 9, 1), 100, merchant: 'Domain'),
          tx(d(2025, 9, 1), 100, merchant: 'Domain'),
        ];
        expect(
          detectSubscriptions(txs, today: d(2026, 10, 6)),
          hasLength(1),
        ); // 400 days
        expect(detectSubscriptions(txs, today: d(2026, 10, 7)), isEmpty); // 401
      },
    );
  });

  group('still going on', () {
    test('a monthly one that was not charged for 45 days is a late one, after that it has stopped', () {
      final txs = charges(
        4,
        d(2026, 10, 4),
      ); // the last is 45 days before 11-18
      expect(detectSubscriptions(txs, today: d(2026, 11, 18)), hasLength(1));
      expect(detectSubscriptions(txs, today: d(2026, 11, 19)), isEmpty);
    });

    test('today with the time of day counts as the day', () {
      final txs = charges(4, d(2026, 10, 4));
      expect(
        detectSubscriptions(txs, today: floating(2026, 11, 18, 23, 59)),
        hasLength(1),
      );
    });
  });

  group('what is left out', () {
    test('income', () {
      final txs = [
        for (final t in charges(4, d(2026, 11, 5)))
          tx(t.date, t.amount, kind: FinKind.income),
      ];
      expect(detectSubscriptions(txs, today: today), isEmpty);
    });

    test(
      'a deleted charge, and the others still count when there are enough',
      () {
        final txs = [
          ...charges(4, d(2026, 11, 5)),
          tx(d(2026, 11, 6), 4000, deleted: true),
        ];
        final s = detectSubscriptions(txs, today: today).single;
        expect(s.count, 4);
        expect(s.lastDate, d(2026, 11, 5));
        // without the deleted one only two are left
        expect(
          detectSubscriptions([
            tx(d(2026, 10, 5), 100),
            tx(d(2026, 11, 5), 100),
            tx(d(2026, 9, 5), 100, deleted: true),
          ], today: today),
          isEmpty,
        );
      },
    );

    test('what a recurring rule made: it is known already', () {
      final txs = [
        for (final t in charges(4, d(2026, 11, 5)))
          tx(t.date, t.amount, source: FinSource.recurring),
      ];
      expect(detectSubscriptions(txs, today: today), isEmpty);
    });

    test('a charge by hand and one by the Wallet are read alike', () {
      final txs = [
        tx(d(2026, 9, 5), 4000, source: FinSource.manual),
        tx(d(2026, 10, 5), 4000, source: FinSource.wallet),
        tx(d(2026, 11, 5), 4000, source: FinSource.manual),
      ];
      expect(detectSubscriptions(txs, today: today), hasLength(1));
    });

    test('a charge without a merchant', () {
      expect(
        detectSubscriptions(
          charges(4, d(2026, 11, 5), merchant: ''),
          today: today,
        ),
        isEmpty,
      );
      expect(
        detectSubscriptions(
          charges(4, d(2026, 11, 5), merchant: '1234'),
          today: today,
        ),
        isEmpty,
      );
    });

    test('a merchant that is known', () {
      final txs = charges(4, d(2026, 11, 5));
      expect(
        detectSubscriptions(txs, today: today, known: {'netflix'}),
        isEmpty,
      );
      expect(
        detectSubscriptions(txs, today: today, known: {'spotify'}),
        hasLength(1),
      );
    });
  });

  group('several of them', () {
    test('the dearest per month first, a tie by the key', () {
      final txs = [
        ...charges(3, d(2026, 11, 5), amount: 2000, merchant: 'Spotify'),
        ...charges(3, d(2026, 11, 6), amount: 5000, merchant: 'Gym'),
        ...charges(3, d(2026, 11, 7), amount: 2000, merchant: 'Apple'),
        ...[
          tx(d(2025, 6, 10), 60000, merchant: 'Domain'),
          tx(d(2026, 6, 10), 60000, merchant: 'Domain'),
        ],
      ];
      final s = detectSubscriptions(txs, today: today);
      // 5000 a month, then 2000 and 2000 (a tie), then the yearly one at 5000 / 12
      expect(s.map((e) => e.key), ['domain', 'gym', 'apple', 'spotify']);
      expect(s.map((e) => e.perMonth), [5000, 5000, 2000, 2000]);
    });

    test(
      'spellings that differ only by a reference number are one merchant',
      () {
        final txs = [
          tx(d(2026, 9, 5), 2000, merchant: 'SP * Spotify P3B1111'),
          tx(d(2026, 10, 5), 2000, merchant: 'SP * Spotify P3B2222'),
          tx(d(2026, 11, 5), 2000, merchant: 'SP * Spotify P3B3333'),
        ];
        final s = detectSubscriptions(txs, today: today).single;
        expect(s.count, 3);
        // the name is the latest one, as written
        expect(s.name, 'SP * Spotify P3B3333');
      },
    );

    test(
      'the name, the price and the category are those of the latest charge',
      () {
        final s = detectSubscriptions([
          tx(d(2026, 9, 5), 4000, merchant: 'NETFLIX', cat: 'cat-fun'),
          tx(d(2026, 10, 5), 4000, merchant: 'Netflix', cat: 'cat-fun'),
          tx(d(2026, 11, 5), 4200, merchant: 'netflix', cat: 'cat-subs'),
        ], today: today).single;
        expect(s.name, 'netflix');
        expect(s.amount, 4200);
        expect(s.categoryId, 'cat-subs');
        expect(s.lastDate, d(2026, 11, 5));
        expect(s.count, 3);
      },
    );

    test('the order of the input does not matter', () {
      final txs = charges(4, d(2026, 11, 5));
      expect(
        detectSubscriptions(txs.reversed, today: today).single.lastDate,
        detectSubscriptions(txs, today: today).single.lastDate,
      );
    });
  });
}
