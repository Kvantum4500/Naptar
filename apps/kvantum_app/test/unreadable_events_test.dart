import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('repository', () {
    late AppDatabase db;
    late EventRepository repo;
    setUp(() async {
      db = await newDb();
      repo = EventRepository(db);
    });
    tearDown(() => db.close());

    final from = DateTime.utc(2026, 5, 1), to = DateTime.utc(2026, 5, 31);

    test('one unreadable series does not hide the other events', () async {
      await repo.saveLocal(evt('good', 'Jó', floating(2026, 5, 5, 9)));
      await repo.saveLocal(
        evt('bad', 'Rossz', floating(2026, 5, 5, 10), rrule: 'FREQ=NONSENSE'),
      );
      final occ = await repo.occurrences(from, to);
      expect(occ.map((o) => o.title), ['Jó']);
      expect((await repo.unreadableEvents()).map((e) => e.title), ['Rossz']);
    });

    test('a WKST=SU series from Google or Apple is shown normally', () async {
      await repo.saveLocal(
        evt(
          'w',
          'Heti',
          floating(2026, 5, 4, 9),
          rrule: 'FREQ=WEEKLY;WKST=SU;BYDAY=MO;COUNT=3',
        ),
      );
      expect((await repo.occurrences(from, to)).length, 3);
      expect(await repo.unreadableEvents(), isEmpty);
    });

    test('with nothing wrong nothing is reported', () async {
      await repo.saveLocal(evt('a', 'A', floating(2026, 5, 5, 9)));
      expect(await repo.unreadableEvents(), isEmpty);
    });
  });

  group('home page', () {
    testWidgets('warns about an unreadable series and can make it a single '
        'event', (tester) async {
      useSize(tester);
      final db = await newDb();
      final repo = EventRepository(db);
      await tester.runAsync(() async {
        await repo.saveLocal(
          evt(
            'bad',
            'Szétesett ismétlés',
            floating(2026, 5, 5, 10),
            rrule: 'FREQ=NONSENSE',
          ),
        );
      });
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('ismétlődési szabályát nem tudom olvasni'),
        findsOneWidget,
      );

      await tester.tap(find.text('Részletek'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Szétesett ismétlés'), findsOneWidget);
      expect(find.textContaining('FREQ=NONSENSE'), findsOneWidget);

      await tester.tap(find.text('Egyszeri eseménnyé alakít'));
      await tester.pumpAndSettle();

      // the event is a normal single event now, the warning is gone
      final saved = (await tester.runAsync(() => repo.all()))!.single;
      expect(saved.rrule, isNull);
      expect(saved.title, 'Szétesett ismétlés');
      expect(
        find.textContaining('ismétlődési szabályát nem tudom olvasni'),
        findsNothing,
      );
      await shutdown(tester, db);
    });

    testWidgets('no warning when every event is readable', (tester) async {
      useSize(tester);
      final db = await newDb();
      await tester.pumpWidget(app(const HomePage(), db));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('ismétlődési szabályát nem tudom olvasni'),
        findsNothing,
      );
      await shutdown(tester, db);
    });
  });
}
