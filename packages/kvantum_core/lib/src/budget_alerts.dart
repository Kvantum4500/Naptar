import 'dart:convert';

import 'finance.dart';

/// Budget alerts: telling the user when a category reaches 80 % of its monthly
/// limit ("close") or goes past it ("over"). Pure functions; the app keeps the
/// [BudgetMemory] and shows the messages.
///
/// The rules, all of them about not crying wolf:
/// - a message comes only when a category's level goes UP since the app last
///   looked (ok -> close, ok -> over, close -> over), never for staying there;
/// - the level is the one the budget screen shows ([BudgetStatus.level]);
/// - what the recurring rules alone cause (the rent that appears on the first
///   of the month) is expected, so it is never news: only spending above that
///   level is.

/// A category that has just reached a higher budget level than before (never
/// [BudgetLevel.ok]).
class BudgetAlert {
  const BudgetAlert({
    required this.categoryId,
    required this.level,
    required this.spent,
    required this.limit,
  });

  final String categoryId;
  final BudgetLevel level;
  final int spent;
  final int limit;

  /// Whole percent of the limit that is spent, rounded down (so "80 %" is never
  /// said of 79,9 %).
  int get percent => limit <= 0 ? 0 : spent * 100 ~/ limit;

  double get ratio => limit <= 0 ? 0 : spent / limit;

  @override
  bool operator ==(Object other) =>
      other is BudgetAlert &&
      other.categoryId == categoryId &&
      other.level == level &&
      other.spent == spent &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(categoryId, level, spent, limit);

  @override
  String toString() => 'BudgetAlert($categoryId, ${level.name}, $spent/$limit)';
}

/// The level each category with a budget had when the app last looked
/// (categories that are fine are left out). It follows the level down as well
/// as up: after the limit has been raised, or an expense deleted, a new
/// crossing is news again.
typedef BudgetMemory = Map<String, BudgetLevel>;

class BudgetAlertPlan {
  const BudgetAlertPlan({required this.alerts, required this.memory});

  /// What to tell the user, the most serious first.
  final List<BudgetAlert> alerts;

  /// What to remember for the next look.
  final BudgetMemory memory;
}

List<BudgetStatus> _statuses(
  Iterable<FinTx> txs,
  Iterable<FinBudget> budgets,
  int year,
  int month,
) => budgetStatus(budgets, monthSummary(txs, year, month));

/// The levels of [year]/[month] as they are now: what to remember when the
/// alerts are switched on, so that what is already over does not shout.
BudgetMemory currentBudgetLevels({
  required Iterable<FinTx> txs,
  required Iterable<FinBudget> budgets,
  required int year,
  required int month,
}) => {
  for (final s in _statuses(txs, budgets, year, month))
    if (s.level != BudgetLevel.ok) s.categoryId: s.level,
};

/// Which categories went up a level since [memory], and what to remember now.
BudgetAlertPlan planBudgetAlerts({
  required Iterable<FinTx> txs,
  required Iterable<FinBudget> budgets,
  required int year,
  required int month,
  required BudgetMemory memory,
}) {
  final all = _statuses(txs, budgets, year, month);
  // what the recurring rules alone spend: expected, so no news
  final planned = monthSummary(
    txs.where((t) => t.id.startsWith(recurringTxPrefix)),
    year,
    month,
  ).expenseByCategory;
  final alerts = <BudgetAlert>[];
  final next = <String, BudgetLevel>{};
  for (final s in all) {
    final level = s.level;
    if (level == BudgetLevel.ok) continue;
    next[s.categoryId] = level;
    final seen = memory[s.categoryId] ?? BudgetLevel.ok;
    final expected = BudgetStatus(
      categoryId: s.categoryId,
      limit: s.limit,
      spent: planned[s.categoryId] ?? 0,
    ).level;
    final known = seen.index >= expected.index ? seen : expected;
    if (level.index > known.index) {
      alerts.add(
        BudgetAlert(
          categoryId: s.categoryId,
          level: level,
          spent: s.spent,
          limit: s.limit,
        ),
      );
    }
  }
  // over before close, then the one furthest gone, then by name for a stable
  // order
  alerts.sort((a, b) {
    final byLevel = b.level.index.compareTo(a.level.index);
    if (byLevel != 0) return byLevel;
    final byRatio = b.ratio.compareTo(a.ratio);
    return byRatio != 0 ? byRatio : a.categoryId.compareTo(b.categoryId);
  });
  return BudgetAlertPlan(alerts: alerts, memory: next);
}

