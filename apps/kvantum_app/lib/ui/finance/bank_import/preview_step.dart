part of '../bank_import_page.dart';

// Step 3 of the bank import: the look at what would be added (rates,
// categories, duplicates, ticks) and the import itself. Part of the library of
// the page.
extension _PreviewStep on _BankImportPageState {
  // ---------------------------------------------------------------- step 3

  Future<void> _toPreview() async {
    if (_busy) return;
    _set(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(financeRepoProvider);
    try {
      final data = _data;
      // (which currencies want a rate: the rows themselves are made below)
      final currencies = [...planBankImport(data, _mapping).rateWanted]..sort();
      for (final c in _rateFields.values) {
        c.dispose();
      }
      _rateFields.clear();
      _rates = {};
      for (final c in currencies) {
        final last = await repo.lastRate(c);
        _rateFields[c] = TextEditingController(
          text: last == null ? '' : formatRate(last),
        );
        if (last != null) _rates[c] = last;
      }
      _cats = sortCategories(await repo.categories());
      _knownIds = await repo.allTxIds();
      _existing = await repo.txs();
      _chosen.clear();
      _ticks.clear();
      _recompute();
      _remembered = await repo.merchantCategories({
        for (final r in _plan.rows) r.merchant,
      });
      // (rows of a currency without a rate are not in the plan yet)
      if (!mounted) return;
      _set(() => _stage = _Stage.preview);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  void _recompute() {
    _plan = planBankImport(
      _data,
      _mapping,
      rates: _rates,
      firstRowNumber: _headerRow + 2,
    );
    _dups = findDuplicates(_plan.rows, _knownIds, _existing);
  }

  void _rateChanged(String currency, String text) {
    final rate = parseRate(text);
    _set(() {
      if (rate == null) {
        _rates.remove(currency);
      } else {
        _rates[currency] = rate;
      }
      _recompute();
    });
    // (the categories remembered for merchants that only now are in the plan)
    ref
        .read(financeRepoProvider)
        .merchantCategories({for (final r in _plan.rows) r.merchant})
        .then((m) {
          if (mounted) _set(() => _remembered = m);
        });
  }

  /// Whether a row is to be added: not one that is in the books already, one
  /// that only looks like a duplicate only when asked for, and what the user
  /// ticked or unticked.
  bool _selected(ImportRow r) {
    if (_dups.known.contains(r.id)) return false;
    return _ticks[r.id] ?? !_dups.similar.containsKey(r.id);
  }

  void _toggle(ImportRow r, bool on) => _set(() => _ticks[r.id] = on);

  /// What a merchant is filed under: what was chosen now, else what was chosen
  /// for it last time.
  String _categoryFor(String merchant) =>
      _chosen[merchantKey(merchant)] ?? _remembered[merchant] ?? kUncategorized;

  Future<void> _chooseCategory(String merchant) async {
    final key = merchantKey(merchant);
    final current = _categoryFor(merchant);
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Kategória: $merchant'),
        children: [
          for (final (id, name) in [
            (kUncategorized, 'Besorolatlan'),
            for (final c in _cats) (c.id, c.name),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, id),
              child: Text(
                id == current ? '✓ $name' : name,
                style: id == current
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _set(() => _chosen[key] = picked);
  }

  Future<void> _import() async {
    // (a second tap finds the first one at work)
    if (_busy) return;
    final rows = [
      for (final r in _plan.rows)
        if (_selected(r)) r,
    ];
    // This page closes below: what the bar of "Visszavonás" needs is taken now.
    final repo = ref.read(financeRepoProvider);
    final undo = ref.read(undoServiceProvider);
    final site = UndoSite.of(context);
    final navigator = Navigator.of(context);
    _set(() {
      _busy = true;
      _error = null;
    });
    try {
      final marks = await repo.addImported([
        for (final r in rows) r.toTx(categoryId: _categoryFor(r.merchant)),
      ]);
      // what the user taught: the categories of merchants, the rates, the columns
      final merchantOf = {for (final r in rows) merchantKey(r.merchant): r};
      for (final e in _chosen.entries) {
        // (a merchant none of whose rows was added is not remembered; and
        // "Besorolatlan" is no category to remember: the store says so)
        final row = merchantOf[e.key];
        if (row != null) await repo.rememberMerchant(row.merchant, e.value);
      }
      for (final c in {
        for (final r in rows)
          if (r.foreign != null) r.foreign!.currency,
      }) {
        final rate = _rates[c];
        if (rate != null) await repo.rememberRate(c, rate);
      }
      await repo.rememberBankMapping(_header, _mapping);
      if (marks.isNotEmpty) {
        undo.offer(
          site,
          message: '${marks.length} tétel importálva',
          undo: () => repo.undoImport(marks),
        );
      }
      if (navigator.mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        _set(() {
          _busy = false;
          _error = 'Az importálás nem sikerült.';
        });
      }
    }
  }

  Widget _previewBody() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = [
      for (final r in _plan.rows)
        if (_selected(r)) r,
    ];
    final known = _plan.rows.where((r) => _dups.known.contains(r.id)).length;
    final similar = _plan.rows
        .where((r) => _dups.similar.containsKey(r.id))
        .length;
    // the merchants, most rows first
    final byMerchant = <String, List<ImportRow>>{};
    for (final r in selected) {
      if (r.merchant.isNotEmpty) {
        byMerchant.putIfAbsent(merchantKey(r.merchant), () => []).add(r);
      }
    }
    final merchants = byMerchant.values.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    // (a row that waits for a rate is not left out: it is told of by the rate)
    final waiting = _plan.issues
        .where((i) => i.problem == ImportProblem.missingRate)
        .length;
    final problems = [
      for (final i in _plan.issues)
        if (i.problem != ImportProblem.missingRate) i,
    ];
    final notes = [
      if (known > 0) '$known már megvan',
      if (similar > 0) '$similar hasonló van a könyvelésben',
      if (problems.isNotEmpty) '${problems.length} sor kimarad',
    ];

    final header = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${selected.length} tétel kerül be',
              key: const Key('bank-summary'),
              style: theme.textTheme.titleMedium,
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(notes.join(' · '), style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
      if (_rateFields.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A fájl idegen pénznemű tételeihez árfolyam kell '
                '(Ft egy egységért); a tétel forintértéke ebből jön ki.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final e in _rateFields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: Key('bank-rate-${e.key}'),
                    controller: e.value,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9 .,]')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Árfolyam (Ft / ${e.key})',
                      border: const OutlineInputBorder(),
                      errorText:
                          e.value.text.trim().isNotEmpty &&
                              _rates[e.key] == null
                          ? 'Adj meg árfolyamot (pl. 400)'
                          : null,
                    ),
                    onChanged: (t) => _rateChanged(e.key, t),
                  ),
                ),
              if (waiting > 0)
                Text(
                  '$waiting sor vár az árfolyamra.',
                  key: const Key('bank-waiting'),
                  style: TextStyle(color: scheme.error),
                ),
            ],
          ),
        ),
      if (merchants.isNotEmpty)
        ExpansionTile(
          key: const Key('bank-merchants'),
          title: Text('Kategóriák kereskedőnként (${merchants.length})'),
          subtitle: const Text('Amit itt választasz, a program megjegyzi.'),
          children: [
            for (final group in merchants.take(60))
              ListTile(
                dense: true,
                key: Key('bank-merchant-${merchantKey(group.first.merchant)}'),
                title: Text(group.first.merchant, maxLines: 1),
                subtitle: Text(
                  '${group.length} tétel · '
                  '${categoryName(_cats, _categoryFor(group.first.merchant))}',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _chooseCategory(group.first.merchant),
              ),
          ],
        ),
      if (problems.isNotEmpty)
        ExpansionTile(
          key: const Key('bank-issues'),
          title: Text('Kimaradó sorok (${problems.length})'),
          children: [
            for (final i in problems.take(_issuesShown))
              ListTile(
                dense: true,
                title: Text('${i.rowNumber}. sor: ${_issueText(i)}'),
              ),
            if (problems.length > _issuesShown)
              ListTile(
                dense: true,
                title: Text('… és még ${problems.length - _issuesShown}'),
              ),
          ],
        ),
      const Divider(height: 1),
    ];

    final rows = _plan.rows;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            key: const Key('bank-rows'),
            itemCount: header.length + rows.length,
            itemBuilder: (context, index) {
              if (index < header.length) return header[index];
              final r = rows[index - header.length];
              final isKnown = _dups.known.contains(r.id);
              final twin = _dups.similar[r.id];
              final category = categoryName(_cats, _categoryFor(r.merchant));
              return CheckboxListTile(
                key: Key('bank-row-${r.rowNumber}'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selected(r),
                onChanged: isKnown ? null : (v) => _toggle(r, v!),
                title: Text(
                  r.merchant.isEmpty
                      ? (r.note.isEmpty ? '(nincs név)' : r.note)
                      : r.merchant,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    fmtDate(r.date),
                    if (r.foreign != null) foreignLine(r.foreign!),
                    category,
                    if (isKnown)
                      'már megvan'
                    else if (twin != null)
                      'hasonló: ${twin.merchant.isEmpty ? 'tétel' : twin.merchant} '
                          '(${fmtDate(twin.date)})',
                  ].join(' · '),
                ),
                secondary: Text(
                  '${r.kind == FinKind.income ? '+' : '−'}'
                  '${formatHuf(r.amount)}',
                  style: TextStyle(
                    color: r.kind == FinKind.income ? scheme.primary : null,
                  ),
                ),
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          ),
        _bottomButton(
          FilledButton(
            key: const Key('bank-import'),
            onPressed: selected.isEmpty ? null : _import,
            child: Text('Importálás (${selected.length})'),
          ),
        ),
      ],
    );
  }
}
