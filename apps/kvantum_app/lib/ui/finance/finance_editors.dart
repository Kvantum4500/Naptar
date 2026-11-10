import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../providers.dart';
import '../format.dart';

DateTime todayFloating() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day);
}

/// Display name of a category id ("Besorolatlan" for the fallback).
String categoryName(List<FinCategory> cats, String id) {
  if (id == kUncategorized) return 'Besorolatlan';
  for (final c in cats) {
    if (c.id == id) return c.name;
  }
  return 'Besorolatlan';
}

/// Default categories first in their usual order, own ones after, by name.
List<FinCategory> sortCategories(Iterable<FinCategory> cats) {
  final order = {for (final (i, c) in defaultCategories().indexed) c.id: i};
  return [...cats]..sort((a, b) {
    final x = order[a.id] ?? 1000, y = order[b.id] ?? 1000;
    return x != y ? x.compareTo(y) : a.name.compareTo(b.name);
  });
}

/// Digits only, to whole forints. Null when empty or zero.
int? parseAmount(String text) {
  final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty || digits.length > 11) return null;
  final n = int.parse(digits);
  return n > 0 ? n : null;
}

final _amountFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
];

/// Asks for one amount (e.g. a goal deposit or a budget). Null on cancel; -1
/// when the optional [clearLabel] button was pressed.
Future<int?> askAmount(
  BuildContext context, {
  required String title,
  int? initial,
  String? clearLabel,
}) => showDialog<int?>(
  context: context,
  builder: (_) =>
      _AmountDialog(title: title, initial: initial, clearLabel: clearLabel),
);

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.title, this.initial, this.clearLabel});
  final String title;
  final int? initial;
  final String? clearLabel;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  // owned by the dialog's state, so it is disposed only after the closing
  // animation has finished
  late final _c = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial}',
  );
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _c,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: _amountFormatters,
      decoration: InputDecoration(labelText: 'Összeg (Ft)', errorText: _error),
    ),
    actions: [
      if (widget.clearLabel != null)
        TextButton(
          onPressed: () => Navigator.pop(context, -1),
          child: Text(widget.clearLabel!),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Mégse'),
      ),
      FilledButton(
        onPressed: () {
          final v = parseAmount(_c.text);
          if (v == null) {
            setState(() => _error = 'Adj meg egy pozitív összeget');
            return;
          }
          Navigator.pop(context, v);
        },
        child: const Text('Mentés'),
      ),
    ],
  );
}

/// Asks for a short text. Null on cancel.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String label = 'Név',
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, label: label, initial: initial),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
  });
  final String title;
  final String label;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _c,
      autofocus: true,
      maxLength: 40,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Mégse'),
      ),
      FilledButton(
        onPressed: () {
          final t = _c.text.trim();
          if (t.isNotEmpty) Navigator.pop(context, t);
        },
        child: const Text('Mentés'),
      ),
    ],
  );
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Törlés'),
          ),
        ],
      ),
    ) ??
    false;

/// Opens the transaction editor (new when [existing] is null).
Future<void> editTx(BuildContext context, {FinTx? existing, DateTime? day}) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: TxEditor(existing: existing, day: day),
        ),
      ),
    );

class TxEditor extends ConsumerStatefulWidget {
  const TxEditor({super.key, this.existing, this.day});
  final FinTx? existing;
  final DateTime? day;

  @override
  ConsumerState<TxEditor> createState() => _TxEditorState();
}

class _TxEditorState extends ConsumerState<TxEditor> {
  late final _amount = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.amount}',
  );
  late final _merchant = TextEditingController(
    text: widget.existing?.merchant ?? '',
  );
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late FinKind _kind = widget.existing?.kind ?? FinKind.expense;
  late DateTime _date = widget.existing?.date ?? widget.day ?? todayFloating();
  late String _cat = widget.existing?.categoryId ?? kUncategorized;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = parseAmount(_amount.text);
    if (v == null) {
      setState(() => _error = 'Adj meg egy pozitív összeget');
      return;
    }
    final repo = ref.read(financeRepoProvider);
    final old = widget.existing;
    final t =
        (old ?? FinTx(id: repo.newId(), date: _date, amount: v, kind: _kind))
            .copyWith(
              date: _date,
              amount: v,
              kind: _kind,
              categoryId: _cat,
              merchant: _merchant.text.trim(),
              note: _note.text.trim(),
            );
    await repo.saveTx(t);
    // the next payment at the same merchant gets this category by itself
    if (t.merchant.isNotEmpty && t.categoryId != kUncategorized) {
      await repo.rememberMerchant(t.merchant, t.categoryId);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final old = widget.existing;
    if (old == null) return;
    if (!await confirm(context, 'Törlöd a tételt?', formatHuf(old.amount))) {
      return;
    }
    await ref.read(financeRepoProvider).deleteTx(old.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cats = sortCategories(
      ref.watch(finCategoriesProvider).value ?? const [],
    );
    final shown = [
      for (final c in cats)
        if (c.kind == _kind) c,
    ];
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
                    widget.existing == null ? 'Új tétel' : 'Tétel szerkesztése',
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
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amount,
                    autofocus: widget.existing == null,
                    keyboardType: TextInputType.number,
                    inputFormatters: _amountFormatters,
                    decoration: InputDecoration(
                      labelText: 'Összeg (Ft)',
                      errorText: _error,
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(fmtDate(_date)),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime(
                          _date.year,
                          _date.month,
                          _date.day,
                        ),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) {
                        setState(
                          () => _date = DateTime.utc(d.year, d.month, d.day),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Kategória'),
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
                  TextField(
                    controller: _merchant,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Kereskedő / honnan-hová',
                    ),
                  ),
                  TextField(
                    controller: _note,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: 'Megjegyzés'),
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
                  onPressed: _delete,
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
