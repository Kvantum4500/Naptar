import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'format.dart';
import 'quick_entry_dialog.dart' show showQuickEntry;
import 'repeat_editor.dart';
import 'undo_service.dart';

const _priorityLabels = {1: 'Alacsony', 2: 'Normál', 3: 'Magas'};

/// Tasks grouped by urgency; done tasks are collapsed at the bottom.
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider).value ?? const <TaskView>[];
    final today = ref.watch(todayProvider);
    final overdue = [
      for (final t in tasks)
        if (t.isOverdue(today)) t,
    ];
    final dueToday = [
      for (final t in tasks)
        if (!t.done && t.due == today) t,
    ];
    final upcoming = [
      for (final t in tasks)
        if (!t.done && t.due != null && t.due!.isAfter(today)) t,
    ];
    final undated = [
      for (final t in tasks)
        if (!t.done && t.due == null) t,
    ];
    final done = [
      for (final t in tasks)
        if (t.done) t,
    ];

    Widget section(String title, List<TaskView> list, {Color? color}) =>
        list.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  '$title (${list.length})',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: color),
                ),
              ),
              for (final t in list) _TaskTile(task: t, today: today),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Feladatok'),
        actions: [
          IconButton(
            key: const Key('tasks-quick-entry'),
            tooltip: 'Gyors felvitel',
            icon: const Icon(Icons.bolt),
            onPressed: () => showQuickEntry(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openTaskEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Új feladat'),
      ),
      body: tasks.isEmpty
          ? const Center(
              child: Text(
                'Még nincs feladat. Az „Új feladat” gombbal vehetsz fel egyet.',
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  children: [
                    section(
                      'Késésben',
                      overdue,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    section('Ma', dueToday),
                    section('Közelgő', upcoming),
                    section('Határidő nélkül', undated),
                    if (done.isNotEmpty)
                      ExpansionTile(
                        title: Text('Kész (${done.length})'),
                        children: [
                          for (final t in done)
                            _TaskTile(task: t, today: today),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task, required this.today});
  final TaskView task;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final overdue = task.isOverdue(today);
    final items =
        ref.watch(checklistsProvider).value?[task.id] ?? const <TaskView>[];
    final rule = task.repeatRule;
    final bits = <String>[
      if (task.due != null) 'Határidő: ${fmtDate(task.due!)}',
      if (rule != null && task.due != null) describeRepeat(rule, task.due!),
      if (items.isNotEmpty)
        '${items.where((i) => i.done).length}/${items.length} részfeladat',
      if (task.estimateMin != null)
        fmtDuration(Duration(minutes: task.estimateMin!)),
      'Energia: ${task.energyNeed}/5',
      if (task.priority == 3) 'Magas prioritás',
    ];
    return Column(
      key: Key('task-${task.id}'),
      children: [
        ListTile(
          leading: Checkbox(
            value: task.done,
            onChanged: (v) => _tick(context, ref, v == true, items),
          ),
          title: Text(
            task.title,
            style: TextStyle(
              decoration: task.done ? TextDecoration.lineThrough : null,
              color: task.done ? scheme.onSurfaceVariant : null,
            ),
          ),
          subtitle: Text(
            bits.join(' · '),
            style: TextStyle(color: overdue ? scheme.error : null),
          ),
          trailing: IconButton(
            tooltip: 'Törlés',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, items),
          ),
          onTap: () => openTaskEditor(context, ref, task: task),
        ),
        if (!task.done)
          for (final item in items)
            _ItemTile(
              item: item,
              onTap: () => openTaskEditor(context, ref, task: task),
            ),
      ],
    );
  }

  /// Ticks the task off, or takes the tick back. A task that repeats comes
  /// back with the next due date, and the bar says so (and can undo it).
  Future<void> _tick(
    BuildContext context,
    WidgetRef ref,
    bool done,
    List<TaskView> items,
  ) async {
    final ops = ref.read(taskOpsProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    final undo = ref.read(undoServiceProvider);
    final site = UndoSite.of(context);
    if (!done) {
      await ops.setDone(task, false);
      sync.requestSync();
      return;
    }
    final result = await ops.complete(task, today: today, items: items);
    sync.requestSync();
    final back = result.comesBack;
    if (back != null) {
      undo.offer(
        site,
        message: 'Kész – következő: ${fmtDate(back)}',
        undo: () async {
          await result.undo();
          sync.requestSync();
          return true;
        },
      );
    }
  }

  /// Deletes the task (and its checklist) at once; "Visszavonás" brings it back.
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    List<TaskView> items,
  ) async {
    // the row is gone as soon as the list refreshes: take what the undo needs now
    final ops = ref.read(taskOpsProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    final undo = ref.read(undoServiceProvider);
    final site = UndoSite.of(context);
    final ids = await ops.delete(task, items: items);
    sync.requestSync();
    undo.offer(
      site,
      message: items.isEmpty
          ? 'Feladat törölve'
          : 'Feladat és részfeladatai törölve',
      undo: () => ops.undelete(ids),
    );
  }
}

/// An item of a checklist, under its task.
class _ItemTile extends ConsumerWidget {
  const _ItemTile({required this.item, required this.onTap});
  final TaskView item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: Key('item-${item.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
        child: Row(
          children: [
            Checkbox(
              visualDensity: VisualDensity.compact,
              value: item.done,
              onChanged: (v) async {
                await ref.read(taskOpsProvider).setDone(item, v == true);
                ref.read(syncControllerProvider.notifier).requestSync();
              },
            ),
            Expanded(
              child: Text(
                item.title,
                style: TextStyle(
                  decoration: item.done ? TextDecoration.lineThrough : null,
                  color: item.done ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openTaskEditor(
  BuildContext context,
  WidgetRef ref, {
  TaskView? task,
  String? initialTitle,
  DateTime? initialDue,
  String? initialRule,
}) => showDialog<void>(
  context: context,
  builder: (_) => TaskEditor(
    task: task,
    initialTitle: initialTitle,
    initialDue: initialDue,
    initialRule: initialRule,
  ),
);

/// An item of the checklist as the editor holds it until "Mentés".
class _ItemDraft {
  _ItemDraft(this.original)
    : title = original?.title ?? '',
      done = original?.done ?? false;

  /// The stored item; null for one added in this editor.
  final TaskView? original;
  String title;
  bool done;
  bool removed = false;
  final key = UniqueKey();

  bool get changed =>
      original != null &&
      (title.trim() != original!.title || done != original!.done);
}

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({
    super.key,
    this.task,
    this.initialTitle,
    this.initialDue,
    this.initialRule,
  });
  final TaskView? task;

  /// For a new task made from a line of text (the quick entry's
  /// "Szerkesztés…"): what is already known.
  final String? initialTitle;
  final DateTime? initialDue;
  final String? initialRule;
  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title, _notes, _minutes;
  DateTime? _due;
  int? _estimate;
  late int _priority, _energy;
  String? _error;
  RecurrenceSpec? _spec;
  String? _rawRule; // a rule this editor cannot show: kept as it is
  late final List<_ItemDraft> _items;
  final _newItem = TextEditingController();

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? widget.initialTitle ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    _estimate = t?.estimateMin;
    _minutes = TextEditingController(
      text:
          _estimate == null ||
              const [15, 30, 45, 60, 90, 120].contains(_estimate)
          ? ''
          : '$_estimate',
    );
    _due = t?.due ?? (t == null ? widget.initialDue : null);
    _priority = t?.priority ?? 2;
    _energy = t?.energyNeed ?? 3;
    final rule = t?.repeatRule ?? (t == null ? widget.initialRule : null);
    if (rule != null && _due != null) {
      _spec = RecurrenceSpec.fromRrule(rule, _due!);
      if (_spec == null) _rawRule = rule;
    }
    _items = [
      for (final i
          in ref.read(checklistsProvider).value?[t?.id] ?? const <TaskView>[])
        _ItemDraft(i),
    ];
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _minutes.dispose();
    _newItem.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final today = ref.read(todayProvider);
    final init = _due ?? today;
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(init.year, init.month, init.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _due = DateTime.utc(d.year, d.month, d.day));
  }

  void _addItem() {
    final text = _newItem.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _items.add(_ItemDraft(null)..title = text);
      _newItem.clear();
    });
  }

  Future<void> _save() async {
    // what was typed into the "new item" field and not added yet is added
    _addItem();
    if (!_form.currentState!.validate()) return;
    if (_spec?.validate() != null) {
      setState(() => _error = _spec!.validate());
      return;
    }
    final custom = int.tryParse(_minutes.text.trim());
    try {
      final old = widget.task;
      final fields = taskFields(
        title: _title.text,
        notes: _notes.text,
        due: _due,
        estimateMin: _minutes.text.trim().isNotEmpty ? custom : _estimate,
        priority: _priority,
        energyNeed: _energy,
        done: old?.done ?? false,
        parent: old?.parentId,
        pos: old?.pos,
        repeat: _due == null
            ? null
            : (_spec != null ? _spec!.toRrule(_due!) : _rawRule),
      );
      final id = old?.id ?? const Uuid().v4();
      final ops = ref.read(taskOpsProvider);
      final records = ref.read(recordRepoProvider);
      await records.edit(kindTask, id, fields);
      // the checklist: what was removed, renamed or ticked, and what is new
      final base = ref.read(appClockProvider)().millisecondsSinceEpoch;
      var added = 0;
      for (final draft in _items) {
        final title = draft.title.trim();
        if (draft.removed || title.isEmpty) {
          if (draft.original != null) {
            await records.delete(kindTask, draft.original!.id);
          }
        } else if (draft.original == null) {
          await ops.addItem(
            id,
            title,
            pos: base + added++,
            id: const Uuid().v4(),
            done: draft.done,
          );
        } else if (draft.changed) {
          await records.edit(kindTask, draft.original!.id, {
            'title': title,
            'done': draft.done,
          });
        }
      }
      ref.read(syncControllerProvider.notifier).requestSync();
      if (mounted) Navigator.pop(context);
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.task != null;
    return AlertDialog(
      title: Text(editing ? 'Feladat szerkesztése' : 'Új feladat'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _title,
                  autofocus: !editing,
                  decoration: const InputDecoration(labelText: 'Cím'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Adj meg egy címet'
                      : null,
                ),
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Megjegyzés'),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickDue,
                      icon: const Icon(Icons.event),
                      label: Text(_due == null ? 'Határidő' : fmtDate(_due!)),
                    ),
                    if (_due != null)
                      IconButton(
                        tooltip: 'Határidő törlése',
                        onPressed: () => setState(() {
                          _due = null;
                          // (a rule is anchored on the due date)
                          _spec = null;
                          _rawRule = null;
                        }),
                        icon: const Icon(Icons.clear),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_due == null)
                  Text(
                    'Ismétlődéshez adj meg határidőt.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else if (_rawRule != null)
                  Text(
                    'Egyedi ismétlődés: ${describeRepeat(_rawRule!, _due!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  RepeatEditor(
                    start: _due!,
                    spec: _spec,
                    onChanged: (v) => setState(() => _spec = v),
                  ),
                const SizedBox(height: 12),
                Text(
                  'Becsült idő',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in const [15, 30, 45, 60, 90, 120])
                      ChoiceChip(
                        label: Text(fmtDuration(Duration(minutes: m))),
                        selected: _estimate == m && _minutes.text.isEmpty,
                        onSelected: (on) => setState(() {
                          _estimate = on ? m : null;
                          _minutes.clear();
                        }),
                      ),
                  ],
                ),
                TextFormField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'vagy percben (egyéb)',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final n = int.tryParse(v.trim());
                    return (n == null || n < 1 || n > 1440)
                        ? '1–1440 perc'
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Prioritás',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final e in _priorityLabels.entries)
                      ButtonSegment(value: e.key, label: Text(e.value)),
                  ],
                  selected: {_priority},
                  onSelectionChanged: (s) =>
                      setState(() => _priority = s.first),
                ),
                const SizedBox(height: 12),
                Text(
                  'Energiaigény (1 = kevés, 5 = sok)',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (var i = 1; i <= 5; i++)
                      ButtonSegment(value: i, label: Text('$i')),
                  ],
                  selected: {_energy},
                  onSelectionChanged: (s) => setState(() => _energy = s.first),
                ),
                const SizedBox(height: 12),
                Text(
                  'Részfeladatok',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final draft in _items)
                  if (!draft.removed)
                    Row(
                      key: draft.key,
                      children: [
                        Checkbox(
                          visualDensity: VisualDensity.compact,
                          value: draft.done,
                          onChanged: (v) =>
                              setState(() => draft.done = v == true),
                        ),
                        Expanded(
                          child: TextFormField(
                            initialValue: draft.title,
                            decoration: const InputDecoration(isDense: true),
                            onChanged: (v) => draft.title = v,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Részfeladat törlése',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => draft.removed = true),
                        ),
                      ],
                    ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newItem,
                        decoration: const InputDecoration(
                          labelText: 'Új részfeladat',
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _addItem(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Részfeladat hozzáadása',
                      icon: const Icon(Icons.add),
                      onPressed: _addItem,
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(onPressed: _save, child: const Text('Mentés')),
      ],
    );
  }
}
