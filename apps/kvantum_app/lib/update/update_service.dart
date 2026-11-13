import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../sync/error_catalog.dart';
import 'update_signature.dart';

/// The largest package the updater takes (SEC-15): the real ones are 15-75 MB.
const maxUpdatePackageBytes = 400 * 1024 * 1024;

/// The checksum and the signature of a release are a line of text each; more
/// than this is not one.
const maxUpdateTextBytes = 4096;

/// What a Windows package may unpack to (the real one: about 50 MB in some
/// hundred files).
const maxUpdateUnpackedBytes = 600 * 1024 * 1024;
const maxUpdateEntries = 10000;

/// One downloadable file of a GitHub release.
class ReleaseAsset {
  const ReleaseAsset(this.name, this.apiUrl, this.size);
  final String name;
  final String apiUrl; // https://api.github.com/repos/.../releases/assets/<id>
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.build,
    required this.tag,
    required this.package,
    this.sha256Asset,
    this.sigAsset,
    this.notes,
  });
  final int build;
  final String tag;
  final ReleaseAsset package;
  final ReleaseAsset? sha256Asset;

  /// `<package>.sig`: the Ed25519 signature of the release (base64), when the
  /// release has one.
  final ReleaseAsset? sigAsset;
  final String? notes;
}

sealed class UpdateStatus {
  const UpdateStatus();
}

class UpToDate extends UpdateStatus {
  const UpToDate(this.current, {this.tokenExpires});
  final int current;

  /// When the update token runs out (UTC), if GitHub said (SEC-4).
  final DateTime? tokenExpires;
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.current, this.info, {this.tokenExpires});
  final int current;
  final ReleaseInfo info;
  final DateTime? tokenExpires;
}

enum UpdateErrorKind {
  notConfigured,
  badToken,
  network,
  noRelease,
  noPackage,
  unsupported,
  other,
}

class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.kind, this.message);
  final UpdateErrorKind kind;
  final String message;
}

/// Which release asset belongs to this platform.
enum UpdatePlatform { windows, android, other }

UpdatePlatform currentUpdatePlatform() => Platform.isWindows
    ? UpdatePlatform.windows
    : (Platform.isAndroid ? UpdatePlatform.android : UpdatePlatform.other);

/// `build-123` -> 123
int? buildFromTag(String tag) {
  final m = RegExp(r'^build-(\d+)$').firstMatch(tag);
  return m == null ? null : int.parse(m[1]!);
}

/// When the update token runs out, as GitHub says in the
/// `github-authentication-token-expiration` header of an answer to a request
/// made with a token that expires (SEC-4). It looks like
/// "2026-12-05 10:00:00 UTC"; a few other writings are read as well (ISO 8601,
/// an offset such as -0500 or +01:00, a date alone). The result is in UTC, or
/// null when there is no such header or it is not understood.
DateTime? parseTokenExpiry(String? raw) {
  if (raw == null) return null;
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?'
    r'\s*(Z|UTC|GMT|[+-]\d{2}:?\d{2})?$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (m == null) return null;
  int part(int i) => int.parse(m[i] ?? '0');
  final y = part(1), mo = part(2), d = part(3);
  final h = part(4), mi = part(5), s = part(6);
  if (h > 23 || mi > 59 || s > 59) return null;
  // (DateTime rolls what does not exist - 31 February, month 13, day 0 - over
  // into another month: that is how it is told)
  if (DateTime.utc(y, mo, d).month != mo) return null;
  final t = DateTime.utc(y, mo, d, h, mi, s);
  final zone = m[7];
  if (zone == null || !(zone.startsWith('+') || zone.startsWith('-'))) return t;
  final digits = zone.substring(1).replaceAll(':', '');
  final oh = int.parse(digits.substring(0, 2));
  final om = int.parse(digits.substring(2));
  if (oh > 23 || om > 59) return null;
  final offset = Duration(hours: oh, minutes: om);
  // (10:00 at -0500 is 15:00 UTC)
  return zone.startsWith('+') ? t.subtract(offset) : t.add(offset);
}

