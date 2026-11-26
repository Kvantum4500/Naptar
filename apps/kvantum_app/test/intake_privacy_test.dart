import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/synced_settings.dart';
import 'package:kvantum_core/kvantum_core.dart' show settingsGoalsId;

/// The food and fluid log stays out of the assistant's reach (8th round): what
/// was eaten and drunk is not sent to a model, and nothing that talks to one
/// knows where it is kept. A structural guard, as for the pay settings:
/// whatever can read the log could send it somewhere.
void main() {
  List<File> dartFiles(String dir) => [
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f,
  ];

  String norm(File f) => f.path.replaceAll('\\', '/');

  const words = [
    'intake',
    'FoodEntry',
    'FluidEntry',
    'DayTotals',
    'IntakeGoals',
    'IntakeLog',
  ];

  test('no file of the assistant knows of the log', () {
    final found = <String>[];
    for (final f in dartFiles('lib/ai')) {
      final text = f.readAsStringSync();
      for (final w in words) {
        if (text.toLowerCase().contains(w.toLowerCase())) {
          found.add('${norm(f)}: $w');
        }
      }
    }
    expect(found, isEmpty);
  });

  test('nor does the part of the core that builds what a model is told', () {
    final dir = Directory('../../packages/kvantum_core/lib/src');
    final found = <String>[];
    for (final f in dartFiles(dir.path)) {
      final name = norm(f).split('/').last;
      // (the log itself, and the list of the kinds that are synced)
      if (name == 'intake.dart' || name == 'models.dart') continue;
      final text = f.readAsStringSync();
      for (final w in words) {
        if (text.contains(w) || text.contains('kindIntake')) {
          found.add('$name: $w');
        }
      }
    }
    expect(found, isEmpty);
  });

  test('only the settings store and the providers of the log know where '
      'the goals are kept', () {
    final users = <String>[];
    for (final f in dartFiles('lib')) {
      final text = f.readAsStringSync();
      if (text.contains('settingsGoalsId') ||
          text.contains('legacyIntakeGoalsKey') ||
          text.contains('intake.goals') ||
          text.contains('watchIntakeGoals') ||
          text.contains('saveIntakeGoals')) {
        users.add(norm(f));
      }
    }
    expect(users..sort(), [
      'lib/data/synced_settings.dart',
      'lib/intake/intake_providers.dart',
    ]);
  });

  test(
    'the goals are a synced setting of their own, with the old key known',
    () {
      expect(settingsGoalsId, 'goals');
      expect(legacyIntakeGoalsKey, 'intake.goals');
    },
  );
}
