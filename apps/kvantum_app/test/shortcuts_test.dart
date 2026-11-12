import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/shortcuts.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';
import 'support/manual_timers.dart';

class _Sync extends SyncController {
  final calls = <String>[];
  @override
  SyncState build() => SyncState(
    configured: true,
    signedIn: true,
    lastSync: DateTime(2026, 11, 12),
  );
  @override
  Future<void> syncNow({bool manual = false}) async =>
      calls.add(manual ? 'manual' : 'auto');
  @override
  void requestSync() {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late _Sync sync;
  late ProviderContainer c;

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    sync = _Sync();
    final timers = ManualTimers();
    await tester.pumpWidget(
      app(
        const HomePage(),
        db,
        extra: [
          appClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 11, 12, 9),
          ),
          midnightTimerProvider.overrideWithValue(timers.make),
          syncControllerProvider.overrideWith(() => sync),
        ],
      ),
    );
    await tester.pumpAndSettle();
    c = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    String? character,
  }) async {
    await tester.sendKeyEvent(key, character: character);
    await tester.pumpAndSettle();
  }

  group('on the calendar page', () {
    testWidgets('N opens the editor for a new event', (tester) async {
      await boot(tester);
      expect(find.text('Mentés'), findsNothing);
      await press(tester, LogicalKeyboardKey.keyN);
      expect(find.text('Mentés'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the editor is a dialog from the rail width', (tester) async {
      await boot(tester, size: const Size(760, 900));
      await press(tester, LogicalKeyboardKey.keyN);
      expect(find.text('Mentés'), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('below it the editor is a page of its own', (tester) async {
      await boot(tester, size: const Size(759, 900));
      await press(tester, LogicalKeyboardKey.keyN);
      expect(find.text('Mentés'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the arrows step by the view and T comes back to today', (
      tester,
    ) async {
      await boot(tester);
      expect(find.text('2026. november'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('2026. december'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('2027. január'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('2026. december'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyT);
      expect(find.text('2026. november'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'the arrows move a week in the week view, a day in the day view',
      (tester) async {
        await boot(tester);
        await press(tester, LogicalKeyboardKey.digit2);
        final before = c.read(selectedDayProvider);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(
          c.read(selectedDayProvider),
          before.add(const Duration(days: 7)),
        );
        await press(tester, LogicalKeyboardKey.digit3);
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(
          c.read(selectedDayProvider),
          before.add(const Duration(days: 6)),
        );
        await shutdown(tester, db);
      },
    );

    testWidgets('1, 2 and 3 choose month, week and day', (tester) async {
      await boot(tester);
      await press(tester, LogicalKeyboardKey.digit2);
      expect(c.read(viewModeProvider), CalView.week);
      await press(tester, LogicalKeyboardKey.digit3);
      expect(c.read(viewModeProvider), CalView.day);
      await press(tester, LogicalKeyboardKey.digit1);
      expect(c.read(viewModeProvider), CalView.month);
      await shutdown(tester, db);
    });

    testWidgets('F5 starts a manual sync', (tester) async {
      await boot(tester);
      await press(tester, LogicalKeyboardKey.f5);
      expect(sync.calls, ['manual']);
      await shutdown(tester, db);
    });

    testWidgets('F1 and ? open the help, which lists the commands', (
      tester,
    ) async {
      await boot(tester);
      await press(tester, LogicalKeyboardKey.f1);
      expect(find.text('Billentyűparancsok'), findsOneWidget);
      for (final (_, what) in shortcutHelp) {
        expect(find.text(what), findsOneWidget, reason: what);
      }
      await tester.tap(find.byKey(const Key('shortcut-help-close')));
      await tester.pumpAndSettle();
      expect(find.text('Billentyűparancsok'), findsNothing);

      await press(tester, LogicalKeyboardKey.slash, character: '?');
      expect(find.text('Billentyűparancsok'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a command does nothing while a dialog is open', (
      tester,
    ) async {
      await boot(tester);
      await press(tester, LogicalKeyboardKey.f1);
      await press(tester, LogicalKeyboardKey.digit2);
      expect(c.read(viewModeProvider), CalView.month);
      await shutdown(tester, db);
    });
  });

  group('typing', () {
    /// A page with a text field next to the keyboard layer.
    Future<(ValueNotifier<int>, FocusNode)> pumpField(
      WidgetTester tester,
    ) async {
      final hits = ValueNotifier<int>(0);
      final field = FocusNode();
      addTearDown(field.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: CalendarKeys(
              actions: {
                NewEventIntent: PageAction<NewEventIntent>((_) => hits.value++),
              },
              child: Scaffold(body: TextField(focusNode: field)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (hits, field);
    }

    testWidgets('a key still does its work when nothing is being typed', (
      tester,
    ) async {
      final (hits, _) = await pumpField(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(hits.value, 1);
    });

    testWidgets('a key typed into a text field starts no command', (
      tester,
    ) async {
      final (hits, field) = await pumpField(tester);
      field.requestFocus();
      await tester.pump();
      expect(isEditingText(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      expect(hits.value, 0, reason: 'the "n" belongs to the text');
      field.unfocus();
      await tester.pump();
    });
  });

  test('the help names every key of the map', () {
    final keys = shortcutHelp.map((e) => e.$1).toList();
    expect(
      keys,
      containsAll(['N', 'T', '← →', '1  2  3', 'F5', 'F1  vagy  ?']),
    );
  });

  test('the key map has no key twice and every command has an action', () {
    final intents = calendarShortcuts.values.map((i) => i.runtimeType).toSet();
    expect(intents, {
      NewEventIntent,
      TodayIntent,
      StepIntent,
      ViewIntent,
      SyncIntent,
      HelpIntent,
    });
  });
}
