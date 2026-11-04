import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// File access for the backup, behind an interface so tests need no dialogs.
abstract class BackupIo {
  /// Lets the user choose where to save [text]. Returns false when cancelled.
  Future<bool> save(String fileName, String text);

  /// Lets the user choose a file; null when cancelled.
  Future<String?> pick();
}

class FilePickerBackupIo implements BackupIo {
  const FilePickerBackupIo();

  @override
  Future<bool> save(String fileName, String text) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: utf8.encode(text),
      mimeType: 'text/calendar',
      dialogTitle: 'Naptár mentése',
    );
    return uri != null;
  }

  @override
  Future<String?> pick() async {
    final f = await FilePicker.pickFile(
      dialogTitle: 'Naptár visszaállítása (.ics)',
    );
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }
}

final backupIoProvider = Provider<BackupIo>(
  (ref) => const FilePickerBackupIo(),
);
