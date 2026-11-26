import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/ai_providers.dart' show assistantControllerProvider;

/// The pages the shell switches between. Most have a button in the bar (or the
/// rail); the assistant is one of "Több": it stays a page of the shell (what
/// was typed is kept, and the running request ends when it is left), only its
/// button is in the menu. The rest (shift planner, settings) opens from "Több"
/// as a page of its own.
enum ShellTab {
  calendar('Naptár', Icons.calendar_month_outlined, Icons.calendar_month),
  tasks('Feladatok', Icons.checklist, Icons.checklist),
  journal('Napló', Icons.menu_book_outlined, Icons.menu_book),
  assistant(
    'Asszisztens',
    Icons.auto_awesome_outlined,
    Icons.auto_awesome,
    inBar: false,
  ),
  finance(
    'Pénzügyek',
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet,
  );

  const ShellTab(this.label, this.icon, this.selectedIcon, {this.inBar = true});
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Whether the page has a button of its own in the bar.
  final bool inBar;

  /// The pages that have a button in the bar, in the order of the buttons.
  static final List<ShellTab> bar = [
    for (final t in values)
      if (t.inBar) t,
  ];
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
