import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../providers.dart';
import '../backup_io.dart';
import '../charts.dart';
import '../theme.dart';
import 'finance_editors.dart';

/// The periods the trend can show, in months.
const trendRanges = <(int, String)>[
  (6, '6 hónap'),
  (12, '12 hónap'),
  (24, '24 hónap'),
];

/// "2026. március".
String trendMonthName(MonthTotal m) =>
    DateFormat('y. MMMM', 'hu').format(DateTime(m.year, m.month));

/// "2025.12." (the first month under a chart).
String trendMonthShort(MonthTotal m) =>
    '${m.year}.${m.month.toString().padLeft(2, '0')}.';

/// The line of one month for the table of data. A month with nothing in it
/// says so (it was most likely not written down: it is not "0 Ft spent").
String trendRow(MonthTotal m) => m.isEmpty
    ? '${trendMonthName(m)}: nincs rögzített tétel'
    : '${trendMonthName(m)}: bevétel ${formatHuf(m.income)} · '
          'kiadás ${formatHuf(m.expense)} · egyenleg ${formatHuf(m.balance)}';

/// What a screen reader says for a chart of one amount per month.
String trendBarsLabel(
  String what,
  List<MonthTotal> totals,
  int Function(MonthTotal) of,
) {
  final total = totals.fold<int>(0, (n, m) => n + of(m));
  final head = '$what az elmúlt ${totals.length} hónapban';
  if (total == 0) return '$head: nincs tétel.';
  var most = totals.first;
  for (final m in totals) {
    if (of(m) > of(most)) most = m;
  }
  return '$head: összesen ${formatHuf(total)}; a legtöbb '
      '${trendMonthName(most)}: ${formatHuf(of(most))}. '
      'Ebben a hónapban eddig ${formatHuf(of(totals.last))}.';
}

String _day(DateTime d) => DateFormat('y.MM.dd.', 'hu').format(d);

/// The amount of a subscription with its period.
String subscriptionAmount(Subscription s) =>
    '${formatHuf(s.amount)} / ${s.cadence == SubscriptionCadence.monthly ? 'hó' : 'év'}';

/// The line under the name of a subscription.
String subscriptionLine(Subscription s) =>
    '${s.cadence == SubscriptionCadence.monthly ? 'havonta' : 'évente'} · '
    'utoljára ${_day(s.lastDate)} · következő várhatóan ${_day(s.nextDate)}';

/// The words over the list of subscriptions.
String subscriptionTotal(List<Subscription> subs) {
  var month = 0, year = 0;
  for (final s in subs) {
    month += s.perMonth;
    year += s.perYear;
  }
  return 'Összesen kb. ${formatHuf(month)} havonta (évente ${formatHuf(year)}).';
}

/// The rule that books a subscription every month: on the day of its last
/// charge, from the month of the next one (the one that has been paid already
/// is not booked again).
FinRecurring subscriptionRule(Subscription s, String id) {
  final title = s.name.length > 60 ? s.name.substring(0, 60) : s.name;
  return FinRecurring(
    id: id,
    title: title,
    amount: s.amount,
    kind: FinKind.expense,
    categoryId: s.categoryId,
    dayOfMonth: s.lastDate.day,
    fromMonth: floating(s.nextDate.year, s.nextDate.month, 1),
  );
}

/// How the money went over the months: bars of what was spent and what came
/// in, a few lines in words, the subscriptions that were found, and the
/// export of the log for a spreadsheet.
class TrendTab extends ConsumerStatefulWidget {
  const TrendTab({super.key});

  @override
  ConsumerState<TrendTab> createState() => _TrendTabState();
}

class _TrendTabState extends ConsumerState<TrendTab> {
  int _months = 12;

