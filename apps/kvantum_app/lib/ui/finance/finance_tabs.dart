import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../providers.dart';
import '../format.dart';
import 'finance_editors.dart';

// ------------------------------------------------------------------ budgets

class BudgetsTab extends ConsumerWidget {
  const BudgetsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = sortCategories(
      ref.watch(finCategoriesProvider).value ?? const <FinCategory>[],
    );
    final budgets = {
      for (final b
          in ref.watch(finBudgetsProvider).value ?? const <FinBudget>[])
        b.categoryId: b,
    };
    final repo = ref.read(financeRepoProvider);
    final expense = [
      for (final c in cats)
        if (c.kind == FinKind.expense) c,
    ];
    final income = [
      for (final c in cats)
        if (c.kind == FinKind.income) c,
    ];

    Future<void> addCategory(FinKind kind) async {
      final name = await askText(
        context,
        title: kind == FinKind.expense
            ? 'Új kiadási kategória'
            : 'Új bevételi kategória',
      );
      if (name == null) return;
      await repo.saveCategory(
        FinCategory(id: 'cat-${repo.newId()}', name: name, kind: kind),
      );
    }

    Future<void> rename(FinCategory c) async {
      final name = await askText(
        context,
        title: 'Kategória átnevezése',
        initial: c.name,
      );
      if (name != null) await repo.saveCategory(c.copyWith(name: name));
    }

    Future<void> remove(FinCategory c) async {
      final ok = await repo.deleteCategory(c.id);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'A(z) „${c.name}” kategóriát tételek vagy ismétlődők használják, ezért nem törölhető. Előbb sorold át őket.',
              ),
            ),
          );
      }
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Havi költségkeret kategóriánként. Az Áttekintésen látod, mennyit költöttél belőle.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final c in expense)
          ListTile(
            dense: true,
            title: Text(c.name),
            subtitle: Text(
              budgets[c.id] == null
                  ? 'Nincs keret'
                  : 'Havi keret: ${formatHuf(budgets[c.id]!.limit)}',
            ),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Keret beállítása',
                  icon: const Icon(Icons.savings_outlined),
                  onPressed: () async {
                    final v = await askAmount(
                      context,
                      title: 'Havi keret: ${c.name}',
                      initial: budgets[c.id]?.limit,
                      clearLabel: budgets[c.id] == null
                          ? null
                          : 'Keret törlése',
                    );
                    if (v == null) return;
                    if (v == -1) {
                      await repo.deleteBudget(c.id);
                    } else {
                      await repo.saveBudget(
                        (budgets[c.id] ?? FinBudget(categoryId: c.id, limit: v))
                            .copyWith(limit: v, deleted: false),
                      );
                    }
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: 'Kategória',
                  onSelected: (v) => v == 'rename' ? rename(c) : remove(c),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Átnevezés')),
                    PopupMenuItem(value: 'delete', child: Text('Törlés')),
                  ],
                ),
              ],
            ),
          ),
        TextButton.icon(
          onPressed: () => addCategory(FinKind.expense),
          icon: const Icon(Icons.add),
          label: const Text('Új kiadási kategória'),
        ),
        const Divider(),
        Text(
          'Bevételi kategóriák',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final c in income)
          ListTile(
            dense: true,
            title: Text(c.name),
            trailing: PopupMenuButton<String>(
              tooltip: 'Kategória',
              onSelected: (v) => v == 'rename' ? rename(c) : remove(c),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Átnevezés')),
                PopupMenuItem(value: 'delete', child: Text('Törlés')),
              ],
            ),
          ),
        TextButton.icon(
          onPressed: () => addCategory(FinKind.income),
          icon: const Icon(Icons.add),
          label: const Text('Új bevételi kategória'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- recurring

class RecurringTab extends ConsumerWidget {
  const RecurringTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules =
        ref.watch(finRecurringProvider).value ?? const <FinRecurring>[];
    final cats =
        ref.watch(finCategoriesProvider).value ?? const <FinCategory>[];
    final sorted = [...rules]
      ..sort((a, b) => a.dayOfMonth.compareTo(b.dayOfMonth));
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Új ismétlődő tétel',
        onPressed: () => _editRule(context, null),
        child: const Icon(Icons.add),
      ),
      body: sorted.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Itt vehetsz fel havonta ismétlődő tételeket (fizetés, lakbér, előfizetések). Maguktól megjelennek a Tételek között a megadott napon.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                for (final r in sorted)
                  ListTile(
                    leading: Icon(
                      r.kind == FinKind.income
                          ? Icons.south_west
                          : Icons.north_east,
                      color: r.kind == FinKind.income
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(r.title),
                    subtitle: Text(
                      'Minden hónap ${r.dayOfMonth}. napján · ${categoryName(cats, r.categoryId)}${r.active ? '' : ' · szünetel'}',
                    ),
                    trailing: Text(formatHuf(r.amount)),
                    onTap: () => _editRule(context, r),
                  ),
              ],
            ),
    );
  }
}

