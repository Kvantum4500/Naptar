import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../a11y.dart';
import '../format.dart';
import '../text_scale.dart';
import '../theme.dart';
import 'finance_editors.dart';
import 'finance_tabs.dart';
import 'finance_trend_tab.dart';

/// The month the Pénzügyek tab is showing (the 1st, floating).
class FinMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final n = ref.read(todayProvider);
    return DateTime.utc(n.year, n.month, 1);
  }

  void shift(int months) =>
      state = DateTime.utc(state.year, state.month + months, 1);
}

final finMonthProvider = NotifierProvider<FinMonth, DateTime>(FinMonth.new);

/// Money: income / expense log, budgets, recurring items and savings goals.
class FinancePage extends ConsumerStatefulWidget {
  const FinancePage({super.key});

  @override
  ConsumerState<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends ConsumerState<FinancePage> {
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Default categories and this / last month's recurring items.
  Future<void> _prepare() async {
    final repo = ref.read(financeRepoProvider);
    await repo.ensureDefaults();
    final n = ref.read(todayProvider);
    final prev = DateTime.utc(n.year, n.month - 1, 1);
    await repo.ensureRecurring(prev.year, prev.month);
    await repo.ensureRecurring(n.year, n.month);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pénzügyek'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Áttekintés'),
              Tab(text: 'Trend'),
              Tab(text: 'Tételek'),
              Tab(text: 'Keretek'),
              Tab(text: 'Ismétlődők'),
              Tab(text: 'Célok'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            OverviewTab(),
            TrendTab(),
            TransactionsTab(),
            BudgetsTab(),
            RecurringTab(),
            GoalsTab(),
          ],
        ),
      ),
    );
  }
}

/// Month switcher shared by the overview and the transaction list.
class MonthBar extends ConsumerWidget {
  const MonthBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(finMonthProvider);
    final notifier = ref.read(finMonthProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Előző hónap',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => notifier.shift(-1),
        ),
        SizedBox(
          width: 170,
          child: Text(
            DateFormat('y. MMMM', 'hu').format(DateTime(m.year, m.month)),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          tooltip: 'Következő hónap',
          icon: const Icon(Icons.chevron_right),
          onPressed: () => notifier.shift(1),
        ),
      ],
    );
  }
}

Color levelColor(BuildContext context, BudgetLevel l) => switch (l) {
  BudgetLevel.ok => statusColorsOf(context).ok,
  BudgetLevel.warn => statusColorsOf(context).warn,
  BudgetLevel.over => Theme.of(context).colorScheme.error,
};

/// The mark that goes with a level, so the colour is not the only signal.
IconData levelIcon(BudgetLevel l) => switch (l) {
  BudgetLevel.ok => Icons.check_circle_outline,
  BudgetLevel.warn => Icons.warning_amber_outlined,
  BudgetLevel.over => Icons.error_outline,
};

/// The line under a budget bar: the level in words (the colour and the mark
/// are not the only signal).
String budgetHint(BudgetStatus b) => switch (b.level) {
  BudgetLevel.over => 'Túllépve: ${formatHuf(-b.remaining)}',
  BudgetLevel.warn => 'Közel a kerethez – maradt: ${formatHuf(b.remaining)}',
  BudgetLevel.ok => 'Maradt: ${formatHuf(b.remaining)}',
};

class OverviewTab extends ConsumerWidget {
  const OverviewTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(finMonthProvider);
    final txs = ref.watch(finTxProvider).value ?? const <FinTx>[];
    final cats = ref.watch(finCategoriesProvider).value ?? const [];
    final budgets = ref.watch(finBudgetsProvider).value ?? const [];
    final s = monthSummary(txs, month.year, month.month);
    final status = budgetStatus(budgets, s);
    final budgeted = {for (final b in status) b.categoryId};
    final unbudgeted = [
      for (final e in s.expenseByCategory.entries)
        if (!budgeted.contains(e.key)) e,
    ]..sort((a, b) => b.value.compareTo(a.value));
    final uncategorized = [
      for (final t in txs)
        if (!t.deleted &&
            t.categoryId == kUncategorized &&
            t.date.year == month.year &&
            t.date.month == month.month)
          t,
    ];
    final sync = ref.watch(syncControllerProvider);
    final signedIn = sync.signedIn;
    final scheme = Theme.of(context).colorScheme;

