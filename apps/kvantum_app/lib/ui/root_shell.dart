import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';

import 'finance/finance_page.dart';
import 'home_page.dart';
import '../diag/diag_log.dart';

/// The two top-level tabs: the calendar and the money pages. Both stay alive
/// while switching, so the calendar keeps its view and scroll position.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  var _index = 0;

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

  static const _destinations = [
    (Icons.calendar_month_outlined, Icons.calendar_month, 'Naptár'),
    (
      Icons.account_balance_wallet_outlined,
      Icons.account_balance_wallet,
      'Pénzügyek',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final body = IndexedStack(
      index: _index,
      children: const [HomePage(), FinancePage()],
    );
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: Text(d.$3),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$2),
              label: d.$3,
            ),
        ],
      ),
    );
  }
}
