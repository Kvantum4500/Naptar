import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/time_grid.dart';
import 'package:kvantum_app/ui/palette.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

Occurrence occ(DateTime s, DateTime e, {bool allDay = false}) => Occurrence(
  eventId: 'e',
  title: 't',
  allDay: allDay,
  tzid: allDay ? null : bp,
  startUtc: allDay ? s : resolveWallClock(bp, s),
  endUtc: allDay ? e : resolveWallClock(bp, e),
  originalStart: s,
);

void main() {
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('dayItemFor (time grid maths)', () {
    final day = floating(2026, 5, 4);
    test('plain event inside the day', () {
      final i = dayItemFor(
        occ(floating(2026, 5, 4, 9), floating(2026, 5, 4, 10, 30)),
        day,
      )!;
      expect((i.startMin, i.endMin), (540, 630));
    });
    test('event crossing midnight is clipped on both days', () {
      final o = occ(floating(2026, 5, 4, 22), floating(2026, 5, 5, 2));
      expect(dayItemFor(o, day)!.endMin, 1440);
      final next = dayItemFor(o, floating(2026, 5, 5))!;
      expect((next.startMin, next.endMin), (0, 120));
    });
    test(
      'event ending exactly at midnight does not appear on the next day',
      () {
        final o = occ(floating(2026, 5, 4, 22), floating(2026, 5, 5, 0));
        expect(dayItemFor(o, floating(2026, 5, 5)), isNull);
      },
    );
    test('event on another day is ignored', () {
      expect(
        dayItemFor(occ(floating(2026, 5, 6, 9), floating(2026, 5, 6, 10)), day),
        isNull,
      );
    });
    test(
      'spring-forward day: 03:30 local sits at 3.5 h wall-clock position',
      () {
        final d = floating(2026, 3, 29);
        final i = dayItemFor(
          occ(floating(2026, 3, 29, 3, 30), floating(2026, 3, 29, 4, 30)),
          d,
        )!;
        expect(i.startMin, 210);
      },
    );
  });

  group('palette', () {
    test('every Google colour id has a name and a readable text colour', () {
      for (final e in eventColorChoices) {
        expect(eventColorNames.containsKey(e.key), isTrue);
        final fg = onEventColor(e.value);
        expect(fg == Colors.white || fg == Colors.black87, isTrue);
      }
      expect(eventColor(null), defaultEventColor);
      expect(eventColor('99'), defaultEventColor);
    });
  });

  testWidgets(
    'month view: colour chips with times, "+N további", jump to day view',
    (tester) async {
      useSize(tester);
      final db = await newDb();
      final repo = EventRepository(db);
      final today = DateTime.now();
      final d = floating(today.year, today.month, 15);
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await repo.saveLocal(
            evt(
              'e$i',
              'Esemény $i',
              d.add(Duration(hours: 8 + i)),
              colorId: i == 0 ? '11' : null,
            ),
          );
        }
        await repo.saveLocal(
          evt('ad', 'Szabadnap', d, len: const Duration(days: 1), allDay: true),
        );
      });
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('08:00 Esemény 0'),
        findsOneWidget,
      ); // 24h time + title
      expect(find.text('Szabadnap'), findsWidgets); // all-day bar
      final more = find.textContaining('további');
      expect(more, findsWidgets);

      await tester.tap(more.first);
      await tester.pumpAndSettle();
      // now in day view: hour scale visible
      expect(find.text('08:00'), findsWidgets);
      expect(find.text('Hét'), findsOneWidget);
      await shutdown(tester, db);
    },
  );

  testWidgets(
    'month view side panel shows the selected day as an hour timeline',
    (tester) async {
      useSize(tester);
      final db = await newDb();
      final repo = EventRepository(db);
      final n = DateTime.now();
      await tester.runAsync(
        () => repo.saveLocal(
          evt(
            'p',
            'Panel esemény',
            floating(n.year, n.month, n.day, 10),
            colorId: '7',
          ),
        ),
      );
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();

      // still the month view ...
      expect(find.text('Hónap'), findsOneWidget);
      // ... and the side panel has the timeline: block with its time range + hour labels
      expect(find.text('Panel esemény'), findsOneWidget);
      expect(find.text('10:00–11:00'), findsOneWidget);
      expect(find.text('12:00'), findsWidgets);
      expect(find.text('1 esemény'), findsOneWidget);

      // tapping the block opens the editor directly, no view switch needed
      await tester.tap(find.text('Panel esemény'));
      await tester.pumpAndSettle();
      expect(find.text('Esemény szerkesztése'), findsOneWidget);
      await shutdown(tester, db);
    },
  );

  testWidgets(
    'side panel: an empty day says so, and a tap on the timeline starts a new event',
    (tester) async {
      useSize(tester);
      final db = await newDb();
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();
      expect(find.text('Nincs esemény erre a napra.'), findsOneWidget);
      final panel = find.byType(TimeGrid);
      expect(panel, findsOneWidget);
      await tester.tapAt(tester.getCenter(panel));
      await tester.pumpAndSettle();
      expect(find.text('Új esemény'), findsWidgets);
      await shutdown(tester, db);
    },
  );

  testWidgets('week view: hour scale, event block, view choice is remembered', (
    tester,
  ) async {
    useSize(tester);
    final db = await newDb();
    final repo = EventRepository(db);
    final n = DateTime.now();
    await tester.runAsync(
      () => repo.saveLocal(
        evt(
          'w',
          'Heti edzés',
          floating(n.year, n.month, n.day, 10),
          colorId: '2',
        ),
      ),
    );
    await tester.pumpWidget(app(const HomePage(), db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hét'));
    await tester.pumpAndSettle();
    expect(find.text('Heti edzés'), findsOneWidget);
    expect(find.text('10:00–11:00'), findsOneWidget);
    expect(find.text('12:00'), findsWidgets);
    final saved = await tester.runAsync(() => repo.meta('calView'));
    expect(saved, 'week');
    await shutdown(tester, db);
  });

  testWidgets(
    'tapping an empty slot in the day view opens a new event at that time',
    (tester) async {
      useSize(tester);
      final db = await newDb();
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nap'));
      await tester.pumpAndSettle();

      // scroll is positioned around "now"/07:00; tap somewhere in the grid body
      final grid = find.byType(TimeGrid);
      final c = tester.getCenter(grid);
      await tester.tapAt(Offset(c.dx, c.dy));
      await tester.pumpAndSettle();
      expect(find.text('Új esemény'), findsWidgets);
      expect(find.text('Mentés'), findsOneWidget);
      await shutdown(tester, db);
    },
  );

  testWidgets('narrow window shows a compact view menu and no overflow', (
    tester,
  ) async {
    useSize(tester, size: const Size(420, 800));
    final db = await newDb();
    await tester.pumpWidget(app(const HomePage(), db));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shutdown(tester, db);
  });
}
