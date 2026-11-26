import 'dart:io';

import 'package:flutter/services.dart';

/// The folder where the Flutter SDK keeps Roboto (the font Android draws the
/// app in), or null if it is not there. A test process runs from
/// `<sdk>/bin/cache/artifacts/engine/<platform>/`.
Directory? materialFontsDir() {
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  final dir = Directory('${artifacts.path}/material_fonts');
  return dir.existsSync() ? dir : null;
}

/// True if [loadRoboto] can find the font.
bool get robotoAvailable =>
    File('${materialFontsDir()?.path}/Roboto-Regular.ttf').existsSync();

/// Loads Roboto, so that text in a test is measured with the real thing. The
/// test font (Ahem) is a square box per letter: far too wide and a little too
/// short, which hides exactly the overflows that fixed heights cause.
Future<void> loadRoboto() async {
  final dir = materialFontsDir();
  if (dir == null) throw StateError('Roboto is not in the Flutter SDK cache');
  final loader = FontLoader('Roboto');
  for (final name in const [
    'Light',
    'Regular',
    'Medium',
    'Bold',
    'Italic',
    'MediumItalic',
    'BoldItalic',
  ]) {
    final file = File('${dir.path}/Roboto-$name.ttf');
    if (!file.existsSync()) continue;
    loader.addFont(
      Future.value(
        ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync())),
      ),
    );
  }
  await loader.load();
  // the icons, so that a picture of a screen shows them
  final icons = File('${dir.path}/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(Uint8List.fromList(icons.readAsBytesSync())),
        ),
      );
    await l.load();
  }
}
