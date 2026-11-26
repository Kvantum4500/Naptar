import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/notify/autostart_tile.dart';
import 'package:kvantum_app/notify/windows_autostart.dart';

import 'support/harness.dart';

const exe = r'C:\Users\Teszt\Kvantum Naptár\kvantum_app.exe';
const wanted = '"$exe" --minimized';

/// The registry as the tool sees it: the two values the startup entry uses.
class FakeRegistry {
  /// The data of the Run value (null: none).
  String? run;

  /// The first byte of Windows' own switch for the entry (null: none).
  int? approved;

  /// Every call in order, as "tool arg arg ...".
  final calls = <String>[];

  /// Makes the tool fail for the calls that start with this (exit code 1).
  String? failFor;

  /// The tool cannot be started at all.
  bool missing = false;

  ProcessResult _done(int code, [String out = '']) =>
      ProcessResult(0, code, out, '');

  Future<ProcessResult> call(String tool, List<String> args) async {
    if (missing) throw const ProcessException('reg', [], 'not found', 2);
    calls.add('$tool ${args.join(' ')}');
    if (failFor != null && args.first == failFor) return _done(1);
    final key = args[1];
    switch (args.first) {
      case 'query':
        if (key == RegAutostartBackend.runKey) {
          return run == null
              ? _done(1)
              : _done(
                  0,
                  '\r\n$key\r\n    ${RegAutostartBackend.valueName}    REG_SZ    $run\r\n\r\n',
                );
        }
        final flag = approved;
        return flag == null
            ? _done(1)
            : _done(
                0,
                '\r\n$key\r\n    ${RegAutostartBackend.valueName}    REG_BINARY    '
                '${flag.toRadixString(16).padLeft(2, '0')}0000000000000000000000\r\n\r\n',
              );
      case 'add':
        run = args[args.indexOf('/d') + 1];
        return _done(0);
      case 'delete':
        if (key == RegAutostartBackend.runKey) {
          final had = run != null;
          run = null;
          return _done(had ? 0 : 1);
        }
        final had = approved != null;
        approved = null;
        return _done(had ? 0 : 1);
    }
    return _done(1);
  }
}

/// The backend with the registry in memory, for the parts above the tool.
class MemoryBackend implements AutostartBackend {
  String? run;
  bool blocked = false;
  final calls = <String>[];
  bool failWrite = false;
  bool failRead = false;

  /// When set, a read waits for it (the system is slow to answer).
  Completer<void>? readGate;

  @override
  Future<String?> readCommand() async {
    await readGate?.future;
    if (failRead) throw const AutostartException('tool:test');
    return run;
  }

  @override
  Future<bool> blockedByWindows() async => blocked;

  @override
  Future<void> writeCommand(String command) async {
    calls.add('write');
    if (failWrite) throw const AutostartException('add:1');
    run = command;
  }

  @override
  Future<void> allow() async {
    calls.add('allow');
    blocked = false;
  }

  @override
  Future<void> removeCommand() async {
    calls.add('remove');
    run = null;
  }
}

