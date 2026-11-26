// Runs the tests of the app and of the core with coverage on, and says how much
// of the code they ran. Dart, not a shell script: it runs on Windows too.
//
//   dart tool/coverage.dart                       both packages, the report
//   dart tool/coverage.dart --only core --top 5   one package
//   dart tool/coverage.dart --min-app 60 --min-core 85   exit code 1 below that
//
// The counting is in lcov.dart (and tested); this file only starts the
// processes and reads their files. Generated code (the drift database) is left
// out of the numbers.
import 'dart:io';

import 'lcov.dart';

Future<int> main(List<String> args) async {
  final CoverageOptions options;
  try {
    options = parseOptions(args);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(coverageUsage);
    return 64;
  }
  if (options.help) {
    stdout.writeln(coverageUsage);
    return 0;
  }

  final root = File.fromUri(Platform.script).parent.parent;
  final problems = <String>[];

  if (options.app) {
    final dir = Directory('${root.path}/apps/kvantum_app');
    stdout.writeln('== app: flutter test --coverage');
    final code = await _run('flutter', ['test', '--coverage'], dir);
    if (code != 0) return _failed('az app tesztjei', code);
    final p = _report(
      'app',
      File('${dir.path}/coverage/lcov.info'),
      options.top,
    );
    final low = belowMinimum('app', p, options.minApp);
    if (low != null) problems.add(low);
  }

  if (options.core) {
    final dir = Directory('${root.path}/packages/kvantum_core');
    stdout.writeln('== mag: dart test --coverage');
    var code = await _run('dart', ['test', '--coverage=coverage/raw'], dir);
    if (code != 0) return _failed('a mag tesztjei', code);
    code = await _run('dart', [
      'run',
      'coverage:format_coverage',
      '--lcov',
      '--in=coverage/raw',
      '--out=coverage/lcov.info',
      '--report-on=lib',
      '--packages=.dart_tool/package_config.json',
    ], dir);
    if (code != 0) return _failed('a lefedettség átalakítása', code);
    final p = _report(
      'mag',
      File('${dir.path}/coverage/lcov.info'),
      options.top,
    );
    final low = belowMinimum('mag', p, options.minCore);
    if (low != null) problems.add(low);
  }

  for (final p in problems) {
    stderr.writeln(p);
  }
  return problems.isEmpty ? 0 : 1;
}

/// Prints the report of [lcov]; the total percentage.
double _report(String name, File lcov, int top) {
  final files = counted(parseLcov(lcov.readAsStringSync()));
  stdout
    ..writeln()
    ..writeln(reportLines(name, files, top: top).join('\n'))
    ..writeln();
  return totalsOf(files).percent;
}

Future<int> _run(String exe, List<String> args, Directory dir) async {
  final process = await Process.start(
    exe,
    args,
    workingDirectory: dir.path,
    mode: ProcessStartMode.inheritStdio,
    // (on Windows `flutter` and `dart` are batch files)
    runInShell: Platform.isWindows,
  );
  return process.exitCode;
}

int _failed(String what, int code) {
  stderr.writeln('$what nem futottak le rendben (kilépési kód $code)');
  return code;
}
