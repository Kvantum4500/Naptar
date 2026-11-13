import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_app/ui/shift_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// A store whose reading waits for the test while its gate is set: the page is
/// "busy" for as long as the test keeps it closed.
class _GatedRepo extends EventRepository {
  _GatedRepo(super.db);
  Completer<void>? gate;

  @override
  Future<List<CalEvent>> all() async {
    final g = gate;
    if (g != null) await g.future;
    return super.all();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late EventRepository repo;

  Future<void> boot(
    WidgetTester tester,
    DateTime day, {
    EventRepository Function(AppDatabase db)? pageRepo,
  }) async {
    useSize(tester, size: const Size(900, 1400));
    db = await newDb();
    repo = EventRepository(db);
    await tester.pumpWidget(
      app(
        const ShiftPage(),
        db,
        extra: [
          selectedDayProvider.overrideWith(() => _Day(day)),
          if (pageRepo != null) repoProvider.overrideWithValue(pageRepo(db)),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<List<CalEvent>> shifts(WidgetTester tester) async =>
      (await tester.runAsync(repo.all))!
          .where((e) => isShiftNotes(e.notes))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  Future<void> create(WidgetTester tester) async {
    final btn = find.text('Létrehozás a naptárban');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
    await tester.pumpAndSettle();
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

  testWidgets('while the plan is made the page is blocked and says why', (
    tester,
  ) async {
    late _GatedRepo gated;
    await boot(
      tester,
      floating(2026, 11, 12),
      pageRepo: (db) => gated = _GatedRepo(db),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final btn = find.text('Létrehozás a naptárban');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(btn);
    gated.gate = Completer<void>(); // the work waits for the test
    await tester.tap(btn);
    await tester.pump();

    // a spinner with its words, over the page
    expect(find.text('A beosztás készül…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // nothing underneath answers meanwhile (a changed day or cycle would
    // change what is being made)
    expect(
      find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Kezdőnap'), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(DatePickerDialog), findsNothing);
    // ... and the keyboard cannot reach it either
    expect(
      tester.widget<ExcludeFocus>(find.byType(ExcludeFocus).first).excluding,
      isTrue,
    );

    gated.gate!.complete();
    gated.gate = null;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    // done: the page is live again
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('A beosztás készül…'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
      findsNothing,
    );
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

  /// The list of the coming shifts comes after the summary and the pay
  /// estimate: scroll it into view.
  Future<void> toList(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Következő műszakok'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapFirst(WidgetTester tester, String tooltip) async {
    await toList(tester);
    final f = find.byTooltip(tooltip).first;
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('swapping a shift changes type and hours and marks it modified', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await create(tester);
    await tapFirst(tester, 'Csere nappali/éjszakai');
    final first = (await shifts(tester)).first;
    expect(first.title, 'Nappali műszak');
    expect(first.start, floating(2026, 11, 12, 6));
    expect(first.end, floating(2026, 11, 12, 18));
    expect(first.notes, kShiftEditedMarker);
    expect(find.textContaining('(módosítva)'), findsWidgets);
    expect((await tester.runAsync(() => repo.pending()))!, isNotEmpty);
    await shutdown(tester, db);
  });

  testWidgets('regenerating keeps modified shifts and does not double them', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await create(tester);
    final before = (await shifts(tester)).length;
    await tapFirst(tester, 'Csere nappali/éjszakai');
    await create(tester);
    final s = await shifts(tester);
    expect(s.length, before); // the swapped day is not generated twice
    final on12 = s.where((e) => e.start.day == 12 && e.start.month == 11);
    expect(on12.length, 1);
    expect(on12.single.notes, kShiftEditedMarker);
    expect(on12.single.title, 'Nappali műszak');
    await shutdown(tester, db);
  });

  testWidgets('an extra shift can be added for the selected day', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await toList(tester);
    await tester.tap(find.text('Extra műszak'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Éjszakai'),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Hozzáadom'));
    await tester.pumpAndSettle();
    final s = await shifts(tester);
    expect(s.single.title, 'Éjszakai műszak');
    expect(s.single.start, floating(2026, 11, 12, 18));
    expect(s.single.end, floating(2026, 11, 13, 6));
    expect(s.single.notes, kShiftEditedMarker);
    await shutdown(tester, db);
  });

  testWidgets('deleting a shift needs no question and can be taken back', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await create(tester);
    final all0 = await shifts(tester);
    // the first row of the list on the page is the one that goes
    final first = all0.first;
    final row =
        '${fmtDate(first.start)} ${fmtTime(first.start)}  ${first.title}';
    await toList(tester);
    expect(find.text(row), findsOneWidget);
    await tapFirst(tester, 'Műszak törlése');
    expect(find.text('Törlöd ezt a műszakot?'), findsNothing);
    final left = await shifts(tester);
    expect(left.length, all0.length - 1);
    expect(left.any((e) => e.id == first.id), isFalse);
    expect(find.text('Műszak törölve'), findsOneWidget);
    expect(find.text(row), findsNothing, reason: 'the list is up to date');
    final hold = ProviderScope.containerOf(
      tester.element(find.byType(ShiftPage)),
    ).read(syncHoldProvider);
    expect(hold.isHeld(first.id), isTrue, reason: 'not uploaded yet');

    await tester.tap(find.text('Visszavonás'));
    await tester.pumpAndSettle();
    final back = await shifts(tester);
    expect(back.map((e) => e.id), all0.map((e) => e.id));
    expect(hold.isHeld(first.id), isFalse);
    expect(
      find.text(row),
      findsOneWidget,
      reason: 'the list on the page shows it again',
    );
    await shutdown(tester, db);
  });

  testWidgets('a deleted shift stays deleted when "Visszavonás" is not used', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await create(tester);
    final before = (await shifts(tester)).length;
    await tapFirst(tester, 'Műszak törlése');
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.text('Visszavonás'), findsNothing);
    expect((await shifts(tester)).length, before - 1);
    await shutdown(tester, db);
  });

  testWidgets('"Visszavonás" after a regeneration brings the old plan back', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await create(tester);
    final first = await shifts(tester);
    await create(tester); // replaces every generated shift
    final second = await shifts(tester);
    final hold = ProviderScope.containerOf(
      tester.element(find.byType(ShiftPage)),
    ).read(syncHoldProvider);
    expect(
      hold.isHeld(second.first.id) && hold.isHeld(first.first.id),
      isTrue,
      reason: 'neither the new nor the replaced shifts go up yet',
    );
    expect(
      second
          .map((e) => e.id)
          .toSet()
          .intersection(first.map((e) => e.id).toSet()),
      isEmpty,
    );
    expect(
      find.textContaining('Beosztás elkészült: ${second.length} műszak'),
      findsOneWidget,
    );

    await tester.tap(find.text('Visszavonás'));
    await tester.pumpAndSettle();
    final undone = await shifts(tester);
    expect(undone.map((e) => e.id).toList(), first.map((e) => e.id).toList());
    await shutdown(tester, db);
  });

  testWidgets('a hand-typed event never shows up in the shift list', (
    tester,
  ) async {
    await boot(tester, floating(2026, 11, 12));
    await tester.runAsync(
      () => repo.saveLocal(evt('hand', 'Fogorvos', floating(2026, 11, 20, 9))),
    );
    await toList(tester);
    await tester.tap(find.text('Extra műszak'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mégse'));
    await tester.pumpAndSettle();
    expect(find.text('Fogorvos'), findsNothing);
    expect(find.textContaining('Nincs műszak'), findsOneWidget);
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
