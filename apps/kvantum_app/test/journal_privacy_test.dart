import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/journal/journal_draft_store.dart';

/// The diary stays out of the assistant's reach, and its pictures stay on the
/// device (8th round): what was written and shown is not sent to a model, and
/// the pictures are in no backup and in no file that goes to Drive. A
/// structural guard: whatever can read the diary could send it somewhere.
void main() {
  List<File> dartFiles(String dir) => [
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f,
  ];

  String norm(File f) => f.path.replaceAll('\\', '/');

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

  test('only the diary itself reads or writes the picture folder', () {
    final users = <String>[];
    for (final f in dartFiles('lib')) {
      final text = f.readAsStringSync();
      if (text.contains('PhotoFiles') || text.contains('photoFilesProvider')) {
        users.add(norm(f));
      }
    }
    expect(users..sort(), [
      'lib/journal/journal_providers.dart',
      'lib/journal/photo_files.dart',
      'lib/journal/photo_import.dart',
      'lib/journal/photo_sweep.dart',
      'lib/main.dart',
      'lib/providers.dart',
    ]);
  });

  test('no backup and no file for Drive can hold a picture', () {
    // (a backup holds the records; the sync sends records: neither is given
    // the folder of the pictures, nor knows a way to it)
    final found = <String>[];
    for (final dir in ['lib/backup', 'lib/drive', 'lib/sync']) {
      for (final f in dartFiles(dir)) {
        final text = f.readAsStringSync();
        for (final w in [
          'PhotoFiles',
          'photoFilesProvider',
          'journal/photos',
        ]) {
          if (text.contains(w)) found.add('${norm(f)}: $w');
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
