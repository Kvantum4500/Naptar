import 'package:test/test.dart';

// The counting of tool/coverage.dart (the repository's coverage tool) lives in
// tool/lcov.dart and has no I/O, so it is tested here, where the CI runs.
import '../../../tool/lcov.dart';

void main() {
  group('reading an lcov file', () {
    test('a file: its lines and how many times each ran', () {
      final files = parseLcov('''
SF:lib/a.dart
DA:1,3
DA:2,0
DA:5,1
end_of_record
''');
      expect(files, hasLength(1));
      expect(files.single.path, 'lib/a.dart');
      expect(files.single.hits, {1: 3, 2: 0, 5: 1});
      expect(files.single.found, 3);
      expect(files.single.covered, 2);
      expect(files.single.missed, 1);
    });

    test('several files, in the order they are written', () {
      final files = parseLcov('''
SF:lib/b.dart
DA:1,1
end_of_record
SF:lib/a.dart
DA:1,0
end_of_record
''');
      expect([for (final f in files) f.path], ['lib/b.dart', 'lib/a.dart']);
    });

    test('a file in it twice has its hits added up, line by line', () {
      final files = parseLcov('''
SF:lib/a.dart
DA:1,0
DA:2,2
end_of_record
SF:lib/a.dart
DA:1,4
DA:3,0
end_of_record
''');
      expect(files, hasLength(1));
      expect(files.single.hits, {1: 4, 2: 2, 3: 0});
    });

    test('a checksum after the count, CRLF line ends and backslash paths', () {
      final files = parseLcov(
        'SF:C:\\work\\lib\\a.dart\r\nDA:1,2,abc123\r\nend_of_record\r\n',
      );
      expect(files.single.path, 'C:/work/lib/a.dart');
      expect(files.single.hits, {1: 2});
    });

    test('what is not a line of a file is left alone', () {
      final files = parseLcov('''
TN:
DA:1,1
SF:lib/a.dart
FN:3,main
DA:x,1
DA:2,y
DA:7
DA:4,1
LF:1
LH:1
end_of_record
DA:9,9
''');
      // (a DA line before any SF, and after end_of_record, belongs to no file)
      expect(files.single.hits, {4: 1});
    });

    test('nothing in it: no files', () {
      expect(parseLcov(''), isEmpty);
    });
  });

  group('what a file says', () {
    test('the percentage is the lines that ran of the lines that could', () {
      expect(const FileCoverage('lib/a.dart', {1: 1, 2: 0}).percent, 50);
      expect(const FileCoverage('lib/a.dart', {1: 5, 2: 1}).percent, 100);
      expect(const FileCoverage('lib/a.dart', {1: 0}).percent, 0);
    });

    test('a file with nothing that could run is fully covered', () {
      expect(const FileCoverage('lib/a.dart', {}).percent, 100);
      expect(const FileCoverage('lib/a.dart', {}).missed, 0);
    });
  });

  group('which files count', () {
    test('the path from its lib/ folder on', () {
      expect(libRelative('lib/src/a.dart'), 'lib/src/a.dart');
      expect(libRelative('/x/y/lib/src/a.dart'), 'lib/src/a.dart');
      expect(libRelative(r'C:\x\lib\a.dart'), 'lib/a.dart');
      expect(libRelative('/x/mylib/a.dart'), '/x/mylib/a.dart');
      expect(libRelative('test/a_test.dart'), 'test/a_test.dart');
    });

    test('generated code is not code anybody wrote', () {
      expect(isGenerated('lib/data/db.g.dart'), isTrue);
      expect(isGenerated('lib/a.freezed.dart'), isTrue);
      expect(isGenerated('lib/generated/a.dart'), isTrue);
      expect(isGenerated('lib/data/db.dart'), isFalse);
      expect(isGenerated('lib/gdb.dart'), isFalse);
    });

    test('only lib/, only what is written', () {
      final files = counted(const [
        FileCoverage('/r/lib/a.dart', {1: 1}),
        FileCoverage('/r/lib/data/db.g.dart', {1: 0, 2: 0}),
        FileCoverage('/r/test/a_test.dart', {1: 1}),
        FileCoverage('lib/b.dart', {1: 0}),
      ]);
      expect([for (final f in files) f.path], ['lib/a.dart', 'lib/b.dart']);
    });
  });

  group('the numbers of a package', () {
    test('the totals add the lines up, not the percentages', () {
      final t = totalsOf(const [
        FileCoverage('lib/a.dart', {1: 1, 2: 1, 3: 1, 4: 1}),
        FileCoverage('lib/b.dart', {1: 0}),
      ]);
      expect((t.found, t.covered), (5, 4));
      expect(t.percent, 80);
    });

    test('no lines at all is fully covered', () {
      expect(totalsOf(const []).percent, 100);
    });

    test('the least covered: the most missing lines first, ties by path', () {
      final least = leastCovered(const [
        FileCoverage('lib/c.dart', {1: 0, 2: 0, 3: 1}),
        FileCoverage('lib/a.dart', {1: 0, 2: 0, 3: 1}),
        FileCoverage('lib/full.dart', {1: 1}),
        FileCoverage('lib/b.dart', {1: 0, 2: 0, 3: 0, 4: 0}),
        FileCoverage('lib/empty.dart', {}),
      ], 10);
      expect(
        [for (final f in least) f.path],
        ['lib/b.dart', 'lib/a.dart', 'lib/c.dart'],
      );
    });

    test('only as many as asked for', () {
      final files = [
        for (var i = 0; i < 5; i++) FileCoverage('lib/f$i.dart', {1: 0}),
      ];
      expect(leastCovered(files, 2), hasLength(2));
      expect(leastCovered(files, 0), isEmpty);
      expect(leastCovered(files, 50), hasLength(5));
    });
  });

  group('the words', () {
    test('a percentage has one decimal and the comma of the language', () {
      expect(percentText(61.24), '61,2');
      expect(percentText(100), '100,0');
      expect(percentText(0), '0,0');
      expect(percentText(99.96), '100,0');
    });

    test('under the minimum it says so; at or above it says nothing', () {
      expect(
        belowMinimum('app', 59.9, 60),
        'app: 59,9 % a megkívánt 60,0 % alatt',
      );
      expect(belowMinimum('app', 60, 60), isNull);
      expect(belowMinimum('app', 70, 60), isNull);
      expect(belowMinimum('app', 1, null), isNull);
    });

    test('the report: the total, then the files that miss the most', () {
      final lines = reportLines('mag', const [
        FileCoverage('lib/a.dart', {1: 1, 2: 0, 3: 0}),
        FileCoverage('lib/b.dart', {1: 1}),
      ], top: 1);
      expect(lines, [
        'mag: 50,0 % (2 / 4 sor, 2 fájl)',
        '      2 hiányzó sor  lib/a.dart (33,3 %)',
      ]);
    });

    test('the report without a gap lists no file', () {
      final lines = reportLines('app', const [
        FileCoverage('lib/a.dart', {1: 1}),
      ]);
      expect(lines, ['app: 100,0 % (1 / 1 sor, 1 fájl)']);
    });
  });

  group('the command line', () {
    test('without arguments: both packages, no minimum, ten files', () {
      final o = parseOptions(const []);
      expect((o.app, o.core, o.help, o.top), (true, true, false, 10));
      expect((o.minApp, o.minCore), (null, null));
    });

    test('one package', () {
      final a = parseOptions(const ['--only', 'app']);
      expect((a.app, a.core), (true, false));
      final c = parseOptions(const ['--only', 'core']);
      expect((c.app, c.core), (false, true));
    });

    test('the minimums, with a point or a comma', () {
      final o = parseOptions(const ['--min-app', '62.5', '--min-core', '85,5']);
      expect((o.minApp, o.minCore), (62.5, 85.5));
    });

    test('how many files', () {
      expect(parseOptions(const ['--top', '3']).top, 3);
      expect(parseOptions(const ['--top', '0']).top, 0);
    });

    test('help, short and long', () {
      expect(parseOptions(const ['-h']).help, isTrue);
      expect(parseOptions(const ['--help']).help, isTrue);
    });

    test('what is wrong with them is said', () {
      void bad(List<String> args, String says) => expect(
        () => parseOptions(args),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(says),
          ),
        ),
        reason: args.join(' '),
      );
      bad(const ['--nope'], 'ismeretlen kapcsoló: --nope');
      bad(const ['--only'], '--only után');
      bad(const ['--only', 'both'], '--only után');
      bad(const ['--min-app'], '--min-app után');
      bad(const ['--min-app', 'x'], '--min-app után');
      bad(const ['--min-core', '-1'], '--min-core után');
      bad(const ['--min-core', '100.5'], '--min-core után');
      bad(const ['--top'], '--top után');
      bad(const ['--top', '-2'], '--top után');
      bad(const ['--top', '2.5'], '--top után');
    });

    test('a percentage at the ends is accepted', () {
      expect(parseOptions(const ['--min-app', '0']).minApp, 0);
      expect(parseOptions(const ['--min-app', '100']).minApp, 100);
    });
  });
}
