import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/main.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/day_utils.dart';
import 'package:kvantum_core/kvantum_core.dart';

void main() {
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('day utils', () {
    test('month grid is 42 Monday-based cells covering the month', () {
      final g = monthGrid(DateTime.utc(2026, 12, 1));
      expect(g.length, 42);
      expect(g.first.weekday, DateTime.monday);
      expect(g.first, DateTime.utc(2026, 11, 30));
      expect(g.contains(DateTime.utc(2026, 12, 31)), isTrue);
    });
    test('event ending exactly at midnight does not touch the next day', () {
      final o = Occurrence(
        eventId: 'e',
        title: 't',
        allDay: false,
        tzid: defaultTz,
        startUtc: resolveWallClock(defaultTz, floating(2026, 12, 31, 22)),
        endUtc: resolveWallClock(defaultTz, floating(2027, 1, 1, 0)),
        originalStart: floating(2026, 12, 31, 22),
      );
      expect(daysOf(o), [DateTime.utc(2026, 12, 31)]);
    });
    test('multi-day all-day event lists each day, end exclusive', () {
      final o = Occurrence(
        eventId: 'e',
        title: 't',
        allDay: true,
        startUtc: DateTime.utc(2026, 12, 30),
        endUtc: DateTime.utc(2027, 1, 2),
        originalStart: floating(2026, 12, 30),
      );
      expect(daysOf(o).map((d) => d.day), [30, 31, 1]);
    });
  });

  Future<void> shutdown(WidgetTester tester, AppDatabase db) async {
    // Unmount first so drift's stream-cleanup timers run, then close the db
    // in real time (closing inside fake async would never complete).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(db.close);
  }

  Future<AppDatabase> boot(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dbProvider.overrideWithValue(db)],
        child: const KvantumApp(),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  testWidgets('add an event in the editor and see it in the day list', (
    tester,
  ) async {
    final db = await boot(tester);
    expect(find.text('Nincs esemény erre a napra.'), findsOneWidget);

    await tester.tap(find.byTooltip('Új esemény'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Futás');
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();

    expect(find.text('Futás'), findsWidgets);
    expect(find.text('Nincs esemény erre a napra.'), findsNothing);
    // Saving queued exactly one pending push.
    final outbox = await tester.runAsync(() => db.select(db.outboxRows).get());
    expect(outbox!.length, 1);
    await shutdown(tester, db);
  });

  testWidgets('empty title is rejected', (tester) async {
    final db = await boot(tester);
    await tester.tap(find.byTooltip('Új esemény'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Adj meg egy címet'), findsOneWidget);
    final rows = await tester.runAsync(() => db.select(db.eventRows).get());
    expect(rows, isEmpty);
    await shutdown(tester, db);
  });
}
