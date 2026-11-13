import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_app/ui/event_editor.dart';
import 'package:kvantum_app/ui/repeat_editor.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// Weekly on Mondays, 4 occurrences: 4., 11., 18., 25. May 2026, 09:00.
CalEvent series() => evt(
  'm',
  'Edzés',
  floating(2026, 5, 4, 9),
  rrule: 'FREQ=WEEKLY;BYDAY=MO;COUNT=4',
);

void main() {
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late EventRepository repo;

  Future<void> openOn(WidgetTester tester, EditTarget target) async {
    useSize(tester);
    db = await newDb();
    repo = EventRepository(db);
    await tester.pumpWidget(app(EventEditor(target: target), db));
    await tester.pumpAndSettle();
  }

  Future<void> seed(WidgetTester tester, [CalEvent? e]) async {
    db = await newDb();
    repo = EventRepository(db);
    await tester.runAsync(() => repo.saveLocal(e ?? series()));
  }

  Future<void> boot(WidgetTester tester, EditTarget target) async {
    useSize(tester);
    await tester.pumpWidget(app(EventEditor(target: target), db));
    await tester.pumpAndSettle();
  }

  EditTarget occurrence2({
    List<CalEvent> overrides = const [],
    CalEvent? event,
  }) => EditTarget(
    event: event ?? series(),
    master: series(),
    overrides: overrides,
    originalStart: floating(2026, 5, 11, 9),
  );

  Future<List<CalEvent>> all(WidgetTester tester) async =>
      (await tester.runAsync(() => repo.all()))!;

  Future<void> rename(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextFormField).first, title);
    await tester.pump();
  }

  group('new events and plain edits', () {
    testWidgets(
      'new event: defaults to 09:00–10:00 on the given slot, saves one queued push',
      (tester) async {
        await openOn(
          tester,
          EditTarget(initialStart: floating(2026, 5, 4, 14, 15)),
        );
        expect(find.text('14:15'), findsOneWidget);
        expect(find.text('15:15'), findsOneWidget);
        await rename(tester, 'Futás');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        final e = (await all(tester)).single;
        expect(e.title, 'Futás');
        expect(e.calendarId, kNaptarCalendar);
        expect(e.start, floating(2026, 5, 4, 14, 15));
        expect((await tester.runAsync(() => repo.pending()))!.length, 1);
        await shutdown(tester, db);
      },
    );

    testWidgets('empty title is rejected and nothing is stored', (
      tester,
    ) async {
      await openOn(tester, EditTarget(initialDay: floating(2026, 5, 4)));
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Adj meg egy címet'), findsOneWidget);
      expect(await all(tester), isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('colour choice is saved', (tester) async {
      await openOn(tester, EditTarget(initialDay: floating(2026, 5, 4)));
      await rename(tester, 'Színes');
      await tester.scrollUntilVisible(
        find.byTooltip('Paradicsom'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Paradicsom'));
      await tester.pump();
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect((await all(tester)).single.colorId, '11');
      await shutdown(tester, db);
    });

    testWidgets(
      'closing with unsaved changes asks first; "Maradok" keeps the editor',
      (tester) async {
        await openOn(tester, EditTarget(initialDay: floating(2026, 5, 4)));
        await rename(tester, 'Fél kész');
        await tester.tap(find.byTooltip('Bezár'));
        await tester.pumpAndSettle();
        expect(find.text('Elveted a módosításokat?'), findsOneWidget);
        await tester.tap(find.text('Maradok'));
        await tester.pumpAndSettle();
        expect(find.text('Mentés'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('closing without changes needs no confirmation', (
      tester,
    ) async {
      await openOn(tester, EditTarget(initialDay: floating(2026, 5, 4)));
      await tester.tap(find.byTooltip('Bezár'));
      await tester.pumpAndSettle();
      expect(find.text('Elveted a módosításokat?'), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('editing one occurrence of a series', () {
    testWidgets('"Csak ez az esemény": a single override, series untouched', (
      tester,
    ) async {
      await seed(tester);
      await boot(tester, occurrence2());
      expect(find.textContaining('Hetente (hétfő)'), findsOneWidget);
      await rename(tester, 'Csak ma más');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect(find.text('Ismétlődő esemény módosítása'), findsOneWidget);
      await tester.tap(find.text('Csak ez az esemény'));
      await tester.pumpAndSettle();

      final events = await all(tester);
      expect(events.length, 2);
      final master = events.firstWhere((e) => e.id == 'm');
      expect(master.title, 'Edzés');
      expect(master.rrule, 'FREQ=WEEKLY;BYDAY=MO;COUNT=4');
      final ov = events.firstWhere((e) => e.isException);
      expect(ov.title, 'Csak ma más');
      expect(ov.originalStart, floating(2026, 5, 11, 9));
      expect(ov.recurringEventId, 'm');
      final occ = (await tester.runAsync(
        () => repo.occurrences(
          DateTime.utc(2026, 5, 1),
          DateTime.utc(2026, 6, 30),
        ),
      ))!;
      expect(occ.map((o) => o.title), [
        'Edzés',
        'Csak ma más',
        'Edzés',
        'Edzés',
      ]);
      await shutdown(tester, db);
    });

    testWidgets(
      '"Ez és a következők": old series ends, new series continues with the edit',
      (tester) async {
        await seed(tester);
        await boot(tester, occurrence2());
        await rename(tester, 'Új időszak');
        await tester.tap(find.text('Mentés'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ez és a következő események'));
        await tester.pumpAndSettle();

        final events = await all(tester);
        expect(events.length, 2);
        final occ = (await tester.runAsync(
          () => repo.occurrences(
            DateTime.utc(2026, 5, 1),
            DateTime.utc(2026, 7, 30),
          ),
        ))!;
        // 4 in total, the first keeps the old title, the other three the new one
        expect(occ.map((o) => o.title), [
          'Edzés',
          'Új időszak',
          'Új időszak',
          'Új időszak',
        ]);
        await shutdown(tester, db);
      },
    );

    testWidgets('"Az összes": the series itself changes, exceptions survive', (
      tester,
    ) async {
      final ov = makeOverride(
        master: series(),
        originalStart: floating(2026, 5, 18, 9),
        newId: 'o1',
        edited: series().copyWith(
          title: 'Kivétel',
          start: floating(2026, 5, 19, 9),
          end: floating(2026, 5, 19, 10),
        ),
      );
      await seed(tester);
      await tester.runAsync(() => repo.saveLocal(ov));
      await boot(tester, occurrence2(overrides: [ov]));
      await rename(tester, 'Mindenhol');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Az összes esemény'));
      await tester.pumpAndSettle();

      final occ = (await tester.runAsync(
        () => repo.occurrences(
          DateTime.utc(2026, 5, 1),
          DateTime.utc(2026, 6, 30),
        ),
      ))!;
      expect(occ.map((o) => o.title), [
        'Mindenhol',
        'Mindenhol',
        'Kivétel',
        'Mindenhol',
      ]);
      await shutdown(tester, db);
    });

    testWidgets('cancelling the scope dialog stores nothing', (tester) async {
      await seed(tester);
      await boot(tester, occurrence2());
      await rename(tester, 'Mégsem');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      await tester.tapAt(
        const Offset(5, 5),
      ); // dismiss the dialog by tapping the barrier
      await tester.pumpAndSettle();
      final events = await all(tester);
      expect(events.single.title, 'Edzés');
      await shutdown(tester, db);
    });
  });

  group('deleting from a series', () {
    testWidgets('"Csak ez": the occurrence disappears, the others stay', (
      tester,
    ) async {
      await seed(tester);
      await boot(tester, occurrence2());
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Csak ez az esemény'));
      await tester.pumpAndSettle();
      final occ = (await tester.runAsync(
        () => repo.occurrences(
          DateTime.utc(2026, 5, 1),
          DateTime.utc(2026, 6, 30),
        ),
      ))!;
      expect(occ.map((o) => o.originalStart.day), [4, 18, 25]);
      await shutdown(tester, db);
    });

    testWidgets('"Ez és a következők": the series ends before this one', (
      tester,
    ) async {
      await seed(tester);
      await boot(tester, occurrence2());
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ez és a következő események'));
      await tester.pumpAndSettle();
      final occ = (await tester.runAsync(
        () => repo.occurrences(
          DateTime.utc(2026, 5, 1),
          DateTime.utc(2026, 6, 30),
        ),
      ))!;
      expect(occ.map((o) => o.originalStart.day), [4]);
      await shutdown(tester, db);
    });

    testWidgets('"Az összes": series and its exceptions are gone', (
      tester,
    ) async {
      final ov = makeOverride(
        master: series(),
        originalStart: floating(2026, 5, 18, 9),
        newId: 'o1',
        edited: series(),
      );
      await seed(tester);
      await tester.runAsync(() => repo.saveLocal(ov));
      await boot(tester, occurrence2(overrides: [ov]));
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Az összes esemény'));
      await tester.pumpAndSettle();
      expect(await all(tester), isEmpty);
      await shutdown(tester, db);
    });

    CalEvent shiftEvent() => evt(
      'sh',
      'Nappali műszak',
      floating(2026, 5, 4, 6),
    ).copyWith(notes: kShiftMarker);

    testWidgets('saving a generated shift unchanged keeps it generated', (
      tester,
    ) async {
      final e = shiftEvent();
      await seed(tester, e);
      await boot(tester, EditTarget(event: e));
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      expect((await all(tester)).single.notes, kShiftMarker);
      await shutdown(tester, db);
    });

    testWidgets('changing a generated shift marks it modified', (tester) async {
      final e = shiftEvent();
      await seed(tester, e);
      await boot(tester, EditTarget(event: e));
      await rename(tester, 'Nappali műszak (csere)');
      await tester.tap(find.text('Mentés'));
      await tester.pumpAndSettle();
      final saved = (await all(tester)).single;
      expect(saved.title, 'Nappali műszak (csere)');
      expect(saved.notes, kShiftEditedMarker);
      await shutdown(tester, db);
    });

    testWidgets('plain event: removed at once, without a question', (
      tester,
    ) async {
      final e = evt('p', 'Egyszeri', floating(2026, 5, 4, 9));
      await seed(tester, e);
      await boot(tester, EditTarget(event: e));
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      expect(find.text('Biztosan törlöd ezt az eseményt?'), findsNothing);
      expect(await all(tester), isEmpty);
      await shutdown(tester, db);
    });
  });

  group('taking a deletion back', () {
    /// The editor opened over a page, the way the app does it: when it closes,
    /// something is left to show the bar.
    Future<void> bootOver(WidgetTester tester, EditTarget target) async {
      useSize(tester);
      await tester.pumpWidget(
        app(const Scaffold(body: Center(child: Text('Naptár'))), db),
      );
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(tester.element(find.text('Naptár'))).push(
          MaterialPageRoute<bool>(builder: (_) => EventEditor(target: target)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<List<int>> days(WidgetTester tester) async => (await tester.runAsync(
      () =>
          repo.occurrences(DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 30)),
    ))!.map((o) => o.originalStart.day).toList();

    Future<void> undo(WidgetTester tester) async {
      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
    }

    /// What the sync is told to leave alone right now.
    SyncHold hold(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.text('Naptár')))
            .read(syncHoldProvider);

    testWidgets('a plain event comes back as it was', (tester) async {
      final e = evt('p', 'Egyszeri', floating(2026, 5, 4, 9));
      await seed(tester, e);
      await bootOver(tester, EditTarget(event: e));
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      expect(find.text('Naptár'), findsOneWidget, reason: 'the editor closed');
      expect(find.text('Esemény törölve'), findsOneWidget);
      expect(await all(tester), isEmpty);
      expect(hold(tester).isHeld('p'), isTrue, reason: 'not uploaded yet');
      await undo(tester);
      expect(hold(tester).isHeld('p'), isFalse, reason: 'back to normal');
      final back = (await all(tester)).single;
      expect(back.id, 'p');
      expect(back.title, 'Egyszeri');
      expect(back.start, floating(2026, 5, 4, 9));
      await shutdown(tester, db);
    });

    testWidgets('one occurrence of a series', (tester) async {
      await seed(tester);
      await bootOver(tester, occurrence2());
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Csak ez az esemény'));
      await tester.pumpAndSettle();
      expect(find.text('Az előfordulás törölve'), findsOneWidget);
      expect(await days(tester), [4, 18, 25]);
      expect(hold(tester).isHeld('m'), isTrue, reason: 'the series is held');
      await undo(tester);
      expect(await days(tester), [4, 11, 18, 25]);
      await shutdown(tester, db);
    });

    testWidgets('this and the following ones', (tester) async {
      await seed(tester);
      await bootOver(tester, occurrence2());
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ez és a következő események'));
      await tester.pumpAndSettle();
      expect(
        find.text('Az előfordulás és a következők törölve'),
        findsOneWidget,
      );
      expect(await days(tester), [4]);
      await undo(tester);
      expect(await days(tester), [4, 11, 18, 25]);
      await shutdown(tester, db);
    });

    testWidgets('a whole series with its exception', (tester) async {
      final ov = makeOverride(
        master: series(),
        originalStart: floating(2026, 5, 18, 9),
        newId: 'o1',
        edited: series().copyWith(
          title: 'Máskor',
          start: floating(2026, 5, 18, 12),
          end: floating(2026, 5, 18, 13),
        ),
      );
      await seed(tester);
      await tester.runAsync(() => repo.saveLocal(ov));
      await bootOver(tester, occurrence2(overrides: [ov]));
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Az összes esemény'));
      await tester.pumpAndSettle();
      expect(find.text('A sorozat törölve'), findsOneWidget);
      expect(await all(tester), isEmpty);
      await undo(tester);
      final back = await all(tester);
      expect(back.map((e) => e.id).toSet(), {'m', 'o1'});
      expect(back.firstWhere((e) => e.id == 'o1').title, 'Máskor');
      expect(await days(tester), [4, 11, 18, 25]);
      await shutdown(tester, db);
    });

    testWidgets('the bar goes after ten seconds and the deletion stays', (
      tester,
    ) async {
      final e = evt('p', 'Egyszeri', floating(2026, 5, 4, 9));
      await seed(tester, e);
      await bootOver(tester, EditTarget(event: e));
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      expect(find.text('Visszavonás'), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Visszavonás'), findsNothing);
      expect(await all(tester), isEmpty);
      expect(hold(tester).isHeld('p'), isFalse, reason: 'it goes up now');
      await shutdown(tester, db);
    });

    testWidgets('a change made meanwhile is not overwritten', (tester) async {
      await seed(tester);
      await bootOver(tester, occurrence2());
      await tester.tap(find.byTooltip('Törlés'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Csak ez az esemény'));
      await tester.pumpAndSettle();
      // the user renames the series while the bar is up
      final m = (await tester.runAsync(() => repo.byId('m')))!;
      await tester.runAsync(
        () => repo.saveLocal(m.copyWith(title: 'Átnevezve')),
      );
      await undo(tester);
      expect(
        find.text('A visszavonás már nem lehetséges: közben megváltozott.'),
        findsOneWidget,
      );
      expect((await tester.runAsync(() => repo.byId('m')))!.title, 'Átnevezve');
      expect(await days(tester), [4, 18, 25], reason: 'nothing was undone');
      await shutdown(tester, db);
    });
  });

  group('RepeatEditor', () {
    Future<RecurrenceSpec?> drive(
      WidgetTester tester,
      DateTime start,
      RecurrenceSpec? initial,
      Future<void> Function(RecurrenceSpec? Function() current) body,
    ) async {
      useSize(tester);
      RecurrenceSpec? spec = initial;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('hu'),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (c, set) => SingleChildScrollView(
                child: RepeatEditor(
                  start: start,
                  spec: spec,
                  onChanged: (s) => set(() => spec = s),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body(() => spec);
      return spec;
    }

    testWidgets(
      'weekly with chosen weekdays and an end count, with live preview',
      (tester) async {
        final start = floating(2026, 5, 4, 9); // Monday
        final spec = await drive(tester, start, null, (cur) async {
          await tester.tap(find.text('Nem ismétlődik'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Hetente').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Cs')); // add Thursday
          await tester.pumpAndSettle();
          expect(cur()!.weekdays, {1, 4});
          await tester.tap(find.text('Soha'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Alkalmak száma után').last);
          await tester.pumpAndSettle();
          await tester.enterText(find.widgetWithText(TextField, '10'), '6');
          await tester.pumpAndSettle();
          expect(find.textContaining('Következő alkalmak'), findsOneWidget);
        });
        expect(spec!.toRrule(start), 'FREQ=WEEKLY;BYDAY=MO,TH;COUNT=6');
      },
    );

    testWidgets('monthly offers day-of-month, nth and last weekday', (
      tester,
    ) async {
      final start = floating(2026, 5, 18, 9); // 3rd Monday
      await drive(
        tester,
        start,
        const RecurrenceSpec(freq: RepeatFreq.monthly),
        (cur) async {
          expect(find.text('Minden hónap 18. napján'), findsOneWidget);
          expect(find.text('Minden hónap 3. hétfő'), findsOneWidget);
          expect(find.text('Minden hónap utolsó hétfő'), findsOneWidget);
          await tester.tap(find.text('Minden hónap utolsó hétfő'));
          await tester.pumpAndSettle();
          expect(cur()!.toRrule(start), 'FREQ=MONTHLY;BYDAY=-1MO');
        },
      );
    });

    testWidgets(
      '5th weekday hides the "nth" choice (it would not exist every month)',
      (tester) async {
        final start = floating(2026, 3, 30, 9); // 5th Monday of March
        await drive(
          tester,
          start,
          const RecurrenceSpec(freq: RepeatFreq.monthly),
          (cur) async {
            expect(find.textContaining('Minden hónap 5.'), findsNothing);
            expect(find.text('Minden hónap utolsó hétfő'), findsOneWidget);
          },
        );
      },
    );

    testWidgets('invalid count shows a message instead of a preview', (
      tester,
    ) async {
      final start = floating(2026, 5, 4, 9);
      await drive(
        tester,
        start,
        const RecurrenceSpec(
          freq: RepeatFreq.daily,
          end: RepeatEnd.count,
          count: 5,
        ),
        (cur) async {
          await tester.enterText(find.widgetWithText(TextField, '5'), '0');
          await tester.pumpAndSettle();
          expect(
            find.text('Az alkalmak száma 1 és 5000 között lehet.'),
            findsOneWidget,
          );
        },
      );
    });

    testWidgets('choosing "Nem ismétlődik" clears the rule', (tester) async {
      final start = floating(2026, 5, 4, 9);
      final spec = await drive(
        tester,
        start,
        const RecurrenceSpec(freq: RepeatFreq.daily),
        (cur) async {
          await tester.tap(find.text('Naponta').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Nem ismétlődik').last);
          await tester.pumpAndSettle();
        },
      );
      expect(spec, isNull);
    });
  });
}
