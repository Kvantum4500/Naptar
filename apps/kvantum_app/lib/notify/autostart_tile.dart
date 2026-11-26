import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diag/diag_log.dart';
import 'windows_autostart.dart';

/// The switch for starting the program with Windows (Settings, under the
/// reminders). Off unless the user turns it on; shows what the system really
/// has, also when Windows' own startup list has switched the entry off.
class AutostartTile extends ConsumerStatefulWidget {
  const AutostartTile({super.key});

  @override
  ConsumerState<AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends ConsumerState<AutostartTile> {
  /// What the system has (null until it has been read).
  AutostartState? _state;

  /// The system could not be asked.
  bool _unknown = false;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final autostart = ref.read(autostartProvider);
    final log = ref.read(diagLogProvider);
    if (autostart == null) return;
    try {
      final state = await autostart.state();
      if (mounted) {
        setState(() {
          _state = state;
          _unknown = false;
        });
      }
    } catch (e, st) {
      log.error('autostart', 'read.failed', e, st);
      if (mounted) setState(() => _unknown = true);
    }
  }

  Future<void> _set(bool on) async {
    final autostart = ref.read(autostartProvider);
    if (autostart == null) return;
    final log = ref.read(diagLogProvider);
    final messenger = ScaffoldMessenger.of(context);
    final error = Theme.of(context).colorScheme.error;
    setState(() => _busy = true);
    try {
      await autostart.setEnabled(on);
      log.info('autostart', on ? 'on' : 'off');
    } catch (e, st) {
      log.error('autostart', 'set.failed', e, st);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'Az automatikus indítást nem sikerült átállítani. Próbáld újra, '
              'vagy a Windows Beállítások → Alkalmazások → Indítás oldalán '
              'állítsd át.',
            ),
            backgroundColor: error,
          ),
        );
    }
    if (!mounted) return;
    await _load(); // (shows what the system has, also after a failure)
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final String hint;
    if (_unknown) {
      hint = 'Nem sikerült megnézni, hogy be van-e kapcsolva.';
    } else if (_state == AutostartState.blocked) {
      hint =
          'A Windows letiltotta (Beállítások → Alkalmazások → Indítás, vagy '
          'Feladatkezelő → Indítás). A kapcsoló bekapcsolása újra engedélyezi.';
    } else {
      hint =
          'Bejelentkezéskor a program magától elindul, lekicsinyítve a '
          'tálcára, szinkronizál és frissíti az emlékeztetőket. Alapból ki '
          'van kapcsolva.';
    }
    return SwitchListTile(
      key: const Key('autostart'),
      contentPadding: EdgeInsets.zero,
      title: const Text('Indítás a Windows-szal'),
      subtitle: Text(hint),
      value: _state == AutostartState.on,
      onChanged: _busy || (_state == null && !_unknown) ? null : _set,
    );
  }
}
