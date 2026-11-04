import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_config.dart';
import 'update_service.dart';

/// Build number of the running app (the CI passes --build-number).
final currentBuildProvider = FutureProvider<int>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber) ?? 0;
});

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(
    client: http.Client(),
    repo: UpdateConfig.repo,
    token: UpdateConfig.token,
    platform: currentUpdatePlatform(),
  ),
);

/// Installs a downloaded package. Replaceable in tests.
abstract class UpdateInstaller {
  /// Returns a message to show when the app does not exit by itself.
  Future<String?> install(File package, ReleaseInfo info);
}

class PlatformUpdateInstaller implements UpdateInstaller {
  @override
  Future<String?> install(File package, ReleaseInfo info) async {
    if (Platform.isWindows) {
      final installDir = File(Platform.resolvedExecutable).parent;
      final exeName = p.basename(Platform.resolvedExecutable);
      if (!isDirWritable(installDir)) {
        return 'A program mappája nincs írható helyen (${installDir.path}). '
            'Másold a programot egy saját mappába (pl. Dokumentumok), és onnan indítsd.';
      }
      final work = Directory(
        p.join(Directory.systemTemp.path, 'naptar-update', 'new-${info.build}'),
      );
      if (work.existsSync()) work.deleteSync(recursive: true);
      final root = extractUpdateZip(package, work, exeName: exeName);
      logUpdate('update to ${info.build}: ${root.path} -> ${installDir.path}');
      try {
        final r = applyUpdateFiles(
          newRoot: root,
          installDir: installDir,
          tag: 'b${info.build}',
          log: logUpdate,
        );
        logUpdate(
          'swap ok: replaced ${r.replaced.length}, unchanged ${r.unchanged.length}',
        );
      } on UpdateSwapException catch (e) {
        return '${e.message}\nNapló: $updateLogPath';
      }
      try {
        await launchNewApp(File(p.join(installDir.path, exeName)));
      } catch (e) {
        logUpdate('launch failed: $e');
        return 'A frissítés telepítve, de az új verzió nem indult el ($e). Indítsd el kézzel a programot.';
      }
      exit(0);
    }
    if (Platform.isAndroid) {
      final r = await OpenFilex.open(
        package.path,
        type: 'application/vnd.android.package-archive',
      );
      if (r.type != ResultType.done) {
        return 'A telepítő nem nyílt meg (${r.message}). Engedélyezd az „ismeretlen forrásból telepítést” '
            'ennél az alkalmazásnál, és próbáld újra.';
      }
      return 'Hagyd jóvá a telepítést a megnyíló ablakban.';
    }
    return 'Ezen a rendszeren nincs önfrissítés.';
  }
}

final updateInstallerProvider = Provider<UpdateInstaller>(
  (ref) => PlatformUpdateInstaller(),
);

Future<Directory> _downloadDir() async {
  if (Platform.isAndroid) {
    return Directory(
      p.join((await getTemporaryDirectory()).path, 'naptar-update'),
    );
  }
  return Directory(p.join(Directory.systemTemp.path, 'naptar-update', 'dl'));
}

Future<void> showUpdateDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const UpdateDialog(),
    );

class UpdateDialog extends ConsumerStatefulWidget {
  const UpdateDialog({super.key});
  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  UpdateStatus? _status;
  bool _busy = false;
  double? _progress;
  String? _message;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    setState(() {
      _status = null;
      _message = null;
    });
    _current = await ref.read(currentBuildProvider.future);
    final s = await ref.read(updateServiceProvider).check(_current);
    if (mounted) setState(() => _status = s);
  }

  Future<void> _install(UpdateAvailable a) async {
    setState(() {
      _busy = true;
      _progress = 0;
      _message = null;
    });
    try {
      final svc = ref.read(updateServiceProvider);
      final file = await svc.download(
        a.info,
        await _downloadDir(),
        onProgress: (f) {
          if (mounted) setState(() => _progress = f);
        },
      );
      if (mounted) setState(() => _progress = null);
      final msg = await ref.read(updateInstallerProvider).install(file, a.info);
      if (mounted) setState(() => _message = msg);
    } on HttpException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _message = 'A csomag nem használható: ${e.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'A frissítés nem sikerült: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final Widget content;
    List<Widget> actions = [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Bezár'),
      ),
    ];

    if (s == null) {
      content = const Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 14),
          Text('Frissítés keresése…'),
        ],
      );
    } else {
      switch (s) {
        case UpToDate():
          content = Text('Naprakész vagy. (Telepített verzió: $_current)');
          actions = [
            TextButton(onPressed: _check, child: const Text('Újra ellenőriz')),
            ...actions,
          ];
        case UpdateAvailable():
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Új verzió érhető el: ${s.info.build} (telepítve: ${s.current}).',
              ),
              if (s.info.notes != null && s.info.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  s.info.notes!.trim(),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                ),
                const SizedBox(height: 4),
                Text('Letöltés… ${((_progress ?? 0) * 100).round()}%'),
              ],
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(_message!),
              ],
              if (Platform.isWindows) ...[
                const SizedBox(height: 10),
                const Text(
                  'A frissítés után a program magától újraindul.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          );
          actions = [
            FilledButton(
              onPressed: _busy ? null : () => _install(s),
              child: const Text('Frissítés most'),
            ),
            ...actions,
          ];
        case UpdateFailed():
          content = Text(s.message);
          if (s.kind == UpdateErrorKind.network ||
              s.kind == UpdateErrorKind.other) {
            actions = [
              TextButton(onPressed: _check, child: const Text('Újrapróbál')),
              ...actions,
            ];
          }
      }
    }
    return AlertDialog(
      title: const Text('Frissítés'),
      content: SizedBox(width: 420, child: content),
      actions: actions,
    );
  }
}
