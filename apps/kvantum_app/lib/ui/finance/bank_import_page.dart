import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../backup/backup_file_io.dart';
import '../../providers.dart';
import '../format.dart';
import '../undo_service.dart';
import 'finance_editors.dart' show categoryName, sortCategories;

/// The most a bank file may be: the text is read on this device in one go.
const bankFileMaxBytes = 5 * 1024 * 1024;

/// The most rows it may have.
const bankFileMaxRows = 20000;

/// How many rows the first look at a mapping shows.
const _sampleRows = 3;

/// How many rows the page names when it says what it left out.
const _issuesShown = 100;

enum _Stage { pick, map, preview }

/// A bank's CSV file into the books, in three steps: choose the file, say which
/// column is what (the page guesses), look over what would be added and add it.
/// What the file says never leaves the device, and nothing is added before the
/// last button; "Visszavonás" takes an import back.
class BankImportPage extends ConsumerStatefulWidget {
  const BankImportPage({super.key});

  @override
  ConsumerState<BankImportPage> createState() => _BankImportPageState();
}

class _BankImportPageState extends ConsumerState<BankImportPage> {
  _Stage _stage = _Stage.pick;
  bool _busy = false;
  String? _error;

  // the file
  DecodedText? _decoded;
  String _delimiter = ';';
  List<List<String>> _rows = const [];
  int _width = 0;

  // the columns
  int _headerRow = -1;
  BankMapping _mapping = BankMapping();
  bool _pairMode = false;

  // the look at what would be added
  final _rateFields = <String, TextEditingController>{};
  Map<String, double> _rates = {};
  List<FinCategory> _cats = const [];
  Set<String> _knownIds = const {};
  List<FinTx> _existing = const [];
  Map<String, String> _remembered = const {};
  final _chosen = <String, String>{};
  final _ticks = <String, bool>{};
  BankImportPlan _plan = const BankImportPlan([], [], {});
  DuplicateReport _dups = const DuplicateReport({}, {});

  @override
  void dispose() {
    for (final c in _rateFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _header => _headerRow >= 0 && _headerRow < _rows.length
      ? _rows[_headerRow]
      : const [];

  List<List<String>> get _data => _rows.sublist(_headerRow + 1);

  // ---------------------------------------------------------------- step 1

  Future<void> _pick() async {
    setState(() => _error = null);
    final Uint8List? bytes;
    try {
      bytes = await ref
          .read(backupFileIoProvider)
          .pick(dialogTitle: 'Bank-kivonat (CSV) megnyitása');
    } catch (e) {
      if (mounted) setState(() => _error = 'A fájl megnyitása nem sikerült.');
      return;
    }
    if (bytes == null || !mounted) return;
    final problem = _problemWith(bytes);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final decoded = decodeText(bytes);
    final delimiter = detectDelimiter(decoded.text);
    final rows = parseCsv(
      decoded.text,
      delimiter,
      maxRows: bankFileMaxRows + 1,
    );
    if (rows.length > bankFileMaxRows) {
      setState(() => _error = 'A fájlnak legfeljebb 20 000 sora lehet.');
      return;
    }
    if (rows.length < 2 || rows.every((r) => r.length < 2)) {
      setState(
        () => _error =
            'Nem találok a fájlban táblázatot (legalább két sor, '
            'több oszlop kell).',
      );
      return;
    }
    _decoded = decoded;
    _delimiter = delimiter;
    _rows = rows;
    _width = rows.take(200).fold<int>(0, (m, r) => math.max(m, r.length));
    _headerRow = findHeaderRow(rows);
    await _guess();
    if (!mounted) return;
    setState(() => _stage = _Stage.map);
  }

  /// What is wrong with the bytes before anything is read, if anything.
  String? _problemWith(Uint8List bytes) {
    if (bytes.isEmpty) return 'A fájl üres.';
    if (bytes.length > bankFileMaxBytes) {
      return 'A fájl túl nagy (legfeljebb 5 MB lehet).';
    }
    // (what a zip file and a PDF file begin with: a text may begin with P)
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return 'Ez nem szöveges fájl, hanem Excel- vagy zip-fájl. Mentsd el '
          'CSV-ként (Excelben: Mentés másként → CSV), vagy töltsd le a bankból '
          'CSV-ként.';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      return 'Ez egy PDF. A bankból CSV-fájl kell.';
    }
    return null;
  }

  /// The columns of the file: what was chosen last time for a file with this
  /// header, else the guess.
  Future<void> _guess() async {
    final repo = ref.read(financeRepoProvider);
    final remembered = await repo.bankMapping(_header);
    _mapping = remembered ?? guessMapping(_header, _data);
    _pairMode = _mapping.hasPair;
  }

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
    setState(() {
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
    setState(() {
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
    if (mounted) setState(() {});
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
              onChanged: (v) => setState(() => _mapping.invertSign = v!),
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
            onChanged: (v) => setState(() => _mapping.dateOrder = v!),
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

  /// The button that goes on: always in reach, below the list.
  Widget _bottomButton(Widget button) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Align(alignment: Alignment.centerRight, child: button),
    ),
  );

  // ---------------------------------------------------------------- step 3

  Future<void> _toPreview() async {
    if (_busy) return;
    setState(() {
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
      setState(() => _stage = _Stage.preview);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    setState(() {
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
          if (mounted) setState(() => _remembered = m);
        });
  }

  /// Whether a row is to be added: not one that is in the books already, one
  /// that only looks like a duplicate only when asked for, and what the user
  /// ticked or unticked.
  bool _selected(ImportRow r) {
    if (_dups.known.contains(r.id)) return false;
    return _ticks[r.id] ?? !_dups.similar.containsKey(r.id);
  }

  void _toggle(ImportRow r, bool on) => setState(() => _ticks[r.id] = on);

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
    setState(() => _chosen[key] = picked);
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
    setState(() {
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
        setState(() {
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

  // ---------------------------------------------------------------- the page

  Widget _pickBody() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('CSV-fájl a bankból', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'Töltsd le a számlatörténetet CSV-ként a bank netbankjából vagy '
          'appjából, és válaszd ki itt. A fájl nem megy sehova: a program a '
          'gépen olvassa.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('bank-pick'),
          icon: const Icon(Icons.upload_file),
          label: const Text('CSV-fájl kiválasztása'),
          onPressed: _pick,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              key: const Key('bank-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'A következő lépésben megmondhatod, melyik oszlop mi; a legtöbbször '
          'már kitalálja. Az ékezetes (UTF-8) és a régi, Windows-1250 kódolású '
          'fájlt is olvassa; legfeljebb 5 MB és 20 000 sor lehet. Ami már '
          'megvan a könyvelésben, azt nem veszi fel még egyszer.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_stage) {
      _Stage.pick => _pickBody(),
      _Stage.map => _mapBody(),
      _Stage.preview => _previewBody(),
    };
    return PopScope(
      canPop: _stage == _Stage.pick,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // back goes one step back, not out of the page
        setState(() {
          _stage = _stage == _Stage.preview ? _Stage.map : _Stage.pick;
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Bank-kivonat importálása')),
        body: body,
      ),
    );
  }
}