// ------------------------------------------------------------------ memory

/// "2026-11": the month a [BudgetMemory] belongs to.
String budgetMonthKey(int year, int month) =>
    '$year-${month.toString().padLeft(2, '0')}';

/// The memory as the text kept on the device; null when there is nothing to
/// remember.
String? encodeBudgetMemory(BudgetMemory memory) {
  if (memory.isEmpty) return null;
  final ids = memory.keys.toList()..sort();
  return jsonEncode({
    for (final id in ids) id: memory[id] == BudgetLevel.over ? 2 : 1,
  });
}

/// Reads [encodeBudgetMemory]'s text back; anything unreadable is no memory.
BudgetMemory decodeBudgetMemory(String? text) {
  if (text == null) return {};
  try {
    final j = jsonDecode(text);
    if (j is! Map) return {};
    final out = <String, BudgetLevel>{};
    j.forEach((id, v) {
      if (v == 1) out[id] = BudgetLevel.warn;
      if (v == 2) out[id] = BudgetLevel.over;
    });
    return out;
  } catch (_) {
    return {};
  }
}

// ---------------------------------------------------------------- messages

/// A notification to show. [key] says what it is about (the category id, or
/// [budgetSummaryKey]): the device derives the notification's id from it and
/// the month, so the same news replaces itself instead of piling up.
class BudgetMessage {
  const BudgetMessage({
    required this.key,
    required this.title,
    required this.body,
  });
  final String key;
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is BudgetMessage &&
      other.key == key &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(key, title, body);

  @override
  String toString() => 'BudgetMessage($key, $title, $body)';
}

/// The key of the one message that tells about several categories.
const budgetSummaryKey = '*';

/// More alerts than this at once (a bank statement pushing five categories
/// over) are told in one message instead of a burst of notifications.
const maxSeparateBudgetAlerts = 3;

/// How many categories the combined message lists before "and N more".
const maxSummaryLines = 6;

BudgetMessage budgetAlertMessage(BudgetAlert a, String name) => BudgetMessage(
  key: a.categoryId,
  title: 'Költségkeret: $name',
  body: a.level == BudgetLevel.over
      ? 'Túllépted a keretet: ${formatHuf(a.spent)} / ${formatHuf(a.limit)} '
            '(+${formatHuf(a.spent - a.limit)}).'
      : 'A keret ${a.percent}%-a elfogyott: ${formatHuf(a.spent)} / '
            '${formatHuf(a.limit)}.',
);

/// What to show for [alerts] (as [planBudgetAlerts] orders them): one message
/// each, or - past [maxSeparateBudgetAlerts] - a single list.
List<BudgetMessage> budgetAlertMessages(
  List<BudgetAlert> alerts,
  String Function(String categoryId) nameOf,
) {
  if (alerts.length <= maxSeparateBudgetAlerts) {
    return [
      for (final a in alerts) budgetAlertMessage(a, nameOf(a.categoryId)),
    ];
  }
  final lines = [
    for (final a in alerts.take(maxSummaryLines))
      '${nameOf(a.categoryId)}: '
          '${a.level == BudgetLevel.over ? 'túllépve' : '${a.percent}%'}',
  ];
  final more = alerts.length - lines.length;
  if (more > 0) lines.add('…és még $more');
  return [
    BudgetMessage(
      key: budgetSummaryKey,
      title: 'Költségkeret: ${alerts.length} kategória',
      body: lines.join('\n'),
    ),
  ];
}
