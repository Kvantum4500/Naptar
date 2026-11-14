import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/backup/backup_bundle.dart';
import 'package:kvantum_app/backup/backup_card.dart';
import 'package:kvantum_app/backup/backup_file_io.dart';
import 'package:kvantum_app/backup/backup_key_store.dart';
import 'package:kvantum_app/backup/backup_providers.dart';
import 'package:kvantum_app/backup/backup_service.dart';
import 'package:kvantum_app/backup/backup_store.dart';
import 'package:kvantum_app/backup/drive_backup.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/update/update_dialog.dart'
    show currentBuildProvider;
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_drive.dart';
import 'support/fake_wallet.dart';
import 'support/harness.dart';

/// Records what the screen asks of the synchronisation, and is signed in when
/// the test says so (with [drive] as its Drive folder).
class _Ctl extends SyncController {
  _Ctl(this.drive, {this.signed = false});
  final DriveRemote? drive;
  final bool signed;
  final calls = <String>[];

  @override
  SyncState build() => SyncState(signedIn: signed);
  @override
  void requestSync() => calls.add('request');
  @override
  DriveRemote? driveRemote() => state.signedIn ? drive : null;

  void setSignedIn(bool on) => state = state.copyWith(signedIn: on);
}

class _FileIo implements BackupFileIo {
  final saved = <({String name, Uint8List bytes})>[];
  Uint8List? toPick;
  bool saveOk = true;
  int picks = 0;

  @override
  Future<bool> save(
    String fileName,
    Uint8List bytes, {
    String dialogTitle = 'Mentés fájlba',
  }) async {
    saved.add((name: fileName, bytes: bytes));
    return saveOk;
  }

  @override
  Future<Uint8List?> pick({
    String dialogTitle = 'Mentés visszaállítása',
  }) async {
    picks++;
    return toPick;
  }
}

/// A folder that cannot be written to.
class _BrokenStore extends MemoryBackupStore {
  @override
  Future<void> write(String name, Uint8List bytes) =>
      throw StateError('lemez tele');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  // 2026-11-13 09:15 on the device's clock (a test may move it on)
  final start = DateTime(2026, 11, 13, 9, 15);
  var now = start;
  const nameNow = 'kvantum-20261113-091500.zip';

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late FinanceRepository fin;
  late MemoryBackupStore store;
  late _FileIo io;
  late _Ctl ctl;
  late BackupService service;
  late FakeDrive drive;
  late MemoryBackupKeyStore keys;

  CalEvent dentist() => evt('a', 'Fogorvos', floating(2026, 11, 14, 10));
  CalEvent gym() => evt('b', 'Edzés', floating(2026, 11, 15, 18));

  /// A backup of the database as it is now.
  Future<Uint8List> backupOf(WidgetTester tester, {String? password}) async =>
      (await tester.runAsync(() => service.create(password: password)))!;

