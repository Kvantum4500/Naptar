import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/drive/finance_mailbox.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/harness.dart';

/// One simulated device: its own database, clock and mailbox.
class Device {
  Device(this.id, this.drive, {int start = 1000}) : now = start;
  final String id;
  final FakeDrive drive;
  int now;
  late AppDatabase db;
  late FinanceRepository repo;
  late FinanceMailbox mail;

  Future<Device> open() async {
    db = await newDb();
    repo = FinanceRepository(db, clock: () => now);
    mail = FinanceMailbox(repo, drive, deviceId: id, clock: () => now);
    return this;
  }

  Future<void> close() => db.close();

  Future<void> addTx(String tid, int amount, {String cat = 'cat-food'}) =>
      repo.saveTx(
        FinTx(
          id: tid,
          date: floating(2026, 11, 8),
          amount: amount,
          kind: FinKind.expense,
          categoryId: cat,
        ),
      );

  Future<Map<String, int>> amounts() async => {
    for (final t in await repo.txs()) t.id: t.amount,
  };
}

int letters(FakeDrive d) => d.files.values
    .where((f) => f.name.startsWith(FinanceMailbox.letterPrefix))
    .length;

void main() {
  late FakeDrive drive;
  late Device a, b;

  setUp(() async {
    drive = FakeDrive();
    a = await Device('aaaa1111', drive).open();
    b = await Device('bbbb2222', drive).open();
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  /// Both devices have announced themselves and know each other.
  Future<void> introduce() async {
    await a.mail.sync();
    await b.mail.sync();
    await a.mail.sync();
    await b.mail.sync();
  }

  test(
    'a change travels as a letter and the letter is deleted on arrival',
    () async {
      await introduce();
      await a.addTx('t1', 500);
      a.now += 10;
      final r1 = await a.mail.sync();
      expect(r1.sentLetters, 1);
      expect(letters(drive), 1);

      final r2 = await b.mail.sync();
      expect(r2.receivedLetters, 1);
      expect(r2.applied, 1);
      expect(await b.amounts(), {'t1': 500});
      expect(letters(drive), 0); // "arrived": nothing left in Drive
    },
  );

  test(
    'Drive keeps only undelivered mail; a quiet run writes nothing',
    () async {
      await introduce();
      await a.addTx('t1', 500);
      await a.mail.sync();
      await b.mail.sync();
      final writes = drive.writes;
      final again = await a.mail.sync();
      final again2 = await b.mail.sync();
      expect(again.sentLetters + again2.sentLetters, 0);
      expect(drive.writes, writes);
      expect(letters(drive), 0);
    },
  );

  test('delivered changes are not sent again', () async {
    await introduce();
    await a.addTx('t1', 500);
    await a.mail.sync();
    expect(await a.repo.dirtyCount(), 0);
    expect((await a.mail.sync()).sentLetters, 0);
  });

  test('the second device receives the whole history', () async {
    await a.repo.ensureDefaults();
    await a.addTx('t1', 500);
    await a.addTx('t2', 700);
    await a.mail.sync(); // nobody to write to yet: stays dirty
    expect(await a.repo.dirtyCount(), greaterThan(0));
    expect(letters(drive), 0);

    await b.mail.sync(); // B shows up
    final r = await a.mail.sync(); // A greets the new device with everything
    expect(r.sentLetters, 1);
    await b.mail.sync();
    expect(await b.amounts(), {'t1': 500, 't2': 700});
    expect(letters(drive), 0);
  });

  test('edits go both ways; the later edit wins on both devices', () async {
    await introduce();
    await a.addTx('t1', 500);
    await a.mail.sync();
    await b.mail.sync();

    a.now = 5000;
    await a.addTx('t1', 600); // A edits at 5000
    b.now = 6000;
    await b.addTx('t1', 700); // B edits later, at 6000
    await a.mail.sync();
    await b.mail.sync();
    await a.mail.sync();
    await b.mail.sync();
    expect(await a.amounts(), {'t1': 700});
    expect(await b.amounts(), {'t1': 700});
  });

  test('equal times are settled the same way on both devices', () async {
    await introduce();
    a.now = 9000;
    b.now = 9000;
    await a.addTx('t1', 111);
    await b.addTx('t1', 222);
    for (var i = 0; i < 2; i++) {
      await a.mail.sync();
      await b.mail.sync();
    }
    expect(await a.amounts(), await b.amounts());
  });

  test('a deletion reaches the other device and the item stays gone', () async {
    await introduce();
    await a.addTx('t1', 500);
    await a.mail.sync();
    await b.mail.sync();
    a.now += 100;
    await a.repo.deleteTx('t1');
    await a.mail.sync();
    await b.mail.sync();
    expect(await b.amounts(), isEmpty);
    // an old letter arriving late cannot bring it back
    b.now += 100;
    await a.mail.sync();
    await b.mail.sync();
    expect(await b.amounts(), isEmpty);
  });

  test('applying the same letter twice changes nothing', () async {
    await introduce();
    await a.addTx('t1', 500);
    await a.mail.sync();
    final copy = drive.files.values.firstWhere(
      (f) => f.name.startsWith(FinanceMailbox.letterPrefix),
    );
    final name = copy.name;
    final content = copy.content;
    await b.mail.sync();
    drive.externalWrite(name, content); // the same letter again
    final r = await b.mail.sync();
    expect(r.receivedLetters, 1);
    expect(r.applied, 0);
    expect(await b.amounts(), {'t1': 500});
  });

  test('a third device joins later and gets everything', () async {
    await introduce();
    await a.addTx('t1', 500);
    await b.addTx('t2', 900);
    for (var i = 0; i < 2; i++) {
      await a.mail.sync();
      await b.mail.sync();
    }
    final c = await Device('cccc3333', drive).open();
    await c.mail.sync();
    await a.mail.sync();
    await b.mail.sync();
    await c.mail.sync();
    expect(await c.amounts(), {'t1': 500, 't2': 900});
    // and a change on C reaches both
    await c.addTx('t3', 1);
    await c.mail.sync();
    await a.mail.sync();
    await b.mail.sync();
    expect((await a.amounts()).containsKey('t3'), isTrue);
    expect((await b.amounts()).containsKey('t3'), isTrue);
    await c.close();
  });

  test('offline: nothing is lost, the next run delivers', () async {
    await introduce();
    await a.addTx('t1', 500);
    drive.offline = true;
    final r = await a.mail.sync();
    expect(r.stoppedEarly, isTrue);
    expect(await a.repo.dirtyCount(), greaterThan(0));
    drive.offline = false;
    expect((await a.mail.sync()).sentLetters, 1);
    await b.mail.sync();
    expect(await b.amounts(), {'t1': 500});
  });

  test('a record edited while the letter is uploading stays queued', () async {
    await introduce();
    await a.addTx('t1', 500);
    drive.duringWrite = () async {
      a.now += 50;
      await a.addTx('t1', 999);
    };
    await a.mail.sync();
    expect(await a.repo.dirtyCount(), 1);
    await a.mail.sync();
    await b.mail.sync();
    expect(await b.amounts(), {'t1': 999});
  });

  test(
    'a corrupt letter is dropped, letters for others are left alone',
    () async {
      await introduce();
      drive.externalWrite(
        'fin-letter-zzzz9999-to-${a.id}-1-0.json',
        'nem json',
      );
      final other = drive.externalWrite(
        'fin-letter-zzzz9999-to-cccc3333-1-0.json',
        jsonEncode({'v': 1, 'records': []}),
      );
      final r = await a.mail.sync();
      expect(r.corrupt, 1);
      expect(drive.files.containsKey(other), isTrue);
    },
  );

  test('a large change is split into letters', () async {
    await introduce();
    for (var i = 0; i < 1000; i++) {
      await a.addTx('x$i', i + 1);
    }
    final r = await a.mail.sync();
    expect(r.sentLetters, 3); // 400 + 400 + 200
    final got = await b.mail.sync();
    expect(got.receivedLetters, 3);
    expect((await b.amounts()).length, 1000);
  });

  test(
    'letters nobody collected expire; the peer then gets a full letter',
    () async {
      await introduce();
      await a.addTx('t1', 500);
      await a.mail.sync(); // letter waits for B
      expect(letters(drive), 1);
      const day = 24 * 3600 * 1000;
      a.now += 61 * day;
      final r = await a.mail.sync();
      expect(r.expired, 1);
      expect(letters(drive), 0);
      // B comes back after two months: it is greeted with everything again
      b.now += 61 * day;
      await b.mail.sync(); // B announces itself again
      await a.mail.sync();
      await b.mail.sync();
      expect(await b.amounts(), {'t1': 500});
    },
  );

  test('a device silent for half a year gets no letters', () async {
    await introduce();
    const day = 24 * 3600 * 1000;
    a.now += 200 * day; // B never shows a sign of life
    await a.addTx('t1', 500);
    final r = await a.mail.sync();
    expect(r.peers, 0);
    expect(r.sentLetters, 0);
    expect(letters(drive), 0);
  });

  test(
    'a device that returns after being written off gets the whole snapshot',
    () async {
      final c = await Device('cccc3333', drive).open();
      addTearDown(c.close);
      for (final d in [a, b, c, a, b, c]) {
        await d.mail.sync(); // everyone announces itself and greets the others
      }
      const day = 24 * 3600 * 1000;

      // B stays away for 200 days; A and C carry on and count it as gone
      a.now += 200 * day;
      c.now += 200 * day;
      await c.mail.sync();
      await a.addTx('t9', 900);
      await a.mail.sync(); // delivered to C only; A's change is now "clean"
      await c.mail.sync();
      expect(await c.amounts(), {'t9': 900});
      expect(await b.amounts(), isEmpty);

      // B comes back: it must not be left with the gap
      b.now = a.now;
      await b.mail.sync();
      await a.mail.sync();
      await b.mail.sync();
      expect(await b.amounts(), {'t9': 900});
    },
  );

  test('the presence note is refreshed only now and then', () async {
    await a.mail.sync();
    final w = drive.writes;
    await a.mail.sync();
    expect(drive.writes, w);
    a.now += 13 * 3600 * 1000;
    await a.mail.sync();
    expect(drive.writes, w + 1);
    expect(
      drive.files.values
          .where((f) => f.name == '${FinanceMailbox.peerPrefix}${a.id}.json')
          .length,
      1,
    );
  });

  test('records of every kind travel', () async {
    await introduce();
    await a.repo.ensureDefaults();
    await a.repo.saveBudget(
      const FinBudget(categoryId: 'cat-food', limit: 40000),
    );
    await a.repo.saveGoal(
      const FinGoal(id: 'g', name: 'Laptop', target: 400000),
    );
    await a.repo.saveDeposit(
      FinDeposit(
        id: 'd',
        goalId: 'g',
        date: floating(2026, 11, 1),
        amount: 1000,
      ),
    );
    await a.repo.saveRecurring(
      FinRecurring(
        id: 'r',
        title: 'Netflix',
        amount: 4490,
        kind: FinKind.expense,
        categoryId: 'cat-subs',
        dayOfMonth: 12,
        fromMonth: floating(2026, 1, 1),
      ),
    );
    await a.repo.saveCategory(
      const FinCategory(id: 'cat-own', name: 'Étterem', kind: FinKind.expense),
    );
    await a.mail.sync();
    await b.mail.sync();
    expect((await b.repo.budgets()).single.limit, 40000);
    expect((await b.repo.goals()).single.name, 'Laptop');
    expect((await b.repo.deposits()).single.amount, 1000);
    expect((await b.repo.recurring()).single.title, 'Netflix');
    expect((await b.repo.categories()).any((c) => c.id == 'cat-own'), isTrue);
  });

  test(
    'generated recurring items are derived on each device, not mailed',
    () async {
      await introduce();
      await a.repo.saveRecurring(
        FinRecurring(
          id: 'r',
          title: 'Lakbér',
          amount: 120000,
          kind: FinKind.expense,
          categoryId: 'cat-housing',
          dayOfMonth: 1,
          fromMonth: floating(2026, 1, 1),
        ),
      );
      await a.repo.ensureRecurring(2026, 11);
      await a.mail.sync();
      await b.mail.sync();
      // B got the rule; it derives the same item by itself, with the same id
      await b.repo.ensureRecurring(2026, 11);
      expect((await b.repo.txs()).map((t) => t.id), ['rec-r-202611']);
      await a.mail.sync();
      await b.mail.sync();
      expect((await a.repo.txs()).length, 1);
      expect((await b.repo.txs()).length, 1);
    },
  );

  group('letters from a newer version of the app', () {
    String letterFor(String to, Map<String, Object?> body) =>
        'fin-letter-bbbb2222-to-$to-1000-0.json';

    test('stay in Drive, are not applied, and are counted', () async {
      await introduce();
      drive.externalWrite(
        letterFor('aaaa1111', {}),
        jsonEncode({
          'v': 2,
          'from': 'bbbb2222',
          'to': 'aaaa1111',
          'sent': 1000,
          'records': [
            {
              'kind': 'tx',
              'data': {'a': 'different shape'},
            },
          ],
        }),
      );
      final r = await a.mail.sync();
      expect(r.newerLetters, 1);
      expect(r.receivedLetters, 0);
      expect(r.corrupt, 0);
      expect(r.applied, 0);
      expect(
        letters(drive),
        1,
        reason: 'not deleted: the newer version needs it',
      );
      expect(await a.repo.txs(), isEmpty);
    });

    test('are not read again while the app runs', () async {
      await introduce();
      drive.externalWrite(
        letterFor('aaaa1111', {}),
        jsonEncode({
          'v': 3,
          'from': 'bbbb2222',
          'to': 'aaaa1111',
          'records': [],
        }),
      );
      await a.mail.sync();
      final again = await a.mail.sync();
      expect(again.newerLetters, 1, reason: 'still counted');
      expect(
        drive.readNames.where((n) => n.startsWith('fin-letter-')),
        hasLength(1),
        reason: 'downloaded once, not on every run',
      );
    });

    test('a kind this version does not know: the rest is applied, the letter stays', () async {
      await introduce();
      final known = FinTx(
        id: 't9',
        date: floating(2026, 11, 8),
        amount: 700,
        kind: FinKind.expense,
        updatedAt: 5000,
      );
      drive.externalWrite(
        letterFor('aaaa1111', {}),
        jsonEncode({
          'v': 1,
          'from': 'bbbb2222',
          'to': 'aaaa1111',
          'sent': 1000,
          'records': [
            {'kind': 'tx', 'data': known.toJson()},
            {
              'kind': 'workout-plan',
              'data': {'id': 'w1'},
            },
          ],
        }),
      );
      final r = await a.mail.sync();
      expect(r.applied, 1);
      expect(r.newerLetters, 1);
      expect(r.receivedLetters, 0);
      expect(await a.amounts(), {'t9': 700});
      expect(
        letters(drive),
        1,
        reason: 'kept for the version that knows the rest',
      );
    });

    test('a damaged letter is still thrown away, as before', () async {
      await introduce();
      drive.externalWrite(letterFor('aaaa1111', {}), 'not json at all');
      final r = await a.mail.sync();
      expect(r.corrupt, 1);
      expect(r.newerLetters, 0);
      expect(letters(drive), 0);
    });

    test('our own letters carry the version this build writes', () async {
      await introduce();
      await a.addTx('t1', 500);
      a.now += 10;
      await a.mail.sync();
      final letter = drive.files.values.firstWhere(
        (f) => f.name.startsWith(FinanceMailbox.letterPrefix),
      );
      expect(
        (jsonDecode(letter.content) as Map)['v'],
        FinanceMailbox.letterVersion,
      );
    });
  });
}
