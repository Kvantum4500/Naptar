import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_log.dart';
import '../providers.dart';
import 'budget_notify.dart';

/// Whether the budget alerts are on (device-local, like the reminders).
const budgetAlertsKey = 'bud.alerts';

/// What the app remembered of the levels of [year]/[month] (see
/// [BudgetMemory]; device-local too).
String budgetMemoryKey(int year, int month) =>
    'bud.alert.${budgetMonthKey(year, month)}';

enum BudgetAlertsStart { on, denied }

/// The switch of the budget alerts.
class BudgetAlertsSetting extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      (await ref.watch(recordRepoProvider).meta(budgetAlertsKey)) == 'on';

  /// Switches the alerts on, when the device lets notifications through. What
  /// is close or over at this moment is remembered, not told: only what comes
  /// after is news.
  Future<BudgetAlertsStart> enable() async {
    final notifier = ref.read(budgetNotifierProvider);
    if (!notifier.supported || !await notifier.ensurePermission()) {
      return BudgetAlertsStart.denied;
    }
    final repo = ref.read(recordRepoProvider);
    final today = ref.read(todayProvider);
    // (asked of the database itself: a provider nobody is listening to is
    // paused, and would never answer)
    final finance = ref.read(financeRepoProvider);
    final levels = currentBudgetLevels(
      txs: await finance.txs(),
      budgets: await finance.budgets(),
      year: today.year,
      month: today.month,
    );
    await repo.setMeta(
      budgetMemoryKey(today.year, today.month),
      encodeBudgetMemory(levels),
    );
    await repo.setMeta(budgetAlertsKey, 'on');
    state = const AsyncData(true);
    return BudgetAlertsStart.on;
  }

  Future<void> disable() async {
    await ref.read(recordRepoProvider).setMeta(budgetAlertsKey, null);
    state = const AsyncData(false);
  }
}

final budgetAlertsSettingProvider =
    AsyncNotifierProvider<BudgetAlertsSetting, bool>(BudgetAlertsSetting.new);

/// How long the alerts wait for the finances to settle before they look (a
/// bank statement writes hundreds of rows, a sync many records).
final budgetAlertDebounceProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 1500),
);

/// Starts the timer of the wait above (replaceable by tests).
final budgetAlertTimerProvider =
    Provider<Timer Function(Duration, void Function())>((_) => Timer.new);

/// Runs of the alert check, one after the other (each reads what the one
/// before wrote).
class BudgetAlertRuns {
  /// The run that came last; waiting for it waits for all of them (tests do).
  Future<void> last = Future.value();

  /// The month whose old memory has been cleared this session.
  String? clearedFor;
}

final budgetAlertRunsProvider = Provider<BudgetAlertRuns>(
  (_) => BudgetAlertRuns(),
);

/// Tells the user when a category reaches 80 % of its budget or goes over it
/// (see `planBudgetAlerts`). Watch it once from the home page.
///
/// It looks whenever the transactions, the budgets or the day change - so a
/// payment from the wallet, a bank statement and a record that came from
/// another device are all seen - after a short wait that every new change
/// starts anew.
final budgetAlertsProvider = Provider<void>((ref) {
  final on = ref.watch(budgetAlertsSettingProvider).value ?? false;
  if (!on) return;
  final notifier = ref.read(budgetNotifierProvider);
  if (!notifier.supported) return;
  // (what the levels are made of; the values are read when the wait is over)
  ref.watch(finTxProvider);
  ref.watch(finBudgetsProvider);
  final today = ref.watch(todayProvider);
  final runs = ref.read(budgetAlertRunsProvider);
  final timer = ref.read(budgetAlertTimerProvider)(
    ref.read(budgetAlertDebounceProvider),
    () {
      // everything the run needs is taken now: it must not touch [ref] after
      // the provider has been rebuilt or disposed
      final txs = ref.read(finTxProvider).value;
      final budgets = ref.read(finBudgetsProvider).value;
      // (not loaded yet is not "nothing spent": there is nothing to say)
      if (txs == null || budgets == null) return;
      final repo = ref.read(recordRepoProvider);
      final finance = ref.read(financeRepoProvider);
      final log = ref.read(diagLogProvider);
      runs.last = runs.last.then((_) async {
        try {
          final month = budgetMonthKey(today.year, today.month);
          final key = budgetMemoryKey(today.year, today.month);
          final before = await repo.meta(key);
          final plan = planBudgetAlerts(
            txs: txs,
            budgets: budgets,
            year: today.year,
            month: today.month,
            memory: decodeBudgetMemory(before),
          );
          // (the categories of the user's own, over the default ones they
          // replace; asked of the database: nobody need be listening)
          final names = {
            for (final c in defaultCategories()) c.id: c.name,
            for (final c in await finance.categories()) c.id: c.name,
          };
          for (final m in budgetAlertMessages(
            plan.alerts,
            (id) => names[id] ?? 'Kategória',
          )) {
            try {
              await notifier.show(
                id: budgetNotificationId(month, m.key),
                title: m.title,
                body: m.body,
              );
            } catch (e, st) {
              // (the news is lost, but the others are still told)
              log.error('app', 'budget.alert_failed', e, st);
            }
          }
          final after = encodeBudgetMemory(plan.memory);
          if (after != before) await repo.setMeta(key, after);
          // the month before last is of no use any more
          if (runs.clearedFor != month) {
            runs.clearedFor = month;
            final old = DateTime.utc(today.year, today.month - 2);
            await repo.setMeta(budgetMemoryKey(old.year, old.month), null);
          }
        } catch (e, st) {
          // alerts are a convenience; never break the app because of them
          log.error('app', 'budget.alerts_failed', e, st);
        }
      });
    },
  );
  ref.onDispose(timer.cancel);
});
