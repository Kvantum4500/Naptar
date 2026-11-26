part of '../bank_import_page.dart';

// Step 2 of the bank import: which column is what (the page guesses), the
// sample rows, and the pickers. Part of the library of the page.
extension _MappingStep on _BankImportPageState {
  // ---------------------------------------------------------------- step 2

  String _colName(int i) {
    final h = i < _header.length ? _header[i].trim() : '';
    return h.isEmpty ? '${i + 1}. oszlop' : h;
  }

  String _colSample(int i) {
    for (final r in _data.take(50)) {
      if (i < r.length && r[i].trim().isNotEmpty) {
        final t = r[i].trim();
        return t.length > 24 ? '${t.substring(0, 24)}…' : t;
      }
    }
    return '';
  }

  void _setColumn(BankField f, int? column) {
    _set(() {
      if (column != null) {
        // (a column is one thing: it leaves what it was)
        for (final other in BankField.values) {
          if (other != f && _mapping[other] == column) _mapping[other] = null;
        }
      }
      _mapping[f] = column;
    });
  }

  void _setPairMode(bool pair) {
    if (pair == _pairMode) return;
    _set(() {
      _pairMode = pair;
      if (pair) {
        _mapping[BankField.amount] = null;
        _mapping[BankField.direction] = null;
        _mapping.invertSign = false;
      } else {
        _mapping[BankField.debit] = null;
        _mapping[BankField.credit] = null;
      }
    });
  }

  Future<void> _setHeaderRow(int row) async {
    _headerRow = row;
    await _guess();
    if (mounted) _set(() {});
  }

