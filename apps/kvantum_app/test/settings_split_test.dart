import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/backup_io.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

// The settings page is a long list of cards, and what the user has typed or
// started on one of them is the page's, not the card's: scroll the card out of
// sight and back, and it is still there. (A list builds only what is near the
// screen and drops the rest, so a card that keeps its own state has to be told
// to keep it.) The order of the cards, the keys and the first text field are
// pinned by settings_groups_test; this pins what must survive the scrolling.

/// Reading the whole calendar waits for [gate] while [closedReads] is set.
class _GatedRepo extends EventRepository {
  _GatedRepo(super.db);
  bool closedReads = false;
  final gate = Completer<void>();

  @override
  Future<List<CalEvent>> all() async {
    if (closedReads) await gate.future;
    return super.all();
  }
}

class _MemoryIo implements BackupIo {
  String? saved;

  @override
  Future<bool> save(
    String fileName,
    String text, {
    String mimeType = 'text/calendar',
    String dialogTitle = 'Naptár mentése',
  }) async {
    saved = text;
    return true;
  }

  @override
  Future<String?> pick() async => null;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late _GatedRepo repo;
  late _MemoryIo io;

  /// The page in a window so low that most of the cards are out of the list.
  Future<void> boot(WidgetTester tester, {String? key}) async {
    useSize(tester, size: const Size(700, 520));
    db = await newDb();
    repo = _GatedRepo(db);
    io = _MemoryIo();
    await tester.pumpWidget(
      app(
        const SettingsPage(),
        db,
        extra: [
          apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(key)),
          currentBuildProvider.overrideWith((ref) async => 7),
          repoProvider.overrideWithValue(repo),
          backupIoProvider.overrideWithValue(io),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  final list = find.byType(Scrollable).first;

  /// Scrolls down / up, a step at a time, until [what] is there to be used.
  Future<void> down(WidgetTester tester, Finder what) async {
    await tester.scrollUntilVisible(what, 250, scrollable: list);
    await tester.pump();
  }

  Future<void> up(WidgetTester tester, Finder what) async {
    await tester.scrollUntilVisible(what, -250, scrollable: list);
    await tester.pump();
  }

  /// Right down to the last card: everything above has been out of sight, and
  /// further than the list builds ahead.
  Future<void> awayFromTheTop(WidgetTester tester) async {
    await down(tester, find.text('A program'));
    expect(
      find.byType(TextField),
      findsNothing,
      reason: 'the fields of the top cards are out of the list now',
    );
  }

  Finder buttonOf(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  bool waiting(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(buttonOf(label)).onPressed == null;

  testWidgets('what was typed as the key is there after the card was away', (
    tester,
  ) async {
    await boot(tester);
    await down(tester, find.widgetWithText(TextField, 'API-kulcs'));
    await tester.enterText(
      find.widgetWithText(TextField, 'API-kulcs'),
      'gsk_secret-typed',
    );
    // (a field that has the focus keeps its card in the list by itself: it is
    // the card's own keeping that is under test, so the focus goes first)
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await awayFromTheTop(tester);
    await up(tester, find.widgetWithText(TextField, 'API-kulcs'));
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'API-kulcs'),
    );
    expect(field.controller?.text, 'gsk_secret-typed');
    await shutdown(tester, db);
  });

  testWidgets('the choice to show the key holds the same way', (tester) async {
    await boot(tester);
    TextField field() =>
        tester.widget<TextField>(find.widgetWithText(TextField, 'API-kulcs'));
    await down(tester, find.byTooltip('Mutat'));
    expect(field().obscureText, isTrue);
    await tester.tap(find.byTooltip('Mutat'));
    await tester.pump();
    expect(field().obscureText, isFalse);
    await awayFromTheTop(tester);
    await up(tester, find.widgetWithText(TextField, 'API-kulcs'));
    expect(field().obscureText, isFalse);
    expect(find.byTooltip('Elrejt'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('what the key section said is still said after it was away', (
    tester,
  ) async {
    await boot(tester, key: 'k');
    await down(tester, find.text('Kulcs törlése'));
    expect(find.text('API-kulcs megadva'), findsOneWidget);
    await tester.tap(find.text('Kulcs törlése'));
    await tester.pumpAndSettle();
    expect(find.text('A kulcs törölve.'), findsOneWidget);
    await awayFromTheTop(tester);
    await up(tester, find.text('A kulcs törölve.'));
    expect(find.text('A kulcs törölve.'), findsOneWidget);
    expect(find.text('Nincs API-kulcs'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('a file job that runs is still shown after its buttons were '
      'away', (tester) async {
    await boot(tester);
    await down(tester, find.text('Mentés fájlba'));
    await tester.pumpAndSettle();
    repo.closedReads = true; // the export waits for the calendar
    await tester.tap(find.text('Mentés fájlba'));
    await tester.pump();
    expect(
      find.descendant(
        of: buttonOf('Mentés fájlba'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(waiting(tester, 'Visszaállítás fájlból'), isTrue);

    // up to the top, where the key field is, and down again
    await up(tester, find.widgetWithText(TextField, 'API-kulcs'));
    expect(find.text('Mentés fájlba'), findsNothing);
    await down(tester, find.text('Mentés fájlba'));
    expect(
      find.descendant(
        of: buttonOf('Mentés fájlba'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: 'the job still runs: the spinner is still there',
    );
    for (final b in [
      'Mentés fájlba',
      'Visszaállítás fájlból',
      'Pénzügyek mentése',
      'Pénzügyek visszaállítása',
    ]) {
      expect(waiting(tester, b), isTrue, reason: '$b still waits');
    }

    repo.gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(waiting(tester, 'Mentés fájlba'), isFalse);
    expect(io.saved, isNotNull, reason: 'the job ended where it began');
    expect(find.text('A naptár elmentve.'), findsOneWidget);
    await shutdown(tester, db);
  });
}