Future<void> _editRule(BuildContext context, FinRecurring? existing) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: _RuleEditor(existing: existing),
        ),
      ),
    );

class _RuleEditor extends ConsumerStatefulWidget {
  const _RuleEditor({this.existing});
  final FinRecurring? existing;

  @override
  ConsumerState<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends ConsumerState<_RuleEditor> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _amount = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.amount}',
  );
  late final _day = TextEditingController(
    text: '${widget.existing?.dayOfMonth ?? ref.read(todayProvider).day}',
  );
  late FinKind _kind = widget.existing?.kind ?? FinKind.expense;
  late String _cat = widget.existing?.categoryId ?? kUncategorized;
  late bool _active = widget.existing?.active ?? true;
  late DateTime _from =
      widget.existing?.fromMonth ??
      DateTime.utc(
        ref.read(todayProvider).year,
        ref.read(todayProvider).month,
        1,
      );
  late DateTime? _to = widget.existing?.toMonth;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _day.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickMonth(DateTime initial) async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Válassz egy napot a hónapból',
    );
    return d == null ? null : DateTime.utc(d.year, d.month, 1);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final amount = parseAmount(_amount.text);
    final day = int.tryParse(_day.text.trim());
    if (title.isEmpty) {
      setState(() => _error = 'Adj nevet a tételnek');
      return;
    }
    if (amount == null) {
      setState(() => _error = 'Adj meg egy pozitív összeget');
      return;
    }
    if (day == null || day < 1 || day > 31) {
      setState(() => _error = 'A nap 1 és 31 között legyen');
      return;
    }
    if (_to != null && _to!.isBefore(_from)) {
      setState(() => _error = 'A záró hónap nem lehet a kezdő előtt');
      return;
    }
    final repo = ref.read(financeRepoProvider);
    final base =
        widget.existing ??
        FinRecurring(
          id: repo.newId(),
          title: title,
          amount: amount,
          kind: _kind,
          categoryId: _cat,
          dayOfMonth: day,
          fromMonth: _from,
        );
    await repo.saveRecurring(
      base.copyWith(
        title: title,
        amount: amount,
        kind: _kind,
        categoryId: _cat,
        dayOfMonth: day,
        fromMonth: _from,
        toMonth: _to,
        clearToMonth: _to == null,
        active: _active,
      ),
    );
    final n = ref.read(todayProvider);
    await repo.ensureRecurring(n.year, n.month);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cats = sortCategories(
      ref.watch(finCategoriesProvider).value ?? const <FinCategory>[],
    );
    final shown = [
      for (final c in cats)
        if (c.kind == _kind) c,
    ];
    String month(DateTime d) =>
        DateFormat('y. MMMM', 'hu').format(DateTime(d.year, d.month));
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.existing == null
                        ? 'Új ismétlődő tétel'
                        : 'Ismétlődő tétel',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<FinKind>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: FinKind.expense,
                        label: Text('Kiadás'),
                      ),
                      ButtonSegment(
                        value: FinKind.income,
                        label: Text('Bevétel'),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (v) => setState(() {
                      _kind = v.first;
                      _cat = kUncategorized;
                    }),
                  ),
                  TextField(
                    controller: _title,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: 'Név (pl. Fizetés, Lakbér)',
                    ),
                  ),
                  TextField(
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                    ],
                    decoration: const InputDecoration(labelText: 'Összeg (Ft)'),
                  ),
                  TextField(
                    controller: _day,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'A hónap hányadik napján',
                      helperText: 'Rövidebb hónapban az utolsó napra esik',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Besorolatlan'),
                        selected: _cat == kUncategorized,
                        onSelected: (_) =>
                            setState(() => _cat = kUncategorized),
                      ),
                      for (final c in shown)
                        ChoiceChip(
                          label: Text(c.name),
                          selected: _cat == c.id,
                          onSelected: (_) => setState(() => _cat = c.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Mettől: '),
                      TextButton(
                        onPressed: () async {
                          final m = await _pickMonth(_from);
                          if (m != null) setState(() => _from = m);
                        },
                        child: Text(month(_from)),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Meddig: '),
                      TextButton(
                        onPressed: () async {
                          final m = await _pickMonth(_to ?? _from);
                          if (m != null) setState(() => _to = m);
                        },
                        child: Text(_to == null ? 'nincs vége' : month(_to!)),
                      ),
                      if (_to != null)
                        IconButton(
                          tooltip: 'Záró hónap törlése',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() => _to = null),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktív'),
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.existing != null)
                TextButton.icon(
                  onPressed: () async {
                    if (!await confirm(
                      context,
                      'Törlöd az ismétlődő tételt?',
                      'A már létrejött tételek megmaradnak, újak nem jönnek létre.',
                    )) {
                      return;
                    }
                    await ref
                        .read(financeRepoProvider)
                        .deleteRecurring(widget.existing!.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Törlés'),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Mégse'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('Mentés')),
            ],
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- goals

class GoalsTab extends ConsumerWidget {
  const GoalsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(finGoalsProvider).value ?? const <FinGoal>[];
    final deposits =
        ref.watch(finDepositsProvider).value ?? const <FinDeposit>[];
    final repo = ref.read(financeRepoProvider);
    final today = ref.watch(todayProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Új cél',
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: const _GoalEditor(),
            ),
          ),
        ),
        child: const Icon(Icons.add),
      ),
      body: goals.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Itt tűzhetsz ki megtakarítási célt (pl. nyaralás), és követheted az előrehaladást.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                for (final g in goals)
                  _GoalCard(
                    goal: g,
                    progress: goalProgress(g, deposits, today),
                    onDeposit: () async {
                      final v = await askAmount(
                        context,
                        title: 'Befizetés: ${g.name}',
                      );
                      if (v == null) return;
                      await repo.saveDeposit(
                        FinDeposit(
                          id: repo.newId(),
                          goalId: g.id,
                          date: ref.read(todayProvider),
                          amount: v,
                        ),
                      );
                    },
                    onDelete: () async {
                      if (await confirm(
                        context,
                        'Törlöd a célt?',
                        '„${g.name}” és a befizetései is törlődnek.',
                      )) {
                        await repo.deleteGoal(g.id);
                      }
                    },
                    onEdit: () => showDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: _GoalEditor(existing: g),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.progress,
    required this.onDeposit,
    required this.onDelete,
    required this.onEdit,
  });
  final FinGoal goal;
  final GoalProgress progress;
  final VoidCallback onDeposit;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    goal.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Cél szerkesztése',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: 'Cél törlése',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
            LinearProgressIndicator(
              value: p.ratio.clamp(0.0, 1.0),
              minHeight: 10,
              borderRadius: BorderRadius.circular(5),
              color: p.reached ? Colors.green : null,
            ),
            const SizedBox(height: 6),
            Text(
              '${formatHuf(p.saved)} / ${formatHuf(p.target)} (${(p.ratio * 100).round()}%)',
            ),
            if (p.reached)
              const Text('Cél elérve!', style: TextStyle(color: Colors.green))
            else ...[
              Text('Hátravan: ${formatHuf(p.remaining)}'),
              if (goal.deadline != null)
                Text('Határidő: ${fmtDate(goal.deadline!)}'),
              if (p.monthlyNeeded != null)
                Text(
                  'Havonta kb. ${formatHuf(p.monthlyNeeded!)} kellene félretenni.',
                ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onDeposit,
                icon: const Icon(Icons.add),
                label: const Text('Befizetés'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalEditor extends ConsumerStatefulWidget {
  const _GoalEditor({this.existing});
  final FinGoal? existing;

  @override
  ConsumerState<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<_GoalEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _target = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.target}',
  );
  late DateTime? _deadline = widget.existing?.deadline;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final target = parseAmount(_target.text);
    if (name.isEmpty) {
      setState(() => _error = 'Adj nevet a célnak');
      return;
    }
    if (target == null) {
      setState(() => _error = 'Adj meg egy pozitív összeget');
      return;
    }
    final repo = ref.read(financeRepoProvider);
    final base =
        widget.existing ??
        FinGoal(id: repo.newId(), name: name, target: target);
    await repo.saveGoal(
      base.copyWith(
        name: name,
        target: target,
        deadline: _deadline,
        clearDeadline: _deadline == null,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.existing == null ? 'Új cél' : 'Cél szerkesztése',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        TextField(
          controller: _name,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Név (pl. Nyaralás)'),
        ),
        TextField(
          controller: _target,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
          ],
          decoration: const InputDecoration(labelText: 'Célösszeg (Ft)'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(
                _deadline == null
                    ? 'Határidő (nem kötelező)'
                    : fmtDate(_deadline!),
              ),
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate:
                      _deadline ?? DateTime.now().add(const Duration(days: 90)),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (d != null) {
                  setState(
                    () => _deadline = DateTime.utc(d.year, d.month, d.day),
                  );
                }
              },
            ),
            if (_deadline != null)
              IconButton(
                tooltip: 'Határidő törlése',
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() => _deadline = null),
              ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Mégse'),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _save, child: const Text('Mentés')),
          ],
        ),
      ],
    ),
  );
}
