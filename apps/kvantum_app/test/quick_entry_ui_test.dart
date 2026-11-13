import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/quick_entry_dialog.dart';
import 'package:kvantum_app/ui/quick_entry_ops.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// Thursday 2026-11-12, 10:00 in Budapest.
DateTime clock() => DateTime.utc(2026, 11, 12, 9);
final now = floating(2026, 11, 12, 10);
final today = floating(2026, 11, 12);

QuickEntry parse(String line) => parseQuickEntry(line, now: now);

class _Sync extends SyncController {
  int requests = 0;
  @override
  SyncState build() => SyncState(
    configured: true,
    signedIn: true,
    lastSync: DateTime(2026, 11, 12),
  );
  @override
  Future<void> syncNow({bool manual = false}) async {}
  @override
  void requestSync() => requests++;
}

/// A calendar that cannot write.
class _BrokenRepo extends EventRepository {
  _BrokenRepo(super.db);
  @override
  Future<void> saveLocal(CalEvent e) async => throw StateError('lemez tele');
}

/// A save that fails the way the database might.
class _FailingOps extends QuickEntryOps {
  _FailingOps(super.ref, this.error);
  final Object error;
  @override
  Future<QuickCreated> create(QuickEntry entry) => Future.error(error);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('what an entry says about its time', () {
    String when(QuickEntry e) => quickWhen(e, today);

    test('an event with a time: the day, then from – to', () {
      expect(
        when(parse('holnap 18:00 edzés')),
        'Holnap · péntek, nov. 13. · 18:00–19:00',
      );
      expect(
        when(parse('ma 9:30-10:15 fogorvos')),
        'Ma · csütörtök, nov. 12. · 09:30–10:15',
      );
    });

    test('a day further away has no "Holnap" in front of it', () {
      expect(
        when(parse('nov. 20. 14:00 ebéd')),
        'péntek, nov. 20. · 14:00–15:00',
      );
    });

    test('an all-day event says so', () {
      expect(when(parse('nov. 20. szülinap')), 'péntek, nov. 20. · egész nap');
    });

    test('an event over midnight says it goes on the next day', () {
      expect(
        when(parse('holnap 22:00-tól 6:00-ig műszak')),
        'Holnap · péntek, nov. 13. · 22:00–06:00 (másnap)',
      );
    });

    test('a task has a deadline, or none', () {
      expect(
        when(parse('péntekig számla befizetése')),
        'Határidő: holnap · péntek, nov. 13.',
      );
      expect(when(parse('tej vásárlása')), 'Határidő nélkül');
      expect(when(parse('nov. 20-ig jelentés')), 'Határidő: péntek, nov. 20.');
    });

    test('another year is named', () {
      final e = QuickEntry(
        kind: QuickKind.event,
        title: 'Tárgyalás',
        date: floating(2027, 1, 5),
        startMinute: 600,
        durationMinutes: 60,
      );
      expect(when(e), '2027. jan. 5., kedd · 10:00–11:00');
    });

    test('an event with no day has no time', () {
      expect(
        when(parse('tej vásárlása').withKind(QuickKind.event)),
        'Nincs időpont',
      );
    });
  });

