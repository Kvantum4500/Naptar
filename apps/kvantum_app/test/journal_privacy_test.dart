import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/journal/journal_draft_store.dart';

/// The diary stays out of the assistant's reach, and its pictures keep to
/// their own way (8th and 9th round): what was written and shown is not sent to
/// a model, the pictures are in no backup, and the only code that carries them
/// to Drive (and back) is the picture sync, which knows nothing of where they
/// are kept. A structural guard: whatever can read the diary could send it
/// somewhere.
void main() {
  List<File> dartFiles(String dir) => [
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f,
  ];

  String norm(File f) => f.path.replaceAll('\\', '/');

  // The one file under lib/ai that is no part of the assistant: the card of
  // the Google account in the settings. It shows how the sync went, and so the
  // line and the switch of the pictures; it holds nothing a model could be
  // sent. (The test below keeps it so.)
  const accountCard = 'lib/ai/settings/account_card.dart';

  test('no file of the assistant knows of the diary or its pictures', () {
    const words = [
      'journal',
      'JournalEntry',
      'JournalDraft',
      'PhotoRef',
      'PhotoFiles',
      'photo',
    ];
    final found = <String>[];
    for (final f in dartFiles('lib/ai')) {
      if (norm(f) == accountCard) continue;
      final text = f.readAsStringSync();
      for (final w in words) {
        if (text.toLowerCase().contains(w.toLowerCase())) {
          found.add('${norm(f)}: $w');
        }
      }
    }
    expect(found, isEmpty);
  });

  test('nor does the part of the core that builds what a model is told', () {
    const own = {'journal.dart', 'models.dart', 'search.dart'};
    final found = <String>[];
    for (final f in dartFiles('../../packages/kvantum_core/lib/src')) {
      final name = norm(f).split('/').last;
      if (own.contains(name)) continue;
      final text = f.readAsStringSync();
      for (final w in ['kindJournal', 'JournalEntry', 'PhotoRef']) {
        if (text.contains(w)) found.add('$name: $w');
      }
    }
    expect(found, isEmpty);
  });

  test('the card of the account is the settings of the sync, and no more', () {
    // (it may speak of the pictures; it may not reach the assistant, the diary
    // or the folder of the pictures)
    final text = File(accountCard).readAsStringSync();
    final imports = RegExp(
      r"^import '([^']+)';",
      multiLine: true,
    ).allMatches(text).map((m) => m[1]!).toList();
    expect(imports, isNotEmpty);
    for (final i in imports) {
      expect(
        i.startsWith('package:flutter/') ||
            i.startsWith('package:flutter_riverpod/') ||
            i.startsWith('../../sync/') ||
            i.startsWith('../../ui/'),
        isTrue,
        reason: i,
      );
    }
    for (final w in [
      'PhotoFiles',
      'photoFilesProvider',
      'PhotoRef',
      'JournalEntry',
      'journal/photos',
    ]) {
      expect(text.contains(w), isFalse, reason: w);
    }
  });

  test('only the diary itself and the picture sync read or write the picture '
      'folder', () {
    final users = <String>[];
    for (final f in dartFiles('lib')) {
      final text = f.readAsStringSync();
      if (text.contains('PhotoFiles') || text.contains('photoFilesProvider')) {
        users.add(norm(f));
      }
    }
    expect(users..sort(), [
      'lib/drive/photo_sync.dart', // (the picture sync: sends and fetches)
      'lib/journal/journal_providers.dart',
      'lib/journal/photo_files.dart',
      'lib/journal/photo_import.dart',
      'lib/journal/photo_sweep.dart',
      'lib/main.dart',
      'lib/providers.dart',
      'lib/sync/sync_controller.dart', // (hands the folder to the picture sync)
    ]);
  });

  test('no backup can hold a picture', () {
    // (a backup holds the records, and the pictures are carried to Drive by
    // the picture sync: the code of the backups is not given the folder of the
    // pictures, nor knows a way to it)
    final found = <String>[];
    for (final f in dartFiles('lib/backup')) {
      final text = f.readAsStringSync();
      for (final w in ['PhotoFiles', 'photoFilesProvider', 'journal/photos']) {
        if (text.contains(w)) found.add('${norm(f)}: $w');
      }
    }
    expect(found, isEmpty);
  });

  test('nothing that goes to Drive knows where the pictures are kept', () {
    // (the picture sync is handed the folder as an object; the place is known
    // to main.dart alone)
    final found = <String>[];
    for (final dir in ['lib/drive', 'lib/sync']) {
      for (final f in dartFiles(dir)) {
        if (f.readAsStringSync().contains('journal/photos')) {
          found.add(norm(f));
        }
      }
    }
    expect(found, isEmpty);
  });

  test(
    'the unsaved start of an entry is kept on the device, not as a record',
    () {
      expect(journalDraftKey, 'journal.draft');
      // (it is in the settings table: the backup and the sync never read it)
      final backup = File('lib/backup/backup_service.dart').readAsStringSync();
      expect(backup.contains('journal.draft'), isFalse);
      expect(backup.contains('journalDraftKey'), isFalse);
    },
  );

  test('the diary needs no new permission of the phone', () {
    // (the picture chooser of the system works without one; the manifest test
    // pins the whole list, this one says why nothing was added for the diary:
    // a permission to read pictures or to use the camera is only ever named
    // to be taken OUT of the merged manifest)
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    for (final p in [
      'READ_MEDIA_IMAGES',
      'READ_EXTERNAL_STORAGE',
      'WRITE_EXTERNAL_STORAGE',
      'CAMERA',
      'ACCESS_MEDIA_LOCATION',
    ]) {
      final tags = RegExp('<uses-permission[^>]*$p[^>]*>')
          .allMatches(manifest)
          .map((m) => m.group(0)!);
      for (final tag in tags) {
        expect(tag, contains('tools:node="remove"'), reason: p);
      }
    }
  });
}