    final amountStyle = Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight: FontWeight.w600);
    final summary = [
      ('Bevétel', s.income, statusColorsOf(context).ok),
      ('Kiadás', s.expense, scheme.error),
      (
        'Egyenleg',
        s.balance,
        s.balance >= 0 ? statusColorsOf(context).ok : scheme.error,
      ),
    ];

    // Three cards side by side where the biggest amount fits in one (card
    // padding 12 + 12, margin 4 + 4); at a large text size, one card with the
    // three lines under each other.
    Widget summaryCards() => LayoutBuilder(
      builder: (context, c) {
        final widest = summary
            .map((e) => textWidth(context, formatHuf(e.$2), amountStyle))
            .reduce((a, b) => a > b ? a : b);
        if (widest + 32 <= c.maxWidth / 3) {
          return Row(
            children: [
              for (final (label, value, color) in summary)
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            formatHuf(value),
                            style: amountStyle?.copyWith(color: color),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (final (label, value, color) in summary)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text(label)),
                        Text(
                          formatHuf(value),
                          style: amountStyle?.copyWith(color: color),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const MonthBar(),
        summaryCards(),
        if (uncategorized.isNotEmpty)
          Card(
            color: scheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text('${uncategorized.length} besorolatlan tétel'),
              subtitle: const Text(
                'A Tételek fülön koppints rájuk, és válassz kategóriát.',
              ),
            ),
          ),
        if (status.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(
              'Költségkeretek',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final b in status)
            _BarRow(
              label: categoryName(cats, b.categoryId),
              right: '${formatHuf(b.spent)} / ${formatHuf(b.limit)}',
              ratio: b.ratio,
              color: levelColor(context, b.level),
              icon: levelIcon(b.level),
              hint: budgetHint(b),
              spoken: spokenBudget(
                b,
                categoryName(cats, b.categoryId),
                budgetHint(b),
              ),
            ),
        ],
        if (unbudgeted.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(
              'Kiadás keret nélkül',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final e in unbudgeted)
            _BarRow(
              label: categoryName(cats, e.key),
              right: formatHuf(e.value),
              ratio: s.expense == 0 ? 0 : e.value / s.expense,
              color: scheme.primary,
              spoken: spokenShare(
                categoryName(cats, e.key),
                e.value,
                s.expense == 0 ? 0 : e.value / s.expense,
              ),
            ),
        ],
        if (s.income == 0 && s.expense == 0)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Ebben a hónapban még nincs tétel. A Tételek fülön a + gombbal vehetsz fel újat.',
              textAlign: TextAlign.center,
            ),
          ),
        const SizedBox(height: 16),
        Text(
          signedIn
              ? 'Az adatok ezen az eszközön vannak elmentve, a változások „levélben” átmennek a másik eszközre is (a Drive-ban csak a még át nem vett levelek vannak). ${sync.financeNote ?? ''}'
              : 'Az adatok csak ezen az eszközön vannak. Belépve a változások átmennek a másik eszközre is.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          'A Drive-ban nincs teljes másolat: időnként készíts mentést a Beállítások → Mentés és visszaállítás oldalon.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.right,
    required this.ratio,
    required this.color,
    required this.spoken,
    this.icon,
    this.hint,
  });
  final String label;
  final String right;
  final double ratio;
  final Color color;

  /// The whole row as one sentence for a screen reader (the row is one stop,
  /// not five: label, amounts, bar, hint).
  final String spoken;

  /// A mark beside the label (budget rows), so the colour is not alone.
  final IconData? icon;
  final String? hint;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: spoken,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The label and the amounts side by side where both fit on one
            // line; the amounts under the label where they do not (a large
            // text size breaks a name in the middle of its word otherwise).
            LayoutBuilder(
              builder: (context, c) {
                final small = Theme.of(context).textTheme.bodySmall;
                final sideBySide =
                    (icon == null ? 0 : 24) +
                        textWidth(
                          context,
                          label,
                          DefaultTextStyle.of(context).style,
                        ) +
                        8 +
                        textWidth(context, right, small) <=
                    c.maxWidth;
                final head = Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 6),
                    ],
                    Expanded(child: Text(label)),
                    if (sideBySide) Text(right, style: small),
                  ],
                );
                if (sideBySide) return head;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    head,
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(right, style: small),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              color: color,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            if (hint != null)
              Text(hint!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}

class TransactionsTab extends ConsumerWidget {
  const TransactionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(finMonthProvider);
    final all = ref.watch(finTxProvider).value ?? const <FinTx>[];
    final cats = ref.watch(finCategoriesProvider).value ?? const [];
    final scheme = Theme.of(context).colorScheme;
    final list =
        [
          for (final t in all)
            if (t.date.year == month.year && t.date.month == month.month) t,
        ]..sort((a, b) {
          final c = b.date.compareTo(a.date);
          return c != 0 ? c : b.updatedAt.compareTo(a.updatedAt);
        });

    final children = <Widget>[const MonthBar()];
    DateTime? last;
    for (final t in list) {
      if (last != t.date) {
        last = t.date;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Text(
              fmtDateLong(t.date),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        );
      }
      final income = t.kind == FinKind.income;
      children.add(
        ListTile(
          dense: true,
          leading: Icon(
            switch (t.source) {
              FinSource.wallet => Icons.account_balance_wallet_outlined,
              FinSource.recurring => Icons.event_repeat,
              FinSource.manual => income ? Icons.south_west : Icons.north_east,
            },
            color: income ? statusColorsOf(context).ok : scheme.error,
            semanticLabel: income ? 'Bevétel' : 'Kiadás',
          ),
          title: Text(
            t.merchant.isEmpty ? categoryName(cats, t.categoryId) : t.merchant,
          ),
          subtitle: Text(
            [
              if (t.merchant.isNotEmpty) categoryName(cats, t.categoryId),
              if (t.note.isNotEmpty) t.note,
            ].join(' · '),
          ),
          trailing: Text(
            '${income ? '+' : '-'}${formatHuf(t.amount)}',
            style: TextStyle(
              color: income ? statusColorsOf(context).ok : scheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          onTap: () => editTx(context, existing: t),
        ),
      );
    }
    if (list.isEmpty) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Nincs tétel ebben a hónapban.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Új tétel',
        onPressed: () {
          final n = ref.read(todayProvider);
          final inMonth = month.year == n.year && month.month == n.month;
          editTx(
            context,
            day: inMonth
                ? DateTime.utc(n.year, n.month, n.day)
                : DateTime.utc(month.year, month.month, 1),
          );
        },
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: children,
      ),
    );
  }
}
