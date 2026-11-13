import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The permissions of the Android app (SEC-14). The merged manifest of a build
// is made of this file and the manifests of the plugins; this test cannot run
// that merge (no Android SDK), but it reads this file as text and keeps what
// the app asks for, and what it keeps out, exactly as decided.

String read(String path) =>
    File('android/app/src/main/$path').readAsStringSync();

/// The text without its comments.
String bare(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// The `uses-permission` elements: name -> whether it carries the marker that
/// removes it from the merged manifest.
Map<String, bool> permissions(String manifest) => {
  for (final m in RegExp(
    r'<uses-permission\s([^>]*?)/?>',
    dotAll: true,
  ).allMatches(manifest))
    RegExp(r'android:name="([^"]+)"')
        .firstMatch(m.group(1)!)!
        .group(1)!: RegExp(r'tools:node="remove"')
        .hasMatch(m.group(1)!),
};

void main() {
  final manifest = bare(read('AndroidManifest.xml'));
  final all = permissions(manifest);
  final asked = {
    for (final e in all.entries)
      if (!e.value) e.key,
  };
  final removed = {
    for (final e in all.entries)
      if (e.value) e.key,
  };
  String name(String short) => 'android.permission.$short';

  test('the manifest knows the tools namespace the removals need', () {
    expect(
      RegExp(r'<manifest[^>]*xmlns:tools="http://schemas.android.com/tools"')
          .hasMatch(manifest),
      isTrue,
    );
  });

  test('what the app asks for is exactly what it uses', () {
    expect(asked, {
      name('INTERNET'),
      name('REQUEST_INSTALL_PACKAGES'),
      name('POST_NOTIFICATIONS'),
      name('RECEIVE_BOOT_COMPLETED'),
      name('ACCESS_COARSE_LOCATION'),
    });
  });

  test('the update can be installed: the install permission is asked for', () {
    expect(asked, contains(name('REQUEST_INSTALL_PACKAGES')));
  });

  test('the storage and media permissions of the file plugin are removed', () {
    expect(removed, {
      name('READ_EXTERNAL_STORAGE'),
      name('READ_MEDIA_IMAGES'),
      name('READ_MEDIA_VIDEO'),
      name('READ_MEDIA_AUDIO'),
    });
  });

  test('every removal is written the way the manifest merger reads it', () {
    for (final n in removed) {
      expect(
        manifest,
        contains(
          RegExp(
            '<uses-permission android:name="${RegExp.escape(n)}" '
            'tools:node="remove"/>',
          ),
        ),
        reason: n,
      );
    }
  });

  test('nothing is asked for and removed at once', () {
    expect(asked.intersection(removed), isEmpty);
  });

  test('no access to files, photos, videos or music is asked for', () {
    for (final n in asked) {
      expect(n, isNot(contains('STORAGE')), reason: n);
      expect(n, isNot(contains('MEDIA')), reason: n);
    }
  });

  test('the location is the approximate one only (what the app says)', () {
    expect(asked, contains(name('ACCESS_COARSE_LOCATION')));
    expect(all.keys, isNot(contains(name('ACCESS_FINE_LOCATION'))));
    expect(all.keys, isNot(contains(name('ACCESS_BACKGROUND_LOCATION'))));
  });

  test('there is no permission the app asks for twice', () {
    final names = [
      for (final m in RegExp(
        r'<uses-permission\s[^>]*android:name="([^"]+)"',
      ).allMatches(manifest))
        m.group(1)!,
    ];
    expect(names.toSet().length, names.length);
  });

  test('the premise of the removals: the update is opened from the app\'s own folder', () {
    // open_filex asks for no permission for a file inside the app's own
    // folders (OpenFilePlugin.pathRequiresPermission): so the download has to
    // stay in the cache folder of the app on Android, not move to a shared one.
    final dialog = File('lib/update/update_dialog.dart').readAsStringSync();
    final dir = RegExp(
      r'Future<Directory> _downloadDir\(\) async \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(dialog)!.group(1)!;
    expect(dir, contains('Platform.isAndroid'));
    expect(dir, contains('getTemporaryDirectory()'));
    for (final shared in [
      'getExternalStorageDirectory',
      'getDownloadsDirectory',
      'getExternalCacheDirectories',
      'Download',
    ]) {
      expect(dir, isNot(contains(shared)), reason: shared);
    }
  });

  test('the debug and profile builds only add the internet permission', () {
    for (final flavour in ['debug', 'profile']) {
      final extra = permissions(
        bare(
          File('android/app/src/$flavour/AndroidManifest.xml')
              .readAsStringSync(),
        ),
      );
      expect(extra.keys.toSet(), {name('INTERNET')}, reason: flavour);
    }
  });
}
