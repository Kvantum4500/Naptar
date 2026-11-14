import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

/// File access for the backup, behind an interface so tests need no dialogs.
abstract class BackupIo {
  /// Lets the user choose where to save [text]. Returns false when cancelled.
  /// [mimeType] and [dialogTitle] say what kind of file it is: a calendar
  /// (.ics) by default, plain text for a diagnostics report.
  Future<bool> save(
    String fileName,
    String text, {
    String mimeType = 'text/calendar',
    String dialogTitle = 'Naptár mentése',
  });

  /// Lets the user choose a file; null when cancelled.
  Future<String?> pick();
}

class FilePickerBackupIo implements BackupIo {
  /// [read] lets the user choose a file and gives its bytes (null when
  /// cancelled); tests replace it, the system's file dialog is not theirs.
  const FilePickerBackupIo({this.read = _pickedBytes});

  final Future<List<int>?> Function() read;

  @override
  Future<bool> save(
    String fileName,
    String text, {
    String mimeType = 'text/calendar',
    String dialogTitle = 'Naptár mentése',
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: utf8.encode(text),
      mimeType: mimeType,
      dialogTitle: dialogTitle,
    );
    return uri != null;
  }

  @override
  Future<String?> pick() async {
    final bytes = await read();
    // a calendar is unfolded before its bytes become letters (see below)
    return bytes == null ? null : decodeCalendarBytes(bytes);
  }
}

Future<List<int>?> _pickedBytes() async {
  final f = await FilePicker.pickFile(
    dialogTitle: 'Naptár visszaállítása (.ics)',
  );
  return f == null ? null : await f.readAsBytes();
}

final backupIoProvider = Provider<BackupIo>(
  (ref) => const FilePickerBackupIo(),
);
