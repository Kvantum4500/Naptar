import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_import.dart';

/// Lets the user choose pictures, behind an interface so tests need no
/// dialogs. (On a phone it is the system's own picture chooser, which needs no
/// permission; on Windows the file window.)
abstract class PhotoPicker {
  /// The chosen pictures; empty when the user gave up.
  Future<List<PickedPhoto>> pick();
}

class FilePickerPhotoPicker implements PhotoPicker {
  const FilePickerPhotoPicker();

  @override
  Future<List<PickedPhoto>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Képek hozzáadása',
      type: FileType.image,
    );
    return [
      for (final f in files)
        PickedPhoto(name: f.name, size: f.lengthSync(), read: f.readAsBytes),
    ];
  }
}

final photoPickerProvider = Provider<PhotoPicker>(
  (ref) => const FilePickerPhotoPicker(),
);