void main() {
  group('reading what the registry tool prints', () {
    test('the data of the value, without the padding', () {
      const out =
          '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\'
          'CurrentVersion\\Run\r\n'
          '    KvantumNaptar    REG_SZ    $wanted\r\n\r\n';
      expect(parseRegText(out, 'KvantumNaptar'), wanted);
    });

    test('another value is not ours, not even one that starts like it', () {
      const out =
          '    KvantumNaptar2    REG_SZ    x\r\n'
          '    Other    REG_SZ    KvantumNaptar    REG_SZ    y\r\n';
      expect(parseRegText(out, 'KvantumNaptar'), isNull);
      expect(parseRegText('', 'KvantumNaptar'), isNull);
    });

    test('an expandable string counts, and an empty one is still there', () {
      expect(
        parseRegText(
          '    KvantumNaptar    REG_EXPAND_SZ    %A%\\x',
          'KvantumNaptar',
        ),
        r'%A%\x',
      );
      expect(
        parseRegText('    KvantumNaptar    REG_SZ    ', 'KvantumNaptar'),
        '',
      );
      expect(parseRegText('    KvantumNaptar    REG_SZ', 'KvantumNaptar'), '');
    });

    test('Windows switched it off when the first byte is odd', () {
      String line(String hex) => '    KvantumNaptar    REG_BINARY    $hex';
      expect(parseRegBlockedFlag(line('020000000000000000000000')), isFalse);
      expect(parseRegBlockedFlag(line('060000000000000000000000')), isFalse);
      expect(parseRegBlockedFlag(line('030000009C5DF8F4D3DBD801')), isTrue);
      expect(parseRegBlockedFlag(line('070000000000000000000000')), isTrue);
      expect(parseRegBlockedFlag(line('3')), isFalse, reason: 'half a byte');
      expect(parseRegBlockedFlag('nothing here'), isFalse);
    });
  });

  group('the registry tool', () {
    late FakeRegistry reg;
    late RegAutostartBackend backend;
    setUp(() {
      reg = FakeRegistry();
      backend = RegAutostartBackend(run: reg.call, regPath: 'reg');
    });

    test('nothing registered: no command', () async {
      expect(await backend.readCommand(), isNull);
      expect(reg.calls, [
        'reg query ${RegAutostartBackend.runKey} /v KvantumNaptar',
      ]);
    });

    test('writing registers the command as a string, forced', () async {
      await backend.writeCommand(wanted);
      expect(reg.calls, [
        'reg add ${RegAutostartBackend.runKey} /v KvantumNaptar /t REG_SZ '
            '/d $wanted /f',
      ]);
      expect(await backend.readCommand(), wanted);
    });

    test('the command goes to the tool as one argument', () async {
      final seen = <List<String>>[];
      final b = RegAutostartBackend(
        run: (tool, args) {
          seen.add(args);
          return reg.call(tool, args);
        },
        regPath: 'reg',
      );
      await b.writeCommand(wanted);
      expect(seen.single, contains(wanted), reason: 'spaces and quotes kept');
    });

    test('a refusal of the tool is an error with a short code', () async {
      reg.failFor = 'add';
      await expectLater(
        backend.writeCommand(wanted),
        throwsA(
          isA<AutostartException>().having((e) => e.code, 'code', 'add:1'),
        ),
      );
    });

    test('a tool that cannot be started is an error too', () async {
      reg.missing = true;
      await expectLater(
        backend.readCommand(),
        throwsA(
          isA<AutostartException>().having(
            (e) => e.code,
            'code',
            startsWith('tool:'),
          ),
        ),
      );
      await expectLater(
        backend.removeCommand(),
        throwsA(isA<AutostartException>()),
      );
    });

    test('removing takes the value away; nothing there is fine', () async {
      reg.run = wanted;
      await backend.removeCommand();
      expect(reg.run, isNull);
      reg.calls.clear();
      await backend.removeCommand(); // (exit code 1: there was none)
      expect(reg.calls, [
        'reg delete ${RegAutostartBackend.runKey} /v KvantumNaptar /f',
        'reg query ${RegAutostartBackend.runKey} /v KvantumNaptar',
      ]);
    });

    test('a removal that did not work is an error', () async {
      reg.run = wanted;
      reg.failFor = 'delete';
      await expectLater(
        backend.removeCommand(),
        throwsA(
          isA<AutostartException>().having((e) => e.code, 'code', 'delete:1'),
        ),
      );
    });

    test(
      'the switch of the Windows startup list is read and cleared',
      () async {
        expect(await backend.blockedByWindows(), isFalse);
        reg.approved = 3;
        expect(await backend.blockedByWindows(), isTrue);
        reg.approved = 2;
        expect(await backend.blockedByWindows(), isFalse);
        reg.approved = 3;
        await backend.allow();
        expect(reg.approved, isNull);
        expect(reg.calls.last, startsWith('reg delete '));
        expect(reg.calls.last, contains(RegAutostartBackend.approvedKey));
        await backend.allow(); // (nothing to clear: no error)
      },
    );

    test('the tool is looked for in the system folder', () {
      expect(
        RegAutostartBackend.systemRegPath({'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\reg.exe',
      );
      expect(
        RegAutostartBackend.systemRegPath({'SystemRoot': r'D:\Win'}),
        r'D:\Win\System32\reg.exe',
      );
      // (where the folder is not known, the name is left to the system)
      expect(RegAutostartBackend.systemRegPath(const {}), 'reg');
      expect(RegAutostartBackend.systemRegPath({'SystemRoot': ''}), 'reg');
    });

    test('the tool is the system\'s, not one a search path finds', () async {
      final seen = <String>[];
      await RegAutostartBackend(
        run: (tool, args) {
          seen.add(tool);
          return reg.call(tool, args);
        },
        regPath: r'C:\Windows\System32\reg.exe',
      ).readCommand();
      expect(seen, [r'C:\Windows\System32\reg.exe']);
    });
  });

  group('the startup entry', () {
    late MemoryBackend mem;
    late WindowsAutostart autostart;
    setUp(() {
      mem = MemoryBackend();
      autostart = WindowsAutostart(backend: mem, executable: exe);
    });

    test('the command is the program, quoted, started minimised', () {
      expect(autostart.command, wanted);
      expect(WindowsAutostart.startupFlag, '--minimized');
    });

    test('off, on, and on but switched off by Windows', () async {
      expect(await autostart.state(), AutostartState.off);
      mem.run = wanted;
      expect(await autostart.state(), AutostartState.on);
      mem.blocked = true;
      expect(await autostart.state(), AutostartState.blocked);
      mem.run = null;
      expect(
        await autostart.state(),
        AutostartState.off,
        reason: 'no entry, nothing to be blocked',
      );
    });

    test(
      'switching on registers it and takes back a Windows switch-off',
      () async {
        mem.blocked = true;
        await autostart.setEnabled(true);
        expect(mem.run, wanted);
        expect(mem.calls, ['write', 'allow']);
        expect(await autostart.state(), AutostartState.on);
      },
    );

    test('switching off removes the entry', () async {
      mem.run = wanted;
      await autostart.setEnabled(false);
      expect(mem.run, isNull);
      expect(await autostart.state(), AutostartState.off);
    });

    test('a failed registration is not followed by anything else', () async {
      mem.failWrite = true;
      await expectLater(
        autostart.setEnabled(true),
        throwsA(isA<AutostartException>()),
      );
      expect(mem.calls, ['write'], reason: 'no allow after a refusal');
    });

    group('repair', () {
      test('creates nothing where the user has no entry', () async {
        expect(await autostart.repair(), isFalse);
        expect(mem.calls, isEmpty);
      });

      test('leaves a good entry alone', () async {
        mem.run = wanted;
        expect(await autostart.repair(), isFalse);
        expect(mem.calls, isEmpty);
      });

      test('follows the program to a new folder', () async {
        mem.run = '"D:\\Old\\kvantum_app.exe" --minimized';
        expect(await autostart.repair(), isTrue);
        expect(mem.run, wanted);
      });

      test('gives an entry of an older version the flag', () async {
        mem.run = '"$exe"';
        expect(await autostart.repair(), isTrue);
        expect(mem.run, wanted);
      });

      test('does not clear a switch-off made in Windows', () async {
        mem
          ..run = '"D:\\Old\\kvantum_app.exe" --minimized'
          ..blocked = true;
        await autostart.repair();
        expect(mem.calls, ['write']);
        expect(mem.blocked, isTrue);
      });

      test(
        'an accented folder name that came back changed is the same',
        () async {
          // (the tool prints in the console's code page)
          mem.run = '"C:\\Users\\Teszt\\Kvantum Napt\u00a0r\\kvantum_app.exe" --minimized';
          expect(await autostart.repair(), isFalse);
        },
      );

      test('letter case does not matter in a path', () async {
        mem.run = wanted.toUpperCase();
        expect(await autostart.repair(), isFalse);
      });
    });
  });

  group('where there is a startup entry', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('only on a computer that runs Windows', () {
      for (final p in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = p;
        final c = ProviderContainer();
        addTearDown(c.dispose);
        expect(
          c.read(autostartProvider) != null,
          Platform.isWindows && p == TargetPlatform.windows,
          reason: '$p',
        );
      }
    });

    test('the one for this program names this program', () {
      final a = WindowsAutostart.forThisProgram();
      expect(a.executable, Platform.resolvedExecutable);
      expect(a.command, startsWith('"${Platform.resolvedExecutable}"'));
    });
  });

  group('the switch in the settings', () {
    late AppDatabase db;
    late MemoryBackend mem;
    late MemoryDiagSink sink;

    Future<void> boot0(WidgetTester tester) async {
      useSize(tester, size: const Size(700, 900));
      db = await newDb();
      sink = MemoryDiagSink();
      await tester.pumpWidget(
        app(
          const Scaffold(body: SingleChildScrollView(child: AutostartTile())),
          db,
          extra: [
            autostartProvider.overrideWithValue(
              WindowsAutostart(backend: mem, executable: exe),
            ),
            diagLogProvider.overrideWithValue(DiagLog()..attach(sink)),
          ],
        ),
      );
      await tester.pump();
    }

    Future<void> boot(WidgetTester tester) async {
      await boot0(tester);
      await tester.pumpAndSettle();
    }

    SwitchListTile tile(WidgetTester tester) =>
        tester.widget<SwitchListTile>(find.byKey(const Key('autostart')));

    setUp(() => mem = MemoryBackend());

    testWidgets('it is off unless the user turned it on', (tester) async {
      await boot(tester);
      expect(tile(tester).value, isFalse);
      expect(find.textContaining('Alapból ki van kapcsolva'), findsOneWidget);
      expect(mem.calls, isEmpty, reason: 'looking changes nothing');
      await shutdown(tester, db);
    });

    testWidgets('it shows an entry that is already there', (tester) async {
      mem.run = wanted;
      await boot(tester);
      expect(tile(tester).value, isTrue);
      await shutdown(tester, db);
    });

    testWidgets('switching on and off', (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('autostart')));
      await tester.pumpAndSettle();
      expect(mem.run, wanted);
      expect(tile(tester).value, isTrue);
      await tester.tap(find.byKey(const Key('autostart')));
      await tester.pumpAndSettle();
      expect(mem.run, isNull);
      expect(tile(tester).value, isFalse);
      await shutdown(tester, db);
    });

    testWidgets('Windows has switched it off: it says so, and on re-allows', (
      tester,
    ) async {
      mem
        ..run = wanted
        ..blocked = true;
      await boot(tester);
      expect(tile(tester).value, isFalse, reason: 'it will not start');
      expect(find.textContaining('A Windows letiltotta'), findsOneWidget);
      await tester.tap(find.byKey(const Key('autostart')));
      await tester.pumpAndSettle();
      expect(mem.blocked, isFalse);
      expect(tile(tester).value, isTrue);
      expect(find.textContaining('A Windows letiltotta'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a refusal: told in plain words, nothing raw, logged by code', (
      tester,
    ) async {
      mem.failWrite = true;
      await boot(tester);
      await tester.tap(find.byKey(const Key('autostart')));
      await tester.pumpAndSettle();
      expect(find.textContaining('nem sikerült átállítani'), findsOneWidget);
      expect(find.textContaining('AutostartException'), findsNothing);
      expect(tile(tester).value, isFalse, reason: 'shows what the system has');
      expect(sink.lines.join('\n'), contains('set.failed'));
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('autostart')))
            .onChanged,
        isNotNull,
        reason: 'can be tried again',
      );
      await shutdown(tester, db);
    });

    testWidgets('when the system cannot be asked it says so', (tester) async {
      mem.failRead = true;
      await boot(tester);
      expect(find.textContaining('Nem sikerült megnézni'), findsOneWidget);
      expect(tile(tester).value, isFalse);
      expect(tile(tester).onChanged, isNotNull);
      await shutdown(tester, db);
    });

    testWidgets('it waits for the answer, then lets the user change it', (
      tester,
    ) async {
      mem.readGate = Completer<void>();
      await boot0(tester);
      expect(tile(tester).onChanged, isNull, reason: 'not known yet');
      mem.readGate!.complete();
      await tester.pumpAndSettle();
      expect(tile(tester).onChanged, isNotNull);
      await shutdown(tester, db);
    });
  });
}
