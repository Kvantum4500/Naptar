import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../data/db_open.dart';
import '../sync/error_catalog.dart';

/// Shown instead of the app when the database must not be opened: an
/// explanation instead of a blank screen, and nothing is touched.
class StartupProblemApp extends StatelessWidget {
  const StartupProblemApp({super.key, required this.problem});
  final Object problem;

  String get _message => switch (problem) {
    final NewerDatabaseError e => e.message,
    final UnreadableDatabaseError e => e.message,
    _ => 'Az adatbázist nem sikerült megnyitni. ${errorInfoFor(problem).text}',
  };

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kvantum Naptár',
    debugShowCheckedModeBanner: false,
    locale: const Locale('hu'),
    supportedLocales: const [Locale('hu')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.storage_outlined, size: 40),
                const SizedBox(height: 16),
                Text(
                  'Az adatbázis nem nyitható meg',
                  key: const Key('startup-title'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                SelectableText(_message, key: const Key('startup-message')),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('startup-close'),
                  onPressed: () => exit(0),
                  child: const Text('Bezárás'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
