import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// File access for the zip backups (the text files of the older backup buttons
/// go through `BackupIo`), behind an interface so tests need no dialogs.
abstract class BackupFileIo {
  /// Lets the user choose where to save [bytes]. Returns false when cancelled.
  Future<bool> save(
    String fileName,
    Uint8List bytes, {
    String dialogTitle = 'Mentés fájlba',
  });

  /// Lets the user choose a file; null when cancelled.
  Future<Uint8List?> pick({String dialogTitle = 'Mentés visszaállítása'});
}

class FilePickerBackupFileIo implements BackupFileIo {
  const FilePickerBackupFileIo();

  @override
  Future<bool> save(
    String fileName,
    Uint8List bytes, {
    String dialogTitle = 'Mentés fájlba',
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/zip',
      dialogTitle: dialogTitle,
    );
    return uri != null;
  }

  @override
  Future<Uint8List?> pick({
    String dialogTitle = 'Mentés visszaállítása',
  }) async {
    final f = await FilePicker.pickFile(dialogTitle: dialogTitle);
    if (f == null) return null;
    return f.readAsBytes();
  }
}

final backupFileIoProvider = Provider<BackupFileIo>(
  (ref) => const FilePickerBackupFileIo(),
);
