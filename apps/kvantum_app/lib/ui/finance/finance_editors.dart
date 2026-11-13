import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../providers.dart';
import '../format.dart';
import '../undo_service.dart';

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

/// An amount in another currency or a rate: digits, a space, a point or a comma.
final _decimalFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9 .,]')),
];

// (the value of the "other currency" choice: it is not a code)
const _otherCurrency = '*';

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
    text: switch (widget.existing) {
      null => '',
      final t when t.foreign != null => plainCents(t.foreign!.cents),
      final t => '${t.amount}',
    },
  );
  late final _rate = TextEditingController(
    text: widget.existing?.foreign == null
        ? ''
        : formatRate(widget.existing!.foreign!.rate),
  );

  /// The currency it was paid in; empty for forints.
  late String _currency = widget.existing?.foreign?.currency ?? '';
  late final _merchant = TextEditingController(
    text: widget.existing?.merchant ?? '',
  );
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late FinKind _kind = widget.existing?.kind ?? FinKind.expense;
  late DateTime _date =
      widget.existing?.date ?? widget.day ?? ref.read(todayProvider);
  late String _cat = widget.existing?.categoryId ?? kUncategorized;
  String? _error;
  String? _rateError;

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  /// The forints a foreign amount is worth as it stands in the fields, or null
  /// when something is missing.
  int? get _forints {
    final cents = parseCents(_amount.text);
    final rate = parseRate(_rate.text);
    if (cents == null || cents <= 0 || rate == null) return null;
    return forintsFor(cents, rate);
  }

  Future<void> _chooseCurrency(String? choice) async {
    if (choice == null) return;
    var next = choice;
    if (choice == _otherCurrency) {
      final text = await askText(
        context,
        title: 'Másik pénznem',
        label: 'A pénznem kódja (pl. AUD)',
      );
      if (text == null || !mounted) return;
      final code = normalizeCurrency(text);
      if (code == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'A pénznem kódja három betű (pl. AUD), a forint nem.',
            ),
          ),
        );
        return;
      }
      next = code;
    }
    if (next == _currency) return;
    final was = _currency;
    final repo = ref.read(financeRepoProvider);
    setState(() {
      _currency = next;
      _error = null;
      _rateError = null;
      if (next.isEmpty) {
        // back to forints: what it was worth stands in the field
        final ft = _forints;
        _amount.text = ft == null ? '' : '$ft';
        // (the rate of the one left is not the rate of the next)
        _rate.clear();
      } else if (was.isEmpty) {
        // (the rate field is empty while the amount is in forints)
        _amount.clear();
      } else {
        _rate.clear();
      }
    });
    if (next.isNotEmpty) {
      // the rate last used for it is the first guess
      final rate = await repo.lastRate(next);
      if (mounted && _currency == next && _rate.text.isEmpty && rate != null) {
        setState(() => _rate.text = formatRate(rate));
      }
    }
  }

  Future<void> _save() async {
    final int amount;
    FinForeign? foreign;
    if (_currency.isEmpty) {
      final v = parseAmount(_amount.text);
      if (v == null) {
        setState(() => _error = 'Adj meg egy pozitív összeget');
        return;
      }
      amount = v;
    } else {
      final cents = parseCents(_amount.text);
      final rate = parseRate(_rate.text);
      if (cents == null || cents <= 0) {
        setState(() => _error = 'Adj meg egy pozitív összeget');
        return;
      }
      if (rate == null) {
        setState(() => _rateError = 'Adj meg árfolyamot (pl. 400)');
        return;
      }
      amount = forintsFor(cents, rate);
      if (amount < 1) {
        setState(() => _error = 'Forintban ez nem érné el az 1 Ft-ot');
        return;
      }
      if (cents > maxForeignCents || amount > 100000000000) {
        setState(() => _error = 'Túl nagy összeg');
        return;
      }
      foreign = FinForeign(currency: _currency, cents: cents, rate: rate);
    }
    final repo = ref.read(financeRepoProvider);
    final old = widget.existing;
    final t =
        (old ??
                FinTx(
                  id: repo.newId(),
                  date: _date,
                  amount: amount,
                  kind: _kind,
                ))
            .copyWith(
              date: _date,
              amount: amount,
              kind: _kind,
              categoryId: _cat,
              merchant: _merchant.text.trim(),
              note: _note.text.trim(),
              foreign: foreign,
              clearForeign: foreign == null,
            );
    await repo.saveTx(t);
    // the next payment in this currency starts from this rate
    if (foreign != null) {
      await repo.rememberRate(foreign.currency, foreign.rate);
    }
    // the next payment at the same merchant gets this category by itself
    if (t.merchant.isNotEmpty && t.categoryId != kUncategorized) {
      await repo.rememberMerchant(t.merchant, t.categoryId);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final old = widget.existing;
    if (old == null) return;
    // No question: "Visszavonás" takes it back. This dialog closes below, so
    // everything the undo needs is taken now.
    final repo = ref.read(financeRepoProvider);
    final undo = ref.read(undoServiceProvider);
    final site = UndoSite.of(context);
    final deleted = await repo.deleteTx(old.id);
    if (deleted.isNotEmpty) {
      undo.offer(
        site,
        message: 'Tétel törölve (${formatHuf(old.amount)})',
        undo: () => repo.undelete(deleted),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  Widget _currencyPicker() {
    final known = commonCurrencies.any((c) => c.$1 == _currency);
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Pénznem'),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('tx-currency'),
          value: _currency,
          isExpanded: true,
          isDense: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('Ft – forint')),
            for (final (code, name) in commonCurrencies)
              DropdownMenuItem(value: code, child: Text('$code – $name')),
            // (a code that was typed in: it stays in the list while it is
            // chosen)
            if (_currency.isNotEmpty && !known)
              DropdownMenuItem(value: _currency, child: Text(_currency)),
            const DropdownMenuItem(
              value: _otherCurrency,
              child: Text('Másik pénznem…'),
            ),
          ],
          onChanged: _chooseCurrency,
        ),
      ),
    );
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
                  _currencyPicker(),
                  TextField(
                    controller: _amount,
                    autofocus: widget.existing == null,
                    keyboardType: _currency.isEmpty
                        ? TextInputType.number
                        : const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: _currency.isEmpty
                        ? _amountFormatters
                        : _decimalFormatters,
                    decoration: InputDecoration(
                      labelText:
                          'Összeg (${_currency.isEmpty ? 'Ft' : _currency})',
                      errorText: _error,
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  if (_currency.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('tx-rate'),
                      controller: _rate,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: _decimalFormatters,
                      decoration: InputDecoration(
                        labelText: 'Árfolyam (Ft / $_currency)',
                        errorText: _rateError,
                      ),
                      onChanged: (_) => setState(() => _rateError = null),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _forints == null
                            ? 'Add meg az összeget és az árfolyamot.'
                            : '= ${formatHuf(_forints!)}',
                        key: const Key('tx-forints'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
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
          // (a wrap, not a row: on a narrow phone, and at a large text size,
          // the three buttons do not fit side by side; as wide as the room
          // there is, so that they stay at the right)
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.existing != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: TextButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Törlés'),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Mégse'),
                ),
                FilledButton(onPressed: _save, child: const Text('Mentés')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
