import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

/// A device with its own (possibly wrong) clock and its own database.
class _Device {
  _Device(this.name, this.time) : db = AppDatabase(NativeDatabase.memory()) {
    records = RecordRepository(db, deviceId: name, clock: () => time);
    finance = FinanceRepository(db, clock: () => time);
  }
  final String name;
  int time;
  final AppDatabase db;
  late final RecordRepository records;
  late final FinanceRepository finance;
}

FinTx tx(String id, {int amount = 1000, String merchant = 'Bolt'}) => FinTx(
  id: id,
  date: DateTime.utc(2026, 11, 11),
  amount: amount,
  kind: FinKind.expense,
  merchant: merchant,
);

void main() {
  late _Device a, b;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    a = _Device('aaaa', 10 * 86400 * 1000);
    b = _Device('bbbb', 10 * 86400 * 1000);
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  group('stampAfter', () {
    SyncRecord rec(Map<String, int> stamps) => SyncRecord(
      id: 'r',
      kind: 'task',
      fields: {
        for (final e in stamps.entries) e.key: FieldValue('v', e.value, 'x'),
      },
    );

    test('the clock, when nothing replaced is newer', () {
      expect(stampAfter(rec({'a': 100}), ['a'], 500), 500);
      expect(stampAfter(rec({}), ['a'], 500), 500);
    });

    test('one millisecond after a value that is as new or newer', () {
      expect(stampAfter(rec({'a': 500}), ['a'], 500), 501);
      expect(stampAfter(rec({'a': 9000}), ['a'], 500), 9001);
    });

    test('only the fields being written count', () {
      expect(stampAfter(rec({'a': 9000, 'b': 100}), ['b'], 500), 500);
      expect(stampAfter(rec({'a': 9000, 'b': 800}), ['a', 'b'], 500), 9001);
    });
  });

  group('records: an edit made on top of what this device has seen wins', () {
    test('even when the other device\'s clock runs ahead', () async {
      a.time += 5 * 86400 * 1000; // device A thinks it is five days later
      await a.records.edit('task', 't1', {'title': 'A: első'});
      final fromA = (await a.records.get('task', 't1'))!;

      await b.records.applyRemote(fromA); // B receives it...
      await b.records.edit('task', 't1', {
        'title': 'B: javított',
      }); // ...and edits
      final fromB = (await b.records.get('task', 't1'))!;
      expect(
        fromB.fields['title']!.ts,
        greaterThan(fromA.fields['title']!.ts),
        reason: 'stamped after the version it replaces, not by the slow clock',
      );

      await a.records.applyRemote(fromB);
      expect((await a.records.get('task', 't1'))!['title'], 'B: javított');
      await b.records.applyRemote((await a.records.get('task', 't1'))!);
      expect((await b.records.get('task', 't1'))!['title'], 'B: javított');
    });

    test('a field nobody ahead has touched keeps the plain clock', () async {
      a.time += 5 * 86400 * 1000;
      await a.records.edit('task', 't1', {'title': 'A'});
      await b.records.applyRemote((await a.records.get('task', 't1'))!);
      await b.records.edit('task', 't1', {'done': true});
      final r = (await b.records.get('task', 't1'))!;
      expect(r.fields['done']!.ts, b.time, reason: 'not infected by the title');
    });

    test(
      'two edits of one field in the same millisecond still order',
      () async {
        await a.records.edit('task', 't1', {'title': 'egy'});
        await a.records.edit('task', 't1', {'title': 'kettő'});
        final r = (await a.records.get('task', 't1'))!;
        expect(r.fields['title']!.ts, a.time + 1);
        expect(r['title'], 'kettő');
      },
    );

    test('a deletion is stamped after the last edit too', () async {
      a.time += 3 * 86400 * 1000;
      await a.records.edit('task', 't1', {'deleted': false});
      await b.records.applyRemote((await a.records.get('task', 't1'))!);
      await b.records.delete('task', 't1');
      final r = (await b.records.get('task', 't1'))!;
      expect(r.deleted, isTrue);
      await a.records.applyRemote(r);
      expect((await a.records.get('task', 't1'))!.deleted, isTrue);
    });

    test('an unchanged value is not stamped again', () async {
      await a.records.edit('task', 't1', {'title': 'x'});
      final first = (await a.records.get('task', 't1'))!.fields['title']!.ts;
      a.time += 1000;
      await a.records.edit('task', 't1', {'title': 'x'});
      expect((await a.records.get('task', 't1'))!.fields['title']!.ts, first);
    });
  });

  group('finance: the same rule', () {
    test('saving twice in one millisecond gives increasing stamps', () async {
      await a.finance.saveTx(tx('x'));
      final first = (await a.finance.txs()).single.updatedAt;
      await a.finance.saveTx(tx('x', amount: 2000));
      final second = (await a.finance.txs()).single.updatedAt;
      expect(second, first + 1);
    });

    test(
      'a record that arrived stamped ahead is beaten by the next edit',
      () async {
        a.time += 6 * 86400 * 1000; // a device with a clock far ahead
        await a.finance.saveTx(tx('x', amount: 1000));
        final sent = await a.finance.mailRecords(onlyDirty: true);
        for (final m in sent) {
          expect(await b.finance.applyIncoming(m.kind, m.data), isTrue);
        }

        await b.finance.saveTx(
          (await b.finance.txs()).single.copyWith(amount: 2500),
        );
        final edited = (await b.finance.txs()).single;
        expect(edited.updatedAt, greaterThan(sent.single.updatedAt));

        for (final m in await b.finance.mailRecords(onlyDirty: true)) {
          await a.finance.applyIncoming(m.kind, m.data);
        }
        expect((await a.finance.txs()).single.amount, 2500);
      },
    );

    test('a deletion is stamped after the version it deletes', () async {
      a.time += 6 * 86400 * 1000;
      await a.finance.saveTx(tx('x'));
      for (final m in await a.finance.mailRecords(onlyDirty: true)) {
        await b.finance.applyIncoming(m.kind, m.data);
      }
      await b.finance.deleteTx('x');
      for (final m in await b.finance.mailRecords(onlyDirty: true)) {
        await a.finance.applyIncoming(m.kind, m.data);
      }
      expect(await a.finance.txs(), isEmpty);
    });
  });

  group('a wrong clock is noticed', () {
    const day = 86400 * 1000;

    test('only a stamp more than two days ahead is suspicious', () {
      expect(clockAhead(null, 1000), isNull);
      expect(clockAhead(1000 + 1 * day, 1000), isNull);
      expect(clockAhead(1000 + 2 * day, 1000), isNull);
      expect(clockAhead(1000 + 3 * day, 1000), const Duration(days: 3));
      expect(clockAhead(1000 - 5 * day, 1000), isNull);
    });

    test('the newest stamp of the records and of the finances', () async {
      expect(await a.records.newestStamp(), isNull);
      expect(await a.finance.newestStamp(), isNull);
      await a.records.edit('task', 't1', {'title': 'x'});
      a.time += 3 * day;
      await a.records.edit('task', 't2', {'title': 'y'});
      await a.finance.saveTx(tx('x'));
      expect(await a.records.newestStamp(), a.time);
      expect(await a.finance.newestStamp(), a.time);
      expect(
        clockAhead(await a.records.newestStamp(), a.time - 3 * day),
        const Duration(days: 3),
      );
    });
  });
}
