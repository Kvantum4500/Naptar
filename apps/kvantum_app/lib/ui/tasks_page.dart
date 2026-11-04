import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'format.dart';

DateTime _today() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day);
}

const _priorityLabels = {1: 'Alacsony', 2: 'Normál', 3: 'Magas'};

/// Tasks grouped by urgency; done tasks are collapsed at the bottom.
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider).value ?? const <TaskView>[];
    final today = _today();
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
      appBar: AppBar(title: const Text('Feladatok')),
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
    final bits = <String>[
      if (task.due != null) 'Határidő: ${fmtDate(task.due!)}',
      if (task.estimateMin != null)
        fmtDuration(Duration(minutes: task.estimateMin!)),
      'Energia: ${task.energyNeed}/5',
      if (task.priority == 3) 'Magas prioritás',
    ];
    return ListTile(
      leading: Checkbox(
        value: task.done,
        onChanged: (v) async {
          await ref.read(recordRepoProvider).edit(kindTask, task.id, {
            'done': v == true,
          });
          ref.read(syncControllerProvider.notifier).requestSync();
        },
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
          color: task.done ? scheme.outline : null,
        ),
      ),
      subtitle: Text(
        bits.join(' · '),
        style: TextStyle(color: overdue ? scheme.error : null),
      ),
      trailing: IconButton(
        tooltip: 'Törlés',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context, ref),
      ),
      onTap: () => openTaskEditor(context, ref, task: task),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Feladat törlése'),
        content: Text('Biztosan törlöd: „${task.title}”?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Törlés'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(recordRepoProvider).delete(kindTask, task.id);
    ref.read(syncControllerProvider.notifier).requestSync();
  }
}

Future<void> openTaskEditor(
  BuildContext context,
  WidgetRef ref, {
  TaskView? task,
}) => showDialog<void>(
  context: context,
  builder: (_) => TaskEditor(task: task),
);

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({super.key, this.task});
  final TaskView? task;
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

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    _estimate = t?.estimateMin;
    _minutes = TextEditingController(
      text:
          _estimate == null ||
              const [15, 30, 45, 60, 90, 120].contains(_estimate)
          ? ''
          : '$_estimate',
    );
    _due = t?.due;
    _priority = t?.priority ?? 2;
    _energy = t?.energyNeed ?? 3;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final init = _due ?? _today();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(init.year, init.month, init.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _due = DateTime.utc(d.year, d.month, d.day));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final custom = int.tryParse(_minutes.text.trim());
    try {
      final fields = taskFields(
        title: _title.text,
        notes: _notes.text,
        due: _due,
        estimateMin: _minutes.text.trim().isNotEmpty ? custom : _estimate,
        priority: _priority,
        energyNeed: _energy,
        done: widget.task?.done ?? false,
      );
      await ref
          .read(recordRepoProvider)
          .edit(kindTask, widget.task?.id ?? const Uuid().v4(), fields);
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
                        onPressed: () => setState(() => _due = null),
                        icon: const Icon(Icons.clear),
                      ),
                  ],
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
