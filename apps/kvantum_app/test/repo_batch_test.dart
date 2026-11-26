import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(ensureTimeZones);

  late AppDatabase db;
  setUp(() async => db = await newDb());
  tearDown(() => db.close());

  CalEvent at(String id, int day) => evt(id, id, floating(2026, 11, day, 9));

  group('several event writes are one unit', () {
    Iterable<CalEvent> breaksAfter(List<CalEvent> good) sync* {
      yield* good;
      throw StateError('the run broke off');
    }

    test('saveAll: a break in the middle leaves nothing behind', () async {
      final repo = EventRepository(db);
      await expectLater(
        repo.saveAll(breaksAfter([at('a', 2), at('b', 3)])),
        throwsStateError,
      );
      expect(await repo.all(), isEmpty);
      expect(await repo.pendingOps(), isEmpty);
    });

    test('deleteAll: a break in the middle deletes nothing', () async {
      final repo = EventRepository(db);
      await repo.saveAll([at('a', 2), at('b', 3)]);
      Iterable<String> ids() sync* {
        yield 'a';
        throw StateError('the run broke off');
      }

      await expectLater(repo.deleteAll(ids()), throwsStateError);
      expect((await repo.all()).map((e) => e.id).toSet(), {'a', 'b'});
    });

    test(
      'atomically: everything or nothing, and the result is returned',
      () async {
        final repo = EventRepository(db);
        final n = await repo.atomically(() async {
          await repo.saveLocal(at('a', 2));
          return 7;
        });
        expect(n, 7);
        await expectLater(
          repo.atomically(() async {
            await repo.saveLocal(at('b', 3));
            throw StateError('no');
          }),
          throwsStateError,
        );
        expect((await repo.all()).map((e) => e.id), ['a']);
      },
    );
  });

  group('the id of this installation', () {
    test(
      'callers at the same moment get the same, and one is stored',
      () async {
        final repo = RecordRepository(db);
        final ids = await Future.wait([
          repo.deviceId(),
          repo.deviceId(),
          repo.deviceId(),
        ]);
        expect(ids.toSet(), hasLength(1));
        final rows = await db.select(db.metaRows).get();
        expect(rows.where((r) => r.key == 'deviceId'), hasLength(1));
      },
    );

    test('two writes at the same moment are made by the same device', () async {
      final repo = RecordRepository(db);
      final recs = await Future.wait([
        repo.edit(kindTask, 'a', taskFields(title: 'a')),
        repo.edit(kindTask, 'b', taskFields(title: 'b')),
      ]);
      final devs = {
        for (final r in recs)
          for (final f in r.fields.values) f.dev,
      };
      expect(devs, hasLength(1));
    });

    test('after a restart the same id comes back', () async {
      final first = await RecordRepository(db).deviceId();
      expect(await RecordRepository(db).deviceId(), first);
    });
  });
}
