import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/ui/checkin.dart';
import 'package:kvantum_app/ui/day_utils.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

DateTime today() => todayIn(DateTime.now());

void main() {
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late RecordRepository repo;

  Future<void> boot(WidgetTester tester, Widget home) async {
    useSize(tester);
    db = await newDb();
    repo = RecordRepository(db);
    await tester.pumpWidget(app(home, db));
    await tester.pumpAndSettle();
  }

  Future<void> seedTask(
    WidgetTester tester,
    String id,
    String title, {
    DateTime? due,
    bool done = false,
  }) => tester.runAsync(
    () =>
        repo.edit(kindTask, id, taskFields(title: title, due: due, done: done)),
  );

  group('tasks page', () {
    testWidgets('empty state explains how to add one', (tester) async {
      await boot(tester, const TasksPage());
      expect(find.textContaining('Még nincs feladat'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('tasks are grouped: overdue, today, upcoming, no date, done', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      final t = today();
      await seedTask(
        tester,
        'a',
        'Késett',
        due: t.subtract(const Duration(days: 1)),
      );
      await seedTask(tester, 'b', 'Mai', due: t);
      await seedTask(
        tester,
        'c',
        'Jövő heti',
        due: t.add(const Duration(days: 3)),
      );
      await seedTask(tester, 'd', 'Valamikor');
      await seedTask(tester, 'e', 'Kész dolog', done: true);
      await tester.pumpAndSettle();
      expect(find.text('Késésben (1)'), findsOneWidget);
      expect(find.text('Ma (1)'), findsOneWidget);
      expect(find.text('Közelgő (1)'), findsOneWidget);
      expect(find.text('Határidő nélkül (1)'), findsOneWidget);
      expect(find.text('Kész (1)'), findsOneWidget);
      expect(find.text('Késett'), findsOneWidget);
      expect(find.text('Kész dolog'), findsNothing); // collapsed until opened
      await tester.tap(find.text('Kész (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Kész dolog'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('adding a task stores all fields and queues it for upload', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      await tester.tap(find.text('Új feladat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Futás a parkban',
      );
      await tester.tap(find.text('45 perc'));
      await tester.tap(find.text('Magas'));
      await tester.tap(find.text('5'));
      await tester.pump();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();

      expect(find.text('Futás a parkban'), findsOneWidget);
      final all = (await tester.runAsync(() => repo.all(kindTask)))!;
      final t = TaskView(all.single);
      expect(
        (t.title, t.estimateMin, t.priority, t.energyNeed, t.done),
        ('Futás a parkban', 45, 3, 5, false),
      );
      expect((await tester.runAsync(() => repo.dirtyCount())), 1);
      await shutdown(tester, db);
    });

    testWidgets('an empty title and an absurd custom duration are rejected', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      await tester.tap(find.text('Új feladat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Adj meg egy címet'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, 'x');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'vagy percben (egyéb)'),
        '99999',
      );
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('1–1440 perc'), findsOneWidget);
      expect((await tester.runAsync(() => repo.all(kindTask)))!, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('ticking the checkbox completes it and moves it under "Kész"', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      await seedTask(tester, 'a', 'Bevásárlás');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text('Kész (1)'), findsOneWidget);
      expect(find.text('Határidő nélkül (1)'), findsNothing);
      final t = TaskView(
        (await tester.runAsync<SyncRecord?>(() => repo.get(kindTask, 'a')))!,
      );
      expect(t.done, isTrue);
      await shutdown(tester, db);
    });

    testWidgets(
      'editing keeps the done state; deleting hides it at once (tombstone)',
      (tester) async {
        await boot(tester, const TasksPage());
        await seedTask(tester, 'a', 'Régi cím', done: true);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kész (1)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Régi cím'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).first, 'Új cím');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        var t = TaskView(
          (await tester.runAsync<SyncRecord?>(() => repo.get(kindTask, 'a')))!,
        );
        expect((t.title, t.done), ('Új cím', true));

        await tester.tap(find.byTooltip('Törlés'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Biztosan törlöd'), findsNothing);
        expect(find.text('Új cím'), findsNothing);
        t = TaskView(
          (await tester.runAsync<SyncRecord?>(() => repo.get(kindTask, 'a')))!,
        );
        expect(t.deleted, isTrue); // kept as a tombstone so the delete syncs
        await shutdown(tester, db);
      },
    );

    testWidgets('"Visszavonás" brings a deleted task back as it was', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      final t0 = today();
      await seedTask(tester, 'a', 'Fogorvos', due: t0);
      await tester.pumpAndSettle();
      expect(find.text('Fogorvos'), findsOneWidget);
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      expect(find.text('Fogorvos'), findsNothing);
      expect(find.text('Feladat törölve'), findsOneWidget);

      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
      expect(find.text('Fogorvos'), findsOneWidget);
      final back = TaskView(
        (await tester.runAsync<SyncRecord?>(() => repo.get(kindTask, 'a')))!,
      );
      expect(back.deleted, isFalse);
      expect(back.title, 'Fogorvos');
      expect(back.due, t0);
      await shutdown(tester, db);
    });

    testWidgets('a deleted task stays deleted when the bar runs out', (
      tester,
    ) async {
      await boot(tester, const TasksPage());
      await seedTask(tester, 'a', 'Fogorvos');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Visszavonás'), findsNothing);
      expect(find.text('Fogorvos'), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('check-in', () {
    testWidgets(
      'banner asks, the dialog saves today, the banner then shows the answers',
      (tester) async {
        await boot(tester, const Scaffold(body: CheckInBanner()));
        expect(find.textContaining('Hogy vagy ma?'), findsOneWidget);
        await tester.tap(find.text('Kitöltöm'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('physical-4')));
        await tester.tap(find.byKey(const Key('mental-2')));
        await tester.tap(find.byKey(const Key('mood-3')));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'fáradt vagyok');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('fizikai 4 · mentális 2 · hangulat 3 · alvás –'),
          findsOneWidget,
        );
        final rec = (await tester.runAsync<SyncRecord?>(
          () => repo.get(kindCheckIn, checkInId(today())),
        ))!;
        final c = CheckInView(rec);
        expect(
          (c.physical, c.mental, c.mood, c.sleep, c.note),
          (4, 2, 3, null, 'fáradt vagyok'),
        );
        expect(
          rec.fields.containsKey('sleep'),
          isFalse,
        ); // unanswered stays unwritten
        await shutdown(tester, db);
      },
    );

    testWidgets('saving with no answer at all is refused', (tester) async {
      await boot(tester, const Scaffold(body: CheckInBanner()));
      await tester.tap(find.text('Kitöltöm'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Válaszolj legalább egy kérdésre.'), findsOneWidget);
      expect((await tester.runAsync(() => repo.all(kindCheckIn)))!, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('editing changes one answer without erasing the others', (
      tester,
    ) async {
      await boot(tester, const Scaffold(body: CheckInBanner()));
      await tester.runAsync(
        () => repo.edit(
          kindCheckIn,
          checkInId(today()),
          checkInFields(physical: 4, sleep: 5),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Módosít'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('physical-4')),
      ); // tapping the chosen value keeps it
      await tester.tap(find.byKey(const Key('mood-2')));
      await tester.pump();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final c = CheckInView(
        (await tester.runAsync<SyncRecord?>(
          () => repo.get(kindCheckIn, checkInId(today())),
        ))!,
      );
      expect((c.physical, c.mood, c.sleep), (4, 2, 5));
      await shutdown(tester, db);
    });

    testWidgets('history lists previous days, newest first', (tester) async {
      await boot(tester, const CheckInHistoryPage());
      expect(find.text('Még nincs check-in.'), findsOneWidget);
      // one write per runAsync, pumping in between: the widget's live query
      // runs in the fake-async zone and would block a second write otherwise
      await tester.runAsync(
        () => repo.edit(
          kindCheckIn,
          '2026-11-02',
          checkInFields(mood: 2, note: 'rossz nap'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => repo.edit(kindCheckIn, '2026-11-04', checkInFields(mood: 5)),
      );
      await tester.pumpAndSettle();
      expect(find.text('rossz nap'), findsOneWidget);
      final first = tester.getTopLeft(find.textContaining('nov. 4.')).dy;
      final second = tester.getTopLeft(find.textContaining('nov. 2.')).dy;
      expect(first, lessThan(second));
      await shutdown(tester, db);
    });
  });
}