/// What to tell the user when the update token runs out within [withinDays]
/// days of [now] (or has), or null (no expiry known, or still far off). After
/// it has run out an installed app finds no more updates, and only a new build
/// that is installed by hand (with a new token in it) brings it back - hence
/// the warning ahead of time.
String? tokenExpiryWarning(
  DateTime? expires,
  DateTime now, {
  int withinDays = 14,
}) {
  if (expires == null) return null;
  final left = expires.difference(now);
  if (left > Duration(days: withinDays)) return null;
  const help =
      'Új kulcs kell hozzá, és az appot utána egyszer kézzel kell újratelepíteni '
      '(leírás: docs/frissito-kulcs.md).';
  if (left.isNegative) {
    return 'A frissítő kulcs lejárt, ezért az app nem talál új verziót. $help';
  }
  final when = left.inDays < 1 ? 'egy napon belül' : '${left.inDays} nap múlva';
  return 'A frissítő kulcs $when lejár; utána az app nem talál új verziót. '
      '$help';
}

bool _isPackage(String name, UpdatePlatform pl) => switch (pl) {
  UpdatePlatform.windows => RegExp(r'^naptar-windows-\d+\.zip$').hasMatch(name),
  UpdatePlatform.android => RegExp(r'^naptar-android-\d+\.apk$').hasMatch(name),
  UpdatePlatform.other => false,
};

/// Whether [url] is the address of the API at [api] - the only place the token
/// goes: https, and the same host and port (not a look-alike host, not a
/// downgrade to plain http, not another port).
bool isUpdateApiUrl(Uri url, Uri api) =>
    api.scheme == 'https' &&
    url.scheme == 'https' &&
    url.host == api.host &&
    url.port == api.port;

class UpdateService {
  UpdateService({
    required this.client,
    required this.repo,
    required this.token,
    required this.platform,
    this.apiBase = 'https://api.github.com',
    this.publicKeys = const [],
    this.requireSignature = false,
    this.log,
    this.maxPackageBytes = maxUpdatePackageBytes,
  });

  final http.Client client;
  final String repo;
  final String token;
  final UpdatePlatform platform;
  final String apiBase;

  /// The public key(s) the releases are signed with (raw Ed25519 keys in
  /// base64; see update_signature.dart). None: no signature is checked.
  final List<String> publicKeys;

  /// Whether a release without a valid signature is refused. Off until the
  /// signing works for every release.
  final bool requireSignature;

  /// Where a download says what it checked (the update log).
  final void Function(String line)? log;

  /// The largest package taken (a parameter for the tests).
  final int maxPackageBytes;

  /// The packages this service has downloaded and verified, with the checksum
  /// they had then: [recheck] holds a file to it once more before it is
  /// installed.
  final _verified = <String, String>{};

