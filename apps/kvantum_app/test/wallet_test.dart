import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/finance/wallet_ingest.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';

void main() {
  late AppDatabase db;
  late FinanceRepository repo;
  late FakeWallet bridge;
  late WalletIngest ingest;

  // 2026-11-08 12:00 local time
  final t0 = DateTime(2026, 11, 8, 12).millisecondsSinceEpoch;

  setUp(() async {
    db = await newDb();
    repo = FinanceRepository(db, clock: () => 5000);
    await repo.ensureDefaults();
    bridge = FakeWallet();
    ingest = WalletIngest(repo, bridge);
  });
  tearDown(() => db.close());

  test(
    'a payment becomes an expense of that day, marked as from Wallet',
    () async {
      bridge.queue.add(note('SPAR', '3 490 Ft · Mastercard •••• 1234', t0));
      final r = await ingest.run();
      expect(r.booked, 1);
      final t = (await repo.txs()).single;
      expect(t.amount, 3490);
      expect(t.kind, FinKind.expense);
      expect(t.merchant, 'SPAR');
      expect(t.source, FinSource.wallet);
      expect(t.date, floating(2026, 11, 8));
      expect(t.categoryId, kUncategorized);
    },
  );

  test('the same notification is never booked twice', () async {
    bridge.queue.add(note('SPAR', '3 490 Ft', t0));
    await ingest.run();
    bridge.queue.add(note('SPAR', '3 490 Ft', t0)); // posted again
    final r = await ingest.run();
    expect(r.booked, 0);
    expect((await repo.txs()).length, 1);
    // but a real second purchase (other time) is a second item
    bridge.queue.add(note('SPAR', '3 490 Ft', t0 + 60000));
    await ingest.run();
    expect((await repo.txs()).length, 2);
  });

  test(
    'a deleted item stays deleted when the same notification shows up again',
    () async {
      bridge.queue.add(note('SPAR', '3 490 Ft', t0));
      await ingest.run();
      await repo.deleteTx((await repo.txs()).single.id);
      bridge.queue.add(note('SPAR', '3 490 Ft', t0));
      await ingest.run();
      expect(await repo.txs(), isEmpty);
    },
  );

  test('offers and foreign-currency payments are not booked', () async {
    bridge.queue
      ..add(note('Google Wallet', 'Új ajánlat érhető el', t0))
      ..add(note('Amazon', '12,99 EUR', t0 + 1))
      ..add(note('MOL', '15 000 Ft', t0 + 2));
    final r = await ingest.run();
    expect((r.booked, r.ignored, r.foreign), (1, 1, 1));
    expect((await repo.txs()).single.merchant, 'MOL');
  });

  test('a refund is booked as income', () async {
    bridge.queue.add(note('Zara', 'Visszatérítés: 5 000 Ft', t0));
    await ingest.run();
    expect((await repo.txs()).single.kind, FinKind.income);
  });

  test('the category the user gave a merchant is used next time', () async {
    bridge.queue.add(note('SPAR', '1 000 Ft', t0));
    await ingest.run();
    final first = (await repo.txs()).single;
    expect(first.categoryId, kUncategorized);
    // the user files it; the merchant is remembered
    await repo.saveTx(first.copyWith(categoryId: 'cat-food'));
    await repo.rememberMerchant('SPAR', 'cat-food');
    bridge.queue.add(note('Spar', '2 000 Ft', t0 + 5000));
    await ingest.run();
    final all = await repo.txs();
    expect(all.firstWhere((t) => t.amount == 2000).categoryId, 'cat-food');
  });

  test(
    'remembering a merchant also files its other uncategorized items',
    () async {
      bridge.queue
        ..add(note('Tesco', '1 000 Ft', t0))
        ..add(note('Tesco', '2 000 Ft', t0 + 1))
        ..add(note('Lidl', '3 000 Ft', t0 + 2));
      await ingest.run();
      final n = await repo.rememberMerchant('TESCO', 'cat-food');
      expect(n, 2);
      final byMerchant = {
        for (final t in await repo.txs())
          '${t.merchant}${t.amount}': t.categoryId,
      };
      expect(byMerchant['Tesco1000'], 'cat-food');
      expect(byMerchant['Tesco2000'], 'cat-food');
      expect(byMerchant['Lidl3000'], kUncategorized);
    },
  );

  test('a remembered category that was deleted is forgotten', () async {
    await repo.saveCategory(
      const FinCategory(id: 'cat-own', name: 'Étterem', kind: FinKind.expense),
    );
    await repo.rememberMerchant('Pizzéria', 'cat-own');
    expect(await repo.merchantCategory('pizzéria'), 'cat-own');
    await repo.deleteCategory('cat-own');
    expect(await repo.merchantCategory('Pizzéria'), isNull);
  });

  test('no merchant, no memory: nothing to look up', () async {
    expect(await repo.merchantCategory(''), isNull);
    expect(await repo.rememberMerchant('', 'cat-food'), 0);
    expect(await repo.rememberMerchant('SPAR', kUncategorized), 0);
  });

  test('switched off: the queue is left alone and nothing is booked', () async {
    await ingest.setAuto(false);
    bridge.queue.add(note('SPAR', '3 490 Ft', t0));
    final r = await ingest.run();
    expect(r.seen, 0);
    expect(bridge.drains, 0);
    expect(bridge.queue.length, 1);
    await ingest.setAuto(true);
    expect((await ingest.run()).booked, 1);
  });

  test('on a platform without Wallet access nothing happens', () async {
    final w = FakeWallet(supported: false)
      ..queue.add(note('SPAR', '3 490 Ft', t0));
    final r = await WalletIngest(repo, w).run();
    expect(r.seen, 0);
    expect(w.drains, 0);
  });

  test('the log is masked, ordered and capped', () async {
    bridge.queue.add(note('SPAR', 'Mastercard •••• 1234 · 3 490 Ft', t0));
    await ingest.run();
    final l = (await ingest.log()).single;
    expect(l.text.contains('1234'), isFalse);
    expect(l.result, 'booked');
    expect(l.amount, 3490);

    for (var i = 0; i < 30; i++) {
      bridge.queue.add(note('Shop$i', '${100 + i} Ft', t0 + 10 + i));
    }
    await ingest.run();
    final log = await ingest.log();
    expect(log.length, 20);
    expect(log.last.title, 'Shop29');
  });

  test('empty queue is a quiet no-op; ids are stable', () async {
    expect((await ingest.run()).seen, 0);
    final a = WalletIngest.idFor(note('X', 'y', 1));
    expect(a, WalletIngest.idFor(note('X', 'y', 1)));
    expect(a, isNot(WalletIngest.idFor(note('X', 'y', 2))));
    expect(a, startsWith('wal-'));
  });
}