  Widget _bars(
    BuildContext context,
    String what,
    List<MonthTotal> totals,
    int Function(MonthTotal) of, {
    required Key key,
    Color? color,
  }) {
    final largest = totals.fold<int>(0, (a, m) => of(m) > a ? of(m) : a);
    final top = niceMoneyMax(largest);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BarChart(
          key: key,
          values: [for (final m in totals) of(m).toDouble()],
          maxValue: top.toDouble(),
          maxLabel: compactHuf(top),
          firstLabel: trendMonthShort(totals.first),
          lastLabel: 'ez a hónap',
          semanticLabel: trendBarsLabel(what, totals, of),
          color: color,
        ),
        Text(
          'Forintban, hónaponként; a jobb szélső oszlop a mostani hónap, még nem kész.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _addRule(Subscription s) async {
    final repo = ref.read(financeRepoProvider);
    final today = ref.read(todayProvider);
    final rule = subscriptionRule(s, repo.newId());
    await repo.saveRecurring(rule);
    await repo.ensureRecurring(today.year, today.month);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Ismétlődő tétel felvéve: ${rule.title} – minden hónap '
          '${rule.dayOfMonth}. napján. Az Ismétlődők fülön szerkesztheted.',
        ),
      ),
    );
  }

  Future<void> _export() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Mit exportálsz?'),
        children: [
          SimpleDialogOption(
            key: const Key('export-month'),
            onPressed: () => Navigator.pop(c, 0),
            child: const Text('A mostani hónap tételeit'),
          ),
          SimpleDialogOption(
            key: const Key('export-range'),
            onPressed: () => Navigator.pop(c, 1),
            child: Text('A kijelzett időszakot ($_months hónap)'),
          ),
          SimpleDialogOption(
            key: const Key('export-all'),
            onPressed: () => Navigator.pop(c, 2),
            child: const Text('Minden tételt'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final today = ref.read(todayProvider);
    final txs = ref.read(finTxProvider).value ?? const <FinTx>[];
    final cats = ref.read(finCategoriesProvider).value ?? const <FinCategory>[];
    DateTime? from;
    final String name;
    switch (choice) {
      case 0:
        from = floating(today.year, today.month, 1);
        name =
            'kvantum-penzugyek-${today.year}-${today.month.toString().padLeft(2, '0')}.csv';
      case 1:
        final first = DateTime.utc(today.year, today.month - _months + 1, 1);
        from = floating(first.year, first.month, 1);
        name = 'kvantum-penzugyek-$_months-honap.csv';
      default:
        name = 'kvantum-penzugyek-osszes.csv';
    }
    final to = choice == 2 ? null : floating(today.year, today.month + 1, 0);
    final csv = exportTxCsv(
      txs,
      categoryName: (id) => categoryName(cats, id),
      from: from,
      to: to,
    );
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await ref
          .read(backupIoProvider)
          .save(
            name,
            csv,
            mimeType: 'text/csv',
            dialogTitle: 'Tételek exportálása',
          );
      if (saved) {
        messenger.showSnackBar(
          const SnackBar(content: Text('A tételek elmentve (CSV).')),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nem sikerült elmenteni a fájlt.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayProvider);
    final txs = ref.watch(finTxProvider).value ?? const <FinTx>[];
    final cats =
        ref.watch(finCategoriesProvider).value ?? const <FinCategory>[];
    final rules =
        ref.watch(finRecurringProvider).value ?? const <FinRecurring>[];
    final data = buildTrend(
      txs,
      today: today,
      months: _months,
      categoryName: (id) => categoryName(cats, id),
    );
    final subs = detectSubscriptions(
      txs,
      today: today,
      // (the rules come without the deleted ones)
      known: {for (final r in rules) subscriptionKey(r.title)},
    );
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          key: const Key('trend-range'),
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (months, label) in trendRanges)
              ChoiceChip(
                key: Key('trend-range-$months'),
                label: Text(label),
                selected: _months == months,
                onSelected: (_) => setState(() => _months = months),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!data.hasData)
          Card(
            key: const Key('trend-empty'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Még nincs elég adat. A Tételek fülön felvett kiadásokból és '
                'bevételekből itt látod hónapról hónapra, hogyan alakul a pénzed.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          )
        else ...[
          Card(
            key: const Key('trend-summary'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < data.summary.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        data.summary[i],
                        style: i == 0
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _Titled(
            'Havi kiadás',
            _bars(
              context,
              'Kiadás',
              data.totals,
              (m) => m.expense,
              key: const Key('trend-expense'),
            ),
          ),
          _Titled(
            'Havi bevétel',
            _bars(
              context,
              'Bevétel',
              data.totals,
              (m) => m.income,
              key: const Key('trend-income'),
              color: statusColorsOf(context).ok,
            ),
          ),
          if (subs.isNotEmpty)
            _Titled(
              'Előfizetések',
              Card(
                key: const Key('trend-subs'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subscriptionTotal(subs),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'A program a tételekből ismerte fel őket: ugyanaz a '
                        'kereskedő, nagyjából ugyanannyi, havonta vagy évente. '
                        'Nem biztos, hogy mind előfizetés.',
                        style: theme.textTheme.bodySmall,
                      ),
                      for (final s in subs) ...[
                        const Divider(height: 20),
                        Semantics(
                          container: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // (a wrap, not a row: at a large text size the
                              // price goes under the name instead of over the edge)
                              Wrap(
                                spacing: 12,
                                runSpacing: 2,
                                children: [
                                  Text(
                                    s.name,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  Text(subscriptionAmount(s)),
                                ],
                              ),
                              Text(
                                subscriptionLine(s),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (s.cadence == SubscriptionCadence.monthly)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              key: Key('sub-add-${s.key}'),
                              icon: const Icon(Icons.event_repeat, size: 18),
                              // (every subscription has this button: a screen
                              // reader is told which one it is for)
                              label: Text(
                                'Felvétel ismétlődőként',
                                semanticsLabel:
                                    'Felvétel ismétlődőként: ${s.name}',
                              ),
                              onPressed: () => _addRule(s),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          _Titled(
            'Adatok szövegesen',
            ExpansionTile(
              key: const Key('trend-table'),
              title: const Text('Hónapok számokkal'),
              children: [
                for (final m in data.totals.reversed)
                  ListTile(dense: true, title: Text(trendRow(m))),
              ],
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('trend-export'),
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Tételek exportálása (CSV)'),
            onPressed: _export,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'A fájlt táblázatkezelő nyitja (pontosvesszővel elválasztva, ékezetesen).',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Titled extends StatelessWidget {
  const _Titled(this.title, this.child);
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        child,
      ],
    ),
  );
}
