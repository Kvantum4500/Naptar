import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../sync/error_catalog.dart';

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
    this.notes,
  });
  final int build;
  final String tag;
  final ReleaseAsset package;
  final ReleaseAsset? sha256Asset;
  final String? notes;
}

sealed class UpdateStatus {
  const UpdateStatus();
}

class UpToDate extends UpdateStatus {
  const UpToDate(this.current);
  final int current;
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.current, this.info);
  final int current;
  final ReleaseInfo info;
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

bool _isPackage(String name, UpdatePlatform pl) => switch (pl) {
  UpdatePlatform.windows => RegExp(r'^naptar-windows-\d+\.zip$').hasMatch(name),
  UpdatePlatform.android => RegExp(r'^naptar-android-\d+\.apk$').hasMatch(name),
  UpdatePlatform.other => false,
};

class UpdateService {
  UpdateService({
    required this.client,
    required this.repo,
    required this.token,
    required this.platform,
    this.apiBase = 'https://api.github.com',
  });

  final http.Client client;
  final String repo;
  final String token;
  final UpdatePlatform platform;
  final String apiBase;

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
    if (build <= currentBuild) return UpToDate(currentBuild);

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
    return UpdateAvailable(
      currentBuild,
      ReleaseInfo(
        build: build,
        tag: '${json['tag_name']}',
        package: pkg,
        sha256Asset: sha,
        notes: json['body'] as String?,
      ),
    );
  }

  /// GET that follows redirects by hand so the token is NEVER forwarded to
  /// another host (GitHub redirects asset downloads to object storage).
  Future<http.StreamedResponse> _open(Uri url, {int hops = 0}) async {
    final req = http.Request('GET', url)
      ..followRedirects = false
      ..headers.addAll(
        url.host == Uri.parse(apiBase).host
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

  /// Downloads the package into [dir], verifies SHA-256 and returns the file.
  Future<File> download(
    ReleaseInfo info,
    Directory dir, {
    void Function(double fraction)? onProgress,
  }) async {
    dir.createSync(recursive: true);
    String? expected;
    if (info.sha256Asset != null) {
      final r = await _open(Uri.parse(info.sha256Asset!.apiUrl));
      if (r.statusCode != 200) {
        throw HttpException(
          'Az ellenőrző összeg nem tölthető le (${r.statusCode}).',
        );
      }
      expected = (await utf8.decoder.bind(r.stream).join())
          .trim()
          .split(RegExp(r'\s+'))
          .first
          .toLowerCase();
    }
    final res = await _open(Uri.parse(info.package.apiUrl));
    if (res.statusCode != 200) {
      throw HttpException('A letöltés nem sikerült (${res.statusCode}).');
    }
    final file = File(p.join(dir.path, info.package.name));
    final sink = file.openWrite();
    final total = res.contentLength ?? info.package.size;
    var got = 0;
    final hash = AccumulatorSink<Digest>();
    final conv = sha256.startChunkedConversion(hash);
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        conv.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call((got / total).clamp(0, 1));
      }
    } finally {
      await sink.close();
    }
    conv.close();
    final actual = hash.events.single.toString();
    if (expected != null && actual != expected) {
      file.deleteSync();
      throw const HttpException(
        'Az ellenőrző összeg nem egyezik, a letöltés sérült. Próbáld újra.',
      );
    }
    if (expected == null) {
      file.deleteSync();
      throw const HttpException(
        'A kiadáshoz nincs ellenőrző összeg, ezért nem telepítem.',
      );
    }
    return file;
  }
}

// ------------------------------------------------------------------ Windows

/// Extracts [zip] into [dest] and returns the folder that holds the app files
/// (handles a zip with a single top-level folder). Rejects path traversal.
Directory extractUpdateZip(
  File zip,
  Directory dest, {
  String exeName = 'kvantum_app.exe',
}) {
  final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
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
