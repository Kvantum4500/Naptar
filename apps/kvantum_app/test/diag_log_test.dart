import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/diag/redact.dart';

class _Silent {
  @override
  String toString() => '';
}

class _Multiline {
  @override
  String toString() => 'első sor\nmásodik sor, amiben egy cím van: Titkos cím';
}

void main() {
  group('safeErrorText: what may be written about an error', () {
    test('the type and the first line of the message', () {
      expect(
        safeErrorText(const FormatException('Hibás szám')),
        startsWith('FormatException: '),
      );
      expect(
        safeErrorText(const FormatException('Hibás szám')),
        contains('Hibás szám'),
      );
      final t = safeErrorText(_Multiline());
      expect(t, contains('első sor'));
      expect(t, isNot(contains('Titkos cím')), reason: 'only the first line');
    });

    test('an empty message leaves the type', () {
      expect(safeErrorText(_Silent()), '_Silent');
    });

    test('an SQL statement and its parameters are cut off', () {
      final t = safeErrorText(
        StateError(
          'while executing, SQL: INSERT INTO event_rows (title) VALUES (?) '
          'Parameters: [Titkos cím]',
        ),
      );
      expect(t, contains('while executing'));
      expect(t, isNot(contains('INSERT')));
      expect(t, isNot(contains('Titkos')));
    });

    test('e-mail addresses, long numbers, user names and secrets are gone', () {
      final t = safeErrorText(
        Exception(
          'jani.kovacs@example.com 1234567890123 C:\\Users\\Jani\\Documents\\x '
          'https://x.test/a?token=SECRETVALUE '
          'AIzaSyA1234567890abcdefghij Bearer abcdefghijklmnop',
        ),
      );
      expect(t, isNot(contains('jani.kovacs')));
      expect(t, isNot(contains('@')));
      expect(t, isNot(contains('1234567890123')));
      expect(t, isNot(contains('Jani')));
      expect(t, isNot(contains('SECRETVALUE')));
      expect(t, isNot(contains('AIzaSy')));
      expect(t, isNot(contains('abcdefghijklmnop')));
      expect(t, contains('[e-mail]'));
      expect(t, contains('[szám]'));
    });

    test('long messages are bounded', () {
      final t = safeErrorText(StateError('szó ' * 300));
      expect(t.length, lessThan(200));
      expect(t, endsWith('…'));
    });

    test('a stack is a few short frames on one line', () {
      final s = safeStackText(
        StackTrace.fromString(
          List.generate(
            30,
            (i) => '#$i      Foo.bar (package:kvantum_app/x.dart:$i:3)',
          ).join('\n'),
        ),
      );
      expect('|'.allMatches(s).length, 5, reason: 'six frames');
      expect(s, isNot(contains('\n')));
    });
  });

  group('DiagEntry', () {
    test('a line is read back', () {
      final e = DiagEntry(
        time: DateTime.utc(2026, 11, 12, 10, 0, 1),
        area: 'sync',
        code: 'calendar.unexpected',
        data: const {'n': 3, 'ok': true},
        error: 'StateError: x',
        stack: '#0 a',
      );
      final back = DiagEntry.tryParse(e.toLine())!;
      expect(back.time, e.time);
      expect(back.area, 'sync');
      expect(back.code, 'calendar.unexpected');
      expect(back.data, {'n': 3, 'ok': true});
      expect(back.error, 'StateError: x');
      expect(back.stack, '#0 a');
    });

    test('what is not a line is not an entry', () {
      for (final bad in [
        '',
        'nem json',
        '{"t":"2026-11-12T10:00:00Z","a":"x"',
        '[1,2]',
        '{"t":"nem idő","a":"x","c":"y"}',
        '{"t":"2026-11-12T10:00:00Z","c":"y"}',
      ]) {
        expect(DiagEntry.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('FileDiagSink', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('diag_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    String line(int i) => 'sor-${i.toString().padLeft(2, '0')}-${'x' * 20}';

    test('creates its folder, appends and reads in order', () async {
      final sink = FileDiagSink('${dir.path}/a/b/diag');
      await sink.append('egy');
      await sink.append('kettő');
      expect(await sink.readLines(), ['egy', 'kettő']);
    });

    test(
      'rotates: two files, the newest line last, the oldest dropped',
      () async {
        final sink = FileDiagSink(dir.path, maxBytes: 100);
        for (var i = 1; i <= 20; i++) {
          await sink.append(line(i));
        }
        final lines = await sink.readLines();
        expect(lines.last, line(20));
        expect(lines.length, inInclusiveRange(4, 7), reason: 'two files of ~3');
        final nums = lines.map((l) => int.parse(l.substring(4, 6))).toList();
        expect(nums, [for (var i = 20 - lines.length + 1; i <= 20; i++) i]);
        expect(File('${dir.path}/diag.log.1').existsSync(), isTrue);
        for (final f in ['diag.log', 'diag.log.1']) {
          expect(File('${dir.path}/$f').lengthSync(), lessThanOrEqualTo(100));
        }
      },
    );

    test('a new run goes on where the old one stopped', () async {
      final first = FileDiagSink(dir.path, maxBytes: 100);
      for (var i = 1; i <= 3; i++) {
        await first.append(line(i));
      }
      final second = FileDiagSink(dir.path, maxBytes: 100);
      await second.append(line(4));
      expect(await second.readLines(), [for (var i = 1; i <= 4; i++) line(i)]);
      expect(File('${dir.path}/diag.log.1').existsSync(), isTrue);
    });

    test('clear removes both files and the sink keeps working', () async {
      final sink = FileDiagSink(dir.path, maxBytes: 100);
      for (var i = 1; i <= 10; i++) {
        await sink.append(line(i));
      }
      await sink.clear();
      expect(await sink.readLines(), isEmpty);
      await sink.append('újra');
      expect(await sink.readLines(), ['újra']);
    });

    test('a torn last line (a crash) does not hide the others', () async {
      final good = DiagEntry(
        time: DateTime.utc(2026, 1, 1),
        area: 'a',
        code: 'c',
      ).toLine();
      File('${dir.path}/diag.log')
          .writeAsStringSync('$good\n$good\n{"t":"2026');
      final log = DiagLog()..attach(FileDiagSink(dir.path));
      expect(await log.tail(), hasLength(2));
    });
  });

  group('DiagLog', () {
    late MemoryDiagSink sink;
    late DateTime clock;
    late DiagLog log;

    setUp(() {
      sink = MemoryDiagSink();
      clock = DateTime.utc(2026, 11, 12, 10);
      log = DiagLog(now: () => clock)..attach(sink);
    });

    List<DiagEntry> written() => [
      for (final l in sink.lines) DiagEntry.tryParse(l)!,
    ];

    test('writes an entry with the time, the area and the code', () async {
      log.info('sync', 'run.ok', data: {'pushed': 2});
      await log.flush();
      final e = written().single;
      expect(e.time, clock);
      expect(e.area, 'sync');
      expect(e.code, 'run.ok');
      expect(e.data, {'pushed': 2});
    });

    test(
      'an error is written as its type and first line, with a short stack',
      () async {
        log.error(
          'drive',
          'push.failed',
          const FormatException('rossz fájl'),
          StackTrace.fromString('#0 a (package:kvantum_app/a.dart:1:1)\n#1 b'),
        );
        await log.flush();
        final e = written().single;
        expect(e.error, 'FormatException: rossz fájl');
        expect(e.stack, contains('package:kvantum_app/a.dart'));
      },
    );

    test(
      'only numbers, flags and short clean strings get in as data',
      () async {
        log.info(
          'x',
          'y',
          data: {
            'n': 3,
            'ok': true,
            'who': 'jani@example.com',
            'long': 'a' * 200,
            'obj': Object(),
            'list': [1, 2],
          },
        );
        await log.flush();
        final d = written().single.data;
        expect(d['n'], 3);
        expect(d['ok'], true);
        expect(d['who'], '[e-mail]');
        expect((d['long'] as String).length, lessThan(70));
        expect(d.containsKey('obj'), isFalse);
        expect(d.containsKey('list'), isFalse);
      },
    );

    test(
      'tail gives the last entries, oldest first, and skips damaged lines',
      () async {
        for (var i = 1; i <= 5; i++) {
          log.info('a', 'c$i');
        }
        await log.flush();
        sink.lines.insert(2, 'sérült sor');
        final tail = await log.tail(3);
        expect(tail.map((e) => e.code), ['c3', 'c4', 'c5']);
        expect((await log.tail(100)).map((e) => e.code), [
          'c1',
          'c2',
          'c3',
          'c4',
          'c5',
        ]);
      },
    );

    test(
      'the same message is written once a minute, the rest is counted',
      () async {
        for (var i = 0; i < 50; i++) {
          log.error('app', 'flutter', StateError('ugyanaz'));
        }
        await log.flush();
        expect(written(), hasLength(1));

        clock = clock.add(const Duration(seconds: 61));
        log.error('app', 'flutter', StateError('ugyanaz'));
        await log.flush();
        final e = written();
        expect(e, hasLength(3));
        expect(e[1].area, 'diag');
        expect(e[1].code, 'suppressed');
        expect(e[1].data['n'], 49);
        expect(e[2].code, 'flutter');
      },
    );

    test('a different error is not swallowed by the first', () async {
      log.error('app', 'flutter', StateError('egy'));
      log.error('app', 'flutter', StateError('másik'));
      await log.flush();
      expect(written(), hasLength(2));
    });

    test('there is a ceiling per minute, then it opens again', () async {
      for (var i = 0; i < 40; i++) {
        log.info('a', 'kód$i');
      }
      await log.flush();
      expect(written(), hasLength(30));

      clock = clock.add(const Duration(minutes: 1, seconds: 1));
      log.info('a', 'később');
      await log.flush();
      final e = written();
      expect(e[30].code, 'suppressed');
      expect(e[30].data['n'], 10);
      expect(e.last.code, 'később');
    });

    test('a failing disk does not reach the caller, and recovers', () async {
      sink.failWith = StateError('lemez');
      log.info('a', 'elveszik');
      log.error('a', 'ez is', StateError('x'));
      await log.flush();
      expect(sink.lines, isEmpty);

      sink.failWith = null;
      log.info('a', 'megvan');
      await log.flush();
      expect(written().map((e) => e.code), ['megvan']);
    });

    test(
      'what was logged before the file is known is written after attach',
      () async {
        final early = DiagLog(now: () => clock);
        early.info('app', 'korai1');
        early.info('app', 'korai2');
        final late = MemoryDiagSink();
        early.attach(late);
        early.info('app', 'kései');
        await early.flush();
        expect(late.lines.map((l) => DiagEntry.tryParse(l)!.code), [
          'korai1',
          'korai2',
          'kései',
        ]);
      },
    );

    test('the early memory is bounded', () async {
      final early = DiagLog(
        now: () => clock,
        bufferLimit: 10,
        maxPerMinute: 1000,
      );
      for (var i = 0; i < 50; i++) {
        early.info('app', 'k$i');
      }
      final late = MemoryDiagSink();
      early.attach(late);
      await early.flush();
      expect(late.lines, hasLength(10));
    });

    test('a disabled log does nothing', () async {
      final off = DiagLog.disabled();
      off.info('a', 'b');
      off.error('a', 'b', StateError('x'));
      off.infoOnce('k', 'a', 'b');
      off.attach(sink);
      await off.flush();
      expect(sink.lines, isEmpty);
      expect(await off.tail(), isEmpty);
      expect(off.enabled, isFalse);
    });

    test('"once" entries are written once per key', () async {
      for (var i = 0; i < 3; i++) {
        log.infoOnce('k1', 'a', 'elso');
        log.errorOnce('k2', 'a', 'masodik', StateError('x'));
      }
      log.infoOnce('k3', 'a', 'harmadik');
      await log.flush();
      expect(written().map((e) => e.code), ['elso', 'masodik', 'harmadik']);
    });

    test('clear empties the log and it can be written again', () async {
      log.info('a', 'régi');
      await log.clear();
      expect(await log.tail(), isEmpty);
      log.info('a', 'új');
      expect((await log.tail()).map((e) => e.code), ['új']);
    });

    test('many writes at once are all whole lines, in order', () async {
      final dir = Directory.systemTemp.createTempSync('diag_many');
      addTearDown(() => dir.deleteSync(recursive: true));
      final busy = DiagLog(now: () => clock, maxPerMinute: 1000)
        ..attach(FileDiagSink(dir.path));
      for (var i = 0; i < 200; i++) {
        busy.info('a', 'k${i.toString().padLeft(3, '0')}');
      }
      await busy.flush();
      final lines = const LineSplitter().convert(
        File('${dir.path}/diag.log').readAsStringSync(),
      );
      expect(lines, hasLength(200));
      expect(
        [for (final l in lines) DiagEntry.tryParse(l)!.code],
        [for (var i = 0; i < 200; i++) 'k${i.toString().padLeft(3, '0')}'],
      );
    });
  });
}
