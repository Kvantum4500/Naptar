import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_app/update/update_service.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Stable asset ids so tests can tell the files apart: zip 101, checksum 102, apk 103.
int _assetId(String name) => name.endsWith('.sha256')
    ? 102
    : (name.endsWith('.zip') ? 101 : (name.endsWith('.apk') ? 103 : 104));

Map<String, Object?> release(int build, {List<String>? names}) => {
  'tag_name': 'build-$build',
  'body': 'Új dolgok',
  'assets': [
    for (final n
        in names ??
            [
              'naptar-windows-$build.zip',
              'naptar-windows-$build.zip.sha256',
              'naptar-android-$build.apk',
            ])
      {
        'name': n,
        'url':
            'https://api.github.com/repos/o/r/releases/assets/${_assetId(n)}',
        'size': 10,
      },
  ],
};

class _MemoryPrefs implements UpdatePrefs {
  _MemoryPrefs(this.on);
  bool on;
  @override
  Future<bool> previews() async => on;
  @override
  Future<void> setPreviews(bool v) async => on = v;
}

UpdateService svc(
  MockClientHandler h, {
  String token = 'tok',
  UpdatePlatform platform = UpdatePlatform.windows,
}) => UpdateService(
  client: MockClient(h),
  repo: 'o/r',
  token: token,
  platform: platform,
);