  Map<String, String> get _auth => {
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  /// Compares the running [currentBuild] with the latest release. With
  /// [includePreviews] the newest published build counts, pre-releases (builds
  /// of work-in-progress branches) included; without it only the release
  /// GitHub marks as "latest" does.
  Future<UpdateStatus> check(
    int currentBuild, {
    bool includePreviews = false,
  }) async {
    if (token.isEmpty) {
      return const UpdateFailed(
        UpdateErrorKind.notConfigured,
        'Ebben a buildben nincs beállítva a frissítés, ezért itt nem lehet '
        'frissíteni. Telepítsd a legújabb csomagot a kiadások oldaláról.',
      );
    }
    if (platform == UpdatePlatform.other) {
      return const UpdateFailed(
        UpdateErrorKind.unsupported,
        'Ezen a rendszeren nincs önfrissítés.',
      );
    }
    final http.Response res;
    try {
      res = await client
          .get(
            Uri.parse(
              includePreviews
                  ? '$apiBase/repos/$repo/releases?per_page=20'
                  : '$apiBase/repos/$repo/releases/latest',
            ),
            headers: {..._auth, 'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 20));
    } on SocketException {
      return const UpdateFailed(
        UpdateErrorKind.network,
        'Nincs kapcsolat a GitHubbal.',
      );
    } on http.ClientException {
      return const UpdateFailed(
        UpdateErrorKind.network,
        'Nincs kapcsolat a GitHubbal.',
      );
    } on TimeoutException {
      return const UpdateFailed(
        UpdateErrorKind.network,
        'A kiszolgáló nem válaszolt időben.',
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      return const UpdateFailed(
        UpdateErrorKind.badToken,
        'A frissítés hozzáférési kulcsa érvénytelen vagy lejárt. Új kulcsot '
        'kell létrehozni a GitHubon, és új verziót építeni vele.',
      );
    }
    if (res.statusCode == 404) {
      return const UpdateFailed(
        UpdateErrorKind.noRelease,
        'Még nincs kiadott verzió (vagy a hozzáférési kulcs nem éri el a '
        'tárolót).',
      );
    }
    if (res.statusCode != 200) {
      return UpdateFailed(
        UpdateErrorKind.other,
        'Váratlan válasz a GitHubtól (${res.statusCode}).',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final Map<String, dynamic> json;
    if (includePreviews) {
      // the newest build among the published releases, pre-releases included
      Map<String, dynamic>? best;
      var bestBuild = -1;
      for (final r in decoded is List ? decoded : const []) {
        if (r is! Map<String, dynamic> || r['draft'] == true) continue;
        final b = buildFromTag('${r['tag_name']}');
        if (b != null && b > bestBuild) {
          best = r;
          bestBuild = b;
        }
      }
      if (best == null) {
        return const UpdateFailed(
          UpdateErrorKind.noRelease,
          'Még nincs kiadott verzió (vagy a hozzáférési kulcs nem éri el a '
          'tárolót).',
        );
      }
      json = best;
    } else {
      json = decoded as Map<String, dynamic>;
    }
    final build = buildFromTag('${json['tag_name']}');
    if (build == null) {
      return UpdateFailed(
        UpdateErrorKind.other,
        'Ismeretlen verziócímke: ${json['tag_name']}',
      );
    }
    // (only a token that expires makes GitHub send the header: its absence is
    // not an answer to anything, and says nothing)
    final expires = parseTokenExpiry(
      res.headers['github-authentication-token-expiration'],
    );
    if (build <= currentBuild) {
      return UpToDate(currentBuild, tokenExpires: expires);
    }

    final assets = [
      for (final a in (json['assets'] as List? ?? const []))
        ReleaseAsset(
          '${a['name']}',
          '${a['url']}',
          (a['size'] as num?)?.toInt() ?? 0,
        ),
    ];
    final pkg = assets.where((a) => _isPackage(a.name, platform)).firstOrNull;
    if (pkg == null) {
      return UpdateFailed(
        UpdateErrorKind.noPackage,
        'A(z) $build. verzióhoz nincs ${platform.name}-csomag a kiadásban.',
      );
    }
    final sha = assets.where((a) => a.name == '${pkg.name}.sha256').firstOrNull;
    final sig = assets.where((a) => a.name == '${pkg.name}.sig').firstOrNull;
    return UpdateAvailable(
      currentBuild,
      ReleaseInfo(
        build: build,
        tag: '${json['tag_name']}',
        package: pkg,
        sha256Asset: sha,
        sigAsset: sig,
        notes: json['body'] as String?,
      ),
      tokenExpires: expires,
    );
  }

  bool _isApi(Uri url) => isUpdateApiUrl(url, Uri.parse(apiBase));

  /// GET that follows redirects by hand so the token is NEVER forwarded to
  /// another host (GitHub redirects asset downloads to object storage), and
  /// nothing is fetched over a connection that is not encrypted.
  Future<http.StreamedResponse> _open(Uri url, {int hops = 0}) async {
    if (url.scheme != 'https') {
      throw const HttpException(
        'A letöltés titkosítatlan (https nélküli) címre mutat, ezért nem '
        'töltöm le.',
      );
    }
    final req = http.Request('GET', url)
      ..followRedirects = false
      ..headers.addAll(
        _isApi(url)
            ? {..._auth, 'Accept': 'application/octet-stream'}
            : {'Accept': 'application/octet-stream'},
      );
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode >= 300 &&
        res.statusCode < 400 &&
        res.headers['location'] != null) {
      await res.stream.drain<void>();
      if (hops >= 5) throw const HttpException('Túl sok átirányítás.');
      return _open(url.resolve(res.headers['location']!), hops: hops + 1);
    }
    return res;
  }

  /// Lets go of an answer without reading the rest of it (the connection is
  /// closed, not drained: the rest may be endless).
  Future<void> _discard(http.StreamedResponse res) =>
      res.stream.listen((_) {}).cancel();

  /// The text of a small release file (the checksum, the signature): `what`
  /// names it in the messages.
  Future<String> _fetchText(ReleaseAsset asset, String what) async {
    if (asset.size > maxUpdateTextBytes) {
      throw HttpException('$what túl nagy, ezért nem használom.');
    }
    final r = await _open(Uri.parse(asset.apiUrl));
    if (r.statusCode != 200) {
      await _discard(r);
      throw HttpException('$what nem tölthető le (${r.statusCode}).');
    }
    final bytes = <int>[];
    await for (final chunk in r.stream) {
      bytes.addAll(chunk);
      if (bytes.length > maxUpdateTextBytes) {
        throw HttpException('$what túl nagy, ezért nem használom.');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Downloads the package into [dir], verifies it and returns the file:
  /// - the size is what the release says it is (and never more than
  ///   [maxPackageBytes]);
  /// - the SHA-256 is the one in the release's checksum file;
  /// - when the app has a public key, the signature of the release (see
  ///   update_signature.dart): with a signature it must be valid, without one
  ///   the release is taken unless [requireSignature]; with no key built in
  ///   nothing is checked beyond the checksum.
  /// Whatever fails, nothing is left in [dir].
  Future<File> download(
    ReleaseInfo info,
    Directory dir, {
    void Function(double fraction)? onProgress,
  }) async {
    final keys = publicKeys;
    if (requireSignature && keys.isEmpty) {
      throw const HttpException(
        'A frissítés aláírása kötelező, de ebben a buildben nincs beépített '
        'kulcs, ezért nem telepítem.',
      );
    }
    final declared = info.package.size;
    if (declared > maxPackageBytes) {
      throw HttpException(
        'A csomag mérete ($declared bájt) a megengedettnél nagyobb, ezért nem '
        'töltöm le.',
      );
    }
    dir.createSync(recursive: true);
    String? expected;
    if (info.sha256Asset != null) {
      expected = (await _fetchText(
        info.sha256Asset!,
        'Az ellenőrző összeg',
      )).trim().split(RegExp(r'\s+')).first.toLowerCase();
    }
    // The signature comes before the big file: a release whose signature
    // cannot be had is no download at all.
    String? signature;
    if (keys.isNotEmpty && info.sigAsset != null) {
      signature = await _fetchText(info.sigAsset!, 'Az aláírás');
    }
    final res = await _open(Uri.parse(info.package.apiUrl));
    if (res.statusCode != 200) {
      await _discard(res);
      throw HttpException('A letöltés nem sikerült (${res.statusCode}).');
    }
    final length = res.contentLength;
    if (declared > 0 && length != null && length != declared) {
      await _discard(res);
      throw HttpException(
        'A kiszolgáló más méretet jelez ($length bájt), mint a kiadás '
        '($declared bájt), ezért nem töltöm le.',
      );
    }
    final file = File(p.join(dir.path, info.package.name));
    final sink = file.openWrite();
    // (what the release says it is; without that, the largest package taken)
    final limit = declared > 0 ? declared : maxPackageBytes;
    final total = length ?? declared;
    var got = 0;
    var tooMuch = false;
    final hash = AccumulatorSink<Digest>();
    final conv = sha256.startChunkedConversion(hash);
    try {
      try {
        await for (final chunk in res.stream) {
          got += chunk.length;
          if (got > limit) {
            tooMuch = true;
            break; // (leaving the loop lets go of the connection)
          }
          sink.add(chunk);
          conv.add(chunk);
          if (total > 0) onProgress?.call((got / total).clamp(0, 1));
        }
      } finally {
        await sink.close();
      }
    } catch (_) {
      _deleteQuietly(file); // (a half-downloaded package is no package)
      rethrow;
    }
    conv.close();
    if (tooMuch) {
      _deleteQuietly(file);
      throw const HttpException(
        'A letöltés nagyobb, mint amekkorának a kiadás mondja, ezért '
        'megszakítottam.',
      );
    }
    if (declared > 0 && got != declared) {
      _deleteQuietly(file);
      throw HttpException(
        'A letöltött méret ($got bájt) nem egyezik a kiadáséval ($declared '
        'bájt), a letöltés sérült. Próbáld újra.',
      );
    }
    final actual = hash.events.single.toString();
    if (expected != null && actual != expected) {
      _deleteQuietly(file);
      throw const HttpException(
        'Az ellenőrző összeg nem egyezik, a letöltés sérült. Próbáld újra.',
      );
    }
    if (expected == null) {
      _deleteQuietly(file);
      throw const HttpException(
        'A kiadáshoz nincs ellenőrző összeg, ezért nem telepítem.',
      );
    }
    final String verdict;
    if (keys.isEmpty) {
      verdict = 'no public key built in, checksum only';
    } else if (signature != null) {
      if (!verifyUpdateSignature(
        publicKeys: keys,
        build: info.build,
        sha256Hex: actual,
        signatureB64: signature,
      )) {
        _deleteQuietly(file);
        log?.call('signature of build ${info.build} is NOT valid: refused');
        throw const HttpException(
          'A kiadás aláírása nem érvényes, ezért nem telepítem.',
        );
      }
      verdict = 'signature valid';
    } else if (requireSignature) {
      _deleteQuietly(file);
      log?.call('build ${info.build} has no signature: refused');
      throw const HttpException(
        'A kiadáshoz nincs aláírás, ezért nem telepítem.',
      );
    } else {
      verdict = 'no signature, accepted (not required yet)';
    }
    log?.call('download of build ${info.build}: sha256 $actual, $verdict');
    _verified[file.path] = actual;
    return file;
  }

  /// Checks the file once more, right before it is installed: it must still be
  /// the one that was verified when it was downloaded (nothing has changed it
  /// in the meantime). A file this service did not download is refused.
  Future<void> recheck(File file) async {
    final want = _verified[file.path];
    if (want == null) {
      throw const HttpException(
        'A csomag ellenőrzése nem történt meg, ezért nem telepítem.',
      );
    }
    final String got;
    try {
      got = (await sha256.bind(file.openRead()).first).toString();
    } on FileSystemException {
      _verified.remove(file.path);
      throw const HttpException(
        'A letöltött csomag eltűnt, ezért nem telepítem. Próbáld újra.',
      );
    }
    if (got != want) {
      _verified.remove(file.path);
      _deleteQuietly(file);
      throw const HttpException(
        'A letöltött csomag időközben megváltozott, ezért nem telepítem. '
        'Próbáld újra.',
      );
    }
  }
}

void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// Deletes what an earlier update left in [root] (the downloaded package, the
/// unpacked copy): everything not touched for [olderThan]. The update log
/// stays. Returns how many entries were removed; never throws (no such folder:
/// nothing to remove).
int cleanupUpdateLeftovers(
  Directory root, {
  DateTime? now,
  Duration olderThan = const Duration(hours: 24),
}) {
  var n = 0;
  try {
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    for (final e in root.listSync(followLinks: false)) {
      if (p.basename(e.path) == 'update.log') continue;
      try {
        if (e.statSync().modified.isBefore(cutoff)) {
          e.deleteSync(recursive: true);
          n++;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return n;
}

// ------------------------------------------------------------------ Windows

/// Extracts [zip] into [dest] and returns the folder that holds the app files
/// (handles a zip with a single top-level folder). Rejects path traversal.
Directory extractUpdateZip(
  File zip,
  Directory dest, {
  String exeName = 'kvantum_app.exe',
  int maxEntries = maxUpdateEntries,
  int maxUnpackedBytes = maxUpdateUnpackedBytes,
}) {
  final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
  // A package that unpacks into something absurd is no update (SEC-15): the
  // sizes are the ones the zip itself declares, looked at before anything is
  // written.
  if (archive.length > maxEntries) {
    throw const FormatException('A csomag túl sok fájlt tartalmaz.');
  }
  var unpacked = 0;
  for (final f in archive) {
    unpacked += f.size;
    if (unpacked > maxUnpackedBytes) {
      throw const FormatException('A csomag kicsomagolva túl nagy lenne.');
    }
  }
  final root = p.canonicalize(dest.path);
  dest.createSync(recursive: true);
  for (final f in archive) {
    final out = p.canonicalize(p.join(dest.path, f.name));
    if (out != root && !p.isWithin(root, out)) {
      throw const FormatException('A csomag érvénytelen útvonalat tartalmaz.');
    }
    if (f.isFile) {
      File(out)
        ..createSync(recursive: true)
        ..writeAsBytesSync(f.content as List<int>);
    } else {
      Directory(out).createSync(recursive: true);
    }
  }
  if (File(p.join(dest.path, exeName)).existsSync()) return dest;
  final subs = dest.listSync().whereType<Directory>().toList();
  for (final d in subs) {
    if (File(p.join(d.path, exeName)).existsSync()) return d;
  }
  throw FormatException('A csomagban nincs $exeName.');
}

bool isDirWritable(Directory d) {
  try {
    final f = File(
      p.join(d.path, '.write-test-${DateTime.now().microsecondsSinceEpoch}'),
    );
    f.writeAsStringSync('x');
    f.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

class UpdateSwapException implements Exception {
  UpdateSwapException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SwapResult {
  const SwapResult({required this.replaced, required this.unchanged});
  final List<String> replaced; // relative paths
  final List<String> unchanged;
}

bool _sameContent(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) return false;
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

/// Replaces the installed files with the ones in [newRoot] while the app is
/// still running, without any helper script.
///
/// Windows lets a running exe/dll be RENAMED (but not overwritten or deleted),
/// so every old file is renamed to `<name>.old-<tag>` and the new one is copied
/// into its place. Files that did not change (e.g. icudtl.dat, which the engine
/// keeps open) are left alone. If anything fails, every step is undone, so the
/// installation is never left half-updated. [beforeStep] lets tests inject
/// failures; [log] receives a line per step.
SwapResult applyUpdateFiles({
  required Directory newRoot,
  required Directory installDir,
  required String tag,
  void Function(String step, String relPath)? beforeStep,
  void Function(String line)? log,
}) {
  final files = newRoot.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final replaced = <String>[];
  final unchanged = <String>[];
  final undo = <void Function()>[];
  try {
    for (final src in files) {
      final rel = p.relative(src.path, from: newRoot.path);
      final target = File(p.join(installDir.path, rel));
      if (target.existsSync() && _sameContent(target, src)) {
        unchanged.add(rel);
        continue;
      }
      target.parent.createSync(recursive: true);
      File? old;
      if (target.existsSync()) {
        old = File('${target.path}.old-$tag');
        if (old.existsSync()) {
          try {
            old.deleteSync(); // left over from an earlier attempt
          } on FileSystemException {
            old = File(
              '${target.path}.old-$tag-${DateTime.now().microsecondsSinceEpoch}',
            );
          }
        }
        beforeStep?.call('rename', rel);
        log?.call('rename $rel');
        target.renameSync(old.path);
      }
      final oldFile = old;
      undo.add(() {
        try {
          if (target.existsSync()) target.deleteSync();
          if (oldFile != null && oldFile.existsSync()) {
            oldFile.renameSync(target.path);
          }
        } catch (_) {}
      });
      beforeStep?.call('copy', rel);
      log?.call('copy $rel');
      src.copySync(target.path);
      replaced.add(rel);
    }
  } catch (e) {
    for (final u in undo.reversed) {
      u();
    }
    log?.call('FAILED, rolled back: $e');
    throw UpdateSwapException(
      'A csere nem sikerült, a régi verzió érintetlen maradt: '
      '${errorInfoFor(e).text}',
    );
  }
  return SwapResult(replaced: replaced, unchanged: unchanged);
}

/// Deletes the `*.old-*` files an update leaves behind (locked ones are kept
/// until the next start). Returns how many were removed.
int cleanupOldFiles(Directory installDir) {
  var n = 0;
  try {
    for (final f in installDir.listSync(recursive: true).whereType<File>()) {
      if (RegExp(r'\.old-[^\\/]*$').hasMatch(f.path)) {
        try {
          f.deleteSync();
          n++;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return n;
}

/// Starts the new version as an independent process; the caller then exits.
Future<void> launchNewApp(File exe) => Process.start(
  exe.path,
  const [],
  workingDirectory: exe.parent.path,
  mode: ProcessStartMode.detached,
);

/// Best-effort update log (shown to the user when something fails).
String get updateLogPath =>
    p.join(Directory.systemTemp.path, 'naptar-update', 'update.log');

void logUpdate(String line) {
  try {
    final f = File(updateLogPath)..parent.createSync(recursive: true);
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}
