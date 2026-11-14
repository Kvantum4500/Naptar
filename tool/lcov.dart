// The pure part of tool/coverage.dart: reading lcov files and working out what
// they say. No file, no process: so it can be tested (packages/kvantum_core/
// test/tool_lcov_test.dart), and so it runs the same on every machine.

/// The lines of one source file: line number → how many times it ran. Only
/// lines that CAN run are in it (an lcov file does not list comments).
class FileCoverage {
  const FileCoverage(this.path, this.hits);

  final String path;
  final Map<int, int> hits;

  int get found => hits.length;
  int get covered => hits.values.where((n) => n > 0).length;
  int get missed => found - covered;

  /// A file with nothing in it that could run counts as covered.
  double get percent => found == 0 ? 100 : covered * 100 / found;
}

/// Reads an lcov tracefile. A file that is in it more than once (the records of
/// several test processes) has the hits of its lines added up.
List<FileCoverage> parseLcov(String text) {
  final files = <String, Map<int, int>>{};
  Map<int, int>? current;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      final path = line.substring(3).replaceAll(r'\', '/');
      current = files.putIfAbsent(path, () => {});
    } else if (line == 'end_of_record') {
      current = null;
    } else if (line.startsWith('DA:') && current != null) {
      // DA:<line>,<hits>[,<checksum>]
      final parts = line.substring(3).split(',');
      if (parts.length < 2) continue;
      final number = int.tryParse(parts[0]);
      final hits = int.tryParse(parts[1]);
      if (number == null || hits == null) continue;
      current[number] = (current[number] ?? 0) + hits;
    }
  }
  return [for (final e in files.entries) FileCoverage(e.key, e.value)];
}

/// The path from its `lib/` folder on (`/x/y/lib/src/a.dart` → `lib/src/a.dart`);
/// a path without one stays as it is.
String libRelative(String path) {
  final p = path.replaceAll(r'\', '/');
  if (p.startsWith('lib/')) return p;
  final i = p.indexOf('/lib/');
  return i < 0 ? p : p.substring(i + 1);
}

/// Generated code (drift's `*.g.dart`, `*.freezed.dart`): nobody writes it, and
/// it would drown what is written (the database file alone is four thousand
/// lines), so it is not counted.
bool isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.contains('/generated/');

/// The files that count: those under `lib/`, generated ones left out.
List<FileCoverage> counted(Iterable<FileCoverage> files) => [
  for (final f in files)
    if (!isGenerated(f.path)) FileCoverage(libRelative(f.path), f.hits),
].where((f) => f.path.startsWith('lib/')).toList();

class CoverageTotals {
  const CoverageTotals(this.found, this.covered);

  final int found;
  final int covered;

  double get percent => found == 0 ? 100 : covered * 100 / found;
}

CoverageTotals totalsOf(Iterable<FileCoverage> files) {
  var found = 0, covered = 0;
  for (final f in files) {
    found += f.found;
    covered += f.covered;
  }
  return CoverageTotals(found, covered);
}

/// The [n] files with the most lines that never ran (a tie: by path).
List<FileCoverage> leastCovered(Iterable<FileCoverage> files, int n) {
  final list =
      [
        for (final f in files)
          if (f.missed > 0) f,
      ]..sort((a, b) {
        final c = b.missed.compareTo(a.missed);
        return c != 0 ? c : a.path.compareTo(b.path);
      });
  return list.take(n).toList();
}

/// "61,2" – one decimal, with the comma of the language of the program.
String percentText(double p) => p.toStringAsFixed(1).replaceAll('.', ',');

/// What to say when [percent] is under [minimum]; null when it is not (or when
/// there is no minimum to keep).
String? belowMinimum(String name, double percent, double? minimum) {
  if (minimum == null || percent >= minimum) return null;
  return '$name: ${percentText(percent)} % a megkívánt ${percentText(minimum)} % alatt';
}

/// The report of one package: the total, then the files that miss the most.
List<String> reportLines(
  String name,
  List<FileCoverage> files, {
  int top = 10,
}) {
  final t = totalsOf(files);
  final out = [
    '$name: ${percentText(t.percent)} % '
        '(${t.covered} / ${t.found} sor, ${files.length} fájl)',
  ];
  for (final f in leastCovered(files, top)) {
    out.add(
      '  ${f.missed.toString().padLeft(5)} hiányzó sor  ${f.path} '
      '(${percentText(f.percent)} %)',
    );
  }
  return out;
}

/// What was asked of the tool on the command line.
class CoverageOptions {
  const CoverageOptions({
    this.app = true,
    this.core = true,
    this.minApp,
    this.minCore,
    this.top = 10,
    this.help = false,
  });

  final bool app;
  final bool core;
  final double? minApp;
  final double? minCore;
  final int top;
  final bool help;
}

const coverageUsage = '''
Használat: dart tool/coverage.dart [kapcsolók]

  --only app|core   csak az egyik csomag (alapból mindkettő)
  --min-app N       az app sorfedettsége legalább N % legyen (különben a kilépési kód 1)
  --min-core N      ugyanez a magra
  --top N           a leghiányosabb N fájl (alapból 10)
  -h, --help        ez a súgó''';

/// Reads the arguments; a [FormatException] says what is wrong with them.
CoverageOptions parseOptions(List<String> args) {
  var app = true, core = true, help = false;
  double? minApp, minCore;
  var top = 10;
  double percentOf(String flag, String? v) {
    final n = v == null ? null : double.tryParse(v.replaceAll(',', '.'));
    if (n == null || n < 0 || n > 100) {
      throw FormatException('$flag után 0 és 100 közötti szám kell');
    }
    return n;
  }

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? next() => i + 1 < args.length ? args[++i] : null;
    switch (a) {
      case '-h' || '--help':
        help = true;
      case '--only':
        switch (next()) {
          case 'app':
            core = false;
          case 'core':
            app = false;
          default:
            throw const FormatException('--only után app vagy core kell');
        }
      case '--min-app':
        minApp = percentOf(a, next());
      case '--min-core':
        minCore = percentOf(a, next());
      case '--top':
        final n = int.tryParse(next() ?? '');
        if (n == null || n < 0) {
          throw const FormatException('--top után egy egész szám kell');
        }
        top = n;
      default:
        throw FormatException('ismeretlen kapcsoló: $a');
    }
  }
  return CoverageOptions(
    app: app,
    core: core,
    minApp: minApp,
    minCore: minCore,
    top: top,
    help: help,
  );
}
