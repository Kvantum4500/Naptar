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

part 'bank_import/mapping_step.dart';
part 'bank_import/preview_step.dart';

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

  // (the two steps live in extensions of their own files, which cannot call
  // the protected [setState] themselves)
  void _set(VoidCallback change) => setState(change);

  /// The button that goes on: always in reach, below the list.
  Widget _bottomButton(Widget button) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Align(alignment: Alignment.centerRight, child: button),
    ),
  );

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
