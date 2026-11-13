import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup/backup_key_store.dart';
import 'backup/backup_providers.dart';
import 'backup/backup_store.dart';
import 'data/db.dart';
import 'data/startup.dart';
import 'diag/diag_log.dart';
import 'diag/guarded.dart';
import 'notify/windows_autostart.dart';
import 'providers.dart' show dbPathProvider, dbProvider;
import 'ui/root_shell.dart';
import 'ui/setup_guide.dart' show setupGuideProvider;
import 'ui/startup_problem.dart';
import 'ui/theme.dart';
import 'update/update_service.dart'
    show cleanupOldFiles, cleanupUpdateLeftovers;

void main() {
  // The log and the error hooks exist before anything else can fail. The log
  // keeps what it gets in memory until the app knows where its data lives.
  final log = DiagLog();
  runGuarded(() => _start(log), log);
}

Future<void> _start(DiagLog log) async {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHooks(log);
  ensureTimeZones();
  if (Platform.isWindows) {
    // files an earlier self-update renamed out of the way
    cleanupOldFiles(File(Platform.resolvedExecutable).parent);
  }
  // the package and the unpacked copy an earlier self-update left behind
  unawaited(_cleanUpdateLeftovers());
  await initializeDateFormatting('hu');
  // Where the database is, whether this build may open it (a newer build's
  // database is left alone), and on Windows the move out of Documents.
  final start = await prepareStartup(
    windows: Platform.isWindows,
    documentsDir: (await getApplicationDocumentsDirectory()).path,
    localAppData: Platform.environment['LOCALAPPDATA'],
  );
  // The log lives next to the database: the same private folder, the same
  // owner, and it goes nowhere on its own.
  log.attach(FileDiagSink(p.join(p.dirname(start.path), 'diag')));
  log.info(
    'app',
    'start',
    data: {
      'os': Platform.operatingSystem,
      'schema': AppDatabase.currentSchemaVersion,
    },
  );
  if (Platform.isWindows) {
    // a startup entry the user switched on follows the program where it is now
    unawaited(_repairAutostart(log));
  }
  final move = start.move;
  if (move != null && (move.moved || move.cleaned || move.problem != null)) {
    log.info(
      'app',
      'db.move',
      data: {
        'moved': move.moved,
        'cleaned': move.cleaned,
        if (move.problem != null) 'why': move.problem,
      },
    );
  }
  if (start.problem != null) {
    log.error('app', 'startup.problem', start.problem!);
    runApp(StartupProblemApp(problem: start.problem!));
    return;
  }
  runApp(
    ProviderScope(
      overrides: [
        dbProvider.overrideWith((ref) {
          final db = AppDatabase.openAt(start.path);
          ref.onDispose(db.close);
          return db;
        }),
        dbPathProvider.overrideWithValue(start.path),
        diagLogProvider.overrideWithValue(log),
        // the daily backup, in a folder next to the database
        backupStoreProvider.overrideWithValue(
          FileBackupStore(Directory(p.join(p.dirname(start.path), 'backups'))),
        ),
        autoBackupRunsProvider.overrideWithValue(true),
        backupKeyStoreProvider.overrideWithValue(SecureBackupKeyStore()),
        // the first-run guide above the calendar (off in tests)
        setupGuideProvider.overrideWithValue(true),
      ],
      child: const KvantumApp(),
    ),
  );
}

/// Clears what an earlier self-update left in the temp folder (SEC-15). It is
/// never in the way of the start: whatever goes wrong here is left alone.
Future<void> _cleanUpdateLeftovers() async {
  try {
    final tmp = Platform.isAndroid
        ? (await getTemporaryDirectory()).path
        : Directory.systemTemp.path;
    cleanupUpdateLeftovers(Directory(p.join(tmp, 'naptar-update')));
  } catch (_) {}
}

Future<void> _repairAutostart(DiagLog log) async {
  try {
    if (await WindowsAutostart.forThisProgram().repair()) {
      log.info('autostart', 'repaired');
    }
  } catch (e, st) {
    log.error('autostart', 'repair.failed', e, st);
  }
}

class KvantumApp extends ConsumerWidget {
  const KvantumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Kvantum Naptár',
    debugShowCheckedModeBanner: false,
    locale: const Locale('hu'),
    supportedLocales: const [Locale('hu')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: appTheme(Brightness.light),
    darkTheme: appTheme(Brightness.dark),
    // light, dark or the system's: the choice is in Settings
    themeMode: ref.watch(themeModeProvider),
    home: const RootShell(),
  );
}
