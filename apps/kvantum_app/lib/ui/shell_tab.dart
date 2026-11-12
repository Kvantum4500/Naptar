import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/ai_providers.dart' show assistantControllerProvider;

/// The pages the bar (or the rail) switches between. The rest (shift planner,
/// settings) opens from "Több".
enum ShellTab {
  calendar('Naptár', Icons.calendar_month_outlined, Icons.calendar_month),
  tasks('Feladatok', Icons.checklist, Icons.checklist),
  assistant('Asszisztens', Icons.auto_awesome_outlined, Icons.auto_awesome),
  finance(
    'Pénzügyek',
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet,
  );

  const ShellTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Which [ShellTab] is showing.
class ShellTabNotifier extends Notifier<ShellTab> {
  @override
  ShellTab build() => ShellTab.calendar;

  void select(ShellTab tab) {
    if (tab == state) return;
    if (state == ShellTab.assistant) {
      // Leaving the assistant ends the running request, as leaving its page
      // used to: nobody waits for the answer, and it would only spend tokens.
      ref.read(assistantControllerProvider.notifier).cancel();
    }
    state = tab;
  }
}

final shellTabProvider = NotifierProvider<ShellTabNotifier, ShellTab>(
  ShellTabNotifier.new,
);