  Future<void> boot(
    WidgetTester tester, {
    Future<void> Function()? seed,
    MemoryBackupStore? withStore,
    Widget? home,
    List<Override> extra = const [],
    Size size = const Size(900, 3200),
    bool signedIn = false,
    String? password,
    double? textScale,
  }) async {
    useSize(tester, size: size);
    now = start;
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db);
    fin = FinanceRepository(db);
    store = withStore ?? MemoryBackupStore();
    io = _FileIo();
    drive = FakeDrive();
    keys = MemoryBackupKeyStore(password);
    ctl = _Ctl(drive, signed: signedIn);
    service = BackupService(
      events: events,
      records: records,
      finance: fin,
      now: () => now,
      build: () async => 73,
      runner: inline,
    );
    if (seed != null) await tester.runAsync(seed);
    await tester.pumpWidget(
      app(
        home ??
            const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: BackupBody(),
              ),
            ),
        db,
        textScale: textScale,
        extra: [
          syncControllerProvider.overrideWith(() => ctl),
          backupStoreProvider.overrideWithValue(store),
          backupRunnerProvider.overrideWithValue(inline),
          backupFileIoProvider.overrideWithValue(io),
          backupKeyStoreProvider.overrideWithValue(keys),
          appClockProvider.overrideWithValue(() => now),
          currentBuildProvider.overrideWith((ref) async => 73),
          ...extra,
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> seedTwo() async {
    await events.saveAll([dentist(), gym()]);
    await records.edit(kindTask, 't1', taskFields(title: 'Bevásárlás'));
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> typeInto(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  String? toast(WidgetTester tester) {
    final bar = find.byType(SnackBar);
    if (bar.evaluate().isEmpty) return null;
    return tester
        .widgetList<Text>(find.descendant(of: bar, matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join(' ');
  }

  group('the card', () {
    testWidgets('a new install says no backup has been made yet', (
      tester,
    ) async {
      await boot(tester);
      expect(find.text('Még nem készült mentés.'), findsOneWidget);
      expect(find.text('Mentések ezen az eszközön'), findsNothing);
      final sw = tester.widget<SwitchListTile>(
        find.byKey(const Key('backup-auto')),
      );
      expect(sw.value, isTrue);
      await shutdown(tester, db);
    });

    testWidgets('"Mentés most" makes a backup and lists it', (tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-now');
      expect(store.files.keys, [nameNow]);
      expect(
        find.text('Utolsó mentés: 2026. november 13. 09:15'),
        findsOneWidget,
      );
      expect(find.text('Mentések ezen az eszközön'), findsOneWidget);
      expect(find.byKey(const Key('backup-entry-$nameNow')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('backup-entry-$nameNow')),
          matching: find.text('2026. november 13. 09:15'),
        ),
        findsOneWidget,
      );
      expect(toast(tester), contains('A mentés elkészült'));
      // a screen reader hears which backup the menu belongs to
      expect(
        find.byTooltip('Műveletek: 2026. november 13. 09:15'),
        findsOneWidget,
      );
      // it holds the data and says which build made it
      final file = unpackBackup(store.files[nameNow]!);
      expect(file.meta.build, 73);
      expect(file.meta.counts['events'], 2);
      expect(file.meta.counts[kindTask], 1);
      expect(file.data.calendarIcs, contains('Fogorvos'));
      await shutdown(tester, db);
    });

    testWidgets('a backup that cannot be written says why', (tester) async {
      await boot(tester, seed: seedTwo, withStore: _BrokenStore());
      await tapKey(tester, 'backup-now');
      expect(
        find.textContaining('Az utolsó mentés nem sikerült:'),
        findsOneWidget,
      );
      expect(toast(tester), contains('A mentés nem sikerült'));
      expect(find.text('Mentések ezen az eszközön'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the switch turns the daily backup off, and it stays off', (
      tester,
    ) async {
      await boot(tester);
      await tapKey(tester, 'backup-auto');
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('backup-auto')))
            .value,
        isFalse,
      );
      final auto = ProviderScope.containerOf(
        tester.element(find.byType(BackupBody)),
      ).read(autoBackupProvider);
      final made = await tester.runAsync(auto.runIfDue);
      expect(made, isNull);
      expect(store.files, isEmpty);
      await tapKey(tester, 'backup-auto');
      final again = await tester.runAsync(auto.runIfDue);
      expect(again?.name, nameNow);
      await shutdown(tester, db);
    });

    testWidgets('only the newest twelve are shown, with a count of the rest', (
      tester,
    ) async {
      final many = MemoryBackupStore();
      for (var d = 1; d <= 14; d++) {
        many.files['kvantum-202611${d.toString().padLeft(2, '0')}-080000.zip'] =
            Uint8List(2048);
      }
      await boot(tester, withStore: many);
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains("'backup-entry-kvantum-"),
        ),
        findsNWidgets(12),
      );
      expect(find.text('és még 2…'), findsOneWidget);
      // newest first
      expect(
        tester.getTopLeft(find.text('2026. november 14. 08:00')).dy,
        lessThan(tester.getTopLeft(find.text('2026. november 13. 08:00')).dy),
      );
      await shutdown(tester, db);
    });
  });

  group('a backup into a file', () {
    testWidgets('without a password anyone can open it', (tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-tofile');
      expect(find.byKey(const Key('backup-save-password')), findsOneWidget);
      await tapKey(tester, 'backup-password-save');
      expect(io.saved, hasLength(1));
      expect(io.saved.single.name, nameNow);
      final file = unpackBackup(io.saved.single.bytes);
      expect(file.data.calendarIcs, contains('Fogorvos'));
      expect(toast(tester), 'A mentés elmentve.');
      await shutdown(tester, db);
    });

    testWidgets('with a password the file is locked', (tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-tofile');
      await typeInto(tester, 'backup-password', 'Titok-2026');
      await typeInto(tester, 'backup-password-again', 'Titok-2026');
      await tapKey(tester, 'backup-password-save');
      final bytes = io.saved.single.bytes;
      expect(
        () => unpackBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.problem,
            'problem',
            BackupProblem.passwordNeeded,
          ),
        ),
      );
      expect(
        unpackBackup(bytes, password: 'Titok-2026').data.calendarIcs,
        contains('Fogorvos'),
      );
      // the text of the file does not show the data
      expect(
        latin1.decode(bytes, allowInvalid: true),
        isNot(contains('Fogorvos')),
      );
      expect(toast(tester), 'A mentés elmentve, jelszóval védve.');
      await shutdown(tester, db);
    });

    testWidgets('two different passwords are not accepted', (tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-tofile');
      await typeInto(tester, 'backup-password', 'Titok-2026');
      await typeInto(tester, 'backup-password-again', 'Titok-2027');
      await tapKey(tester, 'backup-password-save');
      expect(find.text('A két jelszó nem egyezik.'), findsOneWidget);
      expect(find.byKey(const Key('backup-save-password')), findsOneWidget);
      expect(io.saved, isEmpty);
      // typing again clears the complaint
      await typeInto(tester, 'backup-password-again', 'Titok-2026');
      expect(find.text('A két jelszó nem egyezik.'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('cancelling the question saves nothing', (tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-tofile');
      await tapKey(tester, 'backup-password-cancel');
      expect(io.saved, isEmpty);
      expect(find.byKey(const Key('backup-save-password')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('cancelling the system dialog is no success', (tester) async {
      await boot(tester, seed: seedTwo);
      io.saveOk = false;
      await tapKey(tester, 'backup-tofile');
      await tapKey(tester, 'backup-password-save');
      expect(io.saved, hasLength(1));
      expect(toast(tester), isNull);
      await shutdown(tester, db);
    });
  });

  group('restoring', () {
    /// The device lost event a and renamed event b since the backup.
    Future<Uint8List> backupThenChange(
      WidgetTester tester, {
      String? password,
    }) async {
      final bytes = await backupOf(tester, password: password);
      await tester.runAsync(() async {
        await events.deleteLocal('a');
        final b = (await events.byId('b'))!;
        await events.saveLocal(b.copyWith(title: 'Edzés (átírva)'));
      });
      return bytes;
    }

    Future<List<String>> titles(WidgetTester tester) async {
      final all = await tester.runAsync(() => events.all());
      return [for (final e in all!) e.title]..sort();
    }

    testWidgets('a file: the preview says what would happen', (tester) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester);
      await tapKey(tester, 'backup-fromfile');
      expect(find.byKey(const Key('backup-restore')), findsOneWidget);
      expect(find.text('Visszaállítás előnézete'), findsOneWidget);
      expect(find.textContaining('A mentés ideje:'), findsOneWidget);
      expect(
        find.textContaining('2026. november 13. 09:15 (build 73)'),
        findsOneWidget,
      );
      expect(find.textContaining('2 esemény · 1 feladat'), findsOneWidget);
      expect(find.textContaining('1 új · 1 azóta módosult'), findsOneWidget);
      expect(find.textContaining('Edzés (átírva)'), findsOneWidget);
      // nothing has been written yet
      expect(await titles(tester), ['Edzés (átírva)']);
      await shutdown(tester, db);
    });

    testWidgets('"without the changed ones" brings back only what is missing', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester);
      await tapKey(tester, 'backup-fromfile');
      await tapKey(tester, 'restore-keep');
      expect(await titles(tester), ['Edzés (átírva)', 'Fogorvos']);
      expect(toast(tester), 'Visszaállítva: 1 új esemény.');
      expect(ctl.calls, contains('request'));
      await shutdown(tester, db);
    });

    testWidgets('"everything, overwriting" puts the changed one back too', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester);
      await tapKey(tester, 'backup-fromfile');
      await tapKey(tester, 'restore-go');
      expect(await titles(tester), ['Edzés', 'Fogorvos']);
      expect(
        toast(tester),
        'Visszaállítva: 1 új esemény, 1 esemény felülírva.',
      );
      await shutdown(tester, db);
    });

    testWidgets('cancelling the preview changes nothing', (tester) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester);
      await tapKey(tester, 'backup-fromfile');
      await tapKey(tester, 'restore-cancel');
      expect(await titles(tester), ['Edzés (átírva)']);
      expect(ctl.calls, isEmpty);
      expect(toast(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('a backup with nothing new offers nothing to do', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupOf(tester);
      await tapKey(tester, 'backup-fromfile');
      expect(find.textContaining('Nincs mit visszaállítani'), findsOneWidget);
      expect(find.byKey(const Key('restore-go')), findsNothing);
      expect(find.byKey(const Key('restore-keep')), findsNothing);
      await tapKey(tester, 'restore-cancel');
      expect(ctl.calls, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('only a file that was chosen is read', (tester) async {
      await boot(tester, seed: seedTwo);
      io.toPick = null;
      await tapKey(tester, 'backup-fromfile');
      expect(io.picks, 1);
      expect(find.byKey(const Key('backup-restore')), findsNothing);
      expect(toast(tester), isNull);
      await shutdown(tester, db);
    });

    testWidgets('a locked file asks for the password until it is right', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester, password: 'Titok-2026');
      await tapKey(tester, 'backup-fromfile');
      expect(find.byKey(const Key('backup-open-password')), findsOneWidget);
      expect(find.text('Hibás jelszó.'), findsNothing);
      // wrong
      await typeInto(tester, 'backup-password', 'rossz');
      await tapKey(tester, 'backup-password-open');
      expect(find.byKey(const Key('backup-open-password')), findsOneWidget);
      expect(find.text('Hibás jelszó.'), findsOneWidget);
      // right
      await typeInto(tester, 'backup-password', 'Titok-2026');
      await tapKey(tester, 'backup-password-open');
      expect(find.byKey(const Key('backup-restore')), findsOneWidget);
      await tapKey(tester, 'restore-go');
      expect(await titles(tester), ['Edzés', 'Fogorvos']);
      await shutdown(tester, db);
    });

    testWidgets('giving up on the password restores nothing', (tester) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupThenChange(tester, password: 'Titok-2026');
      await tapKey(tester, 'backup-fromfile');
      await tapKey(tester, 'backup-password-cancel');
      expect(find.byKey(const Key('backup-restore')), findsNothing);
      expect(await titles(tester), ['Edzés (átírva)']);
      await shutdown(tester, db);
    });

    testWidgets('a file that is no backup says so', (tester) async {
      await boot(tester, seed: seedTwo);
      io.toPick = Uint8List.fromList(utf8.encode('ez egy szöveg, nem zip'));
      await tapKey(tester, 'backup-fromfile');
      expect(toast(tester), 'Ez a fájl nem a Kvantum Naptár mentése.');
      expect(find.byKey(const Key('backup-restore')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('tasks that are missing come back, and are queued to upload', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo);
      io.toPick = await backupOf(tester);
      await tester.runAsync(() async {
        // as if the database had been lost: only the task row is wiped
        await db.customStatement('DELETE FROM record_rows');
      });
      await tapKey(tester, 'backup-fromfile');
      expect(find.textContaining('1 új'), findsWidgets);
      await tapKey(tester, 'restore-go');
      final task = await tester.runAsync(() => records.get(kindTask, 't1'));
      expect(task, isNotNull);
      expect(toast(tester), contains('1 feladat / check-in / egyéb'));
      await shutdown(tester, db);
    });
  });

  group('the backups on this device', () {
    Future<void> withOne(WidgetTester tester) async {
      await boot(tester, seed: seedTwo);
      await tapKey(tester, 'backup-now');
    }

    Future<void> menu(WidgetTester tester, String item) async {
      await tester.tap(find.byKey(const Key('backup-entry-menu-$nameNow')));
      await tester.pumpAndSettle();
      // (the menu is on top of the page, whose own button may say the same)
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    testWidgets('one can be restored from the list', (tester) async {
      await withOne(tester);
      await tester.runAsync(() => events.deleteLocal('a'));
      await menu(tester, 'Visszaállítás…');
      expect(find.byKey(const Key('backup-restore')), findsOneWidget);
      await tapKey(tester, 'restore-go');
      final all = await tester.runAsync(() => events.all());
      expect([for (final e in all!) e.title]..sort(), ['Edzés', 'Fogorvos']);
      await shutdown(tester, db);
    });

    testWidgets('one can be saved into a file as it is', (tester) async {
      await withOne(tester);
      await menu(tester, 'Mentés fájlba…');
      expect(io.saved.single.name, nameNow);
      expect(io.saved.single.bytes, store.files[nameNow]);
      await shutdown(tester, db);
    });

    testWidgets('one can be deleted, after asking', (tester) async {
      await withOne(tester);
      await menu(tester, 'Törlés…');
      expect(find.byKey(const Key('backup-delete')), findsOneWidget);
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(store.files.keys, [nameNow]);
      await menu(tester, 'Törlés…');
      await tapKey(tester, 'backup-delete-yes');
      expect(store.files, isEmpty);
      expect(find.byKey(const Key('backup-entry-$nameNow')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a backup that has gone from the folder is said to be gone', (
      tester,
    ) async {
      await withOne(tester);
      store.files.clear(); // (the user deleted it with a file manager)
      await menu(tester, 'Visszaállítás…');
      expect(toast(tester), 'Ez a mentés már nincs meg.');
      expect(find.byKey(const Key('backup-restore')), findsNothing);
      // the list was refreshed
      expect(find.byKey(const Key('backup-entry-$nameNow')), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the Drive copy', () {
    SwitchListTile driveSwitch(WidgetTester tester) =>
        tester.widget<SwitchListTile>(find.byKey(const Key('drive-auto')));

    bool enabled(WidgetTester tester, String key) {
      final w = tester.widget(find.byKey(Key(key)));
      return (w as dynamic).onPressed != null;
    }

    List<String> copies() =>
        [for (final f in drive.files.values) f.name]..sort();

    testWidgets('without a password the switch and the button wait for one', (
      tester,
    ) async {
      await boot(tester, signedIn: true);
      expect(find.text('Jelszó megadása'), findsOneWidget);
      expect(find.text('Előbb adj meg egy jelszót.'), findsOneWidget);
      expect(driveSwitch(tester).onChanged, isNull);
      expect(enabled(tester, 'drive-now'), isFalse);
      expect(find.byKey(const Key('drive-password-clear')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('signed out, it asks for the login first', (tester) async {
      await boot(tester, password: 'Titok-2026');
      expect(
        find.textContaining('Előbb lépj be a Google-fiókkal'),
        findsOneWidget,
      );
      expect(driveSwitch(tester).onChanged, isNull);
      expect(enabled(tester, 'drive-now'), isFalse);
      expect(enabled(tester, 'drive-restore'), isFalse);
      expect(find.text('Jelszó módosítása'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the password must be long enough, and typed twice', (
      tester,
    ) async {
      await boot(tester, signedIn: true);
      await tapKey(tester, 'drive-password');
      expect(find.byKey(const Key('drive-password-dialog')), findsOneWidget);
      // too short
      await typeInto(tester, 'backup-password', 'rövid');
      await typeInto(tester, 'backup-password-again', 'rövid');
      await tapKey(tester, 'backup-password-save');
      expect(find.text('Legalább 8 karakter legyen.'), findsOneWidget);
      expect(keys.value, isNull);
      // not the same
      await typeInto(tester, 'backup-password', 'Titok-2026');
      await typeInto(tester, 'backup-password-again', 'Titok-2027');
      await tapKey(tester, 'backup-password-save');
      expect(find.text('A két jelszó nem egyezik.'), findsOneWidget);
      expect(keys.value, isNull);
      // right
      await typeInto(tester, 'backup-password-again', 'Titok-2026');
      await tapKey(tester, 'backup-password-save');
      expect(keys.value, 'Titok-2026');
      expect(toast(tester), 'A jelszó el van mentve.');
      expect(find.text('Jelszó módosítása'), findsOneWidget);
      expect(driveSwitch(tester).onChanged, isNotNull);
      await shutdown(tester, db);
    });

    testWidgets('an empty password is not accepted, and cancelling keeps all', (
      tester,
    ) async {
      await boot(tester, signedIn: true, password: 'Titok-2026');
      await tapKey(tester, 'drive-password');
      await tapKey(tester, 'backup-password-save');
      expect(find.text('Legalább 8 karakter legyen.'), findsOneWidget);
      await tapKey(tester, 'backup-password-cancel');
      expect(keys.value, 'Titok-2026');
      await shutdown(tester, db);
    });

    testWidgets('switching it on makes the first copy at once', (tester) async {
      await boot(tester, seed: seedTwo, signedIn: true, password: 'Titok-2026');
      await tapKey(tester, 'drive-auto');
      expect(driveSwitch(tester).value, isTrue);
      expect(copies(), ['kvbackup-20261113-091500.zip.b64']);
      expect(
        find.text('Utolsó Drive-mentés: 2026. november 13. 09:15'),
        findsOneWidget,
      );
      expect(toast(tester), 'A Drive-mentés elkészült.');
      await shutdown(tester, db);
    });

    testWidgets('"Mentés a Drive-ra most" adds one, and three stay', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo, signedIn: true, password: 'Titok-2026');
      for (var i = 0; i < 4; i++) {
        await tapKey(tester, 'drive-now');
        now = now.add(const Duration(days: 1));
      }
      expect(copies(), [
        'kvbackup-20261114-091500.zip.b64',
        'kvbackup-20261115-091500.zip.b64',
        'kvbackup-20261116-091500.zip.b64',
      ]);
      await shutdown(tester, db);
    });

    testWidgets('a copy that fails says why, in words', (tester) async {
      await boot(tester, seed: seedTwo, signedIn: true, password: 'Titok-2026');
      drive.offline = true;
      await tapKey(tester, 'drive-now');
      expect(
        find.textContaining('Az utolsó Drive-mentés nem sikerült:'),
        findsOneWidget,
      );
      expect(toast(tester), startsWith('A Drive-mentés nem sikerült:'));
      expect(toast(tester), isNot(contains('Exception')));
      expect(drive.files, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('deleting the password switches the copy off, after asking', (
      tester,
    ) async {
      await boot(tester, seed: seedTwo, signedIn: true, password: 'Titok-2026');
      await tapKey(tester, 'drive-auto');
      expect(driveSwitch(tester).value, isTrue);
      await tapKey(tester, 'drive-password-clear');
      expect(
        find.byKey(const Key('drive-password-clear-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('Mégse'));
      await tester.pumpAndSettle();
      expect(keys.value, 'Titok-2026');
      await tapKey(tester, 'drive-password-clear');
      await tapKey(tester, 'drive-password-clear-yes');
      expect(keys.value, isNull);
      expect(driveSwitch(tester).value, isFalse);
      expect(find.text('Jelszó megadása'), findsOneWidget);
      // what is in Drive stays
      expect(copies(), hasLength(1));
      await shutdown(tester, db);
    });

    group('restoring from Drive', () {
      Future<void> oneCopyThenLoss(WidgetTester tester) async {
        await boot(
          tester,
          seed: seedTwo,
          signedIn: true,
          password: 'Titok-2026',
        );
        await tapKey(tester, 'drive-now');
        // the device loses event a
        await tester.runAsync(() => events.deleteLocal('a'));
      }

      Future<List<String>> titles(WidgetTester tester) async {
        final all = await tester.runAsync(() => events.all());
        return [for (final e in all!) e.title]..sort();
      }

      testWidgets('the stored password opens the copy without asking', (
        tester,
      ) async {
        await oneCopyThenLoss(tester);
        await tapKey(tester, 'drive-restore');
        expect(find.byKey(const Key('drive-copies')), findsOneWidget);
        expect(find.text('2026. november 13. 09:15'), findsWidgets);
        await tapKey(tester, 'drive-copy-kvbackup-20261113-091500.zip.b64');
        expect(find.byKey(const Key('backup-open-password')), findsNothing);
        expect(find.byKey(const Key('backup-restore')), findsOneWidget);
        await tapKey(tester, 'restore-go');
        expect(await titles(tester), ['Edzés', 'Fogorvos']);
        expect(ctl.calls, contains('request'));
        await shutdown(tester, db);
      });

      testWidgets('on a new device the password is asked, not complained of', (
        tester,
      ) async {
        await oneCopyThenLoss(tester);
        keys.value = 'Mas-jelszo-77'; // (this device knows another one)
        await tapKey(tester, 'drive-restore');
        await tapKey(tester, 'drive-copy-kvbackup-20261113-091500.zip.b64');
        expect(find.byKey(const Key('backup-open-password')), findsOneWidget);
        expect(find.text('Hibás jelszó.'), findsNothing);
        // a typo is complained of
        await typeInto(tester, 'backup-password', 'Titok-2025');
        await tapKey(tester, 'backup-password-open');
        expect(find.text('Hibás jelszó.'), findsOneWidget);
        // the right one opens it
        await typeInto(tester, 'backup-password', 'Titok-2026');
        await tapKey(tester, 'backup-password-open');
        expect(find.byKey(const Key('backup-restore')), findsOneWidget);
        await tapKey(tester, 'restore-go');
        expect(await titles(tester), ['Edzés', 'Fogorvos']);
        await shutdown(tester, db);
      });

      testWidgets('with no copies there is nothing to choose', (tester) async {
        await boot(tester, signedIn: true, password: 'Titok-2026');
        await tapKey(tester, 'drive-restore');
        expect(toast(tester), 'Még nincs mentés a Drive-ban.');
        expect(find.byKey(const Key('drive-copies')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('the newest copy is first in the list', (tester) async {
        await boot(
          tester,
          seed: seedTwo,
          signedIn: true,
          password: 'Titok-2026',
        );
        await tapKey(tester, 'drive-now');
        now = now.add(const Duration(days: 2));
        await tapKey(tester, 'drive-now');
        await tapKey(tester, 'drive-restore');
        expect(
          tester.getTopLeft(find.text('2026. november 15. 09:15')).dy,
          lessThan(tester.getTopLeft(find.text('2026. november 13. 09:15')).dy),
        );
        await shutdown(tester, db);
      });

      testWidgets('a copy that went meanwhile is said to be gone', (
        tester,
      ) async {
        await oneCopyThenLoss(tester);
        await tapKey(tester, 'drive-restore');
        drive.files.clear();
        await tapKey(tester, 'drive-copy-kvbackup-20261113-091500.zip.b64');
        expect(toast(tester), 'Ez a mentés már nincs meg a Drive-on.');
        expect(find.byKey(const Key('backup-restore')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('no network is told in words', (tester) async {
        await oneCopyThenLoss(tester);
        drive.offline = true;
        await tapKey(tester, 'drive-restore');
        expect(toast(tester), startsWith('A Drive-mentések nem érhetők el:'));
        expect(find.byKey(const Key('drive-copies')), findsNothing);
        await shutdown(tester, db);
      });

      testWidgets('cancelling the list restores nothing', (tester) async {
        await oneCopyThenLoss(tester);
        await tapKey(tester, 'drive-restore');
        await tester.tapAt(const Offset(5, 5)); // (outside the dialog)
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('drive-copies')), findsNothing);
        expect(await titles(tester), ['Edzés']);
        await shutdown(tester, db);
      });
    });
  });

  group('large text', () {
    // 200 % on a narrow phone: nothing is cut off or pushed out of the screen

    /// Taps a button after scrolling it into view and sweeping the toast away
    /// (which may lie over it).
    Future<void> tapShown(WidgetTester tester, String key) async {
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .clearSnackBars();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('the card, with a backup, a complaint and a Drive copy', (
      tester,
    ) async {
      await boot(
        tester,
        seed: seedTwo,
        withStore: _BrokenStore(),
        signedIn: true,
        password: 'Titok-2026',
        size: const Size(360, 3000),
        textScale: 2.0,
      );
      await tapShown(tester, 'backup-now'); // (fails: the complaint shows)
      await tapShown(tester, 'drive-auto'); // (a Drive copy is made)
      expect(find.byKey(const Key('backup-status')), findsOneWidget);
      expect(find.byKey(const Key('drive-status')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('the list of backups with its menus', (tester) async {
      final many = MemoryBackupStore();
      for (var d = 1; d <= 5; d++) {
        many.files['kvantum-202611${d.toString().padLeft(2, '0')}-080000.zip'] =
            Uint8List(3 * 1024 * 1024);
      }
      await boot(
        tester,
        withStore: many,
        size: const Size(360, 3000),
        textScale: 2.0,
      );
      expect(tester.takeException(), isNull);
      await tapShown(tester, 'backup-entry-menu-kvantum-20261105-080000.zip');
      expect(find.text('Visszaállítás…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });

    testWidgets('the password questions', (tester) async {
      await boot(
        tester,
        seed: seedTwo,
        size: const Size(360, 3000),
        textScale: 2.0,
      );
      await tapShown(tester, 'backup-tofile');
      await typeInto(tester, 'backup-password', 'Titok-2026');
      await typeInto(tester, 'backup-password-again', 'Titok-2027');
      await tapKey(tester, 'backup-password-save'); // (the mismatch shows)
      expect(find.text('A két jelszó nem egyezik.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // the window gets short (a phone with the keyboard up): the dialog
      // scrolls, it does not overflow
      tester.view.physicalSize = const Size(360, 420);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const Key('backup-password-cancel')),
      );
      await tapKey(tester, 'backup-password-cancel');
      await shutdown(tester, db);
    });

    testWidgets('the preview of a restore, with changed events, on a short '
        'phone', (tester) async {
      await boot(
        tester,
        seed: seedTwo,
        size: const Size(360, 3000),
        textScale: 2.0,
      );
      final bytes = await backupOf(tester);
      await tester.runAsync(() async {
        await events.deleteLocal('a');
        final b = (await events.byId('b'))!;
        await events.saveLocal(b.copyWith(title: 'Edzés (átírva)'));
      });
      io.toPick = bytes;
      await tapShown(tester, 'backup-fromfile');
      expect(find.byKey(const Key('backup-restore')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // the window gets short: a dialog this long scrolls, it does not overflow
      tester.view.physicalSize = const Size(360, 520);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('restore-keep')), findsOneWidget);
      expect(find.byKey(const Key('restore-go')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('restore-cancel')));
      await tapKey(tester, 'restore-cancel');
      await shutdown(tester, db);
    });

    testWidgets('the list of Drive copies', (tester) async {
      await boot(
        tester,
        seed: seedTwo,
        size: const Size(360, 3000),
        textScale: 2.0,
        signedIn: true,
        password: 'Titok-2026',
      );
      await tapShown(tester, 'drive-now');
      await tapShown(tester, 'drive-restore');
      expect(find.byKey(const Key('drive-copies')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });

  group('the place in the app', () {
    testWidgets('Settings has the card in the data group', (tester) async {
      await boot(
        tester,
        home: const SettingsPage(),
        size: const Size(900, 4800),
        extra: [apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null))],
      );
      expect(find.text('Automatikus mentés'), findsOneWidget);
      expect(find.byType(BackupBody), findsOneWidget);
      // between the "Adatok" heading and the older file buttons
      final data = tester.getTopLeft(find.text('Adatok')).dy;
      final card = tester.getTopLeft(find.text('Automatikus mentés')).dy;
      final old = tester.getTopLeft(find.text('Mentés és visszaállítás')).dy;
      expect(data, lessThan(card));
      expect(card, lessThan(old));
      await shutdown(tester, db);
    });
  });

  group('the automatic backup', () {
    Future<void> bootShell(WidgetTester tester, {bool runs = true}) => boot(
      tester,
      home: const RootShell(),
      size: const Size(360, 800),
      extra: [
        walletBridgeProvider.overrideWithValue(FakeWallet()),
        autoBackupRunsProvider.overrideWithValue(runs),
      ],
    );

    testWidgets('the app makes it once it has started', (tester) async {
      await bootShell(tester);
      expect(store.files.keys, [nameNow]);
      final file = unpackBackup(store.files[nameNow]!);
      expect(file.meta.build, 73);
      await shutdown(tester, db);
    });

    testWidgets('it is not made when the app is not asked to (the tests)', (
      tester,
    ) async {
      await bootShell(tester, runs: false);
      expect(store.files, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('coming back to the app does not make a second one', (
      tester,
    ) async {
      await bootShell(tester);
      now = now.add(const Duration(hours: 19));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(store.files.keys, [nameNow]);
      await shutdown(tester, db);
    });

    testWidgets('an app left open for a day makes one when it is back', (
      tester,
    ) async {
      await bootShell(tester);
      now = now.add(const Duration(hours: 21));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(store.files.keys.toSet(), {
        nameNow,
        'kvantum-20261114-061500.zip',
      });
      await shutdown(tester, db);
    });

    testWidgets('it is not made when the user switched it off', (tester) async {
      await bootShell(tester, runs: false);
      // (the switch is read when it is due: off stays off)
      final auto = ProviderScope.containerOf(
        tester.element(find.byType(RootShell)),
      ).read(autoBackupProvider);
      await tester.runAsync(() => auto.setEnabled(false));
      now = now.add(const Duration(days: 2));
      expect(await tester.runAsync(auto.runIfDue), isNull);
      expect(store.files, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('the weekly Drive copy waits for the login, then is made', (
      tester,
    ) async {
      await boot(
        tester,
        home: const RootShell(),
        size: const Size(360, 800),
        password: 'Titok-2026',
        seed: () async {
          await seedTwo();
          await events.setMeta(DriveBackup.enabledKey, 'on');
        },
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          autoBackupRunsProvider.overrideWithValue(true),
        ],
      );
      // started signed out: the local backup is made, the Drive copy waits
      expect(store.files.keys, [nameNow]);
      expect(drive.files, isEmpty);
      // the login comes
      ctl.setSignedIn(true);
      await tester.pumpAndSettle();
      expect(
        [for (final f in drive.files.values) f.name],
        ['kvbackup-20261113-091500.zip.b64'],
      );
      await shutdown(tester, db);
    });

    testWidgets('the Drive copy is not made either when the app is not asked '
        'to (the tests)', (tester) async {
      await boot(
        tester,
        home: const RootShell(),
        size: const Size(360, 800),
        password: 'Titok-2026',
        signedIn: true,
        seed: () => events.setMeta(DriveBackup.enabledKey, 'on'),
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          autoBackupRunsProvider.overrideWithValue(false),
        ],
      );
      expect(drive.files, isEmpty);
      ctl.setSignedIn(false);
      ctl.setSignedIn(true);
      await tester.pumpAndSettle();
      expect(drive.files, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('the Drive copy is not made when it is switched off', (
      tester,
    ) async {
      await boot(
        tester,
        home: const RootShell(),
        size: const Size(360, 800),
        password: 'Titok-2026',
        signedIn: true,
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          autoBackupRunsProvider.overrideWithValue(true),
        ],
      );
      expect(drive.files, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('an app left open for a week makes the next Drive copy', (
      tester,
    ) async {
      await boot(
        tester,
        home: const RootShell(),
        size: const Size(360, 800),
        password: 'Titok-2026',
        signedIn: true,
        seed: () => events.setMeta(DriveBackup.enabledKey, 'on'),
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          autoBackupRunsProvider.overrideWithValue(true),
        ],
      );
      expect(drive.files, hasLength(1)); // (made at the start)
      now = now.add(const Duration(days: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(drive.files, hasLength(1)); // (too early)
      now = now.add(const Duration(days: 4));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(drive.files, hasLength(2));
      await shutdown(tester, db);
    });

    testWidgets('a failing backup never disturbs the app', (tester) async {
      await boot(
        tester,
        home: const RootShell(),
        size: const Size(360, 800),
        withStore: _BrokenStore(),
        extra: [
          walletBridgeProvider.overrideWithValue(FakeWallet()),
          autoBackupRunsProvider.overrideWithValue(true),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationBar), findsOneWidget);
      final auto = ProviderScope.containerOf(
        tester.element(find.byType(RootShell)),
      ).read(autoBackupProvider);
      final state = await tester.runAsync(auto.state);
      expect(state!.error, isNotNull);
      await shutdown(tester, db);
    });
  });
}
