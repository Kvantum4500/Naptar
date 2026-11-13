import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_store.dart';

void main() {
  group('the name of a backup', () {
    test('says the day and the time', () {
      expect(
        backupFileName(DateTime(2026, 11, 13, 9, 5, 30)),
        'kvantum-20261113-090530.zip',
      );
      expect(
        backupFileName(DateTime(2027, 1, 2, 0, 0, 0)),
        'kvantum-20270102-000000.zip',
      );
    });

    test('is read back', () {
      final t = DateTime(2026, 11, 13, 21, 59, 7);
      expect(backupTimeOf(backupFileName(t)), t);
    });

    test('belongs to us only if it looks like one of ours', () {
      expect(backupTimeOf('kvantum-20261113-090530.zip'), isNotNull);
      expect(backupTimeOf('mentes.zip'), isNull);
      expect(backupTimeOf('kvantum-20261113-090530.zip.part'), isNull);
      expect(backupTimeOf('kvantum-2026113-090530.zip'), isNull);
      expect(
        backupTimeOf('kvantum-20261345-090530.zip'),
        isNull,
      ); // no month 13
      expect(backupTimeOf('kvantum-20261113-250530.zip'), isNull); // no hour 25
    });
  });

  group('which backups go', () {
    final now = DateTime(2026, 11, 13, 10);
    String at(int daysAgo, [int hour = 8]) =>
        backupFileName(DateTime(now.year, now.month, now.day - daysAgo, hour));

    test('nothing, if there is nothing', () {
      expect(backupsToDelete(const [], now), isEmpty);
    });

    test('of a day, only the newest stays', () {
      final a = at(0, 8), b = at(0, 20), c = at(0, 14);
      expect(backupsToDelete([a, b, c], now), unorderedEquals([a, c]));
    });

    test('a week of days stays, one each', () {
      final names = [for (var d = 0; d < 7; d++) at(d)];
      expect(backupsToDelete(names, now), isEmpty);
    });

    test('older than a week: one for each week, four weeks', () {
      // days ago 7 .. 13 are the first week beyond the daily ones, 14 .. 20 the
      // second, and so on; four weeks are kept
      final week = [for (var w = 0; w < 5; w++) at(7 + 7 * w)];
      expect(backupsToDelete(week, now), [week.last]);
      // two in the same week: the newer stays
      final x = at(8), y = at(10);
      expect(backupsToDelete([x, y], now), [y]);
    });

    test('the example of ten daily backups', () {
      final names = [for (var d = 0; d < 10; d++) at(d)];
      // days 0..6 stay; 7, 8, 9 are one week: the newest of them (7) stays
      expect(backupsToDelete(names, now), unorderedEquals([at(8), at(9)]));
    });

    test('a file that is not ours is never named', () {
      expect(
        backupsToDelete(['mentes.zip', 'kvantum-2026.zip', at(0)], now),
        isEmpty,
      );
    });

    test('a backup from the future counts as today', () {
      final future = backupFileName(DateTime(2026, 11, 20, 8));
      final today = at(0);
      // (one day: the later one stays)
      expect(backupsToDelete([future, today], now), [today]);
    });

    test('the rule can be changed', () {
      final names = [for (var d = 0; d < 5; d++) at(d)];
      expect(
        backupsToDelete(names, now, days: 2, weeks: 1),
        unorderedEquals([at(3), at(4)]),
        reason: 'days 0, 1 stay; 2, 3, 4 are one week: 2 stays',
      );
    });
  });

  group('a folder of backups', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('kvantum-backups'));
    tearDown(() => dir.deleteSync(recursive: true));

    final bytes = Uint8List.fromList([1, 2, 3]);

    test('writes, lists newest first, reads and deletes', () async {
      final store = FileBackupStore(Directory('${dir.path}/backups'));
      expect(await store.list(), isEmpty); // (the folder is not there yet)
      await store.write('kvantum-20261111-080000.zip', bytes);
      await store.write('kvantum-20261113-080000.zip', Uint8List(10));
      await store.write('kvantum-20261112-080000.zip', bytes);
      final list = await store.list();
      expect(list.map((e) => e.name), [
        'kvantum-20261113-080000.zip',
        'kvantum-20261112-080000.zip',
        'kvantum-20261111-080000.zip',
      ]);
      expect(list.first.size, 10);
      expect(list.first.time, DateTime(2026, 11, 13, 8));
      expect(await store.read('kvantum-20261112-080000.zip'), bytes);
      await store.delete('kvantum-20261112-080000.zip');
      expect(await store.read('kvantum-20261112-080000.zip'), isNull);
      expect((await store.list()).length, 2);
      await store.delete('kvantum-20261112-080000.zip'); // (already gone)
    });

    test('a write leaves no half-written file behind', () async {
      final store = FileBackupStore(dir);
      await store.write('kvantum-20261113-080000.zip', bytes);
      expect(
        dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
        ['kvantum-20261113-080000.zip'],
      );
    });

    test('a write that was cut short is cleaned up by the next one', () async {
      final store = FileBackupStore(dir);
      File('${dir.path}/kvantum-20261112-080000.zip.part')
          .writeAsBytesSync(bytes);
      File('${dir.path}/jegyzet.txt').writeAsStringSync('az enyém');
      await store.write('kvantum-20261113-080000.zip', bytes);
      final names =
          dir
              .listSync()
              .map((e) => e.path.split(Platform.pathSeparator).last)
              .toList()
            ..sort();
      // (the half file is gone; a file of somebody else is left alone)
      expect(names, ['jegyzet.txt', 'kvantum-20261113-080000.zip']);
    });

    test('only zip files are listed; foreign ones last', () async {
      final store = FileBackupStore(dir);
      File('${dir.path}/notes.txt').writeAsStringSync('x');
      File('${dir.path}/old.zip').writeAsBytesSync(bytes);
      File('${dir.path}/kvantum-20261113-080000.zip.part')
          .writeAsBytesSync(bytes);
      await store.write('kvantum-20261113-080000.zip', bytes);
      final list = await store.list();
      expect(list.map((e) => e.name), [
        'kvantum-20261113-080000.zip',
        'old.zip',
      ]);
      expect(list.last.time, isNull);
    });

    test('a name cannot reach out of the folder', () async {
      final store = FileBackupStore(Directory('${dir.path}/in'));
      await store.write('../escape.zip', bytes);
      expect(File('${dir.path}/escape.zip').existsSync(), isFalse);
      expect(File('${dir.path}/in/escape.zip').existsSync(), isTrue);
    });
  });

  group('the memory folder', () {
    test('works the same way', () async {
      final store = MemoryBackupStore();
      await store.write('kvantum-20261111-080000.zip', Uint8List(3));
      await store.write('kvantum-20261113-080000.zip', Uint8List(5));
      expect((await store.list()).map((e) => e.name), [
        'kvantum-20261113-080000.zip',
        'kvantum-20261111-080000.zip',
      ]);
      expect((await store.read('kvantum-20261113-080000.zip'))!.length, 5);
      await store.delete('kvantum-20261113-080000.zip');
      expect(await store.read('kvantum-20261113-080000.zip'), isNull);
    });
  });
}