  /// A dropdown in a box with its name on the edge.
  Widget _boxed(String label, Widget dropdown) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(child: dropdown),
    ),
  );

  Widget _columnPicker(BankField f, String label, {bool required = false}) =>
      _boxed(
        required ? '$label *' : label,
        DropdownButton<int?>(
          key: Key('bank-col-${f.name}'),
          value: _mapping[f],
          isExpanded: true,
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('— nincs —')),
            for (var i = 0; i < _width; i++)
              DropdownMenuItem<int?>(
                value: i,
                child: Text(
                  [
                    _colName(i),
                    if (_colSample(i).isNotEmpty) _colSample(i),
                  ].join('  ·  '),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => _setColumn(f, v),
        ),
      );

  /// The first rows as the page reads them now.
  List<Widget> _sample() {
    final head = _data.take(40).toList();
    var plan = planBankImport(head, _mapping, firstRowNumber: _headerRow + 2);
    if (plan.rateWanted.isNotEmpty) {
      // (what a row in another currency was paid in is shown as it is; the
      // rate is asked for on the next page)
      plan = planBankImport(
        head,
        _mapping,
        rates: {for (final c in plan.rateWanted) c: 1.0},
        firstRowNumber: _headerRow + 2,
      );
    }
    final out = <Widget>[];
    for (final r in plan.rows.take(_sampleRows)) {
      out.add(
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            r.merchant.isEmpty ? '(nincs név)' : r.merchant,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${r.rowNumber}. sor · ${fmtDate(r.date)}'),
          trailing: Text(_signed(r)),
        ),
      );
    }
    if (out.isEmpty) {
      for (final i in plan.issues.take(_sampleRows)) {
        out.add(
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${i.rowNumber}. sor: ${_issueText(i)}'),
          ),
        );
      }
    }
    return out;
  }

  String _signed(ImportRow r) {
    final sign = r.kind == FinKind.income ? '+' : '−';
    final f = r.foreign;
    return f == null
        ? '$sign${formatHuf(r.amount)}'
        : '$sign${formatForeign(f.cents, f.currency)}';
  }

  String _issueText(ImportIssue i) => importProblemText(i.problem);

  String _delimiterName(String d) => switch (d) {
    ';' => 'pontosvessző',
    ',' => 'vessző',
    '\t' => 'tabulátor',
    _ => 'függőleges vonal',
  };

  String _encodingName(TextEncoding e) => switch (e) {
    TextEncoding.utf8 => 'UTF-8',
    TextEncoding.utf16le || TextEncoding.utf16be => 'UTF-16',
    TextEncoding.windows1250 => 'Windows-1250',
  };

  String _orderName(DateOrder o) => switch (o) {
    DateOrder.ymd => '2026-11-13  (év, hónap, nap)',
    DateOrder.dmy => '13.11.2026  (nap, hónap, év)',
    DateOrder.mdy => '11/13/2026  (hónap, nap, év)',
  };

  Widget _mapBody() {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final sample = _sample();
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text(
          '${_rows.length} sor · ${_encodingName(_decoded!.encoding)} · '
          'elválasztó: ${_delimiterName(_delimiter)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _boxed(
          'Fejléc sora',
          DropdownButton<int>(
            key: const Key('bank-header'),
            value: _headerRow,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: -1, child: Text('Nincs fejléc')),
              for (var i = 0; i < math.min(_rows.length - 1, 20); i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    '${i + 1}. sor: ${_rows[i].take(4).join(' · ')}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => _setHeaderRow(v!),
          ),
        ),
        const SizedBox(height: 4),
        Text('Melyik oszlop mi?', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'A * kötelező. A program kitalálta, nézd át.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _columnPicker(BankField.date, 'Dátum', required: true),
        _boxed(
          'Az összeg a fájlban',
          DropdownButton<bool>(
            key: const Key('bank-money-mode'),
            value: _pairMode,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: false,
                child: Text(
                  'Egy összegoszlop',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: true,
                child: Text(
                  'Terhelés és jóváírás külön',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: (v) => _setPairMode(v!),
          ),
        ),
        if (_pairMode) ...[
          _columnPicker(BankField.debit, 'Terhelés (kiadás)', required: true),
          _columnPicker(BankField.credit, 'Jóváírás (bevétel)', required: true),
        ] else ...[
          _columnPicker(BankField.amount, 'Összeg', required: true),
          _columnPicker(BankField.direction, 'Kiadás / bevétel jelzése'),
          if (_mapping[BankField.direction] == null)
            CheckboxListTile(
              key: const Key('bank-invert'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('A pozitív összeg kiadás'),
              subtitle: const Text(
                'Jelöld, ha a bank a kiadást plusz előjellel írja.',
              ),
              value: _mapping.invertSign,
              onChanged: (v) => _set(() => _mapping.invertSign = v!),
            ),
        ],
        _columnPicker(BankField.merchant, 'Kereskedő / partner'),
        _columnPicker(BankField.note, 'Megjegyzés / közlemény'),
        _columnPicker(BankField.currency, 'Pénznem (ha nem csak forint)'),
        _boxed(
          'A dátum alakja',
          DropdownButton<DateOrder>(
            key: const Key('bank-date-order'),
            value: _mapping.dateOrder,
            isExpanded: true,
            items: [
              for (final o in DateOrder.values)
                DropdownMenuItem(
                  value: o,
                  child: Text(_orderName(o), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _set(() => _mapping.dateOrder = v!),
          ),
        ),
        const SizedBox(height: 16),
        Text('Így olvassa az első sorokat', style: theme.textTheme.titleSmall),
        if (!_mapping.usable)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _pairMode
                  ? 'Válaszd ki a dátum, a terhelés és a jóváírás oszlopát.'
                  : 'Válaszd ki a dátum és az összeg oszlopát.',
              style: TextStyle(color: scheme.error),
            ),
          )
        else if (sample.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Nincs olvasható sor.'),
          )
        else
          Column(key: const Key('bank-sample'), children: sample),
      ],
    );
    return Column(
      children: [
        Expanded(child: list),
        _bottomButton(
          FilledButton(
            key: const Key('bank-next'),
            onPressed: _mapping.usable ? _toPreview : null,
            child: const Text('Tovább'),
          ),
        ),
      ],
    );
  }
}
