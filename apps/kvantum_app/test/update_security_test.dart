import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/providers.dart' show appClockProvider;
import 'package:kvantum_app/update/update_config.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_app/update/update_service.dart';

import 'update_signature_test.dart' show buildA, buildB, keyA, keyB, sigA, sigB;

// The signature tests of update_signature_test.dart use signatures made by
// OpenSSL; here the same ones are used end to end: a "package" whose bytes are
// "package-85" has the checksum hashA, and sigA is the signature of build 85
// with that checksum (the same for build 86, keyB, sigB).

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const api = 'https://api.github.com';
const pkgUrl = '$api/a/1';
const shaUrl = '$api/a/2';
const sigUrl = '$api/a/3';
const blob = 'https://objects.example.com/blob?sig=abc';

final pkg85 = utf8.encode('package-85');
final pkg86 = utf8.encode('package-86');

ReleaseInfo info({
  int build = buildA,
  List<int>? bytes,
  int? size,
  bool sha = true,
  bool sig = true,
  int sigSize = 88,
  String pkgAt = pkgUrl,
}) {
  final b = bytes ?? pkg85;
  return ReleaseInfo(
    build: build,
    tag: 'build-$build',
    package: ReleaseAsset('naptar-windows-$build.zip', pkgAt, size ?? b.length),
    sha256Asset: sha
        ? ReleaseAsset('naptar-windows-$build.zip.sha256', shaUrl, 90)
        : null,
    sigAsset: sig
        ? ReleaseAsset('naptar-windows-$build.zip.sig', sigUrl, sigSize)
        : null,
  );
}

/// A server for one release: the package behind a redirect, its checksum and
/// its signature (any of them can be changed or left out).
class Server {
  Server({List<int>? bytes, this.sha, this.sig = sigA})
    : bytes = bytes ?? pkg85;

  final List<int> bytes;
  final String? sha;
  final String? sig;
  final log = <http.Request>[];

  String get shaText => sha ?? '${sha256.convert(bytes)}  naptar.zip\n';

  Future<http.Response> call(http.Request req) async {
    log.add(req);
    final url = req.url.toString();
    if (url == shaUrl) return http.Response(shaText, 200);
    if (url == sigUrl) {
      return sig == null ? http.Response('', 404) : http.Response(sig!, 200);
    }
    if (url == pkgUrl) {
      return http.Response('', 302, headers: {'location': blob});
    }
    if (url == blob) return http.Response.bytes(bytes, 200);
    return http.Response('', 404);
  }

  bool asked(String url) => log.any((r) => r.url.toString() == url);
  int index(String url) => log.indexWhere((r) => r.url.toString() == url);
}

UpdateService service(
  MockClientHandler h, {
  List<String> keys = const [keyA],
  bool require = false,
  List<String>? log,
  int cap = maxUpdatePackageBytes,
}) => UpdateService(
  client: MockClient(h),
  repo: 'o/r',
  token: 'tok',
  platform: UpdatePlatform.windows,
  publicKeys: keys,
  requireSignature: require,
  log: log?.add,
  maxPackageBytes: cap,
);

