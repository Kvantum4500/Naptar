import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:path_provider/path_provider.dart';

import 'data/db.dart';
import 'data/startup.dart';
import 'providers.dart' show dbProvider;
import 'ui/root_shell.dart';
import 'ui/startup_problem.dart';
import 'update/update_service.dart' show cleanupOldFiles;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  if (start.problem != null) {
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
