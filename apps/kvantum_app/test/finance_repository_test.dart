import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  late AppDatabase db;
  late FinanceRepository repo;
  var t = 1000;

  setUp(() async {
    db = await newDb();
    t = 1000;
    repo = FinanceRepository(db, clock: () => t++);
  });
  tearDown(() => db.close());

  FinTx tx(String id, int amount, {String cat = 'cat-food', int day = 5}) =>
      FinTx(
        id: id,
        date: floating(2026, 11, day),
        amount: amount,
        kind: FinKind.expense,
        categoryId: cat,
      );

  group('the rate of a currency', () {
    test('the one last used is remembered for each currency', () async {
      expect(await repo.lastRate('EUR'), isNull);
      await repo.rememberRate('EUR', 399.5);
      await repo.rememberRate('USD', 380);
      expect(await repo.lastRate('EUR'), 399.5);
      expect(await repo.lastRate('USD'), 380.0);
      expect(await repo.lastRate('GBP'), isNull);
      await repo.rememberRate('EUR', 401.2345);
      expect(await repo.lastRate('EUR'), 401.2345);
      expect(await repo.lastRate('USD'), 380.0);
    });

    test('a rate with three decimals comes back as it was', () async {
      // ("2,512" must not be read as 2512: a rate has decimals of its own)
      await repo.rememberRate('JPY', 2.512);
      expect(await repo.lastRate('JPY'), 2.512);
      await repo.rememberRate('EUR', 399.123);
      expect(await repo.lastRate('EUR'), 399.123);
    });

    test('it stays on this device: nothing is mailed for it', () async {
      await repo.rememberRate('EUR', 399.5);
      expect(await repo.dirtyCount(), 0);
    });

    test('a damaged value is no rate', () async {
      await repo.setMeta('fin.rate.EUR', 'abc');
      expect(await repo.lastRate('EUR'), isNull);
      await repo.setMeta('fin.rate.EUR', '-5');
      expect(await repo.lastRate('EUR'), isNull);
    });
  });

  group('a bank file', () {
    FinTx imported(String id, int amount, {String merchant = 'Spar'}) => FinTx(
      id: id,
      date: floating(2026, 11, 13),
      amount: amount,
      kind: FinKind.expense,
      categoryId: 'cat-food',
      merchant: merchant,
      source: FinSource.imported,
    );

    test(
      'every id there is, deleted ones too, and only those of entries',
      () async {
        await repo.ensureDefaults();
        await repo.saveTx(tx('a', 100));
        await repo.saveTx(tx('b', 200));
        await repo.deleteTx('b');
        expect(await repo.allTxIds(), {'a', 'b'});
        expect(await repo.allTxIds(), isNot(contains('cat-food')));
      },
    );

    test('an import is written in one go, with a mark for each row', () async {
      final marks = await repo.addImported([
        imported('imp-1', 100),
        imported('imp-2', 200),
      ]);
      expect(marks.map((m) => m.id), ['imp-1', 'imp-2']);
      // (the stamps are the store's own, in order, as for any entry)
      expect(marks.map((m) => m.updatedAt), [1000, 1001]);
      final all = await repo.txs();
      expect(all.map((x) => x.id).toSet(), {'imp-1', 'imp-2'});
      expect(all.every((x) => x.source == FinSource.imported), isTrue);
      for (final m in marks) {
        expect(all.firstWhere((x) => x.id == m.id).updatedAt, m.updatedAt);
      }
      // (it travels to the other devices like any entry)
      expect(await repo.dirtyCount(), 2);
    });

    test(
      'what is in the books already is left alone, deleted or not',
      () async {
        await repo.saveTx(tx('imp-1', 999));
        await repo.saveTx(tx('imp-2', 999));
        await repo.deleteTx('imp-2');
        final marks = await repo.addImported([
          imported('imp-1', 1),
          imported('imp-2', 2),
          imported('imp-3', 3),
          imported('imp-3', 4),
        ]);
        expect(marks.map((m) => m.id), ['imp-3']);
        final all = await repo.txs();
        expect(all.firstWhere((x) => x.id == 'imp-1').amount, 999);
        expect(all.firstWhere((x) => x.id == 'imp-3').amount, 3);
        expect(all.any((x) => x.id == 'imp-2'), isFalse);
      },
    );

    test('one sync is asked for, not one for every row', () async {
      var asked = 0;
      final counted = FinanceRepository(
        db,
        clock: () => t++,
        onChanged: () => asked++,
      );
      await counted.addImported([
        imported('imp-1', 1),
        imported('imp-2', 2),
        imported('imp-3', 3),
      ]);
      expect(asked, 1);
      await counted.addImported([imported('imp-1', 1)]);
      expect(asked, 1);
      await counted.addImported(const []);
      expect(asked, 1);
    });

    test('an import is taken back, all of it', () async {
      final marks = await repo.addImported([
        imported('imp-1', 100),
        imported('imp-2', 200),
      ]);
      expect(await repo.undoImport(marks), isTrue);
      expect(await repo.txs(), isEmpty);
      // (the marks of the deletion stay, so the other devices learn of it: it
      // is a newer stamp than the import had, or they would not take it)
      expect(await repo.allTxIds(), {'imp-1', 'imp-2'});
      expect(await repo.dirtyCount(), 2);
      for (final m in marks) {
        final row = await (db.select(
          db.finRows,
        )..where((r) => r.id.equals(m.id))).getSingle();
        expect(row.deleted, isTrue);
        expect(row.updatedAt, greaterThan(m.updatedAt));
      }
      // (and the same rows do not come back by importing them again)
      expect(await repo.addImported([imported('imp-1', 100)]), isEmpty);
      expect(await repo.txs(), isEmpty);
    });

    test('...only while every row is as the import left it', () async {
      final marks = await repo.addImported([
        imported('imp-1', 100),
        imported('imp-2', 200),
        imported('imp-3', 300),
      ]);
      final edited = (await repo.txs()).firstWhere((x) => x.id == 'imp-2');
      await repo.saveTx(edited.copyWith(note: 'átírva'));
      expect(await repo.undoImport(marks), isFalse);
      expect(await repo.txs(), hasLength(3));
    });

    test('an undo asks for one sync, a refused one for none', () async {
      var asked = 0;
      final counted = FinanceRepository(
        db,
        clock: () => t++,
        onChanged: () => asked++,
      );
      final marks = await counted.addImported([
        imported('imp-1', 100),
        imported('imp-2', 200),
      ]);
      expect(asked, 1);
      expect(await counted.undoImport(marks), isTrue);
      expect(asked, 2);
      expect(await counted.undoImport(marks), isFalse);
      expect(await counted.undoImport(const []), isFalse);
      expect(asked, 2);
    });

    test('...and not twice, and not what is not there', () async {
      expect(await repo.undoImport(const []), isFalse);
      expect(await repo.undoImport([const ImportMark('zz', 1)]), isFalse);
      final marks = await repo.addImported([imported('imp-1', 100)]);
      expect(await repo.undoImport(marks), isTrue);
      expect(await repo.undoImport(marks), isFalse);
    });

    test('the categories remembered for merchants', () async {
      await repo.ensureDefaults();
      await repo.rememberMerchant('Spar Kft.', 'cat-food');
      final m = await repo.merchantCategories([
        'Spar Kft.',
        'SPAR kft',
        'Lidl',
        '',
      ]);
      expect(m, {'Spar Kft.': 'cat-food', 'SPAR kft': 'cat-food'});
      // (one that has been deleted is not offered)
      await repo.setMeta('fin.merchantCat', jsonEncode({'lidl': 'cat-gone'}));
      expect(await repo.merchantCategories(['Lidl']), isEmpty);
    });

    test(
      'the columns chosen for a file are found again by its header',
      () async {
        final header = ['Dátum', 'Partner', 'Összeg'];
        final chosen = BankMapping(
          columns: {
            BankField.date: 0,
            BankField.merchant: 1,
            BankField.amount: 2,
          },
          invertSign: true,
          dateOrder: DateOrder.ymd,
        );
        expect(await repo.bankMapping(header), isNull);
        await repo.rememberBankMapping(header, chosen);
        final back = (await repo.bankMapping(header))!;
        expect(back.columns, chosen.columns);
        expect(back.invertSign, isTrue);
        expect(back.dateOrder, DateOrder.ymd);
        // (spaces and capitals in the words do not make another file)
        expect(
          await repo.bankMapping([' dátum', 'PARTNER', 'összeg ']),
          isNotNull,
        );
        // (another file is another file)
        expect(await repo.bankMapping(['Dátum', 'Összeg']), isNull);
        expect(await repo.bankMapping(['Összeg', 'Partner', 'Dátum']), isNull);
        // (and it stays on this device)
        expect(await repo.dirtyCount(), 0);
      },
    );

    test('a damaged memory of columns is none', () async {
      final header = ['Dátum', 'Összeg'];
      final key = 'fin.bank.${fingerprint(headerSignature(header))}';
      await repo.setMeta(key, '{"date": 9}');
      expect(await repo.bankMapping(header), isNull);
      await repo.setMeta(key, 'nem json');
      expect(await repo.bankMapping(header), isNull);
      await repo.setMeta(key, '{"date": 0, "amount": 1}');
      expect(await repo.bankMapping(header), isNotNull);
    });

    test('a file without a header is not remembered', () async {
      await repo.rememberBankMapping(
        const [],
        BankMapping(columns: {BankField.date: 0, BankField.amount: 1}),
      );
      expect(await repo.bankMapping(const []), isNull);
      expect(await repo.meta('fin.bank.${fingerprint('')}'), isNull);
      // (and what might be there is not read for a file without a header)
      await repo.setMeta(
        'fin.bank.${fingerprint(headerSignature(const []))}',
        '{"date": 0, "amount": 1}',
      );
      expect(await repo.bankMapping(const []), isNull);
    });
  });

  group('categories', () {
    test('defaults are created once and need no mailing', () async {
      await repo.ensureDefaults();
      await repo.ensureDefaults();
      final cats = await repo.categories();
      expect(cats.length, defaultCategories().length);
      final rows = await db.select(db.finRows).get();
      expect(rows.every((r) => !r.dirty), isTrue);
    });

    test('a category in use cannot be deleted, a free one can', () async {
      await repo.ensureDefaults();
      await repo.saveTx(tx('a', 500));
      expect(await repo.deleteCategory('cat-food'), isNull);
      expect((await repo.categories()).any((c) => c.id == 'cat-food'), isTrue);
      await repo.saveBudget(
        const FinBudget(categoryId: 'cat-fun', limit: 1000),
      );
      expect(await repo.deleteCategory('cat-fun'), isNotNull);
      expect((await repo.categories()).any((c) => c.id == 'cat-fun'), isFalse);
      expect(await repo.budgets(), isEmpty); // its budget goes with it
    });

    test('renaming bumps the timestamp and marks it dirty', () async {
      await repo.ensureDefaults();
      final c = (await repo.categories()).firstWhere((x) => x.id == 'cat-food');
      await repo.saveCategory(c.copyWith(name: 'Bevásárlás'));
      final back = (await repo.categories()).firstWhere(
        (x) => x.id == 'cat-food',
      );
      expect(back.name, 'Bevásárlás');
      expect(back.updatedAt, greaterThan(0));
      final row = await (db.select(
        db.finRows,
      )..where((r) => r.id.equals('cat-food'))).getSingle();
      expect(row.dirty, isTrue);
    });
  });

  group('transactions', () {
    test(
      'save, update and read back; the timestamp is set by the store',
      () async {
        await repo.saveTx(tx('a', 500));
        final first = (await repo.txs()).single;
        expect(first.updatedAt, 1000);
        await repo.saveTx(first.copyWith(amount: 700));
        final second = (await repo.txs()).single;
        expect(second.amount, 700);
        expect(second.updatedAt, greaterThan(first.updatedAt));
      },
    );

    test(
      'deleting leaves a tombstone that is hidden but stored and dirty',
      () async {
        await repo.saveTx(tx('a', 500));
        await repo.deleteTx('a');
        expect(await repo.txs(), isEmpty);
        final row = await (db.select(
          db.finRows,
        )..where((r) => r.id.equals('a'))).getSingle();
        expect(row.deleted, isTrue);
        expect(row.dirty, isTrue);
        await repo.deleteTx('nincs-ilyen'); // no crash
      },
    );

    test('the stream follows changes', () async {
      final seen = <int>[];
      final sub = repo.watchTx().listen((l) => seen.add(l.length));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repo.saveTx(tx('a', 500));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repo.deleteTx('a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(seen, containsAllInOrder([0, 1, 0]));
    });
  });

  group('recurring', () {
    FinRecurring rule() => FinRecurring(
      id: 'r1',
      title: 'Bérleti díj',
      amount: 120000,
      kind: FinKind.expense,
      categoryId: 'cat-housing',
      dayOfMonth: 5,
      fromMonth: floating(2026, 1, 1),
    );

    test(
      'creates the month once, with a fixed id, and needs no mailing',
      () async {
        await repo.saveRecurring(rule());
        expect(await repo.ensureRecurring(2026, 11), 1);
        expect(await repo.ensureRecurring(2026, 11), 0);
        final tx1 = (await repo.txs()).single;
        expect(tx1.id, 'rec-r1-202611');
        expect(tx1.source, FinSource.recurring);
        final row = await (db.select(
          db.finRows,
        )..where((r) => r.id.equals('rec-r1-202611'))).getSingle();
        expect(row.dirty, isFalse);
      },
    );

    test('a deleted generated item is not brought back', () async {
      await repo.saveRecurring(rule());
      await repo.ensureRecurring(2026, 11);
      await repo.deleteTx('rec-r1-202611');
      expect(await repo.ensureRecurring(2026, 11), 0);
      expect(await repo.txs(), isEmpty);
    });

    test('an edited generated item keeps the edit', () async {
      await repo.saveRecurring(rule());
      await repo.ensureRecurring(2026, 11);
      final g = (await repo.txs()).single;
      await repo.saveTx(g.copyWith(amount: 130000));
      await repo.ensureRecurring(2026, 11);
      expect((await repo.txs()).single.amount, 130000);
    });

    test('a later month creates a new item', () async {
      await repo.saveRecurring(rule());
      await repo.ensureRecurring(2026, 11);
      await repo.ensureRecurring(2026, 12);
      expect((await repo.txs()).map((x) => x.id).toSet(), {
        'rec-r1-202611',
        'rec-r1-202612',
      });
    });
  });

  group('goals', () {
    test('deleting a goal removes its deposits too', () async {
      await repo.saveGoal(
        const FinGoal(id: 'g', name: 'Nyaralás', target: 500000),
      );
      await repo.saveDeposit(
        FinDeposit(
          id: 'd1',
          goalId: 'g',
          date: floating(2026, 11, 1),
          amount: 1000,
        ),
      );
      await repo.saveDeposit(
        FinDeposit(
          id: 'd2',
          goalId: 'x',
          date: floating(2026, 11, 1),
          amount: 2000,
        ),
      );
      await repo.deleteGoal('g');
      expect(await repo.goals(), isEmpty);
      expect((await repo.deposits()).map((d) => d.id), ['d2']);
    });
  });

  group('taking a deletion back', () {
    test(
      'a transaction comes back with a newer stamp and is mailed again',
      () async {
        await repo.ensureDefaults();
        await repo.saveTx(tx('a', 500));
        final deleted = await repo.deleteTx('a');
        expect(deleted.single.kind, 'tx');
        expect(await repo.txs(), isEmpty);
        final mark = deleted.single.updatedAt;

        expect(await repo.undelete(deleted), isTrue);
        final back = (await repo.txs()).single;
        expect((back.id, back.amount, back.deleted), ('a', 500, false));
        expect(back.updatedAt, greaterThan(mark), reason: 'wins over the mark');
        final row = await (db.select(
          db.finRows,
        )..where((r) => r.id.equals('a'))).getSingle();
        expect(row.dirty, isTrue, reason: 'other devices must hear about it');
      },
    );

    test('deleting what is not there gives nothing to take back', () async {
      expect(await repo.deleteTx('nincs-ilyen'), isEmpty);
      expect(await repo.undelete(const []), isFalse);
    });

    test('only while the record still is exactly that deletion mark', () async {
      await repo.saveTx(tx('a', 500));
      final deleted = await repo.deleteTx('a');
      // somebody (another device, an edit) wrote the record again meanwhile:
      // still deleted, but with a newer stamp
      await repo.saveTx(tx('a', 999).copyWith(deleted: true));
      expect(await repo.undelete(deleted), isFalse);
      expect(await repo.txs(), isEmpty, reason: 'nothing was put back');
    });

    test('a purged deletion mark cannot be taken back', () async {
      await repo.saveTx(tx('a', 500));
      final deleted = await repo.deleteTx('a');
      await repo.purgeTombstones(1 << 40);
      expect(await repo.undelete(deleted), isFalse);
      expect(await repo.txs(), isEmpty);
    });

    test('a transaction whose category went meanwhile comes back as '
        '"Besorolatlan"', () async {
      await repo.ensureDefaults();
      await repo.saveCategory(
        const FinCategory(id: 'cat-x', name: 'Új', kind: FinKind.expense),
      );
      await repo.saveTx(tx('a', 500, cat: 'cat-x'));
      final deletedTx = await repo.deleteTx('a');
      expect(await repo.deleteCategory('cat-x'), isNotNull); // now unused
      expect(await repo.undelete(deletedTx), isTrue);
      expect((await repo.txs()).single.categoryId, kUncategorized);
    });

    test('a category goes back together with its budget', () async {
      await repo.ensureDefaults();
      await repo.saveBudget(
        const FinBudget(categoryId: 'cat-fun', limit: 1000),
      );
      final deleted = (await repo.deleteCategory('cat-fun'))!;
      expect(deleted.map((d) => d.kind).toSet(), {'category', 'budget'});
      expect(await repo.undelete(deleted), isTrue);
      expect((await repo.categories()).any((c) => c.id == 'cat-fun'), isTrue);
      expect((await repo.budgets()).single.limit, 1000);
    });

    test(
      'all or nothing: one record changed meanwhile stops the whole undo',
      () async {
        await repo.ensureDefaults();
        await repo.saveBudget(
          const FinBudget(categoryId: 'cat-fun', limit: 1000),
        );
        final deleted = (await repo.deleteCategory('cat-fun'))!;
        // the budget (only) is written again by somebody else
        await repo.saveBudget(
          const FinBudget(categoryId: 'cat-fun', limit: 7000, deleted: true),
        );
        expect(await repo.undelete(deleted), isFalse);
        expect(
          (await repo.categories()).any((c) => c.id == 'cat-fun'),
          isFalse,
          reason: 'the category was NOT put back alone',
        );
      },
    );

    test('a goal goes back together with the deposits it took along', () async {
      await repo.saveGoal(
        const FinGoal(id: 'g', name: 'Nyaralás', target: 100000),
      );
      for (final id in ['d1', 'd2']) {
        await repo.saveDeposit(
          FinDeposit(
            id: id,
            goalId: 'g',
            date: floating(2026, 11, 1),
            amount: 1000,
          ),
        );
      }
      // a deposit deleted earlier must NOT come back with the goal
      await repo.deleteDeposit('d1');
      final deleted = await repo.deleteGoal('g');
      expect(deleted.map((d) => d.id).toSet(), {'g', 'd2'});
      expect(await repo.undelete(deleted), isTrue);
      expect((await repo.goals()).single.id, 'g');
      expect((await repo.deposits()).map((d) => d.id), ['d2']);
    });

    test('a recurring rule comes back', () async {
      await repo.ensureDefaults();
      await repo.saveRecurring(
        FinRecurring(
          id: 'r',
          title: 'Lakbér',
          amount: 120000,
          kind: FinKind.expense,
          categoryId: 'cat-housing',
          dayOfMonth: 1,
          fromMonth: floating(2026, 11, 1),
        ),
      );
      final deleted = await repo.deleteRecurring('r');
      expect(await repo.recurring(), isEmpty);
      expect(await repo.undelete(deleted), isTrue);
      expect((await repo.recurring()).single.title, 'Lakbér');
    });
  });

  group('backup', () {
    test(
      'export and import into an empty database restores everything',
      () async {
        await repo.ensureDefaults();
        await repo.saveTx(tx('a', 500));
        await repo.saveBudget(
          const FinBudget(categoryId: 'cat-food', limit: 40000),
        );
        await repo.saveGoal(
          const FinGoal(id: 'g', name: 'Laptop', target: 400000),
        );
        await repo.saveTx(tx('gone', 9));
        await repo.deleteTx('gone');
        final text = await repo.exportJson();

        final db2 = await newDb();
        final repo2 = FinanceRepository(db2, clock: () => 5000);
        final r = await repo2.importJson(text);
        expect(r.skipped, 0);
        expect(r.added, greaterThan(0));
        expect((await repo2.txs()).map((x) => x.id), ['a']);
        expect((await repo2.budgets()).single.limit, 40000);
        expect((await repo2.goals()).single.name, 'Laptop');
        expect((await repo2.categories()).length, defaultCategories().length);
        await db2.close();
      },
    );

    test('a transaction in another currency comes back with it', () async {
      const eur = FinForeign(currency: 'EUR', cents: 1240, rate: 399.5);
      await repo.saveTx(tx('a', 4954).copyWith(foreign: eur));
      await repo.saveTx(tx('b', 700));
      final text = await repo.exportJson();
      final db2 = await newDb();
      final repo2 = FinanceRepository(db2, clock: () => 5000);
      await repo2.importJson(text);
      final back = {for (final x in await repo2.txs()) x.id: x};
      expect(back['a']!.foreign, eur);
      expect(back['a']!.amount, 4954);
      expect(back['b']!.foreign, isNull);
      await db2.close();
    });

    test('import never overwrites newer data and never deletes', () async {
      await repo.saveTx(tx('a', 500)); // updatedAt 1000
      final text = await repo.exportJson();
      await repo.saveTx((await repo.txs()).single.copyWith(amount: 999));
      await repo.saveTx(tx('b', 1)); // not in the backup
      final r = await repo.importJson(text);
      expect(r.updated, 0);
      expect((await repo.txs()).firstWhere((x) => x.id == 'a').amount, 999);
      expect((await repo.txs()).length, 2);
    });

    test('an older local record is updated from the backup', () async {
      await repo.saveTx(tx('a', 500));
      final text = await repo.exportJson();
      final db2 = await newDb();
      final repo2 = FinanceRepository(db2, clock: () => 1);
      await repo2.saveTx(tx('a', 1)); // updatedAt 1, older than the backup
      final r = await repo2.importJson(text);
      expect(r.updated, 1);
      expect((await repo2.txs()).single.amount, 500);
      await db2.close();
    });

    test('garbage is skipped without crashing', () async {
      expect((await repo.importJson('nem json')).recognized, isFalse);
      expect((await repo.importJson('{"records": 5}')).recognized, isFalse);
      final r = await repo.importJson(
        '{"records": [{"kind": "tx", "data": {"id": "x"}}, {"kind": "ufo", "data": 1}, 7]}',
      );
      expect((r.added, r.skipped, r.recognized), (0, 3, true));
    });

    test('a backup of a newer version is not read, and says why', () async {
      await repo.saveTx(
        FinTx(
          id: 'x',
          date: DateTime.utc(2026, 11, 8),
          amount: 500,
          kind: FinKind.expense,
        ),
      );
      final text = await repo.exportJson();
      expect(jsonDecode(text)['version'], financeBackupVersion);
      final newer = text.replaceFirst(
        '"version":$financeBackupVersion',
        '"version":${financeBackupVersion + 1}',
      );
      expect(newer, isNot(text));

      final db2 = await newDb();
      final repo2 = FinanceRepository(db2);
      final r = await repo2.importJson(newer);
      expect(r.newer, isTrue);
      expect(r.recognized, isTrue);
      expect((r.added, r.updated), (0, 0));
      expect(await repo2.txs(), isEmpty);
      // the same file in this version's format is restored
      final ok = await repo2.importJson(text);
      expect((ok.newer, ok.added), (false, 1));
      await db2.close();
    });
  });

  test(
    'upgrading a v3 database creates the finance table and keeps events',
    () async {
      final dir = Directory.systemTemp.createTempSync('kvantum_mig');
      final file = File('${dir.path}/db.sqlite');
      try {
        final old = AppDatabase(NativeDatabase(file));
        await EventRepository(old)
            .saveLocal(evt('e1', 'Fogorvos', floating(2026, 11, 20, 9)));
        await old.customStatement('DROP TABLE fin_rows');
        await old.customStatement('PRAGMA user_version = 3');
        await old.close();

        final upgraded = AppDatabase(NativeDatabase(file));
        expect(
          (await EventRepository(upgraded).all()).single.title,
          'Fogorvos',
        );
        final repo3 = FinanceRepository(upgraded);
        await repo3.ensureDefaults();
        expect(await repo3.categories(), isNotEmpty);
        await upgraded.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