Matcher refused(Pattern text) => throwsA(
  isA<HttpException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('naptar-sec-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('signed updates', () {
    test('a release with a valid signature is taken', () async {
      final log = <String>[];
      final f = await service(Server().call, log: log).download(info(), dir);
      expect(f.readAsBytesSync(), pkg85);
      expect(log.single, contains('signature valid'));
      expect(log.single, contains('build $buildA'));
    });

    test(
      'the signature of another build does not do (a replayed release)',
      () async {
        // build 86 under the signature of build 85
        final s = Server(bytes: pkg86, sig: sigA);
        await expectLater(
          service(s.call).download(info(build: buildB, bytes: pkg86), dir),
          refused('aláírása nem érvényes'),
        );
        expect(dir.listSync(), isEmpty);
      },
    );

    test('the signature of another file does not do', () async {
      // package-86 with a right checksum, under the signature of package-85
      final s = Server(bytes: pkg86, sig: sigA);
      await expectLater(
        service(s.call).download(info(bytes: pkg86), dir),
        refused('aláírása nem érvényes'),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a signature changed in one bit does not do', () async {
      final bytes = base64.decode(sigA)..[5] ^= 0x10;
      final s = Server(sig: base64.encode(bytes));
      await expectLater(
        service(s.call).download(info(), dir),
        refused('aláírása nem érvényes'),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a signature by another key does not do', () async {
      await expectLater(
        service(Server().call, keys: [keyB]).download(info(), dir),
        refused('aláírása nem érvényes'),
      );
    });

    test('with several keys one of them is enough', () async {
      final f = await service(
        Server().call,
        keys: [keyB, keyA],
      ).download(info(), dir);
      expect(f.existsSync(), isTrue);
    });

    test('a signature that is no signature does not do', () async {
      for (final junk in [
        '',
        'not base64 at all',
        'AAAA',
        sigA.substring(10),
      ]) {
        await expectLater(
          service(Server(sig: junk).call).download(info(), dir),
          refused('aláírása nem érvényes'),
          reason: junk,
        );
        expect(dir.listSync(), isEmpty);
      }
    });

    test('a signature file with a line break at the end is read', () async {
      final f = await service(Server(sig: '$sigA\n').call)
          .download(info(), dir);
      expect(f.existsSync(), isTrue);
    });

    test('the signature is fetched before the big file', () async {
      final s = Server();
      await service(s.call).download(info(), dir);
      expect(s.index(sigUrl), isNonNegative);
      expect(s.index(sigUrl), lessThan(s.index(pkgUrl)));
    });

    test(
      'a signature that cannot be had stops it before the download',
      () async {
        final s = Server(sig: null); // answers 404
        await expectLater(
          service(s.call).download(info(), dir),
          refused('Az aláírás nem tölthető le (404)'),
        );
        expect(s.asked(pkgUrl), isFalse);
        expect(dir.listSync(), isEmpty);
      },
    );

    test(
      'a signature file that is too big is refused, declared or not',
      () async {
        final declared = Server();
        await expectLater(
          service(declared.call).download(info(sigSize: 5000), dir),
          refused('túl nagy'),
        );
        expect(declared.asked(sigUrl), isFalse);

        final actual = Server(sig: 'A' * 5000);
        await expectLater(
          service(actual.call).download(info(), dir),
          refused('túl nagy'),
        );
        expect(actual.asked(pkgUrl), isFalse);
      },
    );

    test('no signature: taken for now, and said so in the log', () async {
      final log = <String>[];
      final s = Server();
      final f = await service(s.call, log: log).download(info(sig: false), dir);
      expect(f.existsSync(), isTrue);
      expect(s.asked(sigUrl), isFalse);
      expect(log.single, contains('no signature, accepted'));
    });

    test('no signature when it is required: refused, nothing left', () async {
      final log = <String>[];
      await expectLater(
        service(
          Server().call,
          require: true,
          log: log,
        ).download(info(sig: false), dir),
        refused('nincs aláírás'),
      );
      expect(dir.listSync(), isEmpty);
      expect(log.single, contains('no signature'));
    });

    test('a valid signature is taken when it is required too', () async {
      final f = await service(
        Server().call,
        require: true,
      ).download(info(), dir);
      expect(f.existsSync(), isTrue);
    });

    test(
      'without a key built in nothing about signatures is checked',
      () async {
        final s = Server(sig: 'garbage');
        final log = <String>[];
        final f = await service(
          s.call,
          keys: const [],
          log: log,
        ).download(info(), dir);
        expect(f.existsSync(), isTrue);
        expect(s.asked(sigUrl), isFalse, reason: 'not even asked for');
        expect(log.single, contains('no public key'));
      },
    );

    test(
      'a signature is required but no key is built in: refused before anything',
      () async {
        final s = Server();
        await expectLater(
          service(s.call, keys: const [], require: true).download(info(), dir),
          refused('nincs beépített kulcs'),
        );
        expect(s.log, isEmpty);
      },
    );

    test('the checksum still has to be right when the signature is', () async {
      final s = Server(sha: '${'0' * 64}  x');
      await expectLater(
        service(s.call).download(info(), dir),
        refused('nem egyezik'),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a refused signature is in the log', () async {
      final log = <String>[];
      await expectLater(
        service(Server(sig: sigB).call, log: log).download(info(), dir),
        throwsA(isA<HttpException>()),
      );
      expect(log.single, contains('NOT valid'));
    });

    test(
      'the signature asset is found by the check, by the package name',
      () async {
        Future<UpdateStatus> check(List<String> names) => UpdateService(
          client: MockClient((_) async {
            return _json({
              'tag_name': 'build-9',
              'assets': [
                for (final n in names)
                  {'name': n, 'url': '$api/assets/${n.hashCode}', 'size': 5},
              ],
            });
          }),
          repo: 'o/r',
          token: 'tok',
          platform: UpdatePlatform.windows,
        ).check(1);
        final signed = await check([
          'naptar-windows-9.zip',
          'naptar-windows-9.zip.sha256',
          'naptar-windows-9.zip.sig',
          'naptar-android-9.apk.sig',
        ]);
        expect(
          (signed as UpdateAvailable).info.sigAsset!.name,
          'naptar-windows-9.zip.sig',
        );
        final unsigned = await check([
          'naptar-windows-9.zip',
          'naptar-windows-9.zip.sha256',
          'naptar-android-9.apk.sig', // (the other platform's signature)
          'naptar-windows-8.zip.sig', // (another build's)
        ]);
        expect((unsigned as UpdateAvailable).info.sigAsset, isNull);
      },
    );
  });

  group('the settings of the build', () {
    test('the service is made from the settings, every one of them', () {
      final c = ProviderContainer(
        overrides: [
          updateSettingsProvider.overrideWithValue(
            const UpdateSettings(
              token: 'T0K',
              repo: 'who/what',
              publicKeys: [keyA, keyB],
              requireSignature: true,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final s = c.read(updateServiceProvider);
      expect(s.token, 'T0K');
      expect(s.repo, 'who/what');
      expect(s.publicKeys, [keyA, keyB]);
      expect(s.requireSignature, isTrue);
      expect(s.log, isNotNull, reason: 'the update log is wired in');
    });

    test('the defaults ask for nothing, and the settings have them too', () {
      const settings = UpdateSettings(token: 't', repo: 'r');
      expect(settings.publicKeys, isEmpty);
      expect(settings.requireSignature, isFalse);
      final s = UpdateService(
        client: MockClient((_) async => http.Response('', 404)),
        repo: 'r',
        token: 't',
        platform: UpdatePlatform.windows,
      );
      expect(s.publicKeys, isEmpty);
      expect(s.requireSignature, isFalse);
      expect(s.log, isNull);
    });

    test('what the build is made with: nothing is defined in a test run', () {
      final b = UpdateSettings.fromBuild();
      expect(b.token, UpdateConfig.token);
      expect(b.token, isEmpty);
      expect(b.repo, UpdateConfig.repo);
      expect(b.repo, 'Kvantum4500/Naptar');
      expect(b.publicKeys, isEmpty);
      expect(b.requireSignature, isFalse);
      expect(UpdateConfig.publicKeys, isEmpty);
      expect(UpdateConfig.requireSignature, isFalse);
    });

    test('the names the build is told are the ones the config reads', () {
      final config = File('lib/update/update_config.dart').readAsStringSync();
      final example = jsonDecode(
        File('secrets.example.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final name in [
        'UPDATE_TOKEN',
        'UPDATE_REPO',
        'UPDATE_PUBLIC_KEY',
        'UPDATE_REQUIRE_SIGNATURE',
      ]) {
        expect(
          RegExp("fromEnvironment\\(\\s*'$name'").hasMatch(config),
          isTrue,
          reason: name,
        );
      }
      for (final name in [
        'UPDATE_TOKEN',
        'UPDATE_PUBLIC_KEY',
        'UPDATE_REQUIRE_SIGNATURE',
      ]) {
        expect(example.keys, contains(name));
      }
      // (nothing is required, and no key is set, until it is chosen)
      expect(example['UPDATE_PUBLIC_KEY'], '');
      expect(example['UPDATE_REQUIRE_SIGNATURE'], 'false');
    });

    test('the build is made from every one of the settings', () {
      final config = File('lib/update/update_config.dart').readAsStringSync();
      final factory = RegExp(
        r'factory UpdateSettings\.fromBuild\(\)(.*?);',
        dotAll: true,
      ).firstMatch(config)!.group(1)!;
      for (final name in ['token', 'repo', 'publicKeys', 'requireSignature']) {
        expect(factory, contains('$name: UpdateConfig.$name'));
      }
      // (and the keys are read from what the build was told)
      expect(config, contains('parseUpdatePublicKeys(_publicKey)'));
    });

    test('the cleanup is started at startup', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('unawaited(_cleanUpdateLeftovers());'));
      expect(main, contains('cleanupUpdateLeftovers(Directory('));
      // (on Android the download is in the cache folder of the app)
      expect(
        RegExp(
          r'Platform\.isAndroid\s*\?\s*\(await getTemporaryDirectory\(\)\)\.path',
        ).hasMatch(main),
        isTrue,
      );
    });

    test(
      'a private key that lands in the folder is not committed by mistake',
      () {
        final ignore = File('../../.gitignore')
            .readAsLinesSync()
            .map((l) => l.trim());
        expect(ignore, contains('*.pem'));
      },
    );

    test('the cleanup looks where the download goes', () {
      for (final file in [
        'lib/main.dart',
        'lib/update/update_dialog.dart',
        'lib/update/update_service.dart',
      ]) {
        expect(
          File(file).readAsStringSync(),
          contains("'naptar-update'"),
          reason: file,
        );
      }
    });
  });

  group('where the token goes', () {
    /// The requests of a download whose package sits at [at].
    Future<List<http.Request>> requests(String at) async {
      final log = <http.Request>[];
      try {
        await service((req) async {
          log.add(req);
          if (req.url.toString() == shaUrl) {
            return http.Response('${sha256.convert(pkg85)}  x', 200);
          }
          if (req.url.toString() == sigUrl) return http.Response(sigA, 200);
          return http.Response.bytes(pkg85, 200);
        }).download(info(pkgAt: at), dir);
      } on HttpException {
        // (what matters here is what was sent)
      }
      return log;
    }

    String? tokenOf(List<http.Request> log, String url) => log
        .where((r) => r.url.toString() == url)
        .map((r) => r.headers['Authorization'])
        .firstOrNull;

    test('the API itself gets it', () async {
      final log = await requests(pkgUrl);
      expect(tokenOf(log, pkgUrl), 'Bearer tok');
      expect(tokenOf(log, shaUrl), 'Bearer tok');
      expect(tokenOf(log, sigUrl), 'Bearer tok');
    });

    test('another host does not, even one that starts like the API', () async {
      for (final url in [
        'https://objects.example.com/x',
        'https://api.github.com.evil.example/x',
        'https://evil-api.github.com/x',
        'https://github.com/x',
        'https://api.githubusercontent.com/x',
      ]) {
        final log = await requests(url);
        final sent = log.where((r) => r.url.toString() == url);
        expect(sent, isNotEmpty, reason: url);
        expect(
          sent.first.headers.containsKey('Authorization'),
          isFalse,
          reason: url,
        );
      }
    });

    test('the API on another port does not', () async {
      final log = await requests('https://api.github.com:8443/x');
      final sent = log.where((r) => r.url.port == 8443);
      expect(sent, isNotEmpty);
      expect(sent.first.headers.containsKey('Authorization'), isFalse);
    });

    test('a plain http address is not even tried', () async {
      for (final url in [
        'http://api.github.com/a/1',
        'ftp://api.github.com/x',
      ]) {
        final log = <http.Request>[];
        await expectLater(
          service((req) async {
            log.add(req);
            return http.Response(
              req.url.toString() == shaUrl
                  ? '${sha256.convert(pkg85)}  x'
                  : sigA,
              200,
            );
          }).download(info(pkgAt: url), dir),
          refused('titkosítatlan'),
          reason: url,
        );
        expect(log.where((r) => r.url.scheme != 'https'), isEmpty);
        expect(dir.listSync(), isEmpty);
      }
    });

    test(
      'a redirect to plain http is refused, the token never goes along',
      () async {
        final log = <http.Request>[];
        await expectLater(
          service((req) async {
            log.add(req);
            final url = req.url.toString();
            if (url == shaUrl) {
              return http.Response('${sha256.convert(pkg85)}', 200);
            }
            if (url == sigUrl) return http.Response(sigA, 200);
            if (url == pkgUrl) {
              return http.Response(
                '',
                302,
                headers: {'location': 'http://api.github.com/a/1'},
              );
            }
            return http.Response.bytes(pkg85, 200);
          }).download(info(), dir),
          refused('titkosítatlan'),
        );
        expect(log.where((r) => r.url.scheme == 'http'), isEmpty);
      },
    );

    test(
      'a redirect to a relative address stays on the API and keeps the token',
      () async {
        final log = <http.Request>[];
        await service((req) async {
          log.add(req);
          final url = req.url.toString();
          if (url == shaUrl) {
            return http.Response('${sha256.convert(pkg85)}', 200);
          }
          if (url == sigUrl) return http.Response(sigA, 200);
          if (url == pkgUrl) {
            return http.Response('', 302, headers: {'location': '/a/9'});
          }
          return http.Response.bytes(pkg85, 200);
        }).download(info(), dir);
        expect(tokenOf(log, '$api/a/9'), 'Bearer tok');
      },
    );
  });

  group('the address of the API', () {
    final apiUri = Uri.parse('https://api.github.com');
    bool is_(String url, [Uri? of]) =>
        isUpdateApiUrl(Uri.parse(url), of ?? apiUri);

    test('is the API itself, however it is written', () {
      expect(is_('https://api.github.com/repos/o/r/releases/assets/1'), isTrue);
      expect(is_('https://api.github.com:443/x'), isTrue);
      expect(is_('https://API.GITHUB.COM/x'), isTrue);
      expect(is_('https://api.github.com'), isTrue);
    });

    test('is no other host, however much it looks like it', () {
      for (final other in [
        'https://github.com/x',
        'https://objects.githubusercontent.com/x',
        'https://api.github.com.evil.example/x',
        'https://evilapi.github.com/x',
        'https://x.api.github.com/x',
        'https://api.github.com@evil.example/x',
        'https://evil.example/api.github.com',
      ]) {
        expect(is_(other), isFalse, reason: other);
      }
    });

    test('is no other port', () {
      expect(is_('https://api.github.com:8443/x'), isFalse);
      expect(is_('https://api.github.com:444/x'), isFalse);
    });

    test('is not without encryption, not even on the right port', () {
      expect(is_('http://api.github.com/x'), isFalse);
      expect(is_('http://api.github.com:443/x'), isFalse);
    });

    test('is not an API that is itself not encrypted', () {
      expect(
        is_(
          'https://api.example.com:443/x',
          Uri.parse('http://api.example.com:443'),
        ),
        isFalse,
      );
    });
  });

  group('redirects', () {
    test(
      'are followed by hand: the client is told not to follow any',
      () async {
        final s = Server();
        await service(s.call).download(info(), dir);
        expect(s.log, isNotEmpty);
        expect(s.log.every((r) => !r.followRedirects), isTrue);
      },
    );

    for (final code in [301, 302, 303, 307, 308]) {
      test('a $code is followed to where it points', () async {
        final s = Server();
        await service((req) {
          if (req.url.toString() == pkgUrl) {
            return Future.value(
              http.Response('', code, headers: {'location': blob}),
            );
          }
          return s.call(req);
        }).download(info(), dir);
        expect(s.asked(blob), isTrue);
      });
    }

    test(
      'an answer in the 3xx without a place to go to is no redirect',
      () async {
        await expectLater(
          service((req) async {
            if (req.url.toString() == shaUrl) {
              return http.Response('${sha256.convert(pkg85)}', 200);
            }
            if (req.url.toString() == sigUrl) return http.Response(sigA, 200);
            return http.Response('', 304);
          }).download(info(), dir),
          refused('(304)'),
        );
      },
    );

    test('a chain that never ends is stopped after five hops', () async {
      final s = Server();
      var asked = 0;
      await expectLater(
        service((req) {
          if (req.url.toString() == pkgUrl) {
            asked++;
            return Future.value(
              http.Response('', 302, headers: {'location': pkgUrl}),
            );
          }
          return s.call(req);
        }).download(info(), dir),
        refused('Túl sok átirányítás'),
      );
      expect(asked, 6, reason: 'the first request and five hops');
    });
  });

  group('the size of the package', () {
    /// A service whose package comes as a stream of [chunks] (with the length
    /// the headers say, or none), ending in an error if [failAfter] is given.
    UpdateService streamed(
      List<List<int>> chunks, {
      int? length,
      Object? failAfter,
      List<String>? log,
    }) => UpdateService(
      client: MockClient.streaming((req, body) async {
        final url = req.url.toString();
        Stream<List<int>> text(String t) => Stream.value(utf8.encode(t));
        if (url == shaUrl) {
          final all = [for (final c in chunks) ...c];
          return http.StreamedResponse(text('${sha256.convert(all)}  x'), 200);
        }
        if (url == sigUrl) return http.StreamedResponse(text(sigA), 200);
        Stream<List<int>> body0() async* {
          for (final c in chunks) {
            yield c;
          }
          if (failAfter != null) throw failAfter;
        }

        return http.StreamedResponse(body0(), 200, contentLength: length);
      }),
      repo: 'o/r',
      token: 'tok',
      platform: UpdatePlatform.windows,
      publicKeys: const [],
      log: log?.add,
    );

    test('exactly what the release says: taken', () async {
      final f = await streamed([pkg85.sublist(0, 4), pkg85.sublist(4)])
          .download(info(), dir);
      expect(f.readAsBytesSync(), pkg85);
    });

    test('more than the release says: stopped, and nothing is left', () async {
      final extra = [...pkg85, ...List.filled(50, 1)];
      await expectLater(
        streamed([extra.sublist(0, 20), extra.sublist(20)])
            .download(info(bytes: pkg85), dir),
        refused('nagyobb'),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('an endless answer is stopped at the declared size', () async {
      var sent = 0;
      final s = UpdateService(
        client: MockClient.streaming((req, body) async {
          final url = req.url.toString();
          if (url == shaUrl) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('${sha256.convert(pkg85)}')),
              200,
            );
          }
          Stream<List<int>> forever() async* {
            while (true) {
              sent += 1000;
              yield List.filled(1000, 7);
              await Future<void>.delayed(Duration.zero);
            }
          }

          return http.StreamedResponse(forever(), 200);
        }),
        repo: 'o/r',
        token: 'tok',
        platform: UpdatePlatform.windows,
      );
      await expectLater(s.download(info(), dir), refused('nagyobb'));
      expect(sent, lessThan(10000));
      expect(dir.listSync(), isEmpty);
    });

    test('less than the release says: refused, nothing is left', () async {
      await expectLater(
        streamed([pkg85.sublist(0, 6)]).download(info(), dir),
        refused('nem egyezik'),
      );
      expect(dir.listSync(), isEmpty);
    });

    test(
      'a server that gives another length than the release: not even read',
      () async {
        var produced = 0;
        final s = UpdateService(
          client: MockClient.streaming((req, body) async {
            final url = req.url.toString();
            if (url == shaUrl) {
              return http.StreamedResponse(
                Stream.value(utf8.encode('${sha256.convert(pkg85)}')),
                200,
              );
            }
            Stream<List<int>> content() async* {
              for (var i = 0; i < 1000; i++) {
                produced++;
                yield [1];
              }
            }

            return http.StreamedResponse(content(), 200, contentLength: 999);
          }),
          repo: 'o/r',
          token: 'tok',
          platform: UpdatePlatform.windows,
        );
        await expectLater(s.download(info(), dir), refused('más méretet'));
        // (let go of at once: not a thousand chunks read to the end)
        expect(produced, lessThan(5));
        expect(dir.listSync(), isEmpty);
      },
    );

    test('with no size anywhere there is no progress to tell', () async {
      final calls = <double>[];
      await streamed([pkg85])
          .download(info(size: 0), dir, onProgress: calls.add);
      expect(calls, isEmpty);
    });

    test(
      'the progress never goes beyond one, whatever the server says',
      () async {
        final calls = <double>[];
        await streamed([
          pkg85.sublist(0, 4),
          pkg85.sublist(4),
        ], length: 3).download(info(size: 0), dir, onProgress: calls.add);
        expect(calls, isNotEmpty);
        expect(calls.every((c) => c >= 0 && c <= 1), isTrue, reason: '$calls');
        expect(calls.last, 1);
      },
    );

    test('the largest size is a limit that can be set: what is over is not asked for', () async {
      final bytes = utf8.encode('x' * 21);
      final s = Server(bytes: bytes);
      await expectLater(
        service(
          s.call,
          keys: const [],
          cap: 20,
        ).download(info(bytes: bytes), dir),
        refused('a megengedettnél nagyobb'),
      );
      expect(s.asked(pkgUrl), isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('and exactly that size is taken', () async {
      final bytes = utf8.encode('x' * 20);
      final f = await service(
        Server(bytes: bytes).call,
        keys: const [],
        cap: 20,
      ).download(info(bytes: bytes), dir);
      expect(f.lengthSync(), 20);
    });

    test(
      'a release that does not say the size is held to the largest one',
      () async {
        final bytes = utf8.encode('x' * 21);
        await expectLater(
          service(
            Server(bytes: bytes).call,
            keys: const [],
            cap: 20,
          ).download(info(bytes: bytes, size: 0), dir),
          refused('nagyobb, mint amekkorának'),
        );
        expect(dir.listSync(), isEmpty);
      },
    );

    test(
      'and one that is just that big is taken (no size to check it against)',
      () async {
        final bytes = utf8.encode('x' * 20);
        final f = await service(
          Server(bytes: bytes).call,
          keys: const [],
          cap: 20,
        ).download(info(bytes: bytes, size: 0), dir);
        expect(f.lengthSync(), 20);
      },
    );

    test('a package larger than the limit is not even asked for', () async {
      final s = Server();
      await expectLater(
        service(s.call).download(info(size: maxUpdatePackageBytes + 1), dir),
        refused('megengedettnél nagyobb'),
      );
      expect(s.log, isEmpty);
      // (the limit itself is fine)
      expect(maxUpdatePackageBytes, 400 * 1024 * 1024);
    });

    test(
      'a release that does not say its size is held to the limit alone',
      () async {
        final f = await streamed([pkg85]).download(info(size: 0), dir);
        expect(f.readAsBytesSync(), pkg85);
      },
    );

    test('the progress follows what has come, ending at one', () async {
      final progress = <double>[];
      await streamed([
        pkg85.sublist(0, 5),
        pkg85.sublist(5),
      ], length: pkg85.length).download(info(), dir, onProgress: progress.add);
      expect(progress, [0.5, 1.0]);
    });

    test('a connection that breaks half way leaves nothing', () async {
      await expectLater(
        streamed([
          pkg85.sublist(0, 5),
        ], failAfter: const SocketException('reset')).download(info(), dir),
        throwsA(isA<SocketException>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a checksum or signature file that is too big is refused', () async {
      final declared = Server();
      await expectLater(
        service(declared.call).download(
          ReleaseInfo(
            build: buildA,
            tag: 'build-$buildA',
            package: const ReleaseAsset('naptar-windows-85.zip', pkgUrl, 10),
            sha256Asset: const ReleaseAsset('x.sha256', shaUrl, 5000),
          ),
          dir,
        ),
        refused('túl nagy'),
      );
      expect(declared.log, isEmpty);

      final actual = Server(sha: 'a' * 5000);
      await expectLater(
        service(actual.call).download(info(sig: false), dir),
        refused('túl nagy'),
      );
      expect(actual.asked(pkgUrl), isFalse);
    });

    test('a checksum file of exactly the largest size is read, one byte more is not', () async {
      final hash = sha256.convert(pkg85).toString();
      final exact = '$hash  ${'x' * (maxUpdateTextBytes - hash.length - 2)}';
      expect(exact.length, maxUpdateTextBytes);
      final f = await service(
        Server(sha: exact).call,
        keys: const [],
      ).download(info(sig: false), dir);
      expect(f.existsSync(), isTrue);
      final s = Server(sha: '$exact!');
      await expectLater(
        service(s.call, keys: const []).download(info(sig: false), dir),
        refused('túl nagy'),
      );
    });

    test('a declared size of exactly the largest text is asked for, one more is not', () async {
      final ok = Server();
      await service(ok.call, keys: const []).download(
        ReleaseInfo(
          build: buildA,
          tag: 'build-$buildA',
          package: const ReleaseAsset('naptar-windows-85.zip', pkgUrl, 10),
          sha256Asset: const ReleaseAsset(
            'x.sha256',
            shaUrl,
            maxUpdateTextBytes,
          ),
        ),
        dir,
      );
      expect(ok.asked(shaUrl), isTrue);
      final no = Server();
      await expectLater(
        service(no.call, keys: const []).download(
          ReleaseInfo(
            build: buildA,
            tag: 'build-$buildA',
            package: const ReleaseAsset('naptar-windows-85.zip', pkgUrl, 10),
            sha256Asset: const ReleaseAsset(
              'x.sha256',
              shaUrl,
              maxUpdateTextBytes + 1,
            ),
          ),
          dir,
        ),
        refused('túl nagy'),
      );
      expect(no.asked(shaUrl), isFalse);
    });

    test('a package of exactly the largest size passes that check (and is then held to its real size)', () async {
      final s = Server();
      await expectLater(
        service(s.call).download(info(size: maxUpdatePackageBytes), dir),
        refused('más méretet'),
      );
      expect(s.asked(pkgUrl), isTrue, reason: 'it was asked for');
    });

    test(
      'the checksum may be followed by the file name, as sha256sum writes it',
      () async {
        final s = Server(
          sha:
              '${sha256.convert(pkg85).toString().toUpperCase()}  naptar.zip\n',
        );
        final f = await service(
          s.call,
          keys: const [],
        ).download(info(sig: false), dir);
        expect(f.existsSync(), isTrue);
      },
    );

    test('and the file may be laid out in other ways', () async {
      final h = sha256.convert(pkg85).toString();
      for (final text in [
        h,
        '$h\n',
        '  $h  \n',
        '\n\n$h  naptar.zip\n',
        '$h\tnaptar.zip',
        '$h\nnaptar.zip',
        '$h *naptar.zip\r\n',
      ]) {
        final f = await service(
          Server(sha: text).call,
          keys: const [],
        ).download(info(sig: false), dir);
        expect(f.existsSync(), isTrue, reason: text);
        f.deleteSync();
      }
    });
  });

  group('the package is checked again before it is installed', () {
    test('the file that was verified passes, as often as asked', () async {
      final svc = service(Server().call);
      final f = await svc.download(info(), dir);
      await svc.recheck(f);
      await svc.recheck(f);
    });

    test('a file that was changed since is refused and deleted', () async {
      final svc = service(Server().call);
      final f = await svc.download(info(), dir);
      f.writeAsBytesSync([...pkg85, 0]);
      await expectLater(svc.recheck(f), refused('megváltozott'));
      expect(f.existsSync(), isFalse);
      // (and it is not a verified file any more)
      await expectLater(svc.recheck(f), refused('nem történt meg'));
    });

    test(
      'a file of the same length but other content is refused too',
      () async {
        final svc = service(Server().call);
        final f = await svc.download(info(), dir);
        f.writeAsBytesSync(pkg86.sublist(0, pkg85.length));
        await expectLater(svc.recheck(f), refused('megváltozott'));
      },
    );

    test('a file that has gone is refused', () async {
      final svc = service(Server().call);
      final f = await svc.download(info(), dir);
      f.deleteSync();
      await expectLater(svc.recheck(f), refused('eltűnt'));
      // (a file put there afterwards is not the one that was verified, however
      // alike it looks)
      f.writeAsBytesSync(pkg85);
      await expectLater(svc.recheck(f), refused('nem történt meg'));
    });

    test('a file this service did not download is refused', () async {
      final f = File('${dir.path}/other.zip')..writeAsBytesSync(pkg85);
      await expectLater(
        service(Server().call).recheck(f),
        refused('nem történt meg'),
      );
      expect(f.existsSync(), isTrue, reason: 'not its file to delete');
    });

    test('a download that was refused is not a verified file', () async {
      final svc = service(Server(sig: sigB).call);
      await expectLater(
        svc.download(info(), dir),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        svc.recheck(File('${dir.path}/naptar-windows-85.zip')),
        refused('nem történt meg'),
      );
    });
  });

  group('what an update leaves behind', () {
    final now = DateTime(2026, 11, 14, 12);

    /// A file last touched [age] before [now].
    File file(String rel, {Duration age = Duration.zero}) {
      final f = File('${dir.path}/$rel')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      f.setLastModifiedSync(now.subtract(age));
      return f;
    }

    test('old files are removed, fresh ones kept', () {
      final oldPkg = file(
        'naptar-windows-80.zip',
        age: const Duration(days: 3),
      );
      final freshPkg = file(
        'naptar-windows-85.zip',
        age: const Duration(hours: 2),
      );
      expect(cleanupUpdateLeftovers(dir, now: now), 1);
      expect(oldPkg.existsSync(), isFalse);
      expect(freshPkg.existsSync(), isTrue);
    });

    test('a folder goes whole, with what is in it, when it is old', () {
      final folder = Directory('${dir.path}/new-80')..createSync();
      File('${folder.path}/sub/app.exe')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      final real = DateTime.now();
      // (a folder made just now is fresh a little later, old a day later)
      expect(
        cleanupUpdateLeftovers(dir, now: real.add(const Duration(hours: 1))),
        0,
      );
      expect(folder.existsSync(), isTrue);
      expect(
        cleanupUpdateLeftovers(dir, now: real.add(const Duration(hours: 25))),
        1,
      );
      expect(folder.existsSync(), isFalse);
    });

    test('a link in the folder goes as a link: what it points to stays', () {
      final outside = Directory.systemTemp.createTempSync('naptar-outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      File('${outside.path}/keep.txt').writeAsStringSync('x');
      final root = Directory('${dir.path}/with-link')..createSync();
      try {
        Link('${root.path}/old-link').createSync(outside.path);
      } on FileSystemException {
        return; // (no links here)
      }
      final n = cleanupUpdateLeftovers(
        root,
        now: DateTime.now().add(const Duration(days: 3)),
      );
      expect(n, 1);
      expect(root.listSync(), isEmpty);
      expect(File('${outside.path}/keep.txt').existsSync(), isTrue);
    });

    test('the update log stays, however old', () {
      final log = file('update.log', age: const Duration(days: 90));
      file('old.zip', age: const Duration(days: 90));
      expect(cleanupUpdateLeftovers(dir, now: now), 1);
      expect(log.existsSync(), isTrue);
    });

    test('a file just inside and just outside the time is told apart', () {
      final inside = file('a.zip', age: const Duration(hours: 23, minutes: 59));
      final outside = file('b.zip', age: const Duration(hours: 24, minutes: 1));
      expect(cleanupUpdateLeftovers(dir, now: now), 1);
      expect(inside.existsSync(), isTrue);
      expect(outside.existsSync(), isFalse);
    });

    test('exactly as old as the time is not older than it', () {
      final exact = file('c.zip', age: const Duration(hours: 24));
      final over = file('d.zip', age: const Duration(hours: 24, seconds: 1));
      expect(cleanupUpdateLeftovers(dir, now: now), 1);
      expect(exact.existsSync(), isTrue);
      expect(over.existsSync(), isFalse);
    });

    test('the time can be chosen', () {
      final f = file('a.zip', age: const Duration(hours: 2));
      expect(
        cleanupUpdateLeftovers(
          dir,
          now: now,
          olderThan: const Duration(hours: 3),
        ),
        0,
      );
      expect(f.existsSync(), isTrue);
      expect(
        cleanupUpdateLeftovers(
          dir,
          now: now,
          olderThan: const Duration(hours: 1),
        ),
        1,
      );
      expect(f.existsSync(), isFalse);
    });

    test(
      'a folder that is not there, or a file in its place, is no trouble',
      () {
        expect(cleanupUpdateLeftovers(Directory('${dir.path}/none')), 0);
        final f = file('plain.txt', age: const Duration(days: 9));
        expect(cleanupUpdateLeftovers(Directory(f.path), now: now), 0);
        expect(f.existsSync(), isTrue);
      },
    );

    test('without a given time it is the clock of the machine', () {
      final f = File('${dir.path}/old.zip')..writeAsStringSync('x');
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final fresh = File('${dir.path}/fresh.zip')..writeAsStringSync('x');
      expect(cleanupUpdateLeftovers(dir), 1);
      expect(f.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });
  });

  group('a package that unpacks into something absurd', () {
    File zipOf(List<ArchiveFile> files) {
      final a = Archive();
      files.forEach(a.addFile);
      return File('${dir.path}/u.zip')
        ..writeAsBytesSync(ZipEncoder().encode(a));
    }

    ArchiveFile f(String name, int size) =>
        ArchiveFile(name, size, List.filled(size, 7));

    Object? tryExtract(File z, {int? entries, int? bytes}) {
      try {
        extractUpdateZip(
          z,
          Directory('${dir.path}/out'),
          maxEntries: entries ?? maxUpdateEntries,
          maxUnpackedBytes: bytes ?? maxUpdateUnpackedBytes,
        );
      } on FormatException catch (e) {
        return e.message;
      }
      return null;
    }

    test('too many files is refused before anything is written', () {
      final z = zipOf([
        f('kvantum_app.exe', 1),
        f('a', 1),
        f('b', 1),
        f('c', 1),
      ]);
      expect(tryExtract(z, entries: 3), contains('túl sok'));
      expect(Directory('${dir.path}/out').existsSync(), isFalse);
    });

    test('exactly the limit of files is fine', () {
      final z = zipOf([f('kvantum_app.exe', 1), f('a', 1), f('b', 1)]);
      expect(tryExtract(z, entries: 3), isNull);
      expect(File('${dir.path}/out/kvantum_app.exe').existsSync(), isTrue);
    });

    test('a size beyond the limit is refused before anything is written', () {
      final z = zipOf([f('kvantum_app.exe', 60), f('big.bin', 41)]);
      expect(tryExtract(z, bytes: 100), contains('túl nagy'));
      expect(Directory('${dir.path}/out').existsSync(), isFalse);
    });

    test('a single file beyond the limit is refused', () {
      final z = zipOf([f('kvantum_app.exe', 101)]);
      expect(tryExtract(z, bytes: 100), contains('túl nagy'));
    });

    test('exactly the limit of bytes is fine', () {
      final z = zipOf([f('kvantum_app.exe', 60), f('big.bin', 40)]);
      expect(tryExtract(z, bytes: 100), isNull);
    });

    test('the limits are what the real package needs, with room to spare', () {
      expect(maxUpdateUnpackedBytes, 600 * 1024 * 1024);
      expect(maxUpdateEntries, 10000);
      expect(maxUpdateTextBytes, 4096);
      // (the default is the constant: a normal package goes through)
      final z = zipOf([f('kvantum_app.exe', 30), f('data/a.bin', 30)]);
      expect(tryExtract(z), isNull);
    });
  });

  group('when the token runs out', () {
    DateTime? parse(String? s) => parseTokenExpiry(s);

    test('GitHub\'s own writing, and the usual others', () {
      final want = DateTime.utc(2026, 12, 5, 10, 0, 0);
      expect(parse('2026-12-05 10:00:00 UTC'), want);
      expect(parse('2026-12-05 10:00:00 +0000'), want);
      expect(parse('2026-12-05T10:00:00Z'), want);
      expect(parse('2026-12-05T10:00:00+00:00'), want);
      expect(parse('2026-12-05 10:00:00'), want);
      expect(parse('2026-12-05 10:00 UTC'), want);
      expect(parse('2026-12-05T10:00:00.123Z'), want);
      expect(parse('  2026-12-05 10:00:00 UTC \n'), want);
      expect(parse('2026-12-05 10:00:00 utc'), want);
      expect(parse('2026-12-05 10:00:00 GMT'), want);
    });

    test('an offset is taken into account the right way round', () {
      expect(parse('2026-12-05 10:00:00 -0500'), DateTime.utc(2026, 12, 5, 15));
      expect(parse('2026-12-05 10:00:00 +0100'), DateTime.utc(2026, 12, 5, 9));
      expect(parse('2026-12-05T10:30:00+05:30'), DateTime.utc(2026, 12, 5, 5));
      expect(parse('2026-12-05T01:00:00+02:00'), DateTime.utc(2026, 12, 4, 23));
    });

    test('a date alone is the start of that day', () {
      expect(parse('2026-12-05'), DateTime.utc(2026, 12, 5));
      expect(parse('2026-12-05 UTC'), DateTime.utc(2026, 12, 5));
    });

    test('what is not a time is nothing', () {
      for (final junk in [
        null,
        '',
        ' ',
        'soon',
        '2026-13-01 10:00:00 UTC',
        '2026-02-31 10:00:00 UTC',
        '2026-12-05 24:00:00 UTC',
        '2026-12-05 25:00:00 UTC',
        '2026-12-05 10:60:00 UTC',
        '2026-12-05 10:00:60 UTC',
        '2026-12-05 10:00:99 UTC',
        '2026-00-10',
        '2026-12-00',
        '2026-04-31',
        'expires 2026-12-05 10:00:00 UTC',
        '12026-12-05 10:00:00 UTC',
        '2026-12-05 10:00:00 UTC soon',
        '2026-12-05 10:00:00 UTC!',
        '2026-12-05 10:00:00 +2500',
        '2026-12-05 10:00:00 +0075',
        '05/12/2026',
        '2026-12-05 10:00:00 PST',
        '1796468400',
      ]) {
        expect(parse(junk), isNull, reason: '$junk');
      }
    });

    test('the last moment of a day is one', () {
      expect(
        parse('2026-12-05 23:59:59 UTC'),
        DateTime.utc(2026, 12, 5, 23, 59, 59),
      );
      expect(parse('2026-12-05 00:00:00 UTC'), DateTime.utc(2026, 12, 5));
      expect(
        parse('2026-12-05 10:00:00 +2359'),
        DateTime.utc(2026, 12, 4, 10, 1),
      );
    });

    test('a leap day is a day', () {
      expect(parse('2028-02-29'), DateTime.utc(2028, 2, 29));
      expect(parse('2026-02-29'), isNull);
    });

    final exp = DateTime.utc(2026, 12, 5, 10);
    String? warn(Duration before, {int within = 14}) =>
        tokenExpiryWarning(exp, exp.subtract(before), withinDays: within);

    test('nothing to say when it is far off, or not known', () {
      expect(tokenExpiryWarning(null, exp), isNull);
      expect(warn(const Duration(days: 15)), isNull);
      expect(warn(const Duration(days: 100)), isNull);
      expect(warn(const Duration(days: 14, minutes: 1)), isNull);
    });

    test('a warning from fourteen days on, counting the days', () {
      expect(warn(const Duration(days: 14)), contains('14 nap múlva lejár'));
      expect(
        warn(const Duration(days: 13, hours: 5)),
        contains('13 nap múlva'),
      );
      expect(warn(const Duration(days: 2, hours: 3)), contains('2 nap múlva'));
      expect(warn(const Duration(days: 1)), contains('1 nap múlva'));
      expect(
        warn(const Duration(hours: 23)),
        contains('egy napon belül lejár'),
      );
      expect(warn(const Duration(minutes: 1)), contains('egy napon belül'));
    });

    test('the limit can be chosen', () {
      expect(warn(const Duration(days: 20), within: 30), contains('20 nap'));
      expect(warn(const Duration(days: 20), within: 10), isNull);
    });

    test('after it has run out, it says so', () {
      final late = tokenExpiryWarning(exp, exp.add(const Duration(seconds: 1)));
      expect(late, contains('lejárt'));
      expect(late, isNot(contains('nap múlva')));
      expect(
        tokenExpiryWarning(exp, exp.add(const Duration(days: 400))),
        contains('lejárt'),
      );
    });

    test('what to do is told, and where to read on', () {
      for (final w in [
        warn(const Duration(days: 3)),
        warn(const Duration(days: -3)),
      ]) {
        expect(w, contains('újratelepíteni'));
        expect(w, contains('docs/frissito-kulcs.md'));
        expect(w, contains('nem talál új verziót'));
      }
    });

    UpdateService checking(Map<String, String> headers, {int build = 9}) =>
        UpdateService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'tag_name': 'build-$build',
                'assets': [
                  {
                    'name': 'naptar-windows-$build.zip',
                    'url': '$api/x',
                    'size': 5,
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json', ...headers},
            ),
          ),
          repo: 'o/r',
          token: 'tok',
          platform: UpdatePlatform.windows,
        );

    test('the check reads the header: for an update, and for none', () async {
      final h = {
        'github-authentication-token-expiration': '2026-12-05 10:00:00 UTC',
      };
      final newer = await checking(h).check(5);
      expect((newer as UpdateAvailable).tokenExpires, exp);
      final same = await checking(h).check(9);
      expect((same as UpToDate).tokenExpires, exp);
    });

    test('no header, or one that makes no sense, is no expiry', () async {
      expect(
        ((await checking({}).check(5)) as UpdateAvailable).tokenExpires,
        isNull,
      );
      expect(((await checking({}).check(9)) as UpToDate).tokenExpires, isNull);
      final junk = {'github-authentication-token-expiration': 'whenever'};
      expect(
        ((await checking(junk).check(5)) as UpdateAvailable).tokenExpires,
        isNull,
      );
    });

    test('the header is not asked for by another name', () async {
      final other = {
        'x-github-authentication-token-expiration': '2026-12-05 10:00:00 UTC',
      };
      expect(
        ((await checking(other).check(5)) as UpdateAvailable).tokenExpires,
        isNull,
      );
    });
  });

  group('the dialog', () {
    final exp = DateTime.utc(2026, 12, 5, 10);
    final cleanup = File(
      '${Directory.systemTemp.path}/naptar-update/dl/naptar-windows-85.zip',
    );

    Widget host({
      required DateTime now,
      String? expiry = '2026-12-05 10:00:00 UTC',
      int latest = 9,
      int installed = 5,
      bool withSig = false,
      bool tamper = false,
      Server? server,
      UpdateInstaller? installer,
      List<String> keys = const [],
      bool require = false,
    }) {
      Future<http.Response> handler(http.Request req) async {
        if (req.url.path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'build-$latest',
              'assets': [
                {
                  'name': 'naptar-windows-$latest.zip',
                  'url': pkgUrl,
                  'size': pkg85.length,
                },
                {
                  'name': 'naptar-windows-$latest.zip.sha256',
                  'url': shaUrl,
                  'size': 90,
                },
                if (withSig)
                  {
                    'name': 'naptar-windows-$latest.zip.sig',
                    'url': sigUrl,
                    'size': 88,
                  },
              ],
            }),
            200,
            headers: {
              'content-type': 'application/json',
              'github-authentication-token-expiration': ?expiry,
            },
          );
        }
        return server != null ? server.call(req) : http.Response('', 404);
      }

      final svc = tamper
          ? _Tampering(
              client: MockClient(handler),
              repo: 'o/r',
              token: 'tok',
              platform: UpdatePlatform.windows,
            )
          : UpdateService(
              client: MockClient(handler),
              repo: 'o/r',
              token: 'tok',
              platform: UpdatePlatform.windows,
              publicKeys: keys,
              requireSignature: require,
            );
      return ProviderScope(
        overrides: [
          currentBuildProvider.overrideWith((ref) async => installed),
          updatePrefsProvider.overrideWithValue(_Prefs()),
          appClockProvider.overrideWithValue(() => now),
          updateServiceProvider.overrideWithValue(svc),
          if (installer != null)
            updateInstallerProvider.overrideWithValue(installer),
        ],
        child: const MaterialApp(home: Scaffold(body: UpdateDialog())),
      );
    }

    final warning = find.byKey(const Key('update-token-warning'));

    /// Opens the dialog and, if [install], presses the button.
    Future<void> open(
      WidgetTester tester,
      Widget app, {
      bool install = false,
    }) async {
      addTearDown(() {
        try {
          cleanup.deleteSync();
        } catch (_) {}
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(app);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      if (!install) return;
      await tester.runAsync(() async {
        await tester.tap(find.text('Frissítés most'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('warns ahead of the expiry, when there is an update', (
      tester,
    ) async {
      await open(tester, host(now: exp.subtract(const Duration(days: 9))));
      expect(find.textContaining('Új verzió érhető el: 9'), findsOneWidget);
      expect(warning, findsOneWidget);
      expect(find.textContaining('9 nap múlva lejár'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      // (an icon with a name for the screen reader: the warning is not colour only)
      expect(
        tester
            .widget<Icon>(find.byIcon(Icons.warning_amber_rounded))
            .semanticLabel,
        'Figyelmeztetés',
      );
    });

    testWidgets(
      'at 360 px and twice the letter size nothing overflows: the dialog scrolls',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await open(tester, host(now: exp.subtract(const Duration(days: 9))));
        expect(tester.takeException(), isNull);
        expect(warning, findsOneWidget);
        // (the part that does not fit is reached by scrolling, the buttons
        // stay where they are)
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(SingleChildScrollView),
          ),
          findsOneWidget,
        );
        expect(
          tester.getRect(find.text('Frissítés most')).bottom,
          lessThan(800),
        );
        expect(tester.getRect(find.text('Bezár')).bottom, lessThan(800));
      },
    );

    testWidgets('and when there is none', (tester) async {
      await open(
        tester,
        host(now: exp.subtract(const Duration(days: 3)), installed: 9),
      );
      expect(find.textContaining('Naprakész vagy'), findsOneWidget);
      expect(find.textContaining('3 nap múlva lejár'), findsOneWidget);
    });

    testWidgets('says nothing while the expiry is far off', (tester) async {
      await open(tester, host(now: exp.subtract(const Duration(days: 15))));
      expect(find.textContaining('Új verzió érhető el'), findsOneWidget);
      expect(warning, findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('says nothing when GitHub did not say', (tester) async {
      await open(
        tester,
        host(now: exp.subtract(const Duration(days: 2)), expiry: null),
      );
      expect(find.textContaining('Új verzió érhető el'), findsOneWidget);
      expect(warning, findsNothing);
    });

    testWidgets('the days are counted from the clock of the app', (
      tester,
    ) async {
      await open(tester, host(now: exp.subtract(const Duration(days: 14))));
      expect(find.textContaining('14 nap múlva lejár'), findsOneWidget);
    });

    testWidgets('an expiry that has passed is said as it is', (tester) async {
      await open(tester, host(now: exp.add(const Duration(days: 2))));
      expect(find.textContaining('A frissítő kulcs lejárt'), findsOneWidget);
    });

    final far = DateTime.utc(2026, 10, 1);

    testWidgets('a signed release is installed', (tester) async {
      final installed = <String>[];
      await open(
        tester,
        host(
          now: far,
          latest: 85,
          withSig: true,
          keys: [keyA],
          server: Server(),
          installer: _Installer(installed),
        ),
        install: true,
      );
      expect(installed, ['naptar-windows-85.zip']);
      expect(find.text('Kész, újraindítás…'), findsOneWidget);
    });

    testWidgets('a release signed by another key is not, and why is shown', (
      tester,
    ) async {
      final installed = <String>[];
      await open(
        tester,
        host(
          now: far,
          latest: 85,
          withSig: true,
          keys: [keyB],
          server: Server(),
          installer: _Installer(installed),
        ),
        install: true,
      );
      expect(installed, isEmpty);
      expect(find.textContaining('aláírása nem érvényes'), findsOneWidget);
    });

    testWidgets('a missing signature stops it when it is required', (
      tester,
    ) async {
      final installed = <String>[];
      await open(
        tester,
        host(
          now: far,
          latest: 85,
          keys: [keyA],
          require: true,
          server: Server(),
          installer: _Installer(installed),
        ),
        install: true,
      );
      expect(installed, isEmpty);
      expect(find.textContaining('nincs aláírás'), findsOneWidget);
    });

    testWidgets('a missing signature does not, as long as it is not required', (
      tester,
    ) async {
      final installed = <String>[];
      await open(
        tester,
        host(
          now: far,
          latest: 85,
          keys: [keyA],
          server: Server(),
          installer: _Installer(installed),
        ),
        install: true,
      );
      expect(installed, ['naptar-windows-85.zip']);
    });

    testWidgets('a package changed after it was verified is not installed', (
      tester,
    ) async {
      final installed = <String>[];
      await open(
        tester,
        host(
          now: far,
          latest: 85,
          tamper: true,
          server: Server(),
          installer: _Installer(installed),
        ),
        install: true,
      );
      expect(installed, isEmpty);
      expect(find.textContaining('időközben megváltozott'), findsOneWidget);
    });
  });
}

/// A service whose download is changed behind its back, after it was verified
/// (what the check before the installation is for).
class _Tampering extends UpdateService {
  _Tampering({
    required super.client,
    required super.repo,
    required super.token,
    required super.platform,
  });

  @override
  Future<File> download(
    ReleaseInfo info,
    Directory dir, {
    void Function(double fraction)? onProgress,
  }) async {
    final f = await super.download(info, dir, onProgress: onProgress);
    f.writeAsBytesSync([...f.readAsBytesSync(), 0]);
    return f;
  }
}

class _Prefs implements UpdatePrefs {
  @override
  Future<bool> previews() async => false;
  @override
  Future<void> setPreviews(bool v) async {}
}

class _Installer implements UpdateInstaller {
  _Installer(this.log);
  final List<String> log;
  @override
  Future<String?> install(File package, ReleaseInfo info) async {
    log.add(package.uri.pathSegments.last);
    return 'Kész, újraindítás…';
  }
}