  group('making them', () {
    late AppDatabase db;
    late EventRepository events;
    late RecordRepository records;
    late ProviderContainer c;

    setUp(() async {
      db = await newDb();
      events = EventRepository(db);
      records = RecordRepository(db);
      c = ProviderContainer(
        overrides: [
          ...baseOverrides(db),
          appClockProvider.overrideWithValue(clock),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
        ],
      );
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<QuickCreated> make(String line) =>
        c.read(quickEntryOpsProvider).create(parse(line));

    group('an event', () {
      test('is stored with its day, time and zone', () async {
        final made = await make('holnap 18:00 edzés');
        final e = (await events.byId(made.id))!;
        expect(made.kind, QuickKind.event);
        expect(e.title, 'Edzés');
        expect(e.start, floating(2026, 11, 13, 18));
        expect(e.end, floating(2026, 11, 13, 19));
        expect(e.tzid, 'Europe/Budapest');
        expect(e.allDay, isFalse);
        expect(e.rrule, isNull);
        expect(e.calendarId, kNaptarCalendar);
        expect(
          made.message,
          'Esemény felvéve: Edzés – Holnap · péntek, nov. 13. · 18:00–19:00',
        );
      });

      test('with a rule repeats', () async {
        final made = await make('minden hétfőn 7:00 futás');
        final e = (await events.byId(made.id))!;
        expect(e.rrule, 'FREQ=WEEKLY;BYDAY=MO');
        expect(e.start, floating(2026, 11, 16, 7));
      });

      test('without a time is an all-day event, ending the next day', () async {
        final made = await make('nov. 20. szülinap');
        final e = (await events.byId(made.id))!;
        expect(e.allDay, isTrue);
        expect(e.tzid, isNull);
        expect(e.start, floating(2026, 11, 20));
        expect(e.end, floating(2026, 11, 21));
      });

      test('stays off Google while it can be taken back', () async {
        final made = await make('holnap 18:00 edzés');
        final hold = c.read(syncHoldProvider);
        expect(hold.isHeld(made.id), isTrue);
        expect(made.hold, isNotNull);
        made.hold!.release();
        expect(hold.isHeld(made.id), isFalse);
      });

      test('is taken back, and is gone', () async {
        final made = await make('holnap 18:00 edzés');
        expect(await made.undo(), isTrue);
        expect(await events.byId(made.id), isNull);
        expect(await events.all(), isEmpty);
      });

      test('is not taken back once it was changed', () async {
        final made = await make('holnap 18:00 edzés');
        final e = (await events.byId(made.id))!;
        await events.saveLocal(e.copyWith(title: 'Más', version: 2));
        expect(await made.undo(), isFalse);
        expect((await events.byId(made.id))!.title, 'Más');
      });
    });

    group('a task', () {
      test('turned into an event is an all-day event on its day', () async {
        final entry = parse('péntekig számla befizetése')
            .withKind(QuickKind.event);
        final made = await c.read(quickEntryOpsProvider).create(entry);
        final e = (await events.byId(made.id))!;
        expect(made.kind, QuickKind.event);
        expect(e.allDay, isTrue);
        expect(e.tzid, isNull);
        expect(e.start, floating(2026, 11, 13));
        expect(e.end, floating(2026, 11, 14));
        expect(await records.all(kindTask), isEmpty);
      });

      test('is stored with its deadline', () async {
        final made = await make('péntekig számla befizetése');
        final t = TaskView((await records.get(kindTask, made.id))!);
        expect(made.kind, QuickKind.task);
        expect(t.title, 'Számla befizetése');
        expect(t.due, floating(2026, 11, 13));
        expect(t.repeatRule, isNull);
        expect(t.done, isFalse);
        expect(
          made.message,
          'Feladat felvéve: Számla befizetése – '
          'Határidő: holnap · péntek, nov. 13.',
        );
      });

      test('without a deadline has none', () async {
        final made = await make('tej vásárlása');
        final t = TaskView((await records.get(kindTask, made.id))!);
        expect(t.due, isNull);
        expect(made.message, contains('Határidő nélkül'));
      });

      test('that repeats keeps its rule on the first deadline', () async {
        final made = await make('minden nap gyógyszer');
        final t = TaskView((await records.get(kindTask, made.id))!);
        expect(t.repeatRule, 'FREQ=DAILY');
        expect(t.due, today);
      });

      test('an event turned into a task keeps the day', () async {
        final entry = parse('holnap 18:00 edzés').withKind(QuickKind.task);
        final made = await c.read(quickEntryOpsProvider).create(entry);
        final t = TaskView((await records.get(kindTask, made.id))!);
        expect(t.due, floating(2026, 11, 13));
        expect(await events.all(), isEmpty);
      });

      test('is taken back, and is deleted', () async {
        final made = await make('tej vásárlása');
        expect(await made.undo(), isTrue);
        expect((await records.get(kindTask, made.id))!.deleted, isTrue);
      });

      test('is not taken back once it was ticked off', () async {
        final made = await make('tej vásárlása');
        await records.edit(kindTask, made.id, {'done': true});
        expect(await made.undo(), isFalse);
        expect((await records.get(kindTask, made.id))!.deleted, isFalse);
      });

      test('is not taken back once it is gone already', () async {
        final made = await make('tej vásárlása');
        await records.delete(kindTask, made.id);
        expect(await made.undo(), isFalse);
      });
    });

    group('what cannot be made', () {
      test('a line with no title', () async {
        await expectLater(
          make('holnap 18:00'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'Adj meg egy címet.',
            ),
          ),
        );
        expect(await events.all(), isEmpty);
        expect(await records.all(kindTask), isEmpty);
      });

      test('an event with no day', () async {
        await expectLater(
          c
              .read(quickEntryOpsProvider)
              .create(parse('tej vásárlása').withKind(QuickKind.event)),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              contains('nap kell'),
            ),
          ),
        );
        expect(await events.all(), isEmpty);
      });

      test('a save that fails lets the hold go', () async {
        // (a hold left behind would keep every later new event off Google)
        final broken = ProviderContainer(
          overrides: [
            ...baseOverrides(db),
            appClockProvider.overrideWithValue(clock),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            repoProvider.overrideWithValue(_BrokenRepo(db)),
          ],
        );
        addTearDown(broken.dispose);
        await expectLater(
          broken
              .read(quickEntryOpsProvider)
              .create(parse('holnap 18:00 edzés')),
          throwsA(isA<StateError>()),
        );
        expect(broken.read(syncHoldProvider).isEmpty, isTrue);
        expect(await events.all(), isEmpty);
      });

      test('nothing stays held after a failed save', () async {
        // (the hold of an event that was not made would keep the next ones
        // off Google for good)
        final hold = c.read(syncHoldProvider);
        await expectLater(
          c
              .read(quickEntryOpsProvider)
              .create(parse('tej vásárlása').withKind(QuickKind.event)),
          throwsArgumentError,
        );
        expect(hold.isEmpty, isTrue);
      });
    });
  });

  group('the dialog', () {
    late AppDatabase db;
    late EventRepository events;
    late RecordRepository records;
    late ProviderContainer c;
    late _Sync sync;

    Future<void> boot(
      WidgetTester tester, {
      Widget home = const HomePage(),
      Size size = const Size(1280, 900),
      double? textScale,
      ThemeData? theme,
      List<Override> extra = const [],
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      events = EventRepository(db);
      records = RecordRepository(db);
      sync = _Sync();
      await tester.pumpWidget(
        app(
          home,
          db,
          textScale: textScale,
          theme: theme,
          extra: [
            appClockProvider.overrideWithValue(clock),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            syncControllerProvider.overrideWith(() => sync),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
            ...extra,
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(
        tester.element(find.byType(home.runtimeType)),
      );
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester) =>
        press(tester, LogicalKeyboardKey.keyQ);

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('quick-text')), text);
      await tester.pump();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    Future<T> run<T>(WidgetTester tester, Future<T> Function() f) async =>
        (await tester.runAsync(f)) as T;

    String textOf(String key) =>
        (find.byKey(Key(key)).evaluate().single.widget as Text).data!;

    bool enabled(WidgetTester tester, String key) {
      final w = tester.widget(find.byKey(Key(key)));
      return switch (w) {
        FilledButton b => b.onPressed != null,
        TextButton b => b.onPressed != null,
        _ => throw StateError('not a button: $w'),
      };
    }

    bool? kindSelected(WidgetTester tester, QuickKind k) => tester
        .widget<ChoiceChip>(find.byKey(Key('quick-kind-${k.name}')))
        .selected;

    group('opening', () {
      testWidgets('Q opens it; a line says what can be written', (
        tester,
      ) async {
        await boot(tester);
        expect(find.byKey(const Key('quick-text')), findsNothing);
        await open(tester);
        expect(find.byKey(const Key('quick-text')), findsOneWidget);
        expect(find.byKey(const Key('quick-help')), findsOneWidget);
        expect(find.byKey(const Key('quick-preview')), findsNothing);
        // nothing to make yet
        expect(enabled(tester, 'quick-add'), isFalse);
        expect(enabled(tester, 'quick-edit'), isFalse);
        expect(enabled(tester, 'quick-cancel'), isTrue);
        await shutdown(tester, db);
      });

      testWidgets('the examples are buttons: a tap writes them in', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await tester.tap(find.widgetWithText(ActionChip, quickExamples.first));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('quick-text')))
              .controller!
              .text,
          quickExamples.first,
        );
        expect(find.byKey(const Key('quick-help')), findsNothing);
        expect(find.byKey(const Key('quick-preview')), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the help also says dictation works', (tester) async {
        await boot(tester);
        await open(tester);
        expect(find.textContaining('Diktálhatsz is'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the key help lists Q', (tester) async {
        await boot(tester);
        await press(tester, LogicalKeyboardKey.f1);
        expect(find.text('Q'), findsOneWidget);
        expect(find.textContaining('Gyors felvitel'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('Mégse closes it and makes nothing', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-cancel');
        expect(find.byKey(const Key('quick-text')), findsNothing);
        expect(await run(tester, events.all), isEmpty);
        expect(find.text('Visszavonás'), findsNothing);
        await shutdown(tester, db);
      });
    });

    group('what it shows', () {
      testWidgets('an event: the title, the time, the kind', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        expect(textOf('quick-title'), 'Edzés');
        expect(textOf('quick-when'), 'Holnap · péntek, nov. 13. · 18:00–19:00');
        expect(find.byKey(const Key('quick-repeat')), findsNothing);
        expect(kindSelected(tester, QuickKind.event), isTrue);
        expect(kindSelected(tester, QuickKind.task), isFalse);
        expect(enabled(tester, 'quick-add'), isTrue);
        expect(enabled(tester, 'quick-edit'), isTrue);
        await shutdown(tester, db);
      });

      testWidgets('a task: the deadline, the kind', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'péntekig számla befizetése');
        expect(textOf('quick-title'), 'Számla befizetése');
        expect(textOf('quick-when'), 'Határidő: holnap · péntek, nov. 13.');
        expect(kindSelected(tester, QuickKind.task), isTrue);
        await shutdown(tester, db);
      });

      testWidgets('a repeat is told in words', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'minden hétfőn 7:00 futás');
        expect(textOf('quick-repeat'), 'Hetente (hétfő)');
        await shutdown(tester, db);
      });

      testWidgets('what was taken for granted is said', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'nov. 20. szülinap');
        expect(
          find.textContaining('Nincs időpont, ezért egész napos eseményt'),
          findsOneWidget,
        );
        await shutdown(tester, db);
      });

      testWidgets('with no title it asks for one and makes nothing', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00');
        expect(find.byKey(const Key('quick-no-title')), findsOneWidget);
        expect(find.byKey(const Key('quick-title')), findsNothing);
        expect(enabled(tester, 'quick-add'), isFalse);
        expect(enabled(tester, 'quick-edit'), isFalse);
        await shutdown(tester, db);
      });

      testWidgets('clearing the line brings the help back', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        expect(find.byKey(const Key('quick-preview')), findsOneWidget);
        await type(tester, '   ');
        expect(find.byKey(const Key('quick-preview')), findsNothing);
        expect(find.byKey(const Key('quick-help')), findsOneWidget);
        expect(enabled(tester, 'quick-add'), isFalse);
        await shutdown(tester, db);
      });

      testWidgets('an event needs a day: without one only a task is offered', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'tej vásárlása');
        expect(kindSelected(tester, QuickKind.task), isTrue);
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(const Key('quick-kind-event')))
              .onSelected,
          isNull,
        );
        await shutdown(tester, db);
      });

      testWidgets('the Esemény / Feladat choice changes what is made', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-kind-task');
        expect(kindSelected(tester, QuickKind.task), isTrue);
        expect(textOf('quick-when'), 'Határidő: holnap · péntek, nov. 13.');
        await tapKey(tester, 'quick-kind-event');
        expect(kindSelected(tester, QuickKind.event), isTrue);
        expect(textOf('quick-when'), 'Holnap · péntek, nov. 13. · 18:00–19:00');
        await shutdown(tester, db);
      });

      testWidgets('a new text is a new question: the choice is forgotten', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-kind-task');
        await type(tester, 'holnap 18:00 edzés a haverral');
        expect(kindSelected(tester, QuickKind.event), isTrue);
        await shutdown(tester, db);
      });
    });

    group('making', () {
      testWidgets('an event: it is stored, and the bar can take it back', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        expect(find.byKey(const Key('quick-text')), findsNothing);

        final all = await run(tester, events.all);
        expect(all, hasLength(1));
        expect(all.single.title, 'Edzés');
        expect(all.single.start, floating(2026, 11, 13, 18));
        expect(sync.requests, greaterThan(0));
        expect(
          find.text(
            'Esemény felvéve: Edzés – Holnap · péntek, nov. 13. · 18:00–19:00',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Visszavonás'));
        await tester.pumpAndSettle();
        expect(await run(tester, events.all), isEmpty);
        await shutdown(tester, db);
      });

      testWidgets('a task: it is stored, and the bar can take it back', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'péntekig számla befizetése');
        await tapKey(tester, 'quick-add');

        final all = await run(tester, () => records.all(kindTask));
        expect(all, hasLength(1));
        final t = TaskView(all.single);
        expect(t.title, 'Számla befizetése');
        expect(t.due, floating(2026, 11, 13));
        expect(await run(tester, events.all), isEmpty);
        expect(
          find.textContaining('Feladat felvéve: Számla befizetése'),
          findsOneWidget,
        );

        await tester.tap(find.text('Visszavonás'));
        await tester.pumpAndSettle();
        expect(
          (await run(tester, () => records.get(kindTask, t.id)))!.deleted,
          isTrue,
        );
        await shutdown(tester, db);
      });

      testWidgets('the Feladat choice makes a task of an event line', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-kind-task');
        await tapKey(tester, 'quick-add');
        expect(await run(tester, events.all), isEmpty);
        final tasks = await run(tester, () => records.all(kindTask));
        expect(tasks, hasLength(1));
        expect(TaskView(tasks.single).due, floating(2026, 11, 13));
        await shutdown(tester, db);
      });

      testWidgets('Enter on the keyboard makes it, too', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick-text')), findsNothing);
        expect(await run(tester, events.all), hasLength(1));
        await shutdown(tester, db);
      });

      testWidgets('Enter on a line with nothing to make does nothing', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick-text')), findsOneWidget);
        expect(await run(tester, events.all), isEmpty);
        // (it was not even tried: no failed attempt to complain about)
        expect(find.byKey(const Key('quick-error')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('the Esemény choice makes an all-day event of a dated task', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'péntekig számla befizetése');
        await tapKey(tester, 'quick-kind-event');
        expect(textOf('quick-when'), 'Holnap · péntek, nov. 13. · egész nap');
        await tapKey(tester, 'quick-add');
        final e = (await run(tester, events.all)).single;
        expect(e.allDay, isTrue);
        expect(e.start, floating(2026, 11, 13));
        expect(e.end, floating(2026, 11, 14));
        expect(await run(tester, () => records.all(kindTask)), isEmpty);
        await shutdown(tester, db);
      });

      testWidgets('a pasted wall of text is cut at 300 characters', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 ${'x' * 400}');
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('quick-text')))
              .controller!
              .text
              .length,
          300,
        );
        await shutdown(tester, db);
      });

      testWidgets('a new event waits for the bar before it goes to Google', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        final id = (await run(tester, events.all)).single.id;
        final hold = c.read(syncHoldProvider);
        expect(hold.isHeld(id), isTrue);
        final before = sync.requests;

        // the window closes: the event may go up now, and the sync is asked
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(hold.isHeld(id), isFalse);
        expect(sync.requests, greaterThan(before));
        expect(await run(tester, events.all), hasLength(1));
        await shutdown(tester, db);
      });

      testWidgets('taking it back lets go of the hold', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        final id = (await run(tester, events.all)).single.id;
        await tester.tap(find.text('Visszavonás'));
        await tester.pumpAndSettle();
        expect(c.read(syncHoldProvider).isHeld(id), isFalse);
        expect(c.read(syncHoldProvider).isEmpty, isTrue);
        await shutdown(tester, db);
      });

      testWidgets('a failed save says why and keeps the dialog', (
        tester,
      ) async {
        await boot(
          tester,
          extra: [
            quickEntryOpsProvider.overrideWith(
              (ref) => _FailingOps(ref, StateError('boom')),
            ),
          ],
        );
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        expect(find.byKey(const Key('quick-text')), findsOneWidget);
        expect(textOf('quick-error'), startsWith('Mentés sikertelen:'));
        // (nothing of the raw error reaches the screen)
        expect(find.textContaining('boom'), findsNothing);
        expect(find.textContaining('StateError'), findsNothing);
        // and it can be tried again, or changed: the message goes away
        expect(enabled(tester, 'quick-add'), isTrue);
        await type(tester, 'holnap 19:00 edzés');
        expect(find.byKey(const Key('quick-error')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('a refusal with a sentence shows the sentence', (
        tester,
      ) async {
        await boot(
          tester,
          extra: [
            quickEntryOpsProvider.overrideWith(
              (ref) => _FailingOps(ref, ArgumentError('Adj meg egy címet.')),
            ),
          ],
        );
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        expect(textOf('quick-error'), 'Adj meg egy címet.');
        await shutdown(tester, db);
      });
    });

    group('Szerkesztés…', () {
      testWidgets('opens the editor with the event filled in', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-edit');
        expect(find.byKey(const Key('quick-text')), findsNothing);
        expect(find.text('Új esemény'), findsOneWidget);
        expect(find.text('Edzés'), findsOneWidget);
        // (the calendar behind has hours of its own)
        Finder inEditor(String t) =>
            find.descendant(of: find.byType(Dialog), matching: find.text(t));
        expect(inEditor('18:00'), findsOneWidget);
        expect(inEditor('19:00'), findsOneWidget);
        // nothing is stored until the editor says so
        expect(await run(tester, events.all), isEmpty);

        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final e = (await run(tester, events.all)).single;
        expect(e.title, 'Edzés');
        expect(e.start, floating(2026, 11, 13, 18));
        expect(e.end, floating(2026, 11, 13, 19));
        expect(e.tzid, 'Europe/Budapest');
        await shutdown(tester, db);
      });

      testWidgets('a night shift arrives with its end on the next day', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 22:00-tól 6:00-ig műszak');
        await tapKey(tester, 'quick-edit');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final e = (await run(tester, events.all)).single;
        expect(e.start, floating(2026, 11, 13, 22));
        expect(e.end, floating(2026, 11, 14, 6));
        await shutdown(tester, db);
      });

      testWidgets('an all-day event arrives all-day', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'nov. 20. szülinap');
        await tapKey(tester, 'quick-edit');
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final e = (await run(tester, events.all)).single;
        expect(e.allDay, isTrue);
        expect(e.start, floating(2026, 11, 20));
        expect(e.end, floating(2026, 11, 21));
        await shutdown(tester, db);
      });

      testWidgets('a repeating event arrives with its rule', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'minden hétfőn 7:00 futás');
        await tapKey(tester, 'quick-edit');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final e = (await run(tester, events.all)).single;
        expect(e.rrule, 'FREQ=WEEKLY;BYDAY=MO');
        expect(e.start, floating(2026, 11, 16, 7));
        await shutdown(tester, db);
      });

      testWidgets('the choice of a task opens the task editor', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'péntekig számla befizetése');
        await tapKey(tester, 'quick-edit');
        expect(find.text('Új feladat'), findsOneWidget);
        expect(find.text('Számla befizetése'), findsOneWidget);
        expect(find.text('2026. november 13.'), findsOneWidget);
        expect(await run(tester, () => records.all(kindTask)), isEmpty);

        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final t = TaskView(
          (await run(tester, () => records.all(kindTask))).single,
        );
        expect(t.title, 'Számla befizetése');
        expect(t.due, floating(2026, 11, 13));
        await shutdown(tester, db);
      });

      testWidgets('the choice of the chips is carried to the editor', (
        tester,
      ) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-kind-task');
        await tapKey(tester, 'quick-edit');
        expect(find.text('Új feladat'), findsOneWidget);
        expect(find.text('Új esemény'), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('a repeating task arrives with its rule', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'minden nap gyógyszer');
        await tapKey(tester, 'quick-edit');
        expect(find.text('Új feladat'), findsOneWidget);
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final t = TaskView(
          (await run(tester, () => records.all(kindTask))).single,
        );
        expect(t.repeatRule, 'FREQ=DAILY');
        expect(t.due, today);
        await shutdown(tester, db);
      });

      testWidgets('closing the editor makes nothing', (tester) async {
        await boot(tester);
        await open(tester);
        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-edit');
        await tester.tap(find.byTooltip('Bezár'));
        await tester.pumpAndSettle();
        expect(find.text('Új esemény'), findsNothing);
        expect(await run(tester, events.all), isEmpty);
        await shutdown(tester, db);
      });
    });

    group('from the other places', () {
      testWidgets('the Feladatok page has a button for it', (tester) async {
        await boot(tester, home: const TasksPage());
        expect(find.byTooltip('Gyors felvitel'), findsOneWidget);
        await tester.tap(find.byTooltip('Gyors felvitel'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick-text')), findsOneWidget);

        await type(tester, 'péntekig számla befizetése');
        await tapKey(tester, 'quick-add');
        // the new task stands in the list at once
        expect(find.text('Számla befizetése'), findsOneWidget);
        expect(find.text('Közelgő (1)'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('"Több" has it, on a phone', (tester) async {
        await boot(tester, home: const RootShell(), size: const Size(360, 800));
        await tester.tap(find.byKey(const Key('nav-more')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('more-quick')), findsOneWidget);
        expect(find.text('Gyors felvitel'), findsOneWidget);
        await tester.tap(find.byKey(const Key('more-quick')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick-text')), findsOneWidget);

        await type(tester, 'holnap 18:00 edzés');
        await tapKey(tester, 'quick-add');
        expect(await run(tester, events.all), hasLength(1));
        // the bar shows on the main frame, above the destinations
        expect(find.textContaining('Esemény felvéve: Edzés'), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('"Több" has it in the rail, too', (tester) async {
        await boot(tester, home: const RootShell());
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text('Több'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('more-quick')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick-text')), findsOneWidget);
        await shutdown(tester, db);
      });
    });

    group('from the search', () {
      Future<void> openSearch(WidgetTester tester) async {
        await tester.tap(find.byTooltip('Keresés'));
        await tester.pumpAndSettle();
      }

      Future<void> search(WidgetTester tester, String q) async {
        await tester.enterText(find.byKey(const Key('search-field')), q);
        await tester.pumpAndSettle();
      }

      testWidgets('a line that says when is offered, and made on a tap', (
        tester,
      ) async {
        await boot(tester);
        await openSearch(tester);
        await search(tester, 'fogorvos holnap 10:00');
        final offer = find.byKey(const Key('search-quick-offer'));
        expect(offer, findsOneWidget);
        expect(find.text('Felvétel: Fogorvos'), findsOneWidget);
        expect(
          find.text('Holnap · péntek, nov. 13. · 10:00–11:00'),
          findsOneWidget,
        );

        await tester.tap(offer);
        await tester.pumpAndSettle();
        // the dialog has the line already, and shows what it understood
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('quick-text')))
              .controller!
              .text,
          'fogorvos holnap 10:00',
        );
        expect(textOf('quick-title'), 'Fogorvos');
        await tapKey(tester, 'quick-add');
        final e = (await run(tester, events.all)).single;
        expect(e.title, 'Fogorvos');
        expect(e.start, floating(2026, 11, 13, 10));
        await shutdown(tester, db);
      });

      testWidgets('an ordinary word is not offered', (tester) async {
        await boot(tester);
        await openSearch(tester);
        await search(tester, 'fogorvos');
        expect(find.byKey(const Key('search-quick-offer')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('a day with nothing else is not offered', (tester) async {
        await boot(tester);
        await openSearch(tester);
        await search(tester, 'péntek');
        // (no title: there is nothing to make)
        expect(find.byKey(const Key('search-quick-offer')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('a repeating line is offered', (tester) async {
        await boot(tester);
        await openSearch(tester);
        await search(tester, 'minden nap gyógyszer');
        expect(find.byKey(const Key('search-quick-offer')), findsOneWidget);
        await shutdown(tester, db);
      });

      testWidgets('the search results stay below the offer', (tester) async {
        await boot(tester);
        await run(
          tester,
          () => events.saveLocal(
            evt('x', 'Fogorvos kontroll', floating(2026, 11, 20, 9)),
          ),
        );
        await openSearch(tester);
        await search(tester, 'fogorvos holnap');
        expect(find.byKey(const Key('search-quick-offer')), findsOneWidget);
        await search(tester, 'fogorvos');
        expect(find.byKey(const Key('search-quick-offer')), findsNothing);
        expect(find.text('Fogorvos kontroll'), findsOneWidget);
        await shutdown(tester, db);
      });
    });

    group('big text and the dark theme', () {
      for (final dark in [false, true]) {
        testWidgets('at twice the text size on a phone nothing overflows '
            '(${dark ? 'dark' : 'light'})', (tester) async {
          await boot(
            tester,
            size: const Size(360, 640),
            textScale: 2.0,
            theme: dark ? ThemeData(brightness: Brightness.dark) : null,
          );
          await open(tester);
          expect(tester.takeException(), isNull);
          await type(tester, 'nov. 20. szülinap');
          expect(find.byKey(const Key('quick-preview')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await type(tester, 'minden hétfőn 7:00 futás');
          expect(tester.takeException(), isNull);
          await type(tester, 'holnap 18:00');
          expect(find.byKey(const Key('quick-no-title')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shutdown(tester, db);
        });
      }

      testWidgets('the buttons can be reached at twice the size', (
        tester,
      ) async {
        await boot(tester, size: const Size(360, 640), textScale: 2.0);
        await open(tester);
        await type(tester, 'minden hétfőn 7:00 futás');
        expect(
          tester.getRect(find.byKey(const Key('quick-add'))).bottom,
          lessThanOrEqualTo(640),
        );
        await tester.tap(find.byKey(const Key('quick-add')));
        await tester.pumpAndSettle();
        expect(await run(tester, events.all), hasLength(1));
        await shutdown(tester, db);
      });
    });
  });
}
