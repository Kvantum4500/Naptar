import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

TaskView task(
  String id, {
  Object? parent,
  Object? pos,
  Object? repeat,
  bool deleted = false,
  String? title,
}) => TaskView(
  SyncRecord(id: id, kind: kindTask).edit(
    {
      'title': title ?? id,
      'parent': parent,
      'pos': pos,
      'repeat': repeat,
      'deleted': deleted,
    },
    ts: 1,
    dev: 'd',
  ),
);

List<String> ids(Iterable<TaskView> l) => [for (final t in l) t.id];

DateTime d(int y, int m, int day) => floating(y, m, day);

void main() {
  group('the fields of a task', () {
    test('the parent, the position and the rule are read as they are', () {
      final t = task('a', parent: ' p ', pos: 3, repeat: ' FREQ=DAILY ');
      expect(t.parentId, 'p');
      expect(t.pos, 3);
      expect(t.repeatRule, 'FREQ=DAILY');
    });

    test('nothing, a blank or a wrong kind of value is no parent, no rule', () {
      for (final v in [null, '', '   ', 5, true]) {
        expect(task('a', parent: v).parentId, isNull, reason: '$v');
        expect(task('a', repeat: v).repeatRule, isNull, reason: '$v');
      }
      expect(task('a', pos: 'x').pos, isNull);
      expect(task('a', pos: double.nan).pos, isNull);
      expect(task('a').pos, isNull);
    });

    test('taskFields carries the three, and nothing by default', () {
      final plain = taskFields(title: 'T');
      expect(plain['parent'], isNull);
      expect(plain['pos'], isNull);
      expect(plain['repeat'], isNull);
      final item = taskFields(title: 'T', parent: ' p ', pos: 7);
      expect(item['parent'], 'p');
      expect(item['pos'], 7);
      final loop = taskFields(
        title: 'T',
        due: d(2026, 11, 16),
        repeat: ' FREQ=WEEKLY;BYDAY=MO ',
      );
      expect(loop['repeat'], 'FREQ=WEEKLY;BYDAY=MO');
    });

    test('a blank parent or a blank rule is stored as none', () {
      final f = taskFields(
        title: 'T',
        due: d(2026, 11, 16),
        parent: '  ',
        repeat: '  ',
      );
      expect(f['parent'], isNull);
      expect(f['repeat'], isNull);
    });

    test('a rule needs a due date: it is anchored on it', () {
      expect(
        () => taskFields(title: 'T', repeat: 'FREQ=DAILY'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Az ismétlődő feladatnak határidő kell.',
          ),
        ),
      );
    });

    test('an item of a checklist does not repeat', () {
      expect(
        () => taskFields(
          title: 'T',
          due: d(2026, 11, 16),
          parent: 'p',
          repeat: 'FREQ=DAILY',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'A részfeladat nem ismétlődhet.',
          ),
        ),
      );
    });

    test('a rule nobody can read is refused', () {
      expect(
        () => taskFields(title: 'T', due: d(2026, 11, 16), repeat: 'sokszor'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Az ismétlődési szabály nem érthető.',
          ),
        ),
      );
    });
  });

  group('checklists', () {
    test('an item is under its task, and not among the tasks', () {
      final all = [task('a'), task('b'), task('i1', parent: 'a')];
      expect(ids(topLevelTasks(all)), ['a', 'b']);
      expect(checklists(all).keys, ['a']);
      expect(ids(checklists(all)['a']!), ['i1']);
    });

    test(
      'the items keep the order they were added in; no position is last',
      () {
        final all = [
          task('a'),
          task('late', parent: 'a', pos: 30),
          task('none', parent: 'a', title: 'Alma'),
          task('first', parent: 'a', pos: 10),
          task('second', parent: 'a', pos: 20),
          task('none2', parent: 'a', title: 'Banán'),
        ];
        expect(ids(checklists(all)['a']!), [
          'first',
          'second',
          'late',
          'none',
          'none2',
        ]);
      },
    );

    test('items of equal position go by title', () {
      final all = [
        task('a'),
        task('x', parent: 'a', pos: 1, title: 'béta'),
        task('y', parent: 'a', pos: 1, title: 'Alfa'),
      ];
      expect(ids(checklists(all)['a']!), ['y', 'x']);
    });

    test('items of equal position go by title, capital letters ignored', () {
      final all = [
        task('a'),
        task('x', parent: 'a', title: 'Barack'),
        task('y', parent: 'a', title: 'alma'),
      ];
      expect(ids(checklists(all)['a']!), ['y', 'x']);
    });

    test('whose task is gone stands on its own (nothing disappears)', () {
      final missing = [task('i', parent: 'nobody')];
      expect(ids(topLevelTasks(missing)), ['i']);
      expect(checklists(missing), isEmpty);
      final gone = [task('a', deleted: true), task('i', parent: 'a')];
      expect(ids(topLevelTasks(gone)), ['a', 'i']);
      expect(checklists(gone), isEmpty);
    });

    test('a deleted item is in nobody\'s list', () {
      final all = [task('a'), task('i', parent: 'a', deleted: true)];
      expect(checklists(all), isEmpty);
    });

    test('a task is not its own item; a loop leaves both on their own', () {
      final self = [task('a', parent: 'a')];
      expect(ids(topLevelTasks(self)), ['a']);
      final loop = [task('a', parent: 'b'), task('b', parent: 'a')];
      expect(ids(topLevelTasks(loop)), ['a', 'b']);
      expect(checklists(loop), isEmpty);
    });

    test('a checklist is one level deep: an item of an item stands alone', () {
      final all = [task('a'), task('b', parent: 'a'), task('c', parent: 'b')];
      expect(ids(topLevelTasks(all)), ['a', 'c']);
      expect(ids(checklists(all)['a']!), ['b']);
      expect(checklists(all).containsKey('b'), isFalse);
    });

    test('a list with no checklists is the list', () {
      final all = [task('a'), task('b')];
      expect(ids(topLevelTasks(all)), ['a', 'b']);
      expect(checklists(all), isEmpty);
    });
  });

  group('the next round of a task that repeats', () {
    NextRound? next(String rule, DateTime due, DateTime today) =>
        nextRound(rule: rule, due: due, today: today);

    test('weekly, done on the day: next week', () {
      expect(
        next('FREQ=WEEKLY;BYDAY=MO', d(2026, 11, 16), d(2026, 11, 16)),
        NextRound(d(2026, 11, 23), 'FREQ=WEEKLY;BYDAY=MO'),
      );
    });

    test('done early, the round after the one due is next, not that one', () {
      expect(
        next('FREQ=WEEKLY;BYDAY=FR', d(2026, 11, 20), d(2026, 11, 16))!.due,
        d(2026, 11, 27),
      );
    });

    test('done late, the rounds missed are dropped', () {
      // due Monday 2 November, done on Tuesday 17th: 9th and 16th are past
      expect(
        next('FREQ=WEEKLY;BYDAY=MO', d(2026, 11, 2), d(2026, 11, 17))!.due,
        d(2026, 11, 23),
      );
      expect(
        next('FREQ=DAILY', d(2026, 11, 10), d(2026, 11, 16))!.due,
        d(2026, 11, 17),
      );
    });

    test('every other week keeps its rhythm', () {
      expect(
        next(
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=SA',
          d(2026, 11, 21),
          d(2026, 11, 21),
        )!.due,
        d(2026, 12, 5),
      );
    });

    test('several days in a week: the next of them', () {
      expect(
        next('FREQ=WEEKLY;BYDAY=TU,TH', d(2026, 11, 17), d(2026, 11, 17))!.due,
        d(2026, 11, 19),
      );
      expect(
        next('FREQ=WEEKLY;BYDAY=TU,TH', d(2026, 11, 19), d(2026, 11, 19))!.due,
        d(2026, 11, 24),
      );
    });

    test('monthly on the 31st skips the months without one', () {
      expect(
        next('FREQ=MONTHLY;BYMONTHDAY=31', d(2027, 1, 31), d(2027, 1, 31))!.due,
        d(2027, 3, 31),
      );
    });

    test('yearly comes back on the same day', () {
      expect(
        next('FREQ=YEARLY', d(2026, 3, 15), d(2026, 3, 15))!.due,
        d(2027, 3, 15),
      );
    });

    test('a count loses the rounds that passed', () {
      // three rounds: 2, 9 and 16 November
      var n = next('FREQ=WEEKLY;COUNT=3', d(2026, 11, 2), d(2026, 11, 2))!;
      expect((n.due, n.rule), (d(2026, 11, 9), 'FREQ=WEEKLY;COUNT=2'));
      n = next(n.rule, n.due, n.due)!;
      expect((n.due, n.rule), (d(2026, 11, 16), 'FREQ=WEEKLY;COUNT=1'));
      expect(next(n.rule, n.due, n.due), isNull, reason: 'that was the last');
    });

    test('a count counts the rounds missed, too', () {
      // five rounds: 2, 9, 16, 23, 30 November; done on the 17th
      final n = next('FREQ=WEEKLY;COUNT=5', d(2026, 11, 2), d(2026, 11, 17))!;
      expect((n.due, n.rule), (d(2026, 11, 23), 'FREQ=WEEKLY;COUNT=2'));
    });

    test('a count that is used up before today ends the series', () {
      expect(
        next('FREQ=WEEKLY;COUNT=2', d(2026, 11, 2), d(2026, 12, 20)),
        isNull,
      );
    });

    test('an end date lets the last round be done, and then it is over', () {
      const rule = 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20261130T235959Z';
      final n = next(rule, d(2026, 11, 23), d(2026, 11, 23))!;
      expect((n.due, n.rule), (d(2026, 11, 30), rule));
      expect(next(rule, d(2026, 11, 30), d(2026, 11, 30)), isNull);
    });

    test('the prefix of a stored rule is tolerated and dropped', () {
      expect(
        next('RRULE:FREQ=DAILY', d(2026, 11, 16), d(2026, 11, 16))!.rule,
        'FREQ=DAILY',
      );
    });

    test('a rule nobody can read has no next round', () {
      expect(next('sokszor', d(2026, 11, 16), d(2026, 11, 16)), isNull);
      expect(next('', d(2026, 11, 16), d(2026, 11, 16)), isNull);
    });

    test('the next round of a round is a round of the same series', () {
      var due = d(2026, 11, 16);
      final seen = <DateTime>[];
      var rule = 'FREQ=WEEKLY;BYDAY=MO;COUNT=4';
      for (var i = 0; i < 6; i++) {
        final n = next(rule, due, due);
        if (n == null) break;
        seen.add(n.due);
        due = n.due;
        rule = n.rule;
      }
      expect(seen, [d(2026, 11, 23), d(2026, 11, 30), d(2026, 12, 7)]);
    });

    test('it says in words how it comes back', () {
      expect(
        describeRepeat('FREQ=WEEKLY;BYDAY=MO', d(2026, 11, 16)),
        'Hetente (hétfő)',
      );
    });
  });
}
