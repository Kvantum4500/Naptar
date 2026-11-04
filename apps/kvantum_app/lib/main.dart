import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'ui/home_page.dart';
import 'update/update_service.dart' show cleanupOldFiles;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureTimeZones();
  if (Platform.isWindows) {
    // files an earlier self-update renamed out of the way
    cleanupOldFiles(File(Platform.resolvedExecutable).parent);
  }
  await initializeDateFormatting('hu');
  runApp(const ProviderScope(child: KvantumApp()));
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
    home: const HomePage(),
  );
}
