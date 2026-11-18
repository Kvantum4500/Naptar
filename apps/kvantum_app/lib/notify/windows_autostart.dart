import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the program starts when the user signs in to Windows.
enum AutostartState {
  /// Not registered.
  off,

  /// Registered, and Windows lets it start.
  on,

  /// Registered, but switched off in Windows' own startup list (Settings /
  /// Task Manager): Windows does not start it.
  blocked,
}

/// Reading or changing the startup entry failed. Carries a short code only
/// (it goes to the log; nothing of the user's is in it).
class AutostartException implements Exception {
  const AutostartException(this.code);
  final String code;

  @override
  String toString() => 'AutostartException($code)';
}

/// The registry side of the startup entry, behind an interface so that it can
/// be tried without Windows.
abstract class AutostartBackend {
  /// The command Windows runs at sign-in, or null when there is none.
  Future<String?> readCommand();

  /// True when the user switched the entry off in Windows' startup list.
  Future<bool> blockedByWindows();

  /// Registers [command] to run at sign-in.
  Future<void> writeCommand(String command);

  /// Takes back a switch-off made in Windows' startup list (nothing if none).
  Future<void> allow();

  /// Removes the entry (nothing if there is none).
  Future<void> removeCommand();
}

/// Runs a system tool and returns what it printed and how it ended.
typedef RunTool = Future<ProcessResult> Function(
  String tool,
  List<String> arguments,
);

/// [AutostartBackend] on `reg.exe`: the current user's `Run` key needs no
/// rights and no native code. Only the exit codes are relied on (the tool's
/// messages are translated); the data of the entry is read for comparison.
class RegAutostartBackend implements AutostartBackend {
  RegAutostartBackend({RunTool? run, String? regPath})
    : _run = run ?? _system,
      _reg = regPath ?? systemRegPath(Platform.environment);

  /// The name of the entry. Never changes: an entry written by an earlier
  /// version is found by it.
  static const valueName = 'KvantumNaptar';
  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Where Windows keeps the switches of its own startup list.
  static const approvedKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

  final RunTool _run;
  final String _reg;

  static Future<ProcessResult> _system(String tool, List<String> arguments) =>
      Process.run(tool, arguments);

  /// The system's own copy of the tool, not whatever a search path finds first.
  @visibleForTesting
  static String systemRegPath(Map<String, String> environment) {
    final root = environment['SystemRoot'];
    return root == null || root.isEmpty ? 'reg' : '$root\\System32\\reg.exe';
  }

  Future<ProcessResult> _call(List<String> arguments) async {
    try {
      return await _run(_reg, arguments);
    } catch (e) {
      throw AutostartException('tool:${e.runtimeType}');
    }
  }

  @override
  Future<String?> readCommand() async {
    final r = await _call(['query', runKey, '/v', valueName]);
    if (r.exitCode != 0) return null;
    return parseRegText('${r.stdout}', valueName) ?? '';
  }

  @override
  Future<bool> blockedByWindows() async {
    final r = await _call(['query', approvedKey, '/v', valueName]);
    if (r.exitCode != 0) return false;
    return parseRegBlockedFlag('${r.stdout}');
  }

  @override
  Future<void> writeCommand(String command) async {
    final r = await _call([
      'add',
      runKey,
      '/v',
      valueName,
      '/t',
      'REG_SZ',
      '/d',
      command,
      '/f',
    ]);
    if (r.exitCode != 0) throw AutostartException('add:${r.exitCode}');
  }

  @override
  Future<void> allow() async {
    // (exit code 1 = the user never switched it off: nothing to take back)
    await _call(['delete', approvedKey, '/v', valueName, '/f']);
  }

  @override
  Future<void> removeCommand() async {
    final r = await _call(['delete', runKey, '/v', valueName, '/f']);
    if (r.exitCode != 0 && await readCommand() != null) {
      throw AutostartException('delete:${r.exitCode}');
    }
  }
}

/// The text of the string value [name] in the output of `reg query`, or null
/// when the output has no such line.
///
///     KvantumNaptar    REG_SZ    "C:\...\kvantum_app.exe" --minimized
@visibleForTesting
String? parseRegText(String output, String name) {
  final line = RegExp(
    '^\\s*${RegExp.escape(name)}\\s+REG_(?:EXPAND_)?SZ(?:\\s+(.*))?\$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(output);
  return line == null ? null : (line.group(1) ?? '').trim();
}

/// True when the binary value in the output of `reg query` says that Windows'
/// startup list has the entry switched off: its first byte is odd (2 and 6
/// mean on, 3 and 7 off).
@visibleForTesting
bool parseRegBlockedFlag(String output) {
  final m = RegExp(r'REG_BINARY\s+([0-9A-Fa-f]{2})').firstMatch(output);
  return m != null && int.parse(m.group(1)!, radix: 16).isOdd;
}

/// The startup entry of this program: it starts when the user signs in, and
/// sits in the taskbar (`--minimized`) so that it can sync and keep the
/// reminders up to date without being in the way.
class WindowsAutostart {
  WindowsAutostart({required this.backend, required this.executable});

  /// The entry for the program that is running now.
  factory WindowsAutostart.forThisProgram() => WindowsAutostart(
    backend: RegAutostartBackend(),
    executable: Platform.resolvedExecutable,
  );

  /// What the runner looks for in the command line (windows/runner/main.cpp).
  static const startupFlag = '--minimized';

  final AutostartBackend backend;
  final String executable;

  /// What Windows runs at sign-in.
  String get command => '"$executable" $startupFlag';

  Future<AutostartState> state() async {
    if (await backend.readCommand() == null) return AutostartState.off;
    return await backend.blockedByWindows()
        ? AutostartState.blocked
        : AutostartState.on;
  }

  Future<void> setEnabled(bool on) async {
    if (on) {
      await backend.writeCommand(command);
      await backend.allow();
    } else {
      await backend.removeCommand();
    }
  }

  /// An entry the user switched on points at the program where it is now: it
  /// moves with the folder, and an entry written by an older version gets the
  /// current flag. Nothing is created where there is none, and a switch-off in
  /// Windows' list stays. True when the entry was rewritten.
  Future<bool> repair() async {
    final stored = await backend.readCommand();
    if (stored == null || _plain(stored) == _plain(command)) return false;
    await backend.writeCommand(command);
    return true;
  }

  /// Compared without the characters outside ASCII and without regard to
  /// case: the tool prints in the console's code page, so an accented folder
  /// name can come back changed, and Windows paths do not care about case.
  static String _plain(String text) =>
      text.replaceAll(RegExp(r'[^\x20-\x7E]'), '').toLowerCase();
}

/// The startup entry; null where there is none: everything but Windows (and
/// a test, which says it is Windows, does not start the system's tools unless
/// it also hands over its own entry).
final autostartProvider = Provider<WindowsAutostart?>(
  (ref) => Platform.isWindows && defaultTargetPlatform == TargetPlatform.windows
      ? WindowsAutostart.forThisProgram()
      : null,
);
