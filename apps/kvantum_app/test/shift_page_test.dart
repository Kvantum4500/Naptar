import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/shift_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late EventRepository repo;

  Future<void> boot(WidgetTester tester, DateTime day) async {
    useSize(tester, size: const Size(900, 1400));
    db = await newDb();
    repo = EventRepository(db);
    await tester.pumpWidget(
      app(
        const ShiftPage(),
        db,
        extra: [selectedDayProvider.overrideWith(() => _Day(day))],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<List<CalEvent>> shifts(WidgetTester tester) async =>
      (await tester.runAsync(repo.all))!
          .where((e) => e.notes == kShiftMarker)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  Future<void> create(WidgetTester tester) async {
    final btn = find.text('Létrehozás a naptárban');
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('creates the 3-3-3-3 cycle as separate events', (tester) async {
    await boot(tester, floating(2026, 11, 12));
    expect(find.textContaining('Előnézet:'), findsOneWidget);
    await create(tester);
    final s = await shifts(tester);
    // 6 months from 12 Nov = 181 days -> 15 full cycles (180 days) + 1 night
    expect(s.length, 15 * 6 + 1);
    expect(s.first.title, 'Éjszakai műszak');
    expect(s.first.start, floating(2026, 11, 12, 18));
    expect(s.first.end, floating(2026, 11, 13, 6));
    expect(s.every((e) => e.tzid == 'Europe/Budapest'), isTrue);
    expect(find.textContaining('műszak létrehozva'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets(
    'running again replaces generated shifts but keeps manual events',
    (tester) async {
      await boot(tester, floating(2026, 11, 12));
      await tester.runAsync(
        () =>
            repo.saveLocal(evt('hand', 'Fogorvos', floating(2026, 11, 20, 9))),
      );
      await create(tester);
      final first = await shifts(tester);
      await create(tester);
      final second = await shifts(tester);
      expect(second.length, first.length); // no duplicates
      expect(
        second
            .map((e) => e.id)
            .toSet()
            .intersection(first.map((e) => e.id).toSet()),
        isEmpty,
      ); // all replaced
      final all = (await tester.runAsync(repo.all))!;
      expect(all.where((e) => e.title == 'Fogorvos').length, 1);
      await shutdown(tester, db);
    },
  );

  testWidgets('the monthly summary follows the generated shifts', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    expect(
      find.textContaining('Ebben a hónapban nincs generált műszak'),
      findsOneWidget,
    );
    await create(tester);
    expect(find.textContaining('Éjszakai műszak: 6'), findsOneWidget);
    expect(find.textContaining('Nappali műszak: 4'), findsOneWidget);
    expect(find.text('Műszakórák összesen: 120'), findsOneWidget);
    expect(find.text('Munkanap: 10 · szabadnap: 20'), findsOneWidget);
    await tester.tap(find.byTooltip('Következő hónap'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026. 12. hó'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('a cycle without any work day creates nothing', (tester) async {
    await boot(tester, floating(2026, 11, 12));
    // delete the first three steps; only the trailing days off remain
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Lépés törlése').first);
      await tester.pump();
    }
    await create(tester);
    expect(find.textContaining('nincs egyetlen munkanap'), findsOneWidget);
    expect(await shifts(tester), isEmpty);
    await shutdown(tester, db);
  });
}

class _Day extends SelectedDay {
  _Day(this.d);
  final DateTime d;
  @override
  DateTime build() => d;
}
