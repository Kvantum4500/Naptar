import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No test waits for the clock.
///
/// A test that sleeps (`Future.delayed(50 ms)`, `sleep`, a real `Timer`) or
/// measures how long something took passes on a quick machine and fails on a
/// slow one, and the time it takes is the sum of its sleeps. Everything that
/// has to be waited for here happens in turns of the event loop (database
/// streams, futures, zero-length timers): the tests wait for THE THING
/// (`turnUntil`, `pumpUntil`, `pumpEventQueue` in `support/turns.dart`), or
/// they run on a clock they drive themselves (`ManualTimers`, `FakeAsync`, an
/// injected `pause` / clock). This scans every test of the app and of the
/// core, and fails on a real wait that is not in [allowed] with its reason.
///
/// A new exception is a decision: it is written here, with why there is no
/// way to wait for the thing itself. The list stays short on purpose.
void main() {
  /// File (relative to its `test/` folder) → what the scan finds there and
  /// why that is not a wait for time.
  const allowed = <String, String>{
    // The bound after which a thing that never happens is reported as a
    // failure: the test itself ends when the thing has happened, and a slow
    // machine only makes it take longer, never fail sooner.
    'support/turns.dart': 'Stopwatch',
  };

  const maxAllowed = 5;

  // what counts as waiting for real time
  final patterns = <String, RegExp>{
    'Future.delayed': RegExp(r'\.delayed\('),
    'sleep': RegExp(r'(?<![A-Za-z0-9_.])sleep\('),
    'Timer': RegExp(r'(?<![A-Za-z0-9_])Timer(\.periodic)?\('),
    'Stopwatch': RegExp(r'(?<![A-Za-z0-9_])Stopwatch\b'),
  };

  final roots = <String, Directory>{
    'app': Directory('test'),
    'core': Directory('../../packages/kvantum_core/test'),
  };

  /// [text] without its comments (a `//` after a `:` is a URL, not a comment).
  String withoutComments(String text) => text
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'(?<!:)//[^\n]*'), '');

  /// The text of the first argument of the call that opens at [open] (the
  /// index of its `(`).
  String firstArgument(String text, int open) {
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) return text.substring(open + 1, i).trim();
      }
      if (c == ',' && depth == 1) return text.substring(open + 1, i).trim();
    }
    return text.substring(open + 1).trim();
  }

  /// "kind: file:line" of every real wait in [files], unless it is allowed
  /// ([allow], by default [allowed]). [skip] is a file that is not scanned
  /// (this one: it names what it looks for).
  List<String> scan(
    Directory root, {
    String skip = 'no_real_waits_test.dart',
    Map<String, String>? allow,
  }) {
    final lets = allow ?? allowed;
    final found = <String>[];
    for (final f in root.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final rel = f.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (rel == skip) continue;
      final text = withoutComments(f.readAsStringSync());
      for (final e in patterns.entries) {
        for (final m in e.value.allMatches(text)) {
          if (e.key == 'Future.delayed') {
            // a zero delay is a turn of the event loop, not a wait
            final open = text.indexOf('(', m.start);
            final arg = firstArgument(text, open).replaceAll('const ', '');
            if (arg == 'Duration.zero' || arg == 'Duration()') continue;
          }
          if (lets[rel] == e.key) continue;
          final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
          found.add('${e.key}: $rel (≈ line $line)');
        }
      }
    }
    return found;
  }

  for (final r in roots.entries) {
    test('the ${r.key} tests wait for things, not for time', () {
      expect(
        r.value.existsSync(),
        isTrue,
        reason:
            'the ${r.key} tests were not found from ${Directory.current.path}: '
            'run the tests from the package, as CI does',
      );
      expect(
        scan(r.value),
        isEmpty,
        reason:
            'a real wait (or a timer, or a stopwatch) in a test: wait for the '
            'thing itself (turnUntil / pumpUntil), or drive a clock of its own',
      );
    });
  }

  test('the exceptions are few, and every one is still needed', () {
    expect(allowed.length, lessThanOrEqualTo(maxAllowed));
    for (final e in allowed.entries) {
      final f = File('${roots['app']!.path}/${e.key}');
      final alt = File('${roots['core']!.path}/${e.key}');
      final file = f.existsSync() ? f : alt;
      expect(file.existsSync(), isTrue, reason: '${e.key} is gone: remove it');
      expect(
        patterns[e.value]!.hasMatch(withoutComments(file.readAsStringSync())),
        isTrue,
        reason: '${e.key} no longer has a ${e.value}: remove the exception',
      );
    }
  });

  group('the scan itself', () {
    test('sees what it is meant to see', () {
      final dir = Directory.systemTemp.createTempSync('no_waits_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/a.dart').writeAsStringSync('''
Future<void> a() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await Future.delayed(
    Duration(seconds: 1),
  );
  sleep(const Duration(seconds: 1));
  Timer(const Duration(seconds: 1), () {});
  Timer.periodic(const Duration(seconds: 1), (_) {});
  final w = Stopwatch()..start();
}
''');
      File('${dir.path}/b.dart').writeAsStringSync('''
// Future.delayed(const Duration(seconds: 1)); only said in a comment
/* Stopwatch in a block comment */
Future<void> b() async {
  await Future<void>.delayed(Duration.zero);
  await Future.delayed(const Duration());
  final url = 'https://example.com/x'; final t = _Timer(); ft.sleepy(1);
  final s = '//';
  await Future.delayed(const Duration(milliseconds: 5)); // a real one
}
''');
      // an exception is for ONE kind of wait in ONE file
      final lenient = scan(dir, allow: const {'a.dart': 'Stopwatch'});
      expect(lenient.where((s) => s.contains(': a.dart')), hasLength(5));
      expect(lenient.where((s) => s.startsWith('Stopwatch:')), isEmpty);
      final found = scan(dir);
      // a.dart: two delays, a sleep, two timers, a stopwatch
      expect(found.where((s) => s.contains(': a.dart')), hasLength(6));
      // b.dart: only the delay of 5 ms (zero delays, comments, `_Timer`, `sleepy`)
      expect(found.where((s) => s.contains(': b.dart')), hasLength(1));
      expect(
        found.singleWhere((s) => s.contains(': b.dart')),
        contains('line 8'),
      );
    });
  });

  // The controller pauses 200 ms of the CLOCK between two uploads. A test that
  // drives a sync run and does not set that pause to zero waits for turns of
  // the event loop while the engine waits for time: on a quick machine the
  // turns are used up first and the test fails (the CI found one: it passed
  // for weeks on a slow machine).
  test(
    'a test that drives a sync run sets the pause between uploads to zero',
    () {
      final drives = RegExp(r'\.(signIn|syncNow)\(');
      final missing = <String>[
        for (final f in Directory('test').listSync().whereType<File>())
          if (f.path.endsWith('_test.dart') &&
              drives.hasMatch(withoutComments(f.readAsStringSync())) &&
              !f.readAsStringSync().contains('syncPaceProvider'))
            f.path,
      ];
      expect(
        missing,
        isEmpty,
        reason: 'add syncPaceProvider.overrideWithValue(Duration.zero) to these tests',
      );
    },
  );
}
