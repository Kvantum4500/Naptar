import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/data/task_ops.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

DateTime d(int y, int m, int day) => floating(y, m, day);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late RecordRepository records;
  late TaskOps ops;

  setUp(() async {
    db = await newDb();
    records = RecordRepository(db);
    ops = TaskOps(records);
  });
  tearDown(() => db.close());

  Future<TaskView> seed(
    String id,
    String title, {
    DateTime? due,
    String? repeat,
    String? parent,
    int? pos,
    bool done = false,
  }) async {
    final r = await records.edit(
      kindTask,
      id,
      taskFields(
        title: title,
        due: due,
        repeat: repeat,
        parent: parent,
        pos: pos,
        done: done,
      ),
    );
    return TaskView(r);
  }

  Future<TaskView> reload(String id) async =>
      TaskView((await records.get(kindTask, id))!);

  group('ticking off', () {
    test('an ordinary task is done, and the tick can be taken back', () async {
      final t = await seed('a', 'Számla', due: d(2026, 11, 20));
      final r = await ops.complete(t, today: d(2026, 11, 16));
      expect(r.comesBack, isNull);
      expect((await reload('a')).done, isTrue);
      await r.undo();
      expect((await reload('a')).done, isFalse);
    });

    test('a task that repeats comes back with the next due date', () async {
      final t = await seed(
        'a',
        'Takarítás',
        due: d(2026, 11, 16),
        repeat: 'FREQ=WEEKLY;BYDAY=MO',
      );
      final r = await ops.complete(t, today: d(2026, 11, 16));
      expect(r.comesBack, d(2026, 11, 23));
      final after = await reload('a');
      expect(after.done, isFalse);
      expect(after.due, d(2026, 11, 23));
      expect(after.repeatRule, 'FREQ=WEEKLY;BYDAY=MO');
    });

    test('taking it back puts the due date and the rule back', () async {
      final t = await seed(
        'a',
        'Takarítás',
        due: d(2026, 11, 16),
        repeat: 'FREQ=WEEKLY;COUNT=3;BYDAY=MO',
      );
      final r = await ops.complete(t, today: d(2026, 11, 16));
      expect((await reload('a')).repeatRule, 'FREQ=WEEKLY;COUNT=2;BYDAY=MO');
      await r.undo();
      final back = await reload('a');
      expect(back.due, d(2026, 11, 16));
      expect(back.repeatRule, 'FREQ=WEEKLY;COUNT=3;BYDAY=MO');
      expect(back.done, isFalse);
    });

    test('a task done late does not come back overdue', () async {
      final t = await seed(
        'a',
        'Takarítás',
        due: d(2026, 11, 2),
        repeat: 'FREQ=WEEKLY;BYDAY=MO',
      );
      final r = await ops.complete(t, today: d(2026, 11, 17));
      expect(r.comesBack, d(2026, 11, 23));
    });

    test('the checklist starts over, and the undo ticks it again', () async {
      final t = await seed(
        'a',
        'Takarítás',
        due: d(2026, 11, 16),
        repeat: 'FREQ=DAILY',
      );
      final one = await seed('i1', 'Por', parent: 'a', pos: 1, done: true);
      final two = await seed('i2', 'Padló', parent: 'a', pos: 2);
      final r = await ops.complete(
        t,
        today: d(2026, 11, 16),
        items: [one, two],
      );
      expect((await reload('i1')).done, isFalse);
      expect((await reload('i2')).done, isFalse);
      await r.undo();
      expect((await reload('i1')).done, isTrue);
      expect((await reload('i2')).done, isFalse);
    });

    test('the last round of a series is done for good', () async {
      final t = await seed(
        'a',
        'Utolsó',
        due: d(2026, 11, 16),
        repeat: 'FREQ=WEEKLY;COUNT=1;BYDAY=MO',
      );
      final r = await ops.complete(t, today: d(2026, 11, 16));
      expect(r.comesBack, isNull);
      final after = await reload('a');
      expect(after.done, isTrue);
      expect(after.due, d(2026, 11, 16));
      await r.undo();
      expect((await reload('a')).done, isFalse);
    });

    test('a task whose rule cannot be read is done like any other', () async {
      await records.edit(kindTask, 'a', {
        'title': 'Régi',
        'due': '2026-11-16',
        'repeat': 'sokszor',
        'done': false,
      });
      final r = await ops.complete(await reload('a'), today: d(2026, 11, 16));
      expect(r.comesBack, isNull);
      expect((await reload('a')).done, isTrue);
    });

    test('an item is ticked and unticked on its own', () async {
      await seed('a', 'Fő');
      final item = await seed('i', 'Rész', parent: 'a', pos: 1);
      await ops.setDone(item, true);
      expect((await reload('i')).done, isTrue);
      await ops.setDone(item, false);
      expect((await reload('i')).done, isFalse);
    });
  });

  group('the checklist', () {
    test('an item remembers its task, its place and its tick', () async {
      await seed('a', 'Fő');
      await ops.addItem('a', ' Első ', pos: 5, id: 'i1');
      await ops.addItem('a', 'Második', pos: 6, id: 'i2', done: true);
      final i1 = await reload('i1');
      expect((i1.title, i1.parentId, i1.pos, i1.done), ('Első', 'a', 5, false));
      expect((await reload('i2')).done, isTrue);
    });

    test('an item is renamed without its other fields', () async {
      await seed('a', 'Fő');
      final item = await seed('i', 'Rész', parent: 'a', pos: 1, done: true);
      await ops.renameItem(item, '  Új név ');
      final after = await reload('i');
      expect(
        (after.title, after.parentId, after.pos, after.done),
        ('Új név', 'a', 1, true),
      );
    });

    test(
      'deleting a task deletes its checklist, and undoing brings all back',
      () async {
        final t = await seed('a', 'Fő');
        final i1 = await seed('i1', 'Egy', parent: 'a', pos: 1);
        final i2 = await seed('i2', 'Kettő', parent: 'a', pos: 2);
        final ids = await ops.delete(t, items: [i1, i2]);
        expect(ids, ['a', 'i1', 'i2']);
        for (final id in ids) {
          expect(
            (await records.get(kindTask, id))!.deleted,
            isTrue,
            reason: id,
          );
        }
        expect(await ops.undelete(ids), isTrue);
        for (final id in ids) {
          expect(
            (await records.get(kindTask, id))!.deleted,
            isFalse,
            reason: id,
          );
        }
      },
    );

    test('undoing a deletion that is gone has nothing to bring back', () async {
      expect(await ops.undelete(['nincs']), isFalse);
    });
  });

  group('the lists', () {
    test('the tasks do not include the items; the checklists do', () async {
      final c = ProviderContainer(overrides: baseOverrides(db));
      addTearDown(c.dispose);
      await seed('a', 'Fő');
      await seed('b', 'Másik');
      await seed('i1', 'Rész', parent: 'a', pos: 1);
      await seed('orphan', 'Árva', parent: 'nincs-ilyen');
      // (a provider that nobody listens to does not run)
      c.listen(tasksProvider, (_, _) {});
      c.listen(checklistsProvider, (_, _) {});
      final tasks = await c.read(tasksProvider.future);
      expect([for (final t in tasks) t.id]..sort(), ['a', 'b', 'orphan']);
      final lists = await c.read(checklistsProvider.future);
      expect(lists.keys, ['a']);
      expect([for (final i in lists['a']!) i.id], ['i1']);
    });
  });

  group('on the page', () {
    Future<void> boot(WidgetTester tester) async {
      useSize(tester);
      await tester.pumpWidget(app(const TasksPage(), db));
      await tester.pumpAndSettle();
    }

    Future<T> run<T>(WidgetTester tester, Future<T> Function() f) async =>
        (await tester.runAsync(f)) as T;

    testWidgets('the items stand under their task, and are not tasks', (
      tester,
    ) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Költözés'));
      await run(
        tester,
        () => seed('i1', 'Dobozok', parent: 'a', pos: 1, done: true),
      );
      await run(tester, () => seed('i2', 'Autó', parent: 'a', pos: 2));
      await run(tester, () => seed('i3', 'Takarítás', parent: 'a', pos: 3));
      await tester.pumpAndSettle();
      expect(find.text('Határidő nélkül (1)'), findsOneWidget);
      expect(find.textContaining('1/3 részfeladat'), findsOneWidget);
      expect(find.byKey(const Key('item-i1')), findsOneWidget);
      // in the order they were added
      expect(
        tester.getTopLeft(find.byKey(const Key('item-i1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('item-i2'))).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('item-i2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('item-i3'))).dy),
      );
      await shutdown(tester, db);
    });

    testWidgets('ticking an item counts it', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Költözés'));
      await run(tester, () => seed('i1', 'Dobozok', parent: 'a', pos: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('0/1 részfeladat'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('item-i1')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('i1'))).done, isTrue);
      expect(find.textContaining('1/1 részfeladat'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an item that is ticked can be unticked again', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Költözés'));
      await run(
        tester,
        () => seed('i1', 'Dobozok', parent: 'a', pos: 1, done: true),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1/1 részfeladat'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('item-i1')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('i1'))).done, isFalse);
      expect(find.textContaining('0/1 részfeladat'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the items of a task that is done are tucked away', (
      tester,
    ) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Kész fő', done: true));
      await run(tester, () => seed('i1', 'Rész', parent: 'a', pos: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kész (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Kész fő'), findsOneWidget);
      expect(find.byKey(const Key('item-i1')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a task that repeats comes back, and the bar can undo it', (
      tester,
    ) async {
      await boot(tester);
      final today = todayOf(tester);
      final rule = 'FREQ=DAILY';
      await run(tester, () => seed('a', 'Gyógyszer', due: today, repeat: rule));
      await tester.pumpAndSettle();
      expect(find.text('Ma (1)'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('task-a')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      final after = await run(tester, () => reload('a'));
      expect(after.done, isFalse);
      expect(after.due, today.add(const Duration(days: 1)));
      expect(find.textContaining('Kész – következő:'), findsOneWidget);
      expect(find.text('Közelgő (1)'), findsOneWidget);

      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('a'))).due, today);
      expect(find.text('Ma (1)'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('ticking a task that repeats starts its checklist over', (
      tester,
    ) async {
      await boot(tester);
      final today = todayOf(tester);
      await run(
        tester,
        () => seed('a', 'Takarítás', due: today, repeat: 'FREQ=DAILY'),
      );
      await run(
        tester,
        () => seed('i1', 'Ablak', parent: 'a', pos: 1, done: true),
      );
      await run(
        tester,
        () => seed('i2', 'Padló', parent: 'a', pos: 2, done: true),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2/2 részfeladat'), findsOneWidget);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const Key('task-a')),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('i1'))).done, isFalse);
      expect((await run(tester, () => reload('i2'))).done, isFalse);
      expect(find.textContaining('0/2 részfeladat'), findsOneWidget);

      // the bar takes the round back, and the items are ticked again
      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('i1'))).done, isTrue);
      expect((await run(tester, () => reload('i2'))).done, isTrue);
      await shutdown(tester, db);
    });

    testWidgets('unticking a task that is done opens it again', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Kész feladat', done: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kész (1)'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('task-a')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('a'))).done, isFalse);
      await shutdown(tester, db);
    });

    testWidgets('an ordinary task says nothing: the tick is its own undo', (
      tester,
    ) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Egyszeri'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('task-a')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visszavonás'), findsNothing);
      expect((await run(tester, () => reload('a'))).done, isTrue);
      await shutdown(tester, db);
    });

    testWidgets('how a task repeats is told under its title', (tester) async {
      await boot(tester);
      await run(
        tester,
        () => seed(
          'a',
          'Takarítás',
          due: todayOf(tester),
          repeat:
              'FREQ=WEEKLY;BYDAY=${const ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'][todayOf(tester).weekday - 1]}',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Hetente ('), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'deleting a task takes its checklist along, and undoing brings it back',
      (tester) async {
        await boot(tester);
        await run(tester, () => seed('a', 'Költözés'));
        await run(tester, () => seed('i1', 'Dobozok', parent: 'a', pos: 1));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('task-a')),
            matching: find.byTooltip('Törlés'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Feladat és részfeladatai törölve'), findsOneWidget);
        expect(
          (await run(tester, () => records.get(kindTask, 'i1')))!.deleted,
          isTrue,
        );
        expect(find.text('Költözés'), findsNothing);

        await tester.tap(find.text('Visszavonás'));
        await tester.pumpAndSettle();
        expect(find.text('Költözés'), findsOneWidget);
        expect(find.byKey(const Key('item-i1')), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('a task without a checklist deletes as before', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Egyedül'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      expect(find.text('Feladat törölve'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('the editor', () {
    Future<void> boot(WidgetTester tester, {DateTime? clock}) async {
      useSize(tester, size: const Size(900, 1600));
      await tester.pumpWidget(
        app(
          const TasksPage(),
          db,
          extra: [
            if (clock != null) appClockProvider.overrideWithValue(() => clock),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<T> run<T>(WidgetTester tester, Future<T> Function() f) async =>
        (await tester.runAsync(f)) as T;

    Future<void> openTask(WidgetTester tester, String title) async {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    Future<void> scrollTo(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    testWidgets('a new task is saved with the items typed under it', (
      tester,
    ) async {
      final clock = DateTime.utc(2030, 5, 6, 7, 8, 9);
      await boot(tester, clock: clock);
      await tester.tap(find.text('Új feladat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Költözés');
      final field = find.widgetWithText(TextField, 'Új részfeladat');
      await scrollTo(tester, field);
      await tester.enterText(field, 'Dobozok');
      await tester.tap(find.byTooltip('Részfeladat hozzáadása'));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Autó');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // typed, not added yet: it is added by the save
      await tester.enterText(field, 'Takarítás');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();

      final all = await run(tester, () => records.all(kindTask));
      final views = [for (final r in all) TaskView(r)];
      final parent = views.singleWhere((t) => t.title == 'Költözés');
      expect(parent.parentId, isNull);
      final items = checklists(views)[parent.id]!;
      expect(
        [for (final i in items) i.title],
        ['Dobozok', 'Autó', 'Takarítás'],
      );
      expect(items.every((i) => !i.done), isTrue);
      // (the places of the items are counted from the clock of the app)
      expect(
        [for (final i in items) i.pos],
        [for (var n = 0; n < 3; n++) clock.millisecondsSinceEpoch + n],
      );
      expect(await run(tester, () => records.dirtyCount()), 4);
      await shutdown(tester, db);
    });

    testWidgets('the items are renamed, ticked, removed; a new one is added', (
      tester,
    ) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Költözés'));
      await run(tester, () => seed('i1', 'Dobozok', parent: 'a', pos: 1));
      await run(tester, () => seed('i2', 'Autó', parent: 'a', pos: 2));
      await run(tester, () => seed('i3', 'Takarítás', parent: 'a', pos: 3));
      await tester.pumpAndSettle();
      await openTask(tester, 'Költözés');

      // rename the first, tick the second, remove the third
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Dobozok'),
        'Dobozok vétele',
      );
      final rows = find.byTooltip('Részfeladat törlése');
      expect(rows, findsNWidgets(3));
      await tester.tap(
        find
            .descendant(
              of: find.ancestor(
                of: find.widgetWithText(TextFormField, 'Autó'),
                matching: find.byType(Row),
              ),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      await tester.tap(rows.last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Takarítás'), findsNothing);
      final field = find.widgetWithText(TextField, 'Új részfeladat');
      await scrollTo(tester, field);
      await tester.enterText(field, 'Kulcsok');
      await tester.tap(find.byTooltip('Részfeladat hozzáadása'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();

      expect((await run(tester, () => reload('i1'))).title, 'Dobozok vétele');
      expect((await run(tester, () => reload('i2'))).done, isTrue);
      expect(
        (await run(tester, () => records.get(kindTask, 'i3')))!.deleted,
        isTrue,
      );
      final views = [
        for (final r in await run(tester, () => records.all(kindTask)))
          TaskView(r),
      ].where((t) => !t.deleted).toList();
      expect(
        [for (final i in checklists(views)['a']!) i.title],
        ['Dobozok vétele', 'Autó', 'Kulcsok'],
      );
      await shutdown(tester, db);
    });

    testWidgets('cancelling leaves the checklist as it was', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Költözés'));
      await run(tester, () => seed('i1', 'Dobozok', parent: 'a', pos: 1));
      await tester.pumpAndSettle();
      await openTask(tester, 'Költözés');
      await tester.tap(find.byTooltip('Részfeladat törlése'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(
        (await run(tester, () => records.get(kindTask, 'i1')))!.deleted,
        isFalse,
      );
      await shutdown(tester, db);
    });

    testWidgets('without a due date there is no repeat to choose', (
      tester,
    ) async {
      await boot(tester);
      await tester.tap(find.text('Új feladat'));
      await tester.pumpAndSettle();
      expect(find.text('Ismétlődéshez adj meg határidőt.'), findsOneWidget);
      expect(find.byType(RepeatEditorProbe), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a task with a due date can be made to repeat', (tester) async {
      await boot(tester);
      await run(tester, () => seed('a', 'Gyógyszer', due: d(2026, 11, 16)));
      await tester.pumpAndSettle();
      await openTask(tester, 'Gyógyszer');
      expect(find.text('Ismétlődéshez adj meg határidőt.'), findsNothing);
      await tester.tap(find.text('Nem ismétlődik'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Naponta').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final t = await run(tester, () => reload('a'));
      expect(t.repeatRule, 'FREQ=DAILY');
      expect(t.due, d(2026, 11, 16));
      await shutdown(tester, db);
    });

    testWidgets('clearing the due date ends the repeat', (tester) async {
      await boot(tester);
      await run(
        tester,
        () =>
            seed('a', 'Gyógyszer', due: d(2026, 11, 16), repeat: 'FREQ=DAILY'),
      );
      await tester.pumpAndSettle();
      await openTask(tester, 'Gyógyszer');
      await tester.tap(find.byTooltip('Határidő törlése'));
      await tester.pumpAndSettle();
      expect(find.text('Ismétlődéshez adj meg határidőt.'), findsOneWidget);
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final t = await run(tester, () => reload('a'));
      expect(t.repeatRule, isNull);
      expect(t.due, isNull);
      await shutdown(tester, db);
    });

    testWidgets('a date set again after clearing it starts without a rule', (
      tester,
    ) async {
      await boot(tester);
      await run(
        tester,
        () => seed(
          'a',
          'Gyógyszer',
          due: d(2026, 11, 16),
          repeat: 'FREQ=WEEKLY;BYDAY=MO',
        ),
      );
      await tester.pumpAndSettle();
      await openTask(tester, 'Gyógyszer');
      await tester.tap(find.byTooltip('Határidő törlése'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Határidő'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // the old rule is not back: the new date is a new start
      expect(find.text('Nem ismétlődik'), findsOneWidget);
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final t = await run(tester, () => reload('a'));
      expect(t.due, isNotNull);
      expect(t.repeatRule, isNull);
      await shutdown(tester, db);
    });

    testWidgets('a rule the editor cannot show is kept, and said so', (
      tester,
    ) async {
      await boot(tester);
      const odd = 'FREQ=WEEKLY;BYDAY=MO;BYHOUR=9';
      await run(
        tester,
        () => records.edit(kindTask, 'a', {
          'title': 'Különös',
          'due': '2026-11-16',
          'repeat': odd,
          'done': false,
        }),
      );
      await tester.pumpAndSettle();
      await openTask(tester, 'Különös');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Egyedi ismétlődés'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect((await run(tester, () => reload('a'))).repeatRule, odd);
      await shutdown(tester, db);
    });

    testWidgets('editing a repeating task keeps its rule and its place', (
      tester,
    ) async {
      await boot(tester);
      await run(
        tester,
        () => seed(
          'a',
          'Heti',
          due: d(2026, 11, 16),
          repeat: 'FREQ=WEEKLY;BYDAY=MO',
        ),
      );
      await tester.pumpAndSettle();
      await openTask(tester, 'Heti');
      await tester.enterText(
        find.byType(TextFormField).first,
        'Heti takarítás',
      );
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final t = await run(tester, () => reload('a'));
      expect(
        (t.title, t.repeatRule, t.due),
        ('Heti takarítás', 'FREQ=WEEKLY;BYDAY=MO', d(2026, 11, 16)),
      );
      await shutdown(tester, db);
    });

    testWidgets('a task that is an orphan keeps its link when edited', (
      tester,
    ) async {
      await boot(tester);
      await run(tester, () => seed('o', 'Árva', parent: 'nincs-ilyen', pos: 4));
      await tester.pumpAndSettle();
      await openTask(tester, 'Árva');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final t = await run(tester, () => reload('o'));
      expect((t.parentId, t.pos), ('nincs-ilyen', 4));
      await shutdown(tester, db);
    });
  });
}

/// The widget the repeat section is made of (its absence is what is tested).
typedef RepeatEditorProbe = DropdownButtonFormField<RepeatFreq?>;

DateTime todayOf(WidgetTester tester) {
  final c = ProviderScope.containerOf(tester.element(find.byType(TasksPage)));
  return c.read(todayProvider);
}