void main() {
  group('version check', () {
    test('buildFromTag parses only build-N tags', () {
      expect(buildFromTag('build-42'), 42);
      expect(buildFromTag('v1.2.3'), isNull);
      expect(buildFromTag('build-x'), isNull);
    });

    test('no token -> clear message, no network call', () async {
      var called = false;
      final r = await svc((_) async {
        called = true;
        return _json({});
      }, token: '').check(1);
      expect(r, isA<UpdateFailed>());
      expect((r as UpdateFailed).kind, UpdateErrorKind.notConfigured);
      expect(called, isFalse);
    });

    test(
      'newer release is offered with the right platform asset and checksum',
      () async {
        late http.Request seen;
        final r = await svc((req) async {
          seen = req;
          return _json(release(9));
        }).check(5);
        expect(seen.headers['Authorization'], 'Bearer tok');
        expect(seen.url.path, '/repos/o/r/releases/latest');
        final a = r as UpdateAvailable;
        expect(a.info.build, 9);
        expect(a.info.package.name, 'naptar-windows-9.zip');
        expect(a.info.sha256Asset!.name, 'naptar-windows-9.zip.sha256');
      },
    );

    test('Android picks the apk; no checksum asset is tolerated here (download refuses later)', () async {
      final r = await svc(
        (_) async => _json(release(9)),
        platform: UpdatePlatform.android,
      ).check(5);
      expect((r as UpdateAvailable).info.package.name, 'naptar-android-9.apk');
      expect(r.info.sha256Asset, isNull);
    });

    test('same or older build is up to date', () async {
      expect(
        await svc((_) async => _json(release(5))).check(5),
        isA<UpToDate>(),
      );
      expect(
        await svc((_) async => _json(release(4))).check(5),
        isA<UpToDate>(),
      );
    });

    test('failures map to distinct, readable kinds', () async {
      Future<UpdateErrorKind> kind(MockClientHandler h) async =>
          ((await svc(h).check(1)) as UpdateFailed).kind;
      expect(await kind((_) async => _json({}, 401)), UpdateErrorKind.badToken);
      expect(await kind((_) async => _json({}, 403)), UpdateErrorKind.badToken);
      expect(
        await kind((_) async => _json({}, 404)),
        UpdateErrorKind.noRelease,
      );
      expect(await kind((_) async => _json({}, 500)), UpdateErrorKind.other);
      expect(
        await kind((_) async => throw const SocketException('no net')),
        UpdateErrorKind.network,
      );
      expect(
        await kind((_) async => _json({'tag_name': 'weird', 'assets': []})),
        UpdateErrorKind.other,
      );
      expect(
        await kind((_) async => _json(release(9, names: ['readme.txt']))),
        UpdateErrorKind.noPackage,
      );
    });

    test('unsupported platform is reported, not crashed', () async {
      final r = await svc(
        (_) async => _json(release(9)),
        platform: UpdatePlatform.other,
      ).check(1);
      expect((r as UpdateFailed).kind, UpdateErrorKind.unsupported);
    });
  });

  group('download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('naptar-dl-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    final bytes = List<int>.generate(5000, (i) => i % 251);
    final sum = sha256.convert(bytes).toString();

    ReleaseInfo info({bool withSha = true}) => ReleaseInfo(
      build: 9,
      tag: 'build-9',
      package: const ReleaseAsset(
        'naptar-windows-9.zip',
        'https://api.github.com/a/1',
        5000,
      ),
      sha256Asset: withSha
          ? const ReleaseAsset(
              'naptar-windows-9.zip.sha256',
              'https://api.github.com/a/2',
              80,
            )
          : null,
    );

    MockClientHandler server({String? shaText, List<http.Request>? log}) =>
        (req) async {
          log?.add(req);
          if (req.url.toString() == 'https://api.github.com/a/2') {
            return http.Response(
              shaText ?? '$sum  naptar-windows-9.zip\n',
              200,
            );
          }
          if (req.url.toString() == 'https://api.github.com/a/1') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://objects.example.com/blob?sig=abc'},
            );
          }
          if (req.url.host == 'objects.example.com') {
            return http.Response.bytes(bytes, 200);
          }
          return http.Response('', 404);
        };

    test('follows the redirect WITHOUT leaking the token, verifies the checksum, reports progress', () async {
      final log = <http.Request>[];
      final progress = <double>[];
      final f = await svc(server(log: log))
          .download(info(), dir, onProgress: progress.add);
      expect(f.readAsBytesSync(), bytes);
      final blob = log.firstWhere((r) => r.url.host == 'objects.example.com');
      expect(blob.headers.containsKey('Authorization'), isFalse);
      final api = log.firstWhere((r) => r.url.path == '/a/1');
      expect(api.headers['Authorization'], 'Bearer tok');
      expect(api.headers['Accept'], 'application/octet-stream');
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
    });

    test('checksum mismatch deletes the file and refuses', () async {
      final bad = 'f' * 64;
      await expectLater(
        svc(server(shaText: '$bad  x')).download(info(), dir),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('nem egyezik'),
          ),
        ),
      );
      expect(dir.listSync(), isEmpty);
    });

    test(
      'a release without checksum is refused (never installs unverified code)',
      () async {
        await expectLater(
          svc(server()).download(info(withSha: false), dir),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              contains('ellenőrző összeg'),
            ),
          ),
        );
        expect(dir.listSync(), isEmpty);
      },
    );

    test(
      'HTTP errors and endless redirects surface as readable errors',
      () async {
        await expectLater(
          svc((_) async => http.Response('', 404)).download(info(), dir),
          throwsA(isA<HttpException>()),
        );
        await expectLater(
          svc(
            (req) async => http.Response(
              '',
              302,
              headers: {'location': 'https://api.github.com/loop'},
            ),
          ).download(info(), dir),
          throwsA(isA<HttpException>()),
        );
      },
    );
  });

  group('Windows package handling', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('naptar-zip-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File zip(Map<String, String> files) {
      final a = Archive();
      files.forEach(
        (n, c) => a.addFile(ArchiveFile(n, c.length, utf8.encode(c))),
      );
      final f = File('${tmp.path}/u.zip')
        ..writeAsBytesSync(ZipEncoder().encode(a));
      return f;
    }

    test('flat zip: app files are at the root', () {
      final root = extractUpdateZip(
        zip({'kvantum_app.exe': 'x', 'data/a.bin': 'y'}),
        Directory('${tmp.path}/out'),
      );
      expect(File('${root.path}/kvantum_app.exe').existsSync(), isTrue);
      expect(File('${root.path}/data/a.bin').existsSync(), isTrue);
    });

    test('zip with a single top folder is unwrapped', () {
      final root = extractUpdateZip(
        zip({'Release/kvantum_app.exe': 'x'}),
        Directory('${tmp.path}/out'),
      );
      expect(root.path, endsWith('Release'));
    });

    test('path traversal is rejected', () {
      expect(
        () => extractUpdateZip(
          zip({'../evil.txt': 'x', 'kvantum_app.exe': 'y'}),
          Directory('${tmp.path}/out'),
        ),
        throwsFormatException,
      );
      expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
    });

    test('a zip without the exe is rejected', () {
      expect(
        () => extractUpdateZip(
          zip({'readme.txt': 'x'}),
          Directory('${tmp.path}/out'),
        ),
        throwsFormatException,
      );
    });

    test(
      'writable check works on a normal folder and fails on a missing one',
      () {
        expect(isDirWritable(tmp), isTrue);
        expect(isDirWritable(Directory('${tmp.path}/nope/none')), isFalse);
      },
    );
  });

  group('Windows file swap (no helper script)', () {
    late Directory root, installDir, newDir;
    setUp(() {
      root = Directory.systemTemp.createTempSync('naptar-swap-test');
      installDir = Directory('${root.path}/install')..createSync();
      newDir = Directory('${root.path}/new')..createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    void write(Directory d, String rel, String content) {
      File('${d.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    String read(String rel) =>
        File('${installDir.path}/$rel').readAsStringSync();

    test('changed files are replaced, new ones added, identical ones untouched', () {
      write(installDir, 'app.exe', 'old exe');
      write(installDir, 'icudtl.dat', 'same data');
      write(installDir, 'data/app.so', 'old so');
      write(newDir, 'app.exe', 'NEW exe');
      write(newDir, 'icudtl.dat', 'same data');
      write(newDir, 'data/app.so', 'NEW so');
      write(newDir, 'data/extra/new.bin', 'brand new');

      final r = applyUpdateFiles(
        newRoot: newDir,
        installDir: installDir,
        tag: 'b5',
      );
      expect(read('app.exe'), 'NEW exe');
      expect(read('data/app.so'), 'NEW so');
      expect(read('data/extra/new.bin'), 'brand new');
      expect(r.unchanged, ['icudtl.dat']);
      expect(r.replaced.toSet(), {
        'app.exe',
        'data/app.so',
        'data/extra/new.bin',
      });
      // the replaced originals are kept aside (a running exe cannot be deleted)
      expect(
        File('${installDir.path}/app.exe.old-b5').readAsStringSync(),
        'old exe',
      );
      expect(
        File('${installDir.path}/icudtl.dat.old-b5').existsSync(),
        isFalse,
      );
    });

    test('a failure half-way undoes everything: the old version is intact', () {
      write(installDir, 'a.dll', 'old a');
      write(installDir, 'b.dll', 'old b');
      write(installDir, 'c.dll', 'old c');
      write(newDir, 'a.dll', 'NEW a');
      write(newDir, 'b.dll', 'NEW b');
      write(newDir, 'c.dll', 'NEW c');
      write(newDir, 'd.dll', 'NEW d');

      var calls = 0;
      expect(
        () => applyUpdateFiles(
          newRoot: newDir,
          installDir: installDir,
          tag: 'b5',
          beforeStep: (step, rel) {
            if (++calls == 5) {
              throw const FileSystemException('locked', 'b.dll');
            }
          },
        ),
        throwsA(
          isA<UpdateSwapException>().having(
            (e) => e.message,
            'message',
            contains('érintetlen'),
          ),
        ),
      );
      expect(read('a.dll'), 'old a');
      expect(read('b.dll'), 'old b');
      expect(read('c.dll'), 'old c');
      expect(File('${installDir.path}/d.dll').existsSync(), isFalse);
      expect(
        installDir.listSync().whereType<File>().any(
          (f) => f.path.contains('.old-'),
        ),
        isFalse,
      );
    });

    test(
      'a leftover .old file from an earlier attempt does not block the swap',
      () {
        write(installDir, 'app.exe', 'old');
        write(installDir, 'app.exe.old-b5', 'stale');
        write(newDir, 'app.exe', 'NEW');
        applyUpdateFiles(newRoot: newDir, installDir: installDir, tag: 'b5');
        expect(read('app.exe'), 'NEW');
        expect(read('app.exe.old-b5'), 'old');
      },
    );

    test(
      'startup cleanup removes only the .old files, including nested ones',
      () {
        write(installDir, 'app.exe', 'keep');
        write(installDir, 'app.exe.old-b5', 'x');
        write(installDir, 'data/app.so.old-b5-123', 'x');
        write(installDir, 'data/readme.old', 'keep: not an update leftover');
        expect(cleanupOldFiles(installDir), 2);
        expect(File('${installDir.path}/app.exe').existsSync(), isTrue);
        expect(File('${installDir.path}/data/readme.old').existsSync(), isTrue);
        expect(File('${installDir.path}/app.exe.old-b5').existsSync(), isFalse);
      },
    );

    test('an update with nothing changed replaces nothing', () {
      write(installDir, 'app.exe', 'same');
      write(newDir, 'app.exe', 'same');
      final r = applyUpdateFiles(
        newRoot: newDir,
        installDir: installDir,
        tag: 'b5',
      );
      expect(r.replaced, isEmpty);
      expect(r.unchanged, ['app.exe']);
    });
  });

  group('update dialog', () {
    UpdateService service(MockClientHandler h, {String token = 'tok'}) =>
        UpdateService(
          client: MockClient(h),
          repo: 'o/r',
          token: token,
          platform: UpdatePlatform.windows,
        );

    Widget host(
      UpdateService s, {
      UpdateInstaller? installer,
      int build = 5,
      bool previews = false,
    }) => ProviderScope(
      overrides: [
        currentBuildProvider.overrideWith((ref) async => build),
        updatePrefsProvider.overrideWithValue(_MemoryPrefs(previews)),
        updateServiceProvider.overrideWithValue(s),
        if (installer != null)
          updateInstallerProvider.overrideWithValue(installer),
      ],
      child: const MaterialApp(home: Scaffold(body: UpdateDialog())),
    );

    testWidgets('up to date', (tester) async {
      await tester.pumpWidget(host(service((_) async => _json(release(5)))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Naprakész vagy'), findsOneWidget);
    });

    testWidgets('no token explains what is missing', (tester) async {
      await tester.pumpWidget(host(service((_) async => _json({}), token: '')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('nincs beállítva a frissítés'),
        findsOneWidget,
      );
      expect(find.textContaining('UPDATE_TOKEN'), findsNothing);
    });

    testWidgets('expired token has its own message', (tester) async {
      await tester.pumpWidget(host(service((_) async => _json({}, 401))));
      await tester.pumpAndSettle();
      expect(find.textContaining('érvénytelen vagy lejárt'), findsOneWidget);
    });

    testWidgets('offline offers a retry that succeeds later', (tester) async {
      var online = false;
      await tester.pumpWidget(
        host(
          service((_) async {
            if (!online) throw const SocketException('x');
            return _json(release(5));
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nincs kapcsolat'), findsOneWidget);
      online = true;
      await tester.tap(find.text('Újrapróbál'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Naprakész vagy'), findsOneWidget);
    });

    testWidgets(
      'available update: download, verify, hand over to the installer',
      (tester) async {
        final bytes = utf8.encode('package-bytes');
        final sum = sha256.convert(bytes).toString();
        final installed = <String>[];
        await tester.runAsync(() async {
          await tester.pumpWidget(
            host(
              service((req) async {
                final path = req.url.path;
                if (path.endsWith('/releases/latest')) return _json(release(9));
                if (path.endsWith('/assets/102')) {
                  return http.Response('$sum  naptar-windows-9.zip', 200);
                }
                if (path.endsWith('/assets/101')) {
                  return http.Response.bytes(bytes, 200);
                }
                return http.Response('', 404);
              }),
              installer: _FakeInstaller(installed),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('Új verzió érhető el: 9'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('Frissítés most'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(installed, ['naptar-windows-9.zip']);
        expect(find.text('Kész, újraindítás…'), findsOneWidget);
      },
    );
  });

  group('preview builds', () {
    List<Object?> releases() => [
      {...release(5), 'prerelease': false},
      {...release(7), 'prerelease': true},
      {...release(9), 'draft': true},
    ];

    test('with previews the newest published build wins, a pre-release '
        'included, a draft never', () async {
      Uri? asked;
      final r = await svc((req) async {
        asked = req.url;
        return _json(releases());
      }).check(5, includePreviews: true);
      expect(asked.toString(), endsWith('/repos/o/r/releases?per_page=20'));
      expect((r as UpdateAvailable).info.build, 7);
    });

    test(
      'without previews only the release marked latest is asked for',
      () async {
        Uri? asked;
        await svc((req) async {
          asked = req.url;
          return _json(release(5));
        }).check(5);
        expect(asked.toString(), endsWith('/repos/o/r/releases/latest'));
      },
    );

    test(
      'a preview that is not newer than the installed build is no update',
      () async {
        final r = await svc((_) async => _json(releases()))
            .check(7, includePreviews: true);
        expect(r, isA<UpToDate>());
      },
    );

    test('no published release at all', () async {
      final empty = await svc((_) async => _json([]))
          .check(1, includePreviews: true);
      expect((empty as UpdateFailed).kind, UpdateErrorKind.noRelease);
      final onlyDraft = await svc(
        (_) async => _json([
          {...release(3), 'draft': true},
        ]),
      ).check(1, includePreviews: true);
      expect((onlyDraft as UpdateFailed).kind, UpdateErrorKind.noRelease);
    });

    testWidgets('the dialog switch changes what is asked and is remembered', (
      tester,
    ) async {
      final asked = <String>[];
      final prefs = _MemoryPrefs(true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentBuildProvider.overrideWith((ref) async => 5),
            updatePrefsProvider.overrideWithValue(prefs),
            updateServiceProvider.overrideWithValue(
              UpdateService(
                client: MockClient((req) async {
                  asked.add(req.url.toString());
                  return req.url.path.endsWith('/latest')
                      ? _json(release(5))
                      : _json([release(7)]);
                }),
                repo: 'o/r',
                token: 'tok',
                platform: UpdatePlatform.windows,
              ),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: UpdateDialog())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Új verzió érhető el: 7'), findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(prefs.on, isFalse);
      expect(find.textContaining('Naprakész vagy'), findsOneWidget);
      expect(asked.last, endsWith('/releases/latest'));
    });
  });
}

class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller(this.log);
  final List<String> log;
  @override
  Future<String?> install(File package, ReleaseInfo info) async {
    log.add(package.uri.pathSegments.last);
    return 'Kész, újraindítás…';
  }
}
