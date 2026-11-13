import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/assistant_page.dart';
import '../ai/settings_page.dart';
import '../backup/backup_providers.dart';
import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import '../widget/widget_sync.dart';
import 'breakpoints.dart';
import 'finance/finance_page.dart';
import 'home_page.dart';
import 'progress_page.dart';
import 'quick_entry_dialog.dart';
import 'shell_tab.dart';
import 'shift_page.dart';
import 'tasks_page.dart';
import 'text_scale.dart';

/// What "Több" offers: the quick entry, and pages that are visited now and
/// then (the progress, the shifts, the settings).
enum _More {
  quick('Gyors felvitel', Icons.bolt),
  progress('Haladás', Icons.show_chart),
  shifts('Beosztás', Icons.event_repeat),
  settings('Beállítások', Icons.settings_outlined);

  const _More(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The frame of the app: the four main pages stay alive while switching (the
/// calendar keeps its view and scroll position), each is built the first time
/// it is shown. At the bottom (phone) or at the side (wide window) are the
/// destinations, and "Több" for the rest.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  /// The pages shown at least once (the others are not built yet).
  final _opened = <ShellTab>{ShellTab.calendar};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _collectWallet();
    // upkeep waits until the first screen is up
    WidgetsBinding.instance.addPostFrameCallback((_) => _housekeeping());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _collectWallet();
      // the midnight timer may have stood still while the device slept
      ref.read(todayProvider.notifier).refresh();
      // a widget may have been put on the home screen meanwhile
      ref.read(widgetKickProvider.notifier).bump();
      // an app left open for days still gets its daily backup
      unawaited(_autoBackup().then((_) => _driveBackup()));
    }
  }

  /// Once a day: forgets old deletion markers and puts right what an
  /// interrupted run left behind.
  Future<void> _housekeeping() async {
    try {
      final report = await ref.read(housekeepingProvider).runIfDue();
      if (report != null && report.requeued > 0 && mounted) {
        ref.read(syncControllerProvider.notifier).requestSync();
      }
    } catch (e, st) {
      // upkeep is a convenience; never let it disturb the app
      ref.read(diagLogProvider).error('app', 'housekeeping.failed', e, st);
    }
    // (the backup comes after the upkeep, which may have tidied the data)
    await _autoBackup();
    await _driveBackup();
  }

  /// The weekly encrypted copy in Drive (does nothing when it is switched off,
  /// nobody is signed in, or one is recent enough; it is tried again when the
  /// login comes and when the app comes back).
  Future<void> _driveBackup() async {
    if (!ref.read(autoBackupRunsProvider)) return;
    try {
      await ref.read(driveBackupProvider).runIfDue();
    } catch (e, st) {
      ref.read(diagLogProvider).error('app', 'drive_backup.failed', e, st);
    }
  }

  /// The daily backup of everything on this device (does nothing when one is
  /// recent enough or it is switched off, and writes down what it did).
  Future<void> _autoBackup() async {
    if (!ref.read(autoBackupRunsProvider)) return;
    try {
      await ref.read(autoBackupProvider).runIfDue();
    } catch (e, st) {
      ref.read(diagLogProvider).error('app', 'backup.failed', e, st);
    }
  }

  /// Books the payment notifications collected while the app was closed.
  Future<void> _collectWallet() async {
    try {
      await ref.read(walletIngestProvider).run();
    } catch (e, st) {
      // never let a notification problem disturb the app
      ref.read(diagLogProvider).error('app', 'wallet.ingest_failed', e, st);
    }
  }

  static Widget _page(ShellTab tab) => switch (tab) {
    ShellTab.calendar => const HomePage(),
    ShellTab.tasks => const TasksPage(),
    ShellTab.assistant => const AssistantPage(),
    ShellTab.finance => const FinancePage(),
  };

  /// The index of "Több" in the bar: after the four pages.
  static final _moreIndex = ShellTab.values.length;

  void _onSelected(int i) {
    if (i == _moreIndex) {
      _openMore();
    } else {
      ref.read(shellTabProvider.notifier).select(ShellTab.values[i]);
    }
  }

  Future<void> _openMore() async {
    final choice = await showModalBottomSheet<_More>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in _More.values)
              ListTile(
                key: Key('more-${m.name}'),
                leading: Icon(m.icon),
                title: Text(m.label),
                onTap: () => Navigator.pop(c, m),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _More.quick) {
      await showQuickEntry(context, ref);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => switch (choice) {
          _More.progress => const ProgressPage(),
          _More.shifts => const ShiftPage(),
          _More.settings => const SettingsPage(),
          _More.quick => const SizedBox.shrink(), // (handled above)
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // the weekly Drive copy needs the login: it waits for it
    ref.listen<bool>(syncControllerProvider.select((s) => s.signedIn), (
      was,
      now,
    ) {
      if (now && was != true) unawaited(_driveBackup());
    });
    final tab = ref.watch(shellTabProvider);
    _opened.add(tab);
    final body = IndexedStack(
      index: tab.index,
      children: [
        for (final t in ShellTab.values)
          if (_opened.contains(t))
            // a page that is not showing takes no keyboard focus and runs no
            // animations
            ExcludeFocus(
              excluding: t != tab,
              child: TickerMode(enabled: t == tab, child: _page(t)),
            )
          else
            const SizedBox.shrink(),
      ],
    );
    final width = MediaQuery.sizeOf(context).width;
    final Widget frame;
    if (useRail(width)) {
      frame = Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tab.index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: _onSelected,
              destinations: [
                for (final t in ShellTab.values)
                  NavigationRailDestination(
                    icon: Icon(t.icon),
                    selectedIcon: Icon(t.selectedIcon),
                    label: Text(t.label),
                  ),
                const NavigationRailDestination(
                  icon: Icon(Icons.more_horiz),
                  label: Text('Több'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    } else {
      frame = Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: _onSelected,
          // Five labels do not fit side by side at a large text size: then
          // only the chosen one is written (the others are still read out
          // and shown as a tooltip).
          labelBehavior: context.textFactor() >= 1.3
              ? NavigationDestinationLabelBehavior.onlyShowSelected
              : NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final t in ShellTab.values)
              NavigationDestination(
                key: Key('nav-${t.name}'),
                icon: Icon(t.icon),
                selectedIcon: Icon(t.selectedIcon),
                label: t.label,
              ),
            const NavigationDestination(
              key: Key('nav-more'),
              icon: Icon(Icons.more_horiz),
              label: 'Több',
            ),
          ],
        ),
      );
    }
    // Back goes to the calendar first, and only from there leaves the app.
    return PopScope(
      canPop: tab == ShellTab.calendar,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ref.read(shellTabProvider.notifier).select(ShellTab.calendar);
        }
      },
      child: frame,
    );
  }
}
