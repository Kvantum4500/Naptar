import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

SyncRecord task(
  String id,
  Map<String, Object?> f, {
  int ts = 100,
  String dev = 'A',
}) => SyncRecord(id: id, kind: kindTask).edit(f, ts: ts, dev: dev);

void main() {
  group('SyncRecord merge', () {
    test('different fields edited on two devices both survive', () {
      final base = task('1', taskFields(title: 'Eredeti'), ts: 100);
      final a = base.edit({'title': 'A cím'}, ts: 200, dev: 'A');
      final b = base.edit({'done': true}, ts: 250, dev: 'B');
      final m = a.merge(b);
      expect(TaskView(m).title, 'A cím');
      expect(TaskView(m).done, isTrue);
    });

    test('the same field: the later write wins, on both merge orders', () {
      final base = task('1', taskFields(title: 'x'));
      final a = base.edit({'title': 'régebbi'}, ts: 200, dev: 'A');
      final b = base.edit({'title': 'újabb'}, ts: 300, dev: 'B');
      expect(TaskView(a.merge(b)).title, 'újabb');
      expect(TaskView(b.merge(a)).title, 'újabb');
    });

    test(
      'equal timestamps are decided by device id, identically everywhere',
      () {
        final base = task('1', taskFields(title: 'x'));
        final a = base.edit({'title': 'A-s'}, ts: 500, dev: 'A');
        final b = base.edit({'title': 'B-s'}, ts: 500, dev: 'B');
        expect(a.merge(b).sameAs(b.merge(a)), isTrue);
        expect(TaskView(a.merge(b)).title, 'B-s');
      },
    );

    test('merge is idempotent, commutative and associative', () {
      final base = task('1', taskFields(title: 'x'));
      final a = base.edit({'title': 'a'}, ts: 200, dev: 'A');
      final b = base.edit({'notes': 'b'}, ts: 210, dev: 'B');
      final c = base.edit({'priority': 3}, ts: 220, dev: 'C');
      expect(a.merge(a).sameAs(a), isTrue);
      expect(a.merge(b).sameAs(b.merge(a)), isTrue);
      expect(a.merge(b).merge(c).sameAs(a.merge(b.merge(c))), isTrue);
    });

    test(
      'a delete beats an older edit but loses to a newer one (undelete)',
      () {
        final base = task('1', taskFields(title: 'x'), ts: 100);
        final del = base.edit({'deleted': true}, ts: 300, dev: 'A');
        final oldEdit = base.edit({'title': 'szerkesztve'}, ts: 200, dev: 'B');
        expect(del.merge(oldEdit).deleted, isTrue);
        expect(
          TaskView(del.merge(oldEdit)).title,
          'szerkesztve',
        ); // field merged, still deleted
        final restore = del.edit({'deleted': false}, ts: 400, dev: 'B');
        expect(del.merge(restore).deleted, isFalse);
      },
    );

    test(
      'saving without changes does not re-stamp fields (no stolen edits)',
      () {
        final base = task('1', taskFields(title: 'x'), ts: 100, dev: 'A');
        final same = base.edit(taskFields(title: 'x'), ts: 999, dev: 'B');
        expect(same.fields['title']!.ts, 100);
        expect(same.fields['title']!.dev, 'A');
      },
    );

    test('updatedAt is the newest field write', () {
      final r = task(
        '1',
        taskFields(title: 'x'),
        ts: 100,
      ).edit({'done': true}, ts: 700, dev: 'A');
      expect(r.updatedAt, 700);
    });
  });

  group('JSON', () {
    test('round trip keeps every field, timestamp and device', () {
      final r = task(
        '7',
        taskFields(
          title: 'Edzés',
          due: DateTime.utc(2026, 5, 4),
          estimateMin: 45,
          priority: 3,
          energyNeed: 5,
        ),
      );
      final back = SyncRecord.decode(r.encode());
      expect(back.sameAs(r), isTrue);
      expect(TaskView(back).due, DateTime.utc(2026, 5, 4));
      expect(TaskView(back).estimateMin, 45);
    });

    test('corrupt or foreign files are rejected with FormatException, never a crash', () {
      for (final bad in [
        '',
        'not json',
        '[]',
        '{"id":1}',
        '{"id":"a","kind":"task","f":5}',
        '{"id":"a","kind":"task","f":{"title":{"v":"x"}}}',
      ]) {
        expect(
          () => SyncRecord.decode(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('a record file from a newer version', () {
    test('is told apart from a corrupt one (and never mistaken for it)', () {
      const newer =
          '{"v":2,"id":"a","kind":"task","f":{"title":{"x":"a different shape"}}}';
      expect(
        () => SyncRecord.decode(newer),
        throwsA(isA<NewerFormatException>()),
      );
      // it is still a FormatException for old code that catches only that,
      // but the newer-version check comes before the field checks
      try {
        SyncRecord.decode(newer);
      } on NewerFormatException catch (e) {
        expect(e.version, 2);
      }
    });

    test('the version of this build and an old file without one read fine', () {
      final r = task('7', taskFields(title: 'x'));
      expect(r.toJson()['v'], syncRecordVersion);
      expect(SyncRecord.decode(r.encode()).sameAs(r), isTrue);
      final old = r.toJson()..remove('v');
      expect(SyncRecord.decode(jsonEncode(old)).sameAs(r), isTrue);
    });

    test('a real corrupt file is still just a FormatException', () {
      expect(
        () => SyncRecord.decode('{"v":1,"id":1}'),
        throwsA(isNot(isA<NewerFormatException>())),
      );
    });
  });

  group('Task model', () {
    test('defaults and validation', () {
      final t = TaskView(task('1', taskFields(title: '  Bevásárlás  ')));
      expect(t.title, 'Bevásárlás');
      expect(t.priority, 2);
      expect(t.energyNeed, 3);
      expect(t.due, isNull);
      expect(t.estimateMin, isNull);
      expect(() => taskFields(title: ' '), throwsArgumentError);
      expect(() => taskFields(title: 'x', priority: 4), throwsArgumentError);
      expect(() => taskFields(title: 'x', energyNeed: 0), throwsArgumentError);
      expect(() => taskFields(title: 'x', estimateMin: 0), throwsArgumentError);
      expect(
        () => taskFields(title: 'x', estimateMin: 1441),
        throwsArgumentError,
      );
    });

    test(
      'out-of-range values read from a foreign file fall back to defaults',
      () {
        final r = SyncRecord(id: '1', kind: kindTask).edit(
          {'title': 'x', 'priority': 99, 'energyNeed': -4, 'due': 'holnap'},
          ts: 1,
          dev: 'A',
        );
        final t = TaskView(r);
        expect(t.priority, 2);
        expect(t.energyNeed, 3);
        expect(t.due, isNull);
      },
    );

    test('overdue only for open tasks with a past due date', () {
      final today = DateTime.utc(2026, 5, 10);
      TaskView mk(DateTime? due, {bool done = false}) =>
          TaskView(task('1', taskFields(title: 'x', due: due, done: done)));
      expect(mk(DateTime.utc(2026, 5, 9)).isOverdue(today), isTrue);
      expect(mk(DateTime.utc(2026, 5, 10)).isOverdue(today), isFalse);
      expect(
        mk(DateTime.utc(2026, 5, 9), done: true).isOverdue(today),
        isFalse,
      );
      expect(mk(null).isOverdue(today), isFalse);
    });
  });

  group('Check-in model', () {
    test('id is the date; values are validated', () {
      final id = checkInId(DateTime.utc(2026, 11, 4));
      expect(id, '2026-11-04');
      final r = SyncRecord(id: id, kind: kindCheckIn).edit(
        checkInFields(
          physical: 4,
          mental: 2,
          mood: 3,
          sleep: 5,
          note: ' fáradt ',
        ),
        ts: 1,
        dev: 'A',
      );
      final c = CheckInView(r);
      expect((c.physical, c.mental, c.mood, c.sleep), (4, 2, 3, 5));
      expect(c.note, 'fáradt');
      expect(c.date, DateTime.utc(2026, 11, 4));
      expect(() => checkInFields(physical: 6), throwsArgumentError);
      expect(() => checkInFields(mood: 0), throwsArgumentError);
    });
    test('unanswered questions are not written, so they cannot erase another device\'s answer', () {
      final fields = checkInFields(mood: 3);
      expect(fields.containsKey('physical'), isFalse);
      final a = SyncRecord(
        id: '2026-11-04',
        kind: kindCheckIn,
      ).edit(checkInFields(physical: 4), ts: 100, dev: 'A');
      final b = SyncRecord(
        id: '2026-11-04',
        kind: kindCheckIn,
      ).edit(checkInFields(mood: 2), ts: 200, dev: 'B');
      final m = CheckInView(a.merge(b));
      expect((m.physical, m.mood), (4, 2));
    });
    test('file names are stable and kind-prefixed', () {
      expect(
        recordFileName(kindCheckIn, '2026-11-04'),
        'checkin-2026-11-04.json',
      );
      expect(recordFileName(kindTask, 'abc'), 'task-abc.json');
    });
  });

  group('a number that is no number', () {
    test('is no priority, no estimate, no rating - and no crash', () {
      final task = SyncRecord(id: 'a', kind: kindTask).edit(
        {
          'title': 'x',
          'priority': double.infinity,
          'energyNeed': double.nan,
          'estimateMin': double.negativeInfinity,
        },
        ts: 1,
        dev: 'A',
      );
      final t = TaskView(task);
      expect((t.priority, t.energyNeed, t.estimateMin), (2, 3, null));
      final day = SyncRecord(
        id: '2026-11-16',
        kind: kindCheckIn,
      ).edit({'physical': double.infinity, 'mood': 4}, ts: 1, dev: 'A');
      expect((CheckInView(day).physical, CheckInView(day).mood), (null, 4));
    });
  });
}
