import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/journal/journal_draft_store.dart';
import 'package:kvantum_app/journal/journal_ops.dart';
import 'package:kvantum_app/journal/journal_providers.dart';
import 'package:kvantum_app/journal/photo_files.dart';
import 'package:kvantum_app/journal/photo_import.dart';
import 'package:kvantum_app/journal/photo_picker.dart';
import 'package:kvantum_app/journal/photo_pipeline.dart'
    show maxPhotoSourceBytes;
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_app/ui/journal/entries_page.dart';
import 'package:kvantum_app/ui/journal/entry_editor.dart';
import 'package:kvantum_app/ui/journal/photo_widgets.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/diary.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';
import 'support/pickers.dart';
import 'support/semantics_tree.dart';
import 'support/turns.dart';

/// The diary page and its editor (8th round): the list by day, what an entry
/// shows, writing and changing one, the pictures, what is kept when the app is
/// closed, deleting with a way back, and the viewer.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  // 11:30 on the 16th in Budapest (a Monday)
  final clock = DateTime.utc(2026, 11, 16, 10, 30);
  final nov16 = DateTime.utc(2026, 11, 16, 11, 30);
  late AppDatabase db;
  late MemoryPhotoFiles files;
  late FakePicker picker;
  int stored = 0;

  /// (the page under an editor is off the screen, so it is the app that is
  /// asked for the providers)
  ProviderContainer scope(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  /// The database is read for real, and every save is a few steps of it: a few
  /// rounds of real turns and frames let all of it arrive (turns, not time).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(turns);
      await tester.pumpAndSettle();
    }
  }

  JournalEntry entry(
    String id, {
    DateTime? at,
    String title = 'Kirándulás',
    String text = 'Szép idő volt.',
    List<PhotoRef> photos = const [],
  }) => JournalEntry.checked(
    id: id,
    at: at ?? nov16,
    title: title,
    text: text,
    photos: photos,
  );

  PhotoRef photo(String id, {bool here = true}) {
    if (here) files.put('$id.jpg', tinyJpeg);
    return PhotoRef(id: id, width: 1200, height: 800, bytes: tinyJpeg.length);
  }

  Future<void> boot(
    WidgetTester tester, {
    List<JournalEntry> entries = const [],
    Size size = const Size(400, 900),
    double? textScale,
    ThemeMode themeMode = ThemeMode.light,
    PhotoImporter? importer,
    List<Override> extra = const [],
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    await tester.pumpWidget(
      app(
        const JournalEntriesPage(),
        db,
        extra: [
          appClockProvider.overrideWithValue(() => clock),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          photoFilesProvider.overrideWithValue(files),
          photoPickerProvider.overrideWithValue(picker),
          photoImporterProvider.overrideWith(
            (ref) =>
                importer ??
                PhotoImporter(
                  files: files,
                  processor: fakeProcessor,
                  newId: () => 'new${++stored}',
                ),
          ),
          ...extra,
        ],
        textScale: textScale,
        themeMode: themeMode,
      ),
    );
    await settle(tester);
    final c = scope(tester);
    for (final e in entries) {
      await tester.runAsync(() => c.read(journalOpsProvider).save(e));
      await settle(tester);
    }
  }

  setUp(() {
    stored = 0;
    // (before the test body: its pictures are put into this store)
    files = MemoryPhotoFiles();
    picker = FakePicker();
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pump();
    await tester.tap(find.byKey(Key(key)));
    await settle(tester);
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  Future<List<JournalEntry>> saved(WidgetTester tester) async => (await tester
      .runAsync(() => scope(tester).read(journalEntriesProvider.future)))!;

  group('the list', () {
    testWidgets('says so when the diary cannot be read', (tester) async {
      await boot(
        tester,
        extra: [
          journalEntriesProvider.overrideWith(
            (ref) => Stream<List<JournalEntry>>.error(StateError('x')),
          ),
        ],
      );
      expect(find.byKey(const Key('journal-error')), findsOneWidget);
      // (and it says why, in the words the error catalog has for it)
      expect(
        tester.widget<Text>(find.byKey(const Key('journal-error'))).data,
        'A napló nem olvasható. ${errorInfoFor(StateError('x')).text}',
      );
      expect(find.byKey(const Key('journal-add')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('says what the diary is for when it is empty', (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('journal-empty')), findsOneWidget);
      expect(find.textContaining('Még nincs bejegyzésed'), findsOneWidget);
      expect(find.byKey(const Key('journal-add')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('has the days, the latest first, with their entries', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [
          entry('a', at: DateTime.utc(2026, 11, 14, 9, 5), title: 'Szombat'),
          entry('b', at: DateTime.utc(2026, 11, 16, 7, 40), title: 'Reggel'),
          entry('c', at: DateTime.utc(2026, 11, 16, 18, 20), title: 'Este'),
        ],
      );
      expect(find.byKey(const Key('journal-empty')), findsNothing);
      final d16 = tester.getTopLeft(
        find.byKey(const Key('journal-day-2026-11-16')),
      );
      final d14 = tester.getTopLeft(
        find.byKey(const Key('journal-day-2026-11-14')),
      );
      expect(d16.dy, lessThan(d14.dy));
      expect(
        find.text(fmtDateLong(DateTime.utc(2026, 11, 16))),
        findsOneWidget,
      );
      // (the evening before the morning, in a day)
      final este = tester.getTopLeft(find.byKey(const Key('entry-c')));
      final reggel = tester.getTopLeft(find.byKey(const Key('entry-b')));
      final szombat = tester.getTopLeft(find.byKey(const Key('entry-a')));
      expect(este.dy, lessThan(reggel.dy));
      expect(reggel.dy, lessThan(szombat.dy));
      expect(find.text('18:20'), findsOneWidget);
      expect(find.text('09:05'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('shows the head, the first lines, and no deleted entry', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [
          entry('a', title: 'Fogorvos', text: 'Egy\nKettő\nHárom\nNégy\nÖt'),
          entry('gone', title: 'Törölt'),
        ],
      );
      await tester.runAsync(
        () => scope(tester).read(journalOpsProvider).delete('gone'),
      );
      await settle(tester);
      expect(find.text('Fogorvos'), findsOneWidget);
      expect(find.textContaining('Egy\nKettő\nHárom'), findsOneWidget);
      expect(find.textContaining('Négy'), findsNothing);
      expect(find.text('Törölt'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets(
      'an entry without a title has its first line as the head, once',
      (tester) async {
        await boot(
          tester,
          entries: [
            entry('a', title: '', text: 'Hosszú nap volt\nMásodik sor'),
          ],
        );
        expect(find.text('Hosszú nap volt'), findsOneWidget);
        expect(find.text('Második sor'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('shows four pictures and says how many more there are', (
      tester,
    ) async {
      await boot(tester);
      final photos = [for (var i = 0; i < 6; i++) photo('p$i')];
      await tester.runAsync(
        () =>
            scope(tester)
                .read(journalOpsProvider)
                .save(entry('a', photos: photos)),
      );
      await settle(tester);
      expect(find.byType(PhotoThumb), findsNWidgets(entryThumbsShown));
      expect(find.byKey(const Key('entry-more-a')), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('says "+N" only for the pictures that are not shown', (
      tester,
    ) async {
      await boot(tester);
      final c = scope(tester);
      // one picture, exactly as many as are shown, and one more than that
      for (final (id, n) in [('one', 1), ('full', 4), ('over', 5)]) {
        final photos = [for (var i = 0; i < n; i++) photo('$id$i')];
        await tester.runAsync(
          () => c
              .read(journalOpsProvider)
              .save(
                entry(
                  id,
                  photos: photos,
                  at: nov16.add(Duration(minutes: n)),
                  title: id,
                ),
              ),
        );
        await settle(tester);
      }
      expect(find.byKey(const Key('entry-more-one')), findsNothing);
      expect(find.byKey(const Key('entry-more-full')), findsNothing);
      expect(find.byKey(const Key('entry-more-over')), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('+0'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a picture that is on another device is told so', (
      tester,
    ) async {
      await boot(tester);
      final p = photo('elsewhere', here: false);
      await tester.runAsync(
        () =>
            scope(tester)
                .read(journalOpsProvider)
                .save(entry('a', photos: [p])),
      );
      await settle(tester);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.byTooltip(photoElsewhereText), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an entry is read out as one thing', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(
        tester,
        entries: [
          entry(
            'a',
            title: 'Fogorvos',
            text: 'Nem fájt.',
            photos: [photo('p1'), photo('p2')],
          ),
        ],
      );
      expect(
        find.bySemanticsLabel('Bejegyzés, 11:30. Fogorvos. Nem fájt.. 2 kép'),
        findsOneWidget,
      );
      // (as that one sentence, not also piece by piece under it)
      expect(
        semanticChildCount(
          tester,
          find.bySemanticsLabel('Bejegyzés, 11:30. Fogorvos. Nem fájt.. 2 kép'),
        ),
        0,
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('a single picture is read out, and the lines of the text run '
        'together', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(
        tester,
        entries: [
          entry(
            'a',
            title: 'Séta',
            text: 'Első sor\nMásodik sor',
            photos: [photo('p1')],
          ),
        ],
      );
      expect(
        find.bySemanticsLabel(
          'Bejegyzés, 11:30. Séta. Első sor Második sor. 1 kép',
        ),
        findsOneWidget,
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('an entry another device wrote appears without a restart', (
      tester,
    ) async {
      await boot(tester);
      final e = entry('x', title: 'Másik gépről');
      await tester.runAsync(
        () => scope(tester)
            .read(recordRepoProvider)
            .applyRemote(
              SyncRecord(
                id: 'x',
                kind: kindJournal,
              ).edit(e.fields, ts: 9000000000000, dev: 'dev2'),
            ),
      );
      await settle(tester);
      expect(find.text('Másik gépről'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a tap opens the entry with what it holds', (tester) async {
      await boot(
        tester,
        entries: [
          entry(
            'a',
            title: 'Fogorvos',
            text: 'Nem fájt.',
            photos: [photo('p1')],
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      expect(find.text('Bejegyzés'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('entry-title')))
            .controller!
            .text,
        'Fogorvos',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('entry-text')))
            .controller!
            .text,
        'Nem fájt.',
      );
      expect(find.text('Képek (1/12)'), findsOneWidget);
      expect(find.byKey(const Key('entry-delete')), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  /// The back button of the page (found by its type: its words depend on the
  /// language).
  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await settle(tester);
  }

  /// The app goes to the background for a moment, and comes back (a frame is
  /// not drawn while it is away).
  Future<void> background(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settle(tester);
  }

  Future<void> openNew(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('journal-add')));
    await settle(tester);
  }

  Finder field(String key) => find.byKey(Key(key));
  String textOf(WidgetTester tester, String key) =>
      tester.widget<TextField>(field(key)).controller!.text;

  group('writing a new entry', () {
    testWidgets('starts now, with empty fields and no pictures', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      expect(find.text('Új bejegyzés'), findsOneWidget);
      expect(find.text(fmtDateLong(nov16)), findsOneWidget);
      expect(find.text('11:30'), findsOneWidget);
      expect(textOf(tester, 'entry-title'), '');
      expect(textOf(tester, 'entry-text'), '');
      expect(find.text('Képek (0/12)'), findsOneWidget);
      expect(find.byKey(const Key('entry-delete')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('is saved, and then it is on the list', (tester) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-title', 'Fogorvos');
      await enter(tester, 'entry-text', 'Nem fájt.\nHétfőn megyek újra.');
      await tapKey(tester, 'entry-save');
      expect(find.byType(JournalEntryEditor), findsNothing);
      expect(find.text('Fogorvos'), findsOneWidget);
      final e = (await saved(tester)).single;
      expect(e.at, nov16);
      expect(e.title, 'Fogorvos');
      expect(e.text, 'Nem fájt.\nHétfőn megyek újra.');
      await shutdown(tester, db);
    });

    testWidgets('with nothing in it is not saved, and says why', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await tapKey(tester, 'entry-save');
      expect(
        find.text('Írj valamit, vagy tölts fel egy képet.'),
        findsOneWidget,
      );
      expect(find.byType(JournalEntryEditor), findsOneWidget);
      expect(await saved(tester), isEmpty);
      // (and once there is something, the message goes with the save)
      await enter(tester, 'entry-text', 'x');
      await tapKey(tester, 'entry-save');
      expect(find.byKey(const Key('entry-error')), findsNothing);
      expect(await saved(tester), hasLength(1));
      await shutdown(tester, db);
    });

    testWidgets('keeps a title and a text within their limits', (tester) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-title', 'c' * 120);
      expect(textOf(tester, 'entry-title').length, maxJournalTitle);
      await enter(tester, 'entry-text', 't' * 21000);
      expect(textOf(tester, 'entry-text').length, maxJournalText);
      await shutdown(tester, db);
    });

    testWidgets('counts the characters only near the end', (tester) async {
      await boot(tester);
      await openNew(tester);
      expect(find.text('0 / $maxJournalTitle'), findsNothing);
      await enter(tester, 'entry-title', 'c' * 75);
      expect(find.text('75 / $maxJournalTitle'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('can be put on another day', (tester) async {
      await boot(tester);
      await openNew(tester);
      await tapKey(tester, 'entry-day');
      await tester.tap(find.text('14'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(
        find.text(fmtDateLong(DateTime.utc(2026, 11, 14))),
        findsOneWidget,
      );
      await enter(tester, 'entry-text', 'Szombati');
      await tapKey(tester, 'entry-save');
      expect(
        (await saved(tester)).single.at,
        DateTime.utc(2026, 11, 14, 11, 30),
      );
      await shutdown(tester, db);
    });

    testWidgets('can be put at another time', (tester) async {
      await boot(tester);
      await openNew(tester);
      await tapKey(tester, 'entry-time');
      await typeTimeInPicker(tester, 21, 40);
      expect(find.text('21:40'), findsOneWidget);
      await enter(tester, 'entry-text', 'Késő este');
      await tapKey(tester, 'entry-save');
      expect(
        (await saved(tester)).single.at,
        DateTime.utc(2026, 11, 16, 21, 40),
      );
      await shutdown(tester, db);
    });

    testWidgets('leaving it with something written asks first', (tester) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Fél sor');
      await back(tester);
      expect(find.byKey(const Key('discard-dialog')), findsOneWidget);
      // "Maradok": back to the writing, nothing lost
      await tapKey(tester, 'discard-stay');
      expect(find.byType(JournalEntryEditor), findsOneWidget);
      expect(textOf(tester, 'entry-text'), 'Fél sor');
      // "Elvetem": gone, nothing saved
      await back(tester);
      await tapKey(tester, 'discard-yes');
      expect(find.byType(JournalEntryEditor), findsNothing);
      expect(await saved(tester), isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('leaving it with only a title asks first', (tester) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-title', 'Csak egy cím');
      await back(tester);
      expect(find.byKey(const Key('discard-dialog')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('leaving it with only a picture asks first', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [chosen('a.jpg')];
      await tapKey(tester, 'entry-add-photo');
      await back(tester);
      expect(find.byKey(const Key('discard-dialog')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a tap outside the question about leaving keeps the writing', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Ez marad');
      await back(tester);
      expect(find.byKey(const Key('discard-dialog')), findsOneWidget);
      // (the question is closed by a tap beside it: no answer is no "Elvetem")
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.byKey(const Key('discard-dialog')), findsNothing);
      expect(find.byType(JournalEntryEditor), findsOneWidget);
      expect(textOf(tester, 'entry-text'), 'Ez marad');
      await shutdown(tester, db);
    });

    testWidgets('leaving it untouched asks nothing', (tester) async {
      await boot(tester);
      await openNew(tester);
      await back(tester);
      expect(find.byKey(const Key('discard-dialog')), findsNothing);
      expect(find.byType(JournalEntryEditor), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('that cannot be saved says so and stays', (tester) async {
      await boot(
        tester,
        extra: [
          journalOpsProvider.overrideWith(
            (ref) => _FailingOps(ref.watch(recordRepoProvider)),
          ),
        ],
      );
      await openNew(tester);
      await enter(tester, 'entry-text', 'Nem menthető');
      await tapKey(tester, 'entry-save');
      expect(find.byKey(const Key('entry-error')), findsOneWidget);
      expect(find.byType(JournalEntryEditor), findsOneWidget);
      expect(
        tester.widget<TextButton>(field('entry-save')).onPressed,
        isNotNull,
      );
      expect(textOf(tester, 'entry-text'), 'Nem menthető');
      await shutdown(tester, db);
    });
  });

  group('the pictures of an entry', () {
    testWidgets('are added from what the user chose', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [chosen('a.jpg'), chosen('b.jpg')];
      await tapKey(tester, 'entry-add-photo');
      expect(picker.calls, 1);
      expect(find.text('Képek (2/12)'), findsOneWidget);
      expect(find.byKey(const Key('entry-photo-new1')), findsOneWidget);
      expect(find.byKey(const Key('entry-photo-new2')), findsOneWidget);
      expect(files.names.toSet(), {'new1.jpg', 'new2.jpg'});
      await tapKey(tester, 'entry-save');
      final e = (await saved(tester)).single;
      expect([for (final p in e.photos) p.id], ['new1', 'new2']);
      expect(e.photos.first.width, 1200);
      await shutdown(tester, db);
    });

    testWidgets('taken in with a failure that is the whole import: told, and '
        'the entry goes on', (tester) async {
      final sink = MemoryDiagSink();
      final log = DiagLog()..attach(sink);
      await boot(
        tester,
        importer: _BrokenImporter(),
        extra: [diagLogProvider.overrideWithValue(log)],
      );
      await openNew(tester);
      await enter(tester, 'entry-text', 'Kép nélkül is mentem');
      picker.next = [chosen('a.jpg')];
      await tapKey(tester, 'entry-add-photo');
      expect(
        tester.widget<Text>(find.byKey(const Key('entry-notice'))).data,
        'A képeket nem sikerült felvenni.',
      );
      expect(find.byKey(const Key('entry-busy')), findsNothing);
      expect(find.text('Képek (0/12)'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(field('entry-add-photo')).onPressed,
        isNotNull,
      );
      await tester.runAsync(log.flush);
      expect(sink.lines.join('\n'), contains('photo.import_failed'));
      await tapKey(tester, 'entry-save');
      expect((await saved(tester)).single.text, 'Kép nélkül is mentem');
      await shutdown(tester, db);
    });

    testWidgets('can be taken out of the entry', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [chosen('a.jpg'), chosen('b.jpg')];
      await tapKey(tester, 'entry-add-photo');
      await tapKey(tester, 'entry-photo-remove-new1');
      expect(find.text('Képek (1/12)'), findsOneWidget);
      expect(find.byKey(const Key('entry-photo-new1')), findsNothing);
      await tapKey(tester, 'entry-save');
      expect(
        [for (final p in (await saved(tester)).single.photos) p.id],
        ['new2'],
      );
      await shutdown(tester, db);
    });

    testWidgets('a picture alone makes an entry', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [chosen('a.jpg')];
      await tapKey(tester, 'entry-add-photo');
      await tapKey(tester, 'entry-save');
      final e = (await saved(tester)).single;
      expect(e.title, '');
      expect(e.heading, '1 kép');
      await shutdown(tester, db);
    });

    testWidgets('that could not be taken in are told of, the rest is kept', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [
        chosen('ok.jpg'),
        chosen('nem.jpg', first: 0),
        chosen('nagy.jpg', size: maxPhotoSourceBytes + 1),
      ];
      await tapKey(tester, 'entry-add-photo');
      expect(find.text('Képek (1/12)'), findsOneWidget);
      expect(
        find.text(
          '1 kép túl nagy (legfeljebb 40 MB); 1 fájl nem kép, vagy ezen az eszközön nem olvasható.',
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('are at most twelve, and the button says so', (tester) async {
      await boot(tester, size: const Size(400, 2000));
      await openNew(tester);
      picker.next = [for (var i = 0; i < 14; i++) chosen('p$i.jpg')];
      await tapKey(tester, 'entry-add-photo');
      expect(find.text('Képek (12/12)'), findsOneWidget);
      expect(find.textContaining('2 kimaradt'), findsOneWidget);
      expect(find.text('Legföljebb 12 kép lehet.'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(field('entry-add-photo')).onPressed,
        isNull,
      );
      await shutdown(tester, db);
    });

    testWidgets('are taken in with the buttons of the page switched off', (
      tester,
    ) async {
      final slow = _SlowImporter();
      await boot(tester, importer: slow);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Várom a képet');
      picker.next = [chosen('a.jpg')];
      await tester.tap(find.byKey(const Key('entry-add-photo')));
      // (the bar moves for ever: nothing settles while it is there)
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(turns);
        await tester.pump();
      }
      expect(find.byKey(const Key('entry-busy')), findsOneWidget);
      expect(tester.widget<TextButton>(field('entry-save')).onPressed, isNull);
      expect(
        tester.widget<OutlinedButton>(field('entry-add-photo')).onPressed,
        isNull,
      );
      await tester.runAsync(() async {
        slow.gate.complete(const PhotoImportResult([]));
        await turns();
      });
      await settle(tester);
      expect(find.byKey(const Key('entry-busy')), findsNothing);
      expect(
        tester.widget<TextButton>(field('entry-save')).onPressed,
        isNotNull,
      );
      await shutdown(tester, db);
    });

    testWidgets('when the chooser gives up nothing happens', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = const [];
      await tapKey(tester, 'entry-add-photo');
      expect(find.text('Képek (0/12)'), findsOneWidget);
      expect(find.byKey(const Key('entry-notice')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('when the chooser cannot open it is told', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.failWith = PlatformException(code: 'nincs');
      await tapKey(tester, 'entry-add-photo');
      expect(find.text('A képválasztó nem nyílt meg.'), findsOneWidget);
      expect(find.byKey(const Key('entry-save')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('of an entry that is changed stay until it is saved', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [
          entry('a', photos: [photo('p1'), photo('p2')]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-photo-remove-p1');
      await back(tester);
      await tapKey(tester, 'discard-yes');
      expect(
        [for (final p in (await saved(tester)).single.photos) p.id],
        ['p1', 'p2'],
      );
      await shutdown(tester, db);
    });
  });

  group('what is kept when the app is closed', () {
    Future<JournalDraft?> draftOf(WidgetTester tester) => tester
        .runAsync(() => scope(tester).read(journalDraftStoreProvider).load())
        .then((d) => d);

    testWidgets('is a draft, made before the chooser opens', (tester) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-title', 'Cím');
      await enter(tester, 'entry-text', 'Fél szöveg');
      picker.next = const [];
      await tapKey(tester, 'entry-add-photo');
      final d = (await draftOf(tester))!;
      expect((d.title, d.text), ('Cím', 'Fél szöveg'));
      await shutdown(tester, db);
    });

    testWidgets('is a draft when the app goes to the background', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Hátterben');
      await background(tester);
      expect((await draftOf(tester))!.text, 'Hátterben');
      await shutdown(tester, db);
    });

    testWidgets('is written when the app goes away, not when it comes back', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Elmegyek');
      // (the first step away is enough: the system may close the app after it)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      expect((await draftOf(tester))?.text, 'Elmegyek');
      // (coming back writes nothing: the draft is cleared, the app returns)
      await tester.runAsync(
        () => scope(tester).read(journalDraftStoreProvider).clear(),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(await draftOf(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('has the day and the time the user chose', (tester) async {
      await boot(tester);
      await openNew(tester);
      await tapKey(tester, 'entry-day');
      await tester.tap(find.text('14'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tapKey(tester, 'entry-time');
      await typeTimeInPicker(tester, 21, 40);
      await enter(tester, 'entry-text', 'Szombat este');
      await background(tester);
      expect((await draftOf(tester))!.at, DateTime.utc(2026, 11, 14, 21, 40));
      await shutdown(tester, db);
    });

    testWidgets('stays when the question about it is closed by a tap beside', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(
        () =>
            scope(tester)
                .read(journalDraftStoreProvider)
                .save(JournalDraft(id: 'draft-1', at: nov16, text: 'Ez marad')),
      );
      await openNew(tester);
      expect(find.byKey(const Key('draft-dialog')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.byKey(const Key('draft-dialog')), findsNothing);
      // (not taken up, and not thrown away either)
      expect(textOf(tester, 'entry-text'), '');
      expect((await draftOf(tester))?.text, 'Ez marad');
      await shutdown(tester, db);
    });

    testWidgets('of a new entry is left alone by the entry that is changed', (
      tester,
    ) async {
      await boot(tester, entries: [entry('a')]);
      await tester.runAsync(
        () =>
            scope(tester)
                .read(journalDraftStoreProvider)
                .save(JournalDraft(id: 'draft-1', at: nov16, text: 'Másik')),
      );
      // saving a change of an entry
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await enter(tester, 'entry-text', 'Új szöveg');
      await tapKey(tester, 'entry-save');
      expect(find.byType(JournalEntryEditor), findsNothing);
      expect((await draftOf(tester))?.text, 'Másik');
      // and leaving another change with "Elvetem"
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await enter(tester, 'entry-text', 'Mégsem');
      await back(tester);
      await tapKey(tester, 'discard-yes');
      expect(find.byType(JournalEntryEditor), findsNothing);
      expect((await draftOf(tester))?.text, 'Másik');
      await shutdown(tester, db);
    });

    testWidgets(
      'that cannot be kept does not stand in the way of the writing',
      (tester) async {
        final sink = MemoryDiagSink();
        final log = DiagLog()..attach(sink);
        await boot(
          tester,
          extra: [
            journalDraftStoreProvider.overrideWith(
              (ref) => _BrokenDrafts(ref.watch(recordRepoProvider)),
            ),
            diagLogProvider.overrideWithValue(log),
          ],
        );
        await openNew(tester);
        await enter(tester, 'entry-text', 'Mégis megmarad');
        await background(tester);
        expect(find.byType(JournalEntryEditor), findsOneWidget);
        await tapKey(tester, 'entry-save');
        expect((await saved(tester)).single.text, 'Mégis megmarad');
        expect(find.byType(JournalEntryEditor), findsNothing);
        await tester.runAsync(log.flush);
        final text = sink.lines.join('\n');
        expect(text, contains('draft.save_failed'));
        expect(text, contains('draft.clear_failed'));
        await shutdown(tester, db);
      },
    );

    testWidgets('has the pictures taken in so far', (tester) async {
      await boot(tester);
      await openNew(tester);
      picker.next = [chosen('a.jpg')];
      await tapKey(tester, 'entry-add-photo');
      expect([for (final p in (await draftOf(tester))!.photos) p.id], ['new1']);
      await shutdown(tester, db);
    });

    testWidgets(
      'is offered when the next new entry opens, and can be continued',
      (tester) async {
        await boot(tester);
        await tester.runAsync(
          () => scope(tester)
              .read(journalDraftStoreProvider)
              .save(
                JournalDraft(
                  id: 'draft-1',
                  at: DateTime.utc(2026, 11, 15, 20, 5),
                  title: 'Félbehagyott',
                  text: 'Itt hagytam abba',
                  photos: [photo('dp1')],
                ),
              ),
        );
        await openNew(tester);
        expect(find.byKey(const Key('draft-dialog')), findsOneWidget);
        expect(find.textContaining('Félbehagyott'), findsWidgets);
        await tapKey(tester, 'draft-continue');
        expect(textOf(tester, 'entry-title'), 'Félbehagyott');
        expect(textOf(tester, 'entry-text'), 'Itt hagytam abba');
        expect(find.text('Képek (1/12)'), findsOneWidget);
        expect(
          find.text(fmtDateLong(DateTime.utc(2026, 11, 15))),
          findsOneWidget,
        );
        await tapKey(tester, 'entry-save');
        final e = (await saved(tester)).single;
        expect(e.id, 'draft-1');
        expect(e.title, 'Félbehagyott');
        // (saved: no draft any more)
        expect(await draftOf(tester), isNull);
        await shutdown(tester, db);
      },
    );

    testWidgets('is not lost while the question about it is open and the app '
        'goes to the background', (tester) async {
      await boot(tester);
      await tester.runAsync(
        () => scope(tester)
            .read(journalDraftStoreProvider)
            .save(JournalDraft(id: 'draft-1', at: nov16, text: 'Itt tartok')),
      );
      await openNew(tester);
      expect(find.byKey(const Key('draft-dialog')), findsOneWidget);
      await background(tester);
      expect((await draftOf(tester))?.text, 'Itt tartok');
      await tapKey(tester, 'draft-continue');
      expect(textOf(tester, 'entry-text'), 'Itt tartok');
      await shutdown(tester, db);
    });

    testWidgets('can be put aside for a new, empty entry', (tester) async {
      await boot(tester);
      await tester.runAsync(
        () =>
            scope(tester)
                .read(journalDraftStoreProvider)
                .save(JournalDraft(id: 'draft-1', at: nov16, text: 'Régi')),
      );
      await openNew(tester);
      await tapKey(tester, 'draft-discard');
      expect(textOf(tester, 'entry-text'), '');
      expect(await draftOf(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets(
      'is not offered when there is none, nor for an entry that exists',
      (tester) async {
        await boot(tester, entries: [entry('a')]);
        await openNew(tester);
        expect(find.byKey(const Key('draft-dialog')), findsNothing);
        await back(tester);
        await tester.runAsync(
          () =>
              scope(tester)
                  .read(journalDraftStoreProvider)
                  .save(JournalDraft(id: 'draft-1', at: nov16, text: 'Régi')),
        );
        await tester.tap(find.byKey(const Key('entry-a')));
        await settle(tester);
        expect(find.byKey(const Key('draft-dialog')), findsNothing);
        expect(textOf(tester, 'entry-text'), 'Szép idő volt.');
        await shutdown(tester, db);
      },
    );

    testWidgets('leaving the entry with "Elvetem" clears the draft', (
      tester,
    ) async {
      await boot(tester);
      await openNew(tester);
      await enter(tester, 'entry-text', 'Elvetett');
      await background(tester);
      expect(await draftOf(tester), isNotNull);
      await back(tester);
      await tapKey(tester, 'discard-yes');
      expect(await draftOf(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('an entry that is changed has no draft', (tester) async {
      await boot(tester, entries: [entry('a')]);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await enter(tester, 'entry-text', 'Új szöveg');
      await background(tester);
      expect(await draftOf(tester), isNull);
      await shutdown(tester, db);
    });
  });

  group('changing and deleting an entry', () {
    testWidgets('a change is saved in the same entry', (tester) async {
      await boot(tester, entries: [entry('a', title: 'Régi cím')]);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await enter(tester, 'entry-title', 'Új cím');
      await tapKey(tester, 'entry-save');
      final all = await saved(tester);
      expect(all, hasLength(1));
      expect(all.single.title, 'Új cím');
      expect(all.single.text, 'Szép idő volt.');
      expect(find.text('Új cím'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a deletion can be taken back', (tester) async {
      await boot(tester, entries: [entry('a', title: 'Törlendő')]);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-delete');
      expect(find.byType(JournalEntryEditor), findsNothing);
      expect(find.text('Törlendő'), findsNothing);
      expect(find.text('Bejegyzés törölve'), findsOneWidget);
      await tester.tap(find.text('Visszavonás'));
      await settle(tester);
      expect(find.text('Törlendő'), findsOneWidget);
      expect((await saved(tester)).single.id, 'a');
      await shutdown(tester, db);
    });

    testWidgets('a deletion is final when the bar goes', (tester) async {
      await boot(tester, entries: [entry('a', title: 'Törlendő')]);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-delete');
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      expect(find.text('Törlendő'), findsNothing);
      expect(await saved(tester), isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('that cannot be made says so, and the entry stays', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [entry('a', title: 'Marad')],
        extra: [
          journalOpsProvider.overrideWith(
            (ref) => _FailingDelete(ref.watch(recordRepoProvider)),
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-delete');
      expect(find.byKey(const Key('entry-error')), findsOneWidget);
      expect(find.byType(JournalEntryEditor), findsOneWidget);
      expect(find.text('Bejegyzés törölve'), findsNothing);
      // (not stuck: the button works again)
      expect(
        tester.widget<IconButton>(field('entry-delete')).onPressed,
        isNotNull,
      );
      expect((await saved(tester)).single.id, 'a');
      await shutdown(tester, db);
    });

    testWidgets('a day outside the years of the picker can still be changed', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [entry('a', at: DateTime.utc(1987, 3, 2, 8))],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-day');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('a day after the years of the picker can still be changed', (
      tester,
    ) async {
      await boot(
        tester,
        entries: [entry('a', at: DateTime.utc(2150, 3, 2, 8))],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tapKey(tester, 'entry-day');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });

  group('the small pictures', () {
    testWidgets('are named for a screen reader, by the name they are given or '
        'as a picture', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [photoFilesProvider.overrideWithValue(files)],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  PhotoThumb(photo: photo('p1')),
                  PhotoThumb(photo: photo('p2'), label: 'Kép 2 / 3'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Kép'), findsOneWidget);
      expect(find.bySemanticsLabel('Kép 2 / 3'), findsOneWidget);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('the viewer', () {
    Future<void> openViewer(
      WidgetTester tester, {
      int count = 3,
      int tap = 0,
    }) async {
      await boot(
        tester,
        entries: [
          entry('a', photos: [for (var i = 0; i < count; i++) photo('p$i')]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(Key('entry-photo-p$tap')));
      await settle(tester);
    }

    testWidgets('opens at the picture that was touched', (tester) async {
      await openViewer(tester, tap: 1);
      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
      expect(find.text('2 / 3'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('goes from picture to picture by swiping', (tester) async {
      await openViewer(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.fling(
        find.byKey(const Key('photo-viewer')),
        const Offset(-300, 0),
        1000,
      );
      await settle(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.fling(
        find.byKey(const Key('photo-viewer')),
        const Offset(300, 0),
        1000,
      );
      await settle(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('goes by the arrow keys', (tester) async {
      await openViewer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('has arrow buttons on a wide window, and none at the ends', (
      tester,
    ) async {
      await boot(
        tester,
        size: const Size(1000, 800),
        entries: [
          entry('a', photos: [photo('p0'), photo('p1')]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-p0')));
      await settle(tester);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byKey(const Key('photo-prev')),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'photo-next');
      expect(find.text('2 / 2'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byKey(const Key('photo-next')),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await shutdown(tester, db);
    });

    testWidgets('has none on a phone, and none for one picture', (
      tester,
    ) async {
      await openViewer(tester, count: 1);
      expect(find.byKey(const Key('photo-prev')), findsNothing);
      expect(find.byKey(const Key('photo-next')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('has no arrow buttons on a phone, however many pictures', (
      tester,
    ) async {
      await openViewer(tester);
      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
      expect(find.byKey(const Key('photo-prev')), findsNothing);
      expect(find.byKey(const Key('photo-next')), findsNothing);
      await shutdown(tester, db);
    });

    /// The viewer, opened on the first of [count] pictures in a window
    /// [width] pixels wide.
    Future<void> openWide(
      WidgetTester tester, {
      required double width,
      required int count,
    }) async {
      await boot(
        tester,
        size: Size(width, 800),
        entries: [
          entry('a', photos: [for (var i = 0; i < count; i++) photo('p$i')]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-p0')));
      await settle(tester);
      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
    }

    testWidgets('has no arrow buttons for one picture, however wide the '
        'window', (tester) async {
      await openWide(tester, width: 1000, count: 1);
      expect(find.byKey(const Key('photo-prev')), findsNothing);
      expect(find.byKey(const Key('photo-next')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('has the arrow buttons from a window of 600 pixels', (
      tester,
    ) async {
      await openWide(tester, width: 600, count: 2);
      expect(find.byKey(const Key('photo-prev')), findsOneWidget);
      expect(find.byKey(const Key('photo-next')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('has none in a window of 599 pixels', (tester) async {
      await openWide(tester, width: 599, count: 2);
      expect(find.byKey(const Key('photo-prev')), findsNothing);
      expect(find.byKey(const Key('photo-next')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('lets a swipe turn the page again after a button has turned '
        'it from a picture that was zoomed in', (tester) async {
      await openWide(tester, width: 1000, count: 2);
      final page = find.byKey(const Key('photo-viewer'));
      await tester.tap(page);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(page);
      await settle(tester);
      // (zoomed in: a swipe does not turn the page, the button does)
      await tester.fling(page, const Offset(-300, 0), 1000);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      await tapKey(tester, 'photo-next');
      expect(find.text('2 / 2'), findsOneWidget);
      // (the next picture is whole: the swipe is free again)
      await tester.fling(page, const Offset(300, 0), 1000);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('calls out the count of pictures to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await openViewer(tester);
      final count = tester.getSemantics(find.byKey(const Key('photo-count')));
      expect(count.flagsCollection.isLiveRegion, isTrue);
      expect(count.label, contains('1 / 3'));
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('zooms by a double tap, and a swipe moves the picture then', (
      tester,
    ) async {
      await openViewer(tester);
      final page = find.byKey(const Key('photo-viewer'));
      await tester.tap(page);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(page);
      await settle(tester);
      // (zoomed in: the page does not turn)
      await tester.fling(page, const Offset(-300, 0), 1000);
      await settle(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      // (a double tap again: back to the whole picture, and the page turns)
      await tester.tap(page);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(page);
      await settle(tester);
      await tester.fling(page, const Offset(-300, 0), 1000);
      await settle(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('says why there is no picture', (tester) async {
      await boot(
        tester,
        entries: [
          entry('a', photos: [photo('there'), photo('elsewhere', here: false)]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-elsewhere')));
      await settle(tester);
      expect(find.text(photoElsewhereText), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('says that a file that is no picture cannot be shown, in the '
        'list and full screen', (tester) async {
      files.put('bad.jpg', Uint8List.fromList([1, 2, 3, 4]));
      await boot(
        tester,
        entries: [
          entry(
            'a',
            photos: [
              const PhotoRef(id: 'bad', width: 100, height: 80, bytes: 4),
            ],
          ),
        ],
      );
      // (the engine says it cannot read it a moment after the first frame)
      await settle(tester);
      await settle(tester);
      expect(find.byTooltip(photoUnreadableText), findsOneWidget);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-bad')));
      await settle(tester);
      await settle(tester);
      expect(find.text(photoUnreadableText), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('says the same when the store cannot read the file', (
      tester,
    ) async {
      files = _UnreadableStore();
      await boot(
        tester,
        entries: [
          entry('a', photos: [photo('p1')]),
        ],
      );
      expect(find.byTooltip(photoUnreadableText), findsOneWidget);
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-p1')));
      await settle(tester);
      expect(find.text(photoUnreadableText), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('shows a progress mark while the file is read, then the '
        'picture', (tester) async {
      final slow = _SlowStore();
      files = slow;
      await boot(
        tester,
        entries: [
          entry('a', photos: [photo('p1')]),
        ],
      );
      await tester.tap(find.byKey(const Key('entry-a')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('entry-photo-p1')));
      // (the mark turns for ever: no settling while it is there)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.runAsync(() async {
        slow.gate.complete(tinyJpeg);
        await pumpEventQueue(times: 50);
      });
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('is read out picture by picture', (tester) async {
      final handle = tester.ensureSemantics();
      await openViewer(tester);
      expect(find.bySemanticsLabel('Kép 1 / 3'), findsWidgets);
      handle.dispose();
      await shutdown(tester, db);
    });
  });
}

/// Operations that fail (a disk that cannot be written, a database that is
/// closed): the editor must stay and say so.
class _FailingOps extends JournalOps {
  _FailingOps(super.repo);

  @override
  Future<void> save(JournalEntry entry) =>
      throw StateError('az adatbázis nem írható');
}

/// Drafts that can neither be kept nor cleared (a disk that is full).
class _BrokenDrafts extends JournalDraftStore {
  const _BrokenDrafts(super.repo);

  @override
  Future<void> save(JournalDraft draft) => throw StateError('nincs hely');

  @override
  Future<void> clear() => throw StateError('nincs hely');
}

/// An importer that fails as a whole (not one picture at a time).
class _BrokenImporter extends PhotoImporter {
  _BrokenImporter() : super(files: MemoryPhotoFiles());

  @override
  Future<PhotoImportResult> import(
    List<PickedPhoto> picked, {
    required int room,
  }) => throw StateError('nem olvasható');
}

/// An importer that is still at work, until [gate] says it is done.
class _SlowImporter extends PhotoImporter {
  _SlowImporter() : super(files: MemoryPhotoFiles());

  final gate = Completer<PhotoImportResult>();

  @override
  Future<PhotoImportResult> import(
    List<PickedPhoto> picked, {
    required int room,
  }) => gate.future;
}

/// A store that gives an error when a picture is read.
class _UnreadableStore extends MemoryPhotoFiles {
  @override
  Future<Uint8List?> read(String name) => throw StateError('nem olvasható');
}

/// A store whose read is still going on, until [gate] says it is over.
class _SlowStore extends MemoryPhotoFiles {
  final gate = Completer<Uint8List?>();

  @override
  Future<Uint8List?> read(String name) => gate.future;
}

/// The same for a deletion.
class _FailingDelete extends JournalOps {
  _FailingDelete(super.repo);

  @override
  Future<void> delete(String id) => throw StateError('az adatbázis nem írható');
}
