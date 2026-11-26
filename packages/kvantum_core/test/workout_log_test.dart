import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The feedback after a workout (2e): the record, its id, the Drive file name
/// and what two devices make of the same one.
void main() {
  Map<String, Object?> fields({
    bool done = true,
    int? bodyLoad = 4,
    int? mindLoad = 2,
    int? energyStart = 3,
    int? energyEnd = 2,
    int? experience = 4,
    String note = '',
    String title = 'Gym',
    int minutes = 60,
  }) => workoutLogFields(
    title: title,
    date: DateTime.utc(2026, 5, 5),
    minutes: minutes,
    sport: 'gym',
    done: done,
    bodyLoad: bodyLoad,
    mindLoad: mindLoad,
    energyStart: energyStart,
    energyEnd: energyEnd,
    experience: experience,
    note: note,
  );

  WorkoutLogView view(
    Map<String, Object?> f, {
    String id = 'e1-202605051800',
  }) => WorkoutLogView(
    SyncRecord(id: id, kind: kindWorkoutLog).edit(f, ts: 1, dev: 'A'),
  );

  group('the record', () {
    test('every answer is read back', () {
      final v = view(fields(note: ' jó volt '));
      expect(v.title, 'Gym');
      expect(v.date, DateTime.utc(2026, 5, 5));
      expect(v.minutes, 60);
      expect(v.sport, 'gym');
      expect(v.done, isTrue);
      expect((v.bodyLoad, v.mindLoad), (4, 2));
      expect((v.energyStart, v.energyEnd), (3, 2));
      expect(v.experience, 4);
      expect(v.note, 'jó volt');
      expect(v.deleted, isFalse);
      expect(v.answered, isTrue);
    });

    test('only the answered questions are written', () {
      final f = fields(
        bodyLoad: 3,
        mindLoad: null,
        energyStart: null,
        energyEnd: null,
        experience: null,
      );
      expect(f.containsKey('bodyLoad'), isTrue);
      for (final k in ['mindLoad', 'energyStart', 'energyEnd', 'experience']) {
        expect(f.containsKey(k), isFalse, reason: k);
      }
      expect(view(f).mindLoad, isNull);
    });

    test('a workout that did not happen carries no ratings', () {
      final f = fields(done: false);
      expect(f['done'], isFalse);
      for (final k in [
        'bodyLoad',
        'mindLoad',
        'energyStart',
        'energyEnd',
        'experience',
      ]) {
        expect(f.containsKey(k), isFalse, reason: k);
      }
      final v = view(f);
      expect(v.done, isFalse);
      expect(v.answered, isFalse);
    });

    test('a record without "done" is a workout that happened', () {
      final v = WorkoutLogView(
        SyncRecord(
          id: 'x',
          kind: kindWorkoutLog,
        ).edit({'bodyLoad': 3}, ts: 1, dev: 'A'),
      );
      expect(v.done, isTrue);
    });

    test('out-of-range values are refused, the texts are cut', () {
      for (final bad in [0, 6, -1]) {
        expect(
          () => fields(bodyLoad: bad),
          throwsArgumentError,
          reason: '$bad',
        );
        expect(() => fields(experience: bad), throwsArgumentError);
      }
      expect(() => fields(minutes: 0), throwsArgumentError);
      expect(() => fields(minutes: 24 * 60 + 1), throwsArgumentError);
      final f = fields(title: 'A' * 200, note: 'b' * 300);
      expect((f['title'] as String).length, 80);
      expect((f['note'] as String).length, 120);
    });

    test('values that are out of range in a record are not answers', () {
      final v = WorkoutLogView(
        SyncRecord(id: 'x', kind: kindWorkoutLog).edit(
          {'bodyLoad': 9, 'mindLoad': 'sok', 'minutes': 100000},
          ts: 1,
          dev: 'A',
        ),
      );
      expect((v.bodyLoad, v.mindLoad, v.minutes), (null, null, null));
    });
  });

  group('the id', () {
    test('an event and the start of its occurrence', () {
      expect(
        workoutLogId('3f2a-9c1b', DateTime.utc(2026, 5, 5, 18, 5)),
        '3f2a-9c1b-202605051805',
      );
    });

    test('a recurring event has one feedback per day', () {
      final a = workoutLogId('s1', DateTime.utc(2026, 5, 5, 18));
      final b = workoutLogId('s1', DateTime.utc(2026, 5, 6, 18));
      expect(a, isNot(b));
      expect(a, workoutLogId('s1', DateTime.utc(2026, 5, 5, 18)));
    });

    test('only characters that are safe in a Drive file name', () {
      final id = workoutLogId('a/b c:d@é', DateTime.utc(2026, 1, 2, 3, 4));
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id), isTrue, reason: id);
      expect(id.length, lessThanOrEqualTo(64 + 13));
      expect(workoutLogId('x' * 200, DateTime.utc(2026, 1, 2)).length, 77);
    });
  });

  group('the Drive file name', () {
    test('the new kind is synced and its name is recognised', () {
      expect(syncedKinds, contains(kindWorkoutLog));
      final name = recordFileName(kindWorkoutLog, 'e1-202605051800');
      expect(name, 'workoutlog-e1-202605051800.json');
      final m = recordFileNamePattern.firstMatch(name)!;
      expect((m[1], m[2]), (kindWorkoutLog, 'e1-202605051800'));
      expect(safeRecordFileNamePattern.hasMatch(name), isTrue);
    });

    test('every kind has its name recognised, and only those', () {
      for (final k in syncedKinds) {
        final m = recordFileNamePattern.firstMatch(
          recordFileName(k, '2026-05-05'),
        );
        expect(m?[1], k);
        expect(m?[2], '2026-05-05');
      }
      for (final bad in [
        'fin-peers.json',
        'unknown-1.json',
        'workoutlog.json',
        'task-1.txt',
        'xtask-1.json',
        'workoutlogs-1.json',
      ]) {
        expect(recordFileNamePattern.hasMatch(bad), isFalse, reason: bad);
        expect(safeRecordFileNamePattern.hasMatch(bad), isFalse, reason: bad);
      }
    });

    test('the strict form refuses an id that is not safe', () {
      expect(recordFileNamePattern.hasMatch('task-a b.json'), isTrue);
      expect(safeRecordFileNamePattern.hasMatch('task-a b.json'), isFalse);
      expect(safeRecordFileNamePattern.hasMatch('task-a/b.json'), isFalse);
    });
  });

  group('two devices', () {
    test('answers of different questions are both kept', () {
      final base = SyncRecord(id: 'e1-202605051800', kind: kindWorkoutLog);
      final phone = base.edit(
        fields(
          mindLoad: null,
          energyStart: null,
          energyEnd: null,
          experience: null,
        ),
        ts: 10,
        dev: 'phone',
      );
      final pc = base.edit(
        fields(
          bodyLoad: null,
          mindLoad: 3,
          energyStart: 4,
          energyEnd: 3,
          experience: 5,
        ),
        ts: 20,
        dev: 'pc',
      );
      final merged = phone.merge(pc);
      expect(merged.sameAs(pc.merge(phone)), isTrue);
      final v = WorkoutLogView(merged);
      expect(v.bodyLoad, 4); // the phone's answer
      expect(
        (v.mindLoad, v.energyStart, v.energyEnd, v.experience),
        (3, 4, 3, 5),
      );
    });

    test('the file survives the trip as JSON', () {
      final rec = SyncRecord(
        id: 'e1-202605051800',
        kind: kindWorkoutLog,
      ).edit(fields(), ts: 5, dev: 'A');
      final back = SyncRecord.decode(rec.encode());
      expect(back.kind, kindWorkoutLog);
      expect(WorkoutLogView(back).bodyLoad, 4);
    });
  });
}
