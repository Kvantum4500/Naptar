import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/db.dart';
import 'data/startup.dart';
import 'diag/diag_log.dart';
import 'diag/guarded.dart';
import 'providers.dart' show dbPathProvider, dbProvider;
import 'ui/root_shell.dart';
import 'ui/startup_problem.dart';
import 'update/update_service.dart' show cleanupOldFiles;

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
      ],
      child: const KvantumApp(),
    ),
  );
}

class KvantumApp extends StatelessWidget {
  const KvantumApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kvantum Naptár',
    debugShowCheckedModeBanner: false,
    locale: const Locale('hu'),
    supportedLocales: const [Locale('hu')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const RootShell(),
  );
}
