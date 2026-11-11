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
      expect(await repo.deleteCategory('cat-food'), isFalse);
      expect((await repo.categories()).any((c) => c.id == 'cat-food'), isTrue);
      await repo.saveBudget(
        const FinBudget(categoryId: 'cat-fun', limit: 1000),
      );
      expect(await repo.deleteCategory('cat-fun'), isTrue);
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
        expect((await repo3.categories()), isNotEmpty);
        await upgraded.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
