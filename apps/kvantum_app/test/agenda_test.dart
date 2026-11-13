import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/agenda_view.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

Occurrence occ(
  DateTime startWall,
  DateTime endWall, {
  bool allDay = false,
  String title = 'x',
}) => Occurrence(
  eventId: 'e',
  title: title,
  startUtc: allDay ? startWall : resolveWallClock(bp, startWall),
  endUtc: allDay ? endWall : resolveWallClock(bp, endWall),
  originalStart: startWall,
  allDay: allDay,
  tzid: allDay ? null : bp,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the words of the list', () {
    final today = DateTime.utc(2026, 11, 11);

    test('relative names for the days around today', () {
      expect(relativeDayName(DateTime.utc(2026, 11, 10), today), 'Tegnap');
      expect(relativeDayName(DateTime.utc(2026, 11, 11), today), 'Ma');
      expect(relativeDayName(DateTime.utc(2026, 11, 12), today), 'Holnap');
      expect(relativeDayName(DateTime.utc(2026, 11, 13), today), 'Holnapután');
      expect(relativeDayName(DateTime.utc(2026, 11, 14), today), isNull);
      expect(relativeDayName(DateTime.utc(2026, 11, 9), today), isNull);
    });

    test('a day title is the weekday and date, with the name before it', () {
      expect(
        agendaDayTitle(DateTime.utc(2026, 11, 11), today),
        'Ma · szerda, nov. 11.',
      );
      expect(
        agendaDayTitle(DateTime.utc(2026, 11, 12), today),
        'Holnap · csütörtök, nov. 12.',
      );
      expect(
        agendaDayTitle(DateTime.utc(2026, 11, 16), today),
        'hétfő, nov. 16.',
      );
    });

    test('the time column: start and end, "egész nap", "→" and "folyt."', () {
      final d = DateTime.utc(2026, 11, 12);
      // an ordinary one
      expect(
        agendaWhen(
          occ(floating(2026, 11, 12, 9), floating(2026, 11, 12, 10, 30)),
          d,
        ),
        '09:00\n10:30',
      );
      // all day
      expect(
        agendaWhen(
          occ(
            DateTime.utc(2026, 11, 12),
            DateTime.utc(2026, 11, 13),
            allDay: true,
          ),
          d,
        ),
        'egész nap',
      );
      // runs past midnight: the first day shows an arrow, the next "folyt."
      final night = occ(floating(2026, 11, 12, 22), floating(2026, 11, 13, 2));
      expect(agendaWhen(night, d), '22:00\n→');
      expect(agendaWhen(night, DateTime.utc(2026, 11, 13)), 'folyt.');
      // one that ends exactly at midnight ends on its own day
      expect(
        agendaWhen(occ(floating(2026, 11, 12, 22), floating(2026, 11, 13)), d),
        '22:00\n00:00',
      );
    });
  });

  group('the view', () {
    late AppDatabase db;
    late EventRepository events;
    late RecordRepository records;
    late ProviderContainer c;

    Future<void> boot(
      WidgetTester tester, {
      Size size = const Size(1280, 900),
      bool seed = true,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      events = EventRepository(db);
      records = RecordRepository(db);
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          extra: [
            // Wednesday 2026-11-11, noon in Budapest
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 11, 11),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
      if (seed) {
        // (the events and the tasks are written one after the other, with a
        // frame between: the open streams settle before the next write)
        await tester.runAsync(
          () => events.saveAll([
            evt('a', 'Fogorvos', floating(2026, 11, 11, 14)),
            evt(
              'b',
              'Szabadnap',
              floating(2026, 11, 11),
              allDay: true,
              len: const Duration(days: 1),
            ),
            evt('c', 'Reggeli edzés', floating(2026, 11, 12, 9)),
            evt('d', 'Vacsora', floating(2026, 11, 16, 18)),
            evt('f', 'Távoli', floating(2026, 12, 20, 9)),
            // the 14th day of the list is the 24th: in; the 25th: out
            evt('g', 'Utolsó napi dolog', floating(2026, 11, 24, 9)),
            evt('h', 'Egy nappal később', floating(2026, 11, 25, 9)),
          ]),
        );
        await tester.pumpAndSettle();
        for (final (id, fields) in [
          ('t1', taskFields(title: 'Késő feladat', due: floating(2026, 11, 9))),
          ('t2', taskFields(title: 'Mai feladat', due: floating(2026, 11, 11))),
          (
            't3',
            taskFields(title: 'Jövő heti feladat', due: floating(2026, 11, 18)),
          ),
          (
            't4',
            taskFields(
              title: 'Kész feladat',
              due: floating(2026, 11, 12),
              done: true,
            ),
          ),
          ('t5', taskFields(title: 'Dátum nélkül')),
        ]) {
          await tester.runAsync(() => records.edit(kindTask, id, fields));
        }
        await tester.pumpAndSettle();
      }
    }

    Future<void> openAgenda(WidgetTester tester) async {
      await tester.tap(find.text('Napirend'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the days that have something, with their names', (
      tester,
    ) async {
      await boot(tester);
      await openAgenda(tester);
      expect(c.read(viewModeProvider), CalView.agenda);
      expect(find.byType(AgendaView), findsOneWidget);
      expect(find.text('Ma · szerda, nov. 11.'), findsOneWidget);
      expect(find.text('Holnap · csütörtök, nov. 12.'), findsOneWidget);
      expect(find.text('hétfő, nov. 16.'), findsOneWidget);
      // a day with nothing on it, and what is beyond the 14 days, are absent
      expect(find.textContaining('péntek, nov. 13.'), findsNothing);
      expect(find.text('Távoli'), findsNothing);
      expect(find.text('Utolsó napi dolog'), findsOneWidget);
      expect(find.text('Egy nappal később'), findsNothing);
      expect(find.text('Fogorvos'), findsOneWidget);
      expect(find.text('Reggeli edzés'), findsOneWidget);
      expect(find.text('Vacsora'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('all-day events come first, then by start time', (
      tester,
    ) async {
      await boot(tester);
      await openAgenda(tester);
      final allDay = tester.getTopLeft(find.text('Szabadnap')).dy;
      final timed = tester.getTopLeft(find.text('Fogorvos')).dy;
      expect(allDay, lessThan(timed));
      expect(find.text('egész nap'), findsOneWidget);
      expect(find.text('14:00\n15:00'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('tasks due on a day are under it; done and undated ones not', (
      tester,
    ) async {
      await boot(tester);
      await openAgenda(tester);
      // 'Mai feladat' is under Today, after its events
      final events = tester.getTopLeft(find.text('Fogorvos')).dy;
      final task = tester.getTopLeft(find.textContaining('Mai feladat')).dy;
      expect(task, greaterThan(events));
      expect(find.textContaining('Jövő heti feladat'), findsOneWidget);
      expect(find.textContaining('Kész feladat'), findsNothing);
      expect(find.textContaining('Dátum nélkül'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('overdue open tasks come first, as "Késésben"', (tester) async {
      await boot(tester);
      await openAgenda(tester);
      expect(find.text('Késésben'), findsOneWidget);
      expect(find.textContaining('Késő feladat'), findsOneWidget);
      expect(
        find.textContaining('határidő: 2026. november 9.'),
        findsOneWidget,
      );
      final late = tester.getTopLeft(find.text('Késésben')).dy;
      final first = tester.getTopLeft(find.text('Ma · szerda, nov. 11.')).dy;
      expect(late, lessThan(first));
      await shutdown(tester, db);
    });

    testWidgets('no "Késésben" when the list does not reach back to today', (
      tester,
    ) async {
      await boot(tester);
      await openAgenda(tester);
      await tester.tap(find.byTooltip('Következő'));
      await tester.pumpAndSettle();
      expect(find.text('Késésben'), findsNothing);
      expect(find.textContaining('Késő feladat'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a step is 14 days; the title shows the range', (tester) async {
      await boot(tester);
      await openAgenda(tester);
      expect(find.text('2026. nov. 11. – 24.'), findsOneWidget);
      await tester.tap(find.byTooltip('Következő'));
      await tester.pumpAndSettle();
      expect(c.read(selectedDayProvider), DateTime.utc(2026, 11, 25));
      expect(find.text('2026. nov. 25. – dec. 8.'), findsOneWidget);
      await tester.tap(find.byTooltip('Előző'));
      await tester.tap(find.byTooltip('Előző'));
      await tester.pumpAndSettle();
      expect(c.read(selectedDayProvider), DateTime.utc(2026, 10, 28));
      expect(find.text('2026. okt. 28. – nov. 10.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the title names both years across New Year', (tester) async {
      await boot(tester, seed: false);
      c.read(selectedDayProvider.notifier).set(DateTime.utc(2026, 12, 28));
      await openAgenda(tester);
      expect(find.text('2026. dec. 28. – 2027. jan. 10.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('it starts at the chosen day, not at today', (tester) async {
      await boot(tester);
      c.read(selectedDayProvider.notifier).set(DateTime.utc(2026, 12, 15));
      await openAgenda(tester);
      expect(find.text('Távoli'), findsOneWidget);
      expect(find.text('Fogorvos'), findsNothing);
      expect(find.text('Késésben'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a tap opens the event, or the task', (tester) async {
      await boot(tester);
      await openAgenda(tester);
      await tester.tap(find.text('Fogorvos'));
      await tester.pumpAndSettle();
      expect(find.text('Esemény szerkesztése'), findsOneWidget);
      await tester.tap(find.byTooltip('Bezár'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Mai feladat'));
      await tester.pumpAndSettle();
      expect(find.text('Feladat szerkesztése'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an event over midnight is on both days, "folyt." on the 2nd', (
      tester,
    ) async {
      await boot(tester, seed: false);
      await tester.runAsync(
        () => events.saveLocal(
          evt(
            'n',
            'Éjszakás',
            floating(2026, 11, 11, 22),
            len: const Duration(hours: 6),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openAgenda(tester);
      expect(find.text('Éjszakás'), findsNWidgets(2));
      expect(find.text('22:00\n→'), findsOneWidget);
      expect(find.text('folyt.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an empty range says so', (tester) async {
      await boot(tester, seed: false);
      await openAgenda(tester);
      expect(
        find.text('Nincs esemény és határidős feladat ebben az időszakban.'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('the list follows the data', (tester) async {
      await boot(tester, seed: false);
      await openAgenda(tester);
      await tester.runAsync(
        () => events.saveLocal(evt('x', 'Új dolog', floating(2026, 11, 13, 8))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Új dolog'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the choice is remembered with the other views', (
      tester,
    ) async {
      await boot(tester, seed: false);
      await openAgenda(tester);
      final saved = await tester.runAsync(
        () => c.read(repoProvider).meta('calView'),
      );
      expect(saved, 'agenda');
      await shutdown(tester, db);
    });

    testWidgets('in a narrow window the view menu has it', (tester) async {
      await boot(tester, size: const Size(420, 800));
      await tester.tap(find.byTooltip('Nézet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Napirend'));
      await tester.pumpAndSettle();
      expect(c.read(viewModeProvider), CalView.agenda);
      expect(find.byType(AgendaView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('key 4 shows it, key 1 goes back to the month', (tester) async {
      await boot(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.pumpAndSettle();
      expect(c.read(viewModeProvider), CalView.agenda);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(c.read(viewModeProvider), CalView.month);
      await shutdown(tester, db);
    });

    testWidgets('a phone-wide window shows the list without overflow', (
      tester,
    ) async {
      await boot(tester, size: const Size(320, 640));
      c.read(viewModeProvider.notifier).set(CalView.agenda);
      await tester.pumpAndSettle();
      expect(find.text('Fogorvos'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });
}
