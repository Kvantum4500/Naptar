import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/backup/backup_file_io.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/finance/bank_import_page.dart';
import 'package:kvantum_app/ui/finance/finance_editors.dart'
    show sortCategories;
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/format.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

class _Picker implements BackupFileIo {
  Uint8List? bytes;
  int picks = 0;

  /// Whether choosing a file goes wrong.
  bool fail = false;

  @override
  Future<Uint8List?> pick({
    String dialogTitle = 'Mentés visszaállítása',
  }) async {
    picks++;
    if (fail) throw StateError('no picker');
    return bytes;
  }

  @override
  Future<bool> save(
    String fileName,
    Uint8List bytes, {
    String dialogTitle = 'Mentés fájlba',
  }) async => false;
}

Uint8List utf8Bytes(String text, {bool bom = false}) => Uint8List.fromList([
  if (bom) ...[0xEF, 0xBB, 0xBF],
  ...utf8.encode(text),
]);

/// The text as Windows-1250 writes it.
Uint8List cp1250Bytes(String text) {
  final reverse = {for (var i = 0; i < 128; i++) windows1250High[i]: 0x80 + i};
  return Uint8List.fromList([
    for (final u in text.runes) u < 0x80 ? u : reverse[u]!,
  ]);
}

/// The text as UTF-16 writes it, with its byte-order mark.
Uint8List utf16Bytes(String text, {bool bigEndian = false}) {
  final out = <int>[bigEndian ? 0xFE : 0xFF, bigEndian ? 0xFF : 0xFE];
  for (final u in text.codeUnits) {
    out.addAll(bigEndian ? [u >> 8, u & 0xFF] : [u & 0xFF, u >> 8]);
  }
  return Uint8List.fromList(out);
}

/// A store that can be made to fail, and that counts what the page asks for.
class _SpyRepo extends FinanceRepository {
  _SpyRepo(super.db);

  int txsCalls = 0;
  int failImports = 0;

  @override
  Future<List<FinTx>> txs() {
    txsCalls++;
    return super.txs();
  }

  @override
  Future<List<ImportMark>> addImported(List<FinTx> items) async {
    if (failImports > 0) {
      failImports--;
      throw StateError('no database');
    }
    return super.addImported(items);
  }
}

/// A statement the way a Hungarian bank might write it (the shape is a
/// plausible one; no real export was at hand): a line above the table, the
/// header, a semicolon, dates with points, amounts with a decimal comma.
const otpLike =
    'Számlakivonat;2026. november;;;;\n'
    'Könyvelés dátuma;Tranzakció típusa;Partner neve;Közlemény;Összeg;Devizanem\n'
    '2026.11.13;Kártyavásárlás;SPAR Magyarország Kft.;bevásárlás;-4 500,00;HUF\n'
    '2026.11.14;Kártyavásárlás;LIDL;;-1 200,00;HUF\n'
    '2026.11.15;Átutalás;Munkahely Kft.;fizetés;300 000,00;HUF\n'
    '2026.11.15;Kártyavásárlás;SPAR Magyarország Kft.;;-2 300,00;HUF\n';

/// Money out and money in in two columns, dates day first.
const twoColumns =
    'Tranzakció dátuma;Terhelés;Jóváírás;Partner neve;Közlemény\n'
    '13.11.2026;4 500;;SPAR;\n'
    '15.11.2026;;300 000;Munkahely;fizetés\n';

/// A card statement in English, with a currency column.
const cardLike =
    'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'CARD_PAYMENT,Current,2026-11-13 10:00:00,2026-11-13 10:05:00,Spar Wien,-12.40,0.00,EUR,COMPLETED,100.00\n'
    'CARD_PAYMENT,Current,2026-11-14 12:00:00,2026-11-14 12:01:00,Billa,-5.00,0.00,EUR,COMPLETED,95.00\n'
    'CARD_PAYMENT,Current,2026-11-15 12:00:00,2026-11-15 12:01:00,Lidl,-3000,0.00,HUF,COMPLETED,95.00\n';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late FinanceRepository repo;
  late _Picker picker;
  late _SpyRepo spy;

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(900, 1400),
    double? textScale,
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    spy = _SpyRepo(db);
    repo = spy;
    picker = _Picker();
    await tester.runAsync(repo.ensureDefaults);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BankImportPage(),
                  ),
                ),
                child: const Text('Import megnyitása'),
              ),
            ),
          ),
        ),
        db,
        textScale: textScale,
        extra: [
          financeRepoProvider.overrideWithValue(repo),
          backupFileIoProvider.overrideWithValue(picker),
          appClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 11, 18, 9),
          ),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          walletBridgeProvider.overrideWithValue(FakeWallet()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import megnyitása'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Uint8List bytes) async {
    picker.bytes = bytes;
    // (at a big text the button is further down the page)
    final button = find.byKey(const Key('bank-pick'));
    await tester.scrollUntilVisible(button, 200);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// The arrow of the bar (the system's back does the same).
  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('bank-next')));
    await tester.pumpAndSettle();
  }

  /// Reads the column a picker shows.
  int? column(WidgetTester tester, String field) => tester
      .widget<DropdownButton<int?>>(find.byKey(Key('bank-col-$field')))
      .value;

  /// Chooses an item of a column picker by a word of its text.
  Future<void> choose(WidgetTester tester, String field, String word) async {
    await tester.ensureVisible(find.byKey(Key('bank-col-$field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('bank-col-$field')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(word).last);
    await tester.pumpAndSettle();
  }

  /// Says whether the money is in one column or in two.
  Future<void> setMode(WidgetTester tester, String word) async {
    await tester.tap(find.byKey(const Key('bank-money-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(word).last);
    await tester.pumpAndSettle();
  }

  Future<List<FinTx>> txs(WidgetTester tester) async =>
      (await tester.runAsync(repo.txs))!;

  Future<void> importIt(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('bank-import')));
    await tester.pumpAndSettle();
  }

  Finder summary() => find.byKey(const Key('bank-summary'));

  group('the file', () {
    testWidgets('the page says what it does, and reads nothing before asked', (
      tester,
    ) async {
      await boot(tester);
      expect(find.text('Bank-kivonat importálása'), findsOneWidget);
      expect(find.text('CSV-fájl kiválasztása'), findsOneWidget);
      expect(find.textContaining('nem megy sehova'), findsOneWidget);
      expect(picker.picks, 0);
      await shutdown(tester, db);
    });

    testWidgets('no file chosen: nothing changes', (tester) async {
      await boot(tester);
      picker.bytes = null;
      await tester.tap(find.byKey(const Key('bank-pick')));
      await tester.pumpAndSettle();
      expect(picker.picks, 1);
      expect(find.byKey(const Key('bank-error')), findsNothing);
      expect(find.text('CSV-fájl kiválasztása'), findsOneWidget);
      await shutdown(tester, db);
    });

    for (final (name, bytes, words) in [
      ('an empty file', Uint8List(0), 'üres'),
      ('an Excel file', Uint8List.fromList([0x50, 0x4B, 3, 4, 0, 0]), 'Excel'),
      (
        'a PDF',
        Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31]),
        'PDF',
      ),
      ('a line of text', utf8Bytes('csak egy sor\n'), 'táblázatot'),
      ('a header without rows', utf8Bytes('Dátum;Összeg\n'), 'táblázatot'),
      ('text without cells', utf8Bytes('egy\nkettő\nhárom\n'), 'táblázatot'),
      ('a file that is too big', Uint8List(bankFileMaxBytes + 1), 'túl nagy'),
      (
        'a file of too many rows',
        utf8Bytes(List.generate(bankFileMaxRows + 1, (i) => 'a;$i').join('\n')),
        '20 000',
      ),
    ]) {
      testWidgets('$name is told why it is not read', (tester) async {
        await boot(tester);
        await pick(tester, bytes);
        final error = tester.widget<Text>(find.byKey(const Key('bank-error')));
        expect(error.data, contains(words));
        expect(find.byKey(const Key('bank-next')), findsNothing);
        await shutdown(tester, db);
      });
    }

    testWidgets('as many rows as are allowed are read', (tester) async {
      await boot(tester);
      final rows = [
        'Dátum;Összeg',
        ...List.generate(bankFileMaxRows - 1, (i) => '2026.11.13;-100'),
      ];
      await pick(tester, utf8Bytes(rows.join('\n')));
      expect(find.byKey(const Key('bank-error')), findsNothing);
      expect(find.byKey(const Key('bank-next')), findsOneWidget);
      expect(find.textContaining('$bankFileMaxRows sor'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('only what begins like a zip or a PDF is taken for one', (
      tester,
    ) async {
      await boot(tester);
      // (a text may begin with P, with PK, with %: it is no zip, no PDF)
      for (final bytes in [
        [0x50, 0x4B, 0x03, 0x05, 0, 0],
        [0x50, 0x4B, 0x04, 0x04, 0, 0],
        [0x51, 0x4B, 0x03, 0x04, 0, 0],
        [0x50, 0x4C, 0x03, 0x04, 0, 0],
        [0x25, 0x50, 0x44, 0x47, 0, 0],
        [0x25, 0x50, 0x45, 0x46, 0, 0],
        [0x26, 0x50, 0x44, 0x46, 0, 0],
        [0x25, 0x51, 0x44, 0x46, 0, 0],
        [0x50, 0x4B, 0x03],
        [0x25, 0x50, 0x44],
        [0x50],
      ]) {
        await pick(tester, Uint8List.fromList(bytes));
        final error = tester.widget<Text>(find.byKey(const Key('bank-error')));
        expect(error.data, contains('táblázatot'), reason: '$bytes');
      }
      // (and the signs themselves are enough, however short the file)
      await pick(tester, Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]));
      var told = tester.widget<Text>(find.byKey(const Key('bank-error'))).data;
      expect(told, contains('Excel'));
      expect(told, isNot(contains('PDF')));
      await pick(tester, Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));
      told = tester.widget<Text>(find.byKey(const Key('bank-error'))).data;
      expect(told, contains('PDF'));
      expect(told, isNot(contains('Excel')));
      await shutdown(tester, db);
    });

    testWidgets('a text that begins with a P is a text', (tester) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes('Partner;Dátum;Összeg\nSpar;2026.11.13;-100\n'),
      );
      expect(find.byKey(const Key('bank-error')), findsNothing);
      expect(find.byKey(const Key('bank-next')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a file of the largest size is read', (tester) async {
      await boot(tester);
      final head = utf8.encode('Dátum;Összeg;Megjegyzés\n2026.11.13;-100;');
      final bytes = Uint8List(bankFileMaxBytes)
        ..setAll(0, head)
        ..fillRange(head.length, bankFileMaxBytes, 0x78);
      await pick(tester, bytes);
      expect(find.byKey(const Key('bank-error')), findsNothing);
      expect(find.byKey(const Key('bank-next')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a header and one row are enough', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes('Dátum;Összeg\n2026.11.13;-100\n'));
      await next(tester);
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a line of one cell above the table is no matter', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes('Kivonat\nDátum;Összeg\n2026.11.13;-100\n'));
      expect(find.byKey(const Key('bank-error')), findsNothing);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
            .value,
        1,
      );
      await shutdown(tester, db);
    });

    testWidgets('how the file was read is told: the separator and the code', (
      tester,
    ) async {
      await boot(tester);
      const table = 'Dátum#Összeg\n2026.11.13#-100\n';
      for (final (bytes, words) in [
        (utf8Bytes(table.replaceAll('#', ';')), 'elválasztó: pontosvessző'),
        (utf8Bytes(table.replaceAll('#', ',')), 'elválasztó: vessző'),
        (utf8Bytes(table.replaceAll('#', '\t')), 'elválasztó: tabulátor'),
        (utf8Bytes(table.replaceAll('#', '|')), 'elválasztó: függőleges vonal'),
        (utf8Bytes(table.replaceAll('#', ';')), 'UTF-8'),
        (utf16Bytes(table.replaceAll('#', ';')), 'UTF-16'),
        (utf16Bytes(table.replaceAll('#', ';'), bigEndian: true), 'UTF-16'),
        (cp1250Bytes(table.replaceAll('#', ';')), 'Windows-1250'),
      ]) {
        await pick(tester, bytes);
        expect(find.textContaining(words), findsOneWidget, reason: words);
        expect(column(tester, 'date'), 0, reason: words);
        expect(column(tester, 'amount'), 1, reason: words);
        await back(tester);
      }
      await shutdown(tester, db);
    });

    testWidgets('a mistake in the reading is told, and the page goes on', (
      tester,
    ) async {
      await boot(tester);
      picker.fail = true;
      await tester.tap(find.byKey(const Key('bank-pick')));
      await tester.pumpAndSettle();
      expect(find.text('A fájl megnyitása nem sikerült.'), findsOneWidget);
      // (the next try goes through, and the mistake does not stay)
      picker.fail = false;
      await pick(tester, utf8Bytes(otpLike));
      expect(find.byKey(const Key('bank-next')), findsOneWidget);
      await back(tester);
      expect(find.byKey(const Key('bank-pick')), findsOneWidget);
      expect(find.byKey(const Key('bank-error')), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the columns', () {
    testWidgets('the file says what it is, and the columns are guessed', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      expect(
        find.textContaining('6 sor · UTF-8 · elválasztó: pontosvessző'),
        findsOneWidget,
      );
      expect(column(tester, 'date'), 0);
      expect(column(tester, 'amount'), 4);
      expect(column(tester, 'merchant'), 2);
      expect(column(tester, 'note'), 3);
      expect(column(tester, 'currency'), 5);
      expect(column(tester, 'direction'), isNull);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
            .value,
        1,
      );
      // (what is needed is starred)
      expect(find.text('Dátum *'), findsOneWidget);
      expect(find.text('Összeg *'), findsOneWidget);
      expect(find.text('Kereskedő / partner'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a byte-order mark is no part of the first cell', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike, bom: true));
      expect(column(tester, 'date'), 0);
      expect(find.textContaining('UTF-8'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the first rows are shown as they are read', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      final sample = find.byKey(const Key('bank-sample'));
      expect(sample, findsOneWidget);
      expect(
        find.descendant(
          of: sample,
          matching: find.text('SPAR Magyarország Kft.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sample, matching: find.text('−${formatHuf(4500)}')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sample,
          matching: find.text('3. sor · ${fmtDate(DateTime(2026, 11, 13))}'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('without a date or an amount the page asks, and waits', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await choose(tester, 'amount', 'nincs');
      expect(column(tester, 'amount'), isNull);
      expect(
        find.text('Válaszd ki a dátum és az összeg oszlopát.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bank-next')))
            .onPressed,
        isNull,
      );
      await choose(tester, 'amount', 'Összeg');
      expect(column(tester, 'amount'), 4);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bank-next')))
            .onPressed,
        isNotNull,
      );
      await shutdown(tester, db);
    });

    testWidgets('a column is one thing: it leaves what it was', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await choose(tester, 'merchant', 'Könyvelés dátuma');
      expect(column(tester, 'merchant'), 0);
      expect(column(tester, 'date'), isNull);
      // (and the others are where they were)
      expect(column(tester, 'amount'), 4);
      expect(column(tester, 'note'), 3);
      expect(column(tester, 'currency'), 5);
      await shutdown(tester, db);
    });

    testWidgets('the header row can be another', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      expect(
        find.textContaining('Könyvelés dátuma  ·  2026.11.13'),
        findsWidgets,
      );
      await tester.tap(find.byKey(const Key('bank-header')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1. sor: Számlakivonat').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
            .value,
        0,
      );
      // (the names of the columns are the cells of that row now)
      await tester.tap(find.byKey(const Key('bank-col-merchant')));
      await tester.pumpAndSettle();
      // (and what is under the name is the first cell under that row)
      expect(find.text('Számlakivonat  ·  Könyvelés dátuma'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('a file without a header is read by its cells', (tester) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          '2026.11.13;SPAR;-4 500\n2026.11.14;LIDL;-1 200\n2026.11.15;COOP;-900\n',
        ),
      );
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
            .value,
        -1,
      );
      expect(column(tester, 'date'), 0);
      expect(column(tester, 'amount'), 2);
      // (no header: the columns are told by their places, and a row is a row)
      await tester.tap(find.byKey(const Key('bank-col-merchant')));
      await tester.pumpAndSettle();
      expect(find.textContaining('2. oszlop'), findsWidgets);
      await tester.tap(find.textContaining('2. oszlop').last);
      await tester.pumpAndSettle();
      final sample = find.byKey(const Key('bank-sample'));
      expect(
        find.descendant(
          of: sample,
          matching: find.text('1. sor · ${fmtDate(DateTime(2026, 11, 13))}'),
        ),
        findsOneWidget,
      );
      await next(tester);
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('no header can be said, and the columns are guessed again', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await tester.tap(find.byKey(const Key('bank-header')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nincs fejléc').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
            .value,
        -1,
      );
      // (the words of the header are not there to tell the columns by)
      expect(column(tester, 'merchant'), isNot(2));
      await tester.tap(find.byKey(const Key('bank-col-merchant')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1. oszlop'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('money out and money in in two columns', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(twoColumns));
      expect(find.byKey(const Key('bank-col-debit')), findsOneWidget);
      expect(find.byKey(const Key('bank-col-credit')), findsOneWidget);
      expect(find.byKey(const Key('bank-col-amount')), findsNothing);
      expect(column(tester, 'debit'), 1);
      expect(column(tester, 'credit'), 2);
      // (the cell shown under a name is the first one that says something)
      expect(find.text('Terhelés  ·  4 500'), findsWidgets);
      expect(find.text('Jóváírás  ·  300 000'), findsWidgets);
      expect(
        tester
            .widget<DropdownButton<bool>>(
              find.byKey(const Key('bank-money-mode')),
            )
            .value,
        isTrue,
      );
      expect(find.byKey(const Key('bank-invert')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the mode of the money can be changed', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await setMode(tester, 'Terhelés és jóváírás külön');
      expect(find.byKey(const Key('bank-col-debit')), findsOneWidget);
      expect(find.byKey(const Key('bank-col-amount')), findsNothing);
      expect(
        find.text('Válaszd ki a dátum, a terhelés és a jóváírás oszlopát.'),
        findsOneWidget,
      );
      await setMode(tester, 'Egy összegoszlop');
      expect(find.byKey(const Key('bank-col-amount')), findsOneWidget);
      expect(find.byKey(const Key('bank-col-debit')), findsNothing);
      expect(column(tester, 'amount'), isNull);
      await shutdown(tester, db);
    });

    testWidgets('changing the mode of the money leaves the other mode clean', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      // a mark on the sign, then the other mode and back
      await tester.ensureVisible(find.byKey(const Key('bank-invert')));
      await tester.tap(find.byKey(const Key('bank-invert')));
      await tester.pumpAndSettle();
      await setMode(tester, 'Terhelés és jóváírás külön');
      await setMode(tester, 'Egy összegoszlop');
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('bank-invert')))
            .value,
        isFalse,
      );
      // a column that says the direction, then the other mode and back
      await choose(tester, 'direction', 'Tranzakció típusa');
      expect(column(tester, 'direction'), 1);
      await setMode(tester, 'Terhelés és jóváírás külön');
      await setMode(tester, 'Egy összegoszlop');
      expect(column(tester, 'direction'), isNull);
      // two columns, then one, and two again
      await setMode(tester, 'Terhelés és jóváírás külön');
      await choose(tester, 'debit', 'Összeg');
      await choose(tester, 'credit', 'Közlemény');
      expect(column(tester, 'debit'), 4);
      expect(column(tester, 'credit'), 3);
      await setMode(tester, 'Egy összegoszlop');
      await setMode(tester, 'Terhelés és jóváírás külön');
      expect(column(tester, 'debit'), isNull);
      expect(column(tester, 'credit'), isNull);
      await shutdown(tester, db);
    });

    testWidgets(
      'the names of the columns are the cells of the header, trimmed',
      (tester) async {
        await boot(tester);
        await pick(tester, utf8Bytes(' Dátum ; Összeg \n2026.11.13;-100\n'));
        expect(find.text('Dátum  ·  2026.11.13'), findsWidgets);
        expect(find.text('Összeg  ·  -100'), findsWidgets);
        await shutdown(tester, db);
      },
    );

    testWidgets('a cell is cut in the sample at twenty-four letters', (
      tester,
    ) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Partner;Összeg;Megjegyzés\n'
          '2026.11.13;ABCDEFGHIJKLMNOPQRSTUVWXYZ;-100;ABCDEFGHIJKLMNOPQRSTUVWX\n',
        ),
      );
      expect(find.text('Partner  ·  ABCDEFGHIJKLMNOPQRSTUVWX…'), findsWidgets);
      expect(
        find.text('Megjegyzés  ·  ABCDEFGHIJKLMNOPQRSTUVWX'),
        findsWidgets,
      );
      await shutdown(tester, db);
    });

    testWidgets('the table is as wide as its widest row', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes('Dátum;Összeg\n2026.11.13;-100;extra\n'));
      await tester.ensureVisible(find.byKey(const Key('bank-col-merchant')));
      await tester.tap(find.byKey(const Key('bank-col-merchant')));
      await tester.pumpAndSettle();
      expect(find.text('3. oszlop  ·  extra'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('the header is one of the first twenty rows, or none', (
      tester,
    ) async {
      await boot(tester);
      int count() => tester
          .widget<DropdownButton<int>>(find.byKey(const Key('bank-header')))
          .items!
          .length;
      await pick(tester, utf8Bytes(otpLike));
      expect(count(), 1 + 5);
      await back(tester);
      await pick(
        tester,
        utf8Bytes(
          [
            'Dátum;Összeg',
            for (var i = 0; i < 24; i++) '2026.11.13;-100',
          ].join('\n'),
        ),
      );
      expect(count(), 1 + 20);
      await shutdown(tester, db);
    });

    testWidgets('a row in another currency is shown as it was paid', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(cardLike));
      final sample = find.byKey(const Key('bank-sample'));
      expect(
        find.descendant(of: sample, matching: find.text('Spar Wien')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sample,
          matching: find.text('2. sor · ${fmtDate(DateTime(2026, 11, 13))}'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sample,
          matching: find.text('−${formatForeign(1240, 'EUR')}'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sample, matching: find.text('−${formatHuf(3000)}')),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('the three ways to write a date are named', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await tester.ensureVisible(find.byKey(const Key('bank-date-order')));
      await tester.tap(find.byKey(const Key('bank-date-order')));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-13  (év, hónap, nap)'), findsWidgets);
      expect(find.text('13.11.2026  (nap, hónap, év)'), findsWidgets);
      expect(find.text('11/13/2026  (hónap, nap, év)'), findsWidgets);
      await shutdown(tester, db);
    });

    testWidgets('columns told by hand over a table that says nothing', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes('Dátum;Összeg\n ; \n ; \n'));
      expect(
        find.text('Válaszd ki a dátum és az összeg oszlopát.'),
        findsOneWidget,
      );
      await choose(tester, 'date', 'Dátum');
      await choose(tester, 'amount', 'Összeg');
      expect(find.text('Nincs olvasható sor.'), findsOneWidget);
      expect(find.byKey(const Key('bank-sample')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the signs can be turned round', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await tester.ensureVisible(find.byKey(const Key('bank-invert')));
      await tester.tap(find.byKey(const Key('bank-invert')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('bank-invert')))
            .value,
        isTrue,
      );
      final sample = find.byKey(const Key('bank-sample'));
      expect(
        find.descendant(of: sample, matching: find.text('+${formatHuf(4500)}')),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a direction column takes the place of the signs', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await choose(tester, 'direction', 'Tranzakció típusa');
      expect(find.byKey(const Key('bank-invert')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the order of a date can be told', (tester) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Partner;Összeg\n03/04/2026;Spar;-100\n05/06/2026;Lidl;-200\n',
        ),
      );
      final sample = find.byKey(const Key('bank-sample'));
      expect(
        find.descendant(
          of: sample,
          matching: find.text('2. sor · ${fmtDate(DateTime(2026, 4, 3))}'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('bank-date-order')));
      await tester.tap(find.byKey(const Key('bank-date-order')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('hónap, nap, év').last);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: sample,
          matching: find.text('2. sor · ${fmtDate(DateTime(2026, 3, 4))}'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('rows that cannot be read are told of', (tester) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Partner;Összeg\n2026.11.13;Spar;-100\n2026.11.14;Lidl;-200\n',
        ),
      );
      expect(find.text('2. sor: a dátum nem olvasható'), findsNothing);
      // (a column that is no date is taken for the date)
      await choose(tester, 'date', 'Partner');
      expect(find.text('2. sor: a dátum nem olvasható'), findsOneWidget);
      expect(find.text('3. sor: a dátum nem olvasható'), findsOneWidget);
      expect(find.byKey(const Key('bank-sample')), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('the look at what would be added', () {
    testWidgets('how many, and what', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(summary(), findsOneWidget);
      expect(find.text('4 tétel kerül be'), findsOneWidget);
      expect(find.byKey(const Key('bank-import')), findsOneWidget);
      expect(find.text('Importálás (4)'), findsOneWidget);
      expect(find.text('LIDL'), findsOneWidget);
      expect(find.text('Munkahely Kft.'), findsOneWidget);
      expect(find.text('SPAR Magyarország Kft.'), findsNWidgets(2));
      expect(find.text('+${formatHuf(300000)}'), findsOneWidget);
      // (an income is of another colour than an expense)
      expect(
        tester.widget<Text>(find.text('+${formatHuf(300000)}')).style?.color,
        isNotNull,
      );
      expect(
        tester.widget<Text>(find.text('−${formatHuf(1200)}')).style?.color,
        isNull,
      );
      // nothing is in the books yet
      expect(await txs(tester), isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('a row can be left out', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-row-4')));
      await tester.pumpAndSettle();
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      expect(find.text('Importálás (3)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-row-4')));
      await tester.pumpAndSettle();
      expect(find.text('4 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('back goes one step back, and out from the first', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(summary(), findsOneWidget);
      await back(tester);
      expect(find.byKey(const Key('bank-next')), findsOneWidget);
      expect(column(tester, 'date'), 0);
      await back(tester);
      expect(find.byKey(const Key('bank-pick')), findsOneWidget);
      await back(tester);
      expect(find.text('Import megnyitása'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an entry that looks the same is left out until asked for', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(
        () => repo.saveTx(
          FinTx(
            id: 'mine',
            date: floating(2026, 11, 14),
            amount: 1200,
            kind: FinKind.expense,
            categoryId: 'cat-food',
            merchant: 'Lidl, kézzel',
          ),
        ),
      );
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      expect(
        find.textContaining('1 hasonló van a könyvelésben'),
        findsOneWidget,
      );
      expect(find.textContaining('hasonló: Lidl, kézzel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-row-4')));
      await tester.pumpAndSettle();
      expect(find.text('4 tétel kerül be'), findsOneWidget);
      // (and asked for twice is not asked for)
      await tester.tap(find.byKey(const Key('bank-row-4')));
      await tester.pumpAndSettle();
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('back and forward again starts the look afresh', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(find.text('Kategóriák kereskedőnként (3)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-row-5')));
      await tester.pumpAndSettle();
      // (a merchant none of whose rows is added is not asked about)
      expect(find.text('Kategóriák kereskedőnként (2)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bank-merchant-munkahely kft')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Közlekedés').last);
      await tester.pumpAndSettle();
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      await back(tester);
      await next(tester);
      expect(find.text('4 tétel kerül be'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('bank-merchant-lidl')),
          matching: find.text('1 tétel · Besorolatlan'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a second tap on "Tovább" finds the first at work', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      final before = spy.txsCalls;
      await tester.tap(find.byKey(const Key('bank-next')));
      await tester.tap(find.byKey(const Key('bank-next')));
      await tester.pumpAndSettle();
      expect(spy.txsCalls, before + 1);
      expect(find.text('4 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'a tick the user gave is not kept when the look is made again',
      (tester) async {
        await boot(tester);
        await tester.runAsync(
          () => repo.saveTx(
            FinTx(
              id: 'mine',
              date: floating(2026, 11, 14),
              amount: 1200,
              kind: FinKind.expense,
              categoryId: 'cat-food',
            ),
          ),
        );
        await pick(tester, utf8Bytes(otpLike));
        await next(tester);
        // (a twin without a merchant is told as "tétel")
        expect(find.textContaining('hasonló: tétel'), findsOneWidget);
        expect(find.text('3 tétel kerül be'), findsOneWidget);
        await tester.tap(find.byKey(const Key('bank-row-4')));
        await tester.pumpAndSettle();
        expect(find.text('4 tétel kerül be'), findsOneWidget);
        await back(tester);
        await next(tester);
        expect(find.text('3 tétel kerül be'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('a row has the merchant, else the note, else no name', (
      tester,
    ) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Összeg;Közlemény\n'
          '2026.11.13;-100;kenyér\n'
          '2026.11.14;-200;\n',
        ),
      );
      // (the sample says it, too)
      final sample = find.byKey(const Key('bank-sample'));
      expect(
        find.descendant(of: sample, matching: find.text('(nincs név)')),
        findsNWidgets(2),
      );
      await next(tester);
      Finder title(int row, String text) => find.descendant(
        of: find.byKey(Key('bank-row-$row')),
        matching: find.text(text),
      );
      expect(title(2, 'kenyér'), findsOneWidget);
      expect(title(3, '(nincs név)'), findsOneWidget);
      // (and rows without a merchant are not a merchant to give a category)
      expect(find.byKey(const Key('bank-merchants')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('rows that are left out are told of, and why', (tester) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Partner;Összeg\n'
          '2026.11.13;Spar;-100\n'
          'nem dátum;Lidl;-200\n'
          '2026.11.15;Coop;\n',
        ),
      );
      await next(tester);
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      expect(find.textContaining('2 sor kimarad'), findsOneWidget);
      expect(find.text('Kimaradó sorok (2)'), findsOneWidget);
      await tester.tap(find.text('Kimaradó sorok (2)'));
      await tester.pumpAndSettle();
      expect(find.text('3. sor: a dátum nem olvasható'), findsOneWidget);
      expect(find.text('4. sor: az összeg nem olvasható'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('adding it', () {
    testWidgets('the entries are written, and "Visszavonás" is on offer', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      // the page is closed, the bar says it
      expect(find.byKey(const Key('bank-pick')), findsNothing);
      expect(find.text('Import megnyitása'), findsOneWidget);
      expect(find.text('4 tétel importálva'), findsOneWidget);
      expect(find.text('Visszavonás'), findsOneWidget);
      final all = await txs(tester);
      expect(all, hasLength(4));
      final spar = all.where((t) => t.merchant == 'SPAR Magyarország Kft.');
      expect(spar.map((t) => t.amount).toSet(), {4500, 2300});
      expect(all.every((t) => t.source == FinSource.imported), isTrue);
      expect(all.every((t) => t.id.startsWith('imp-')), isTrue);
      final pay = all.firstWhere((t) => t.merchant == 'Munkahely Kft.');
      expect(pay.kind, FinKind.income);
      expect(pay.amount, 300000);
      expect(pay.note, 'fizetés');
      expect(pay.date, floating(2026, 11, 15));
      expect(pay.categoryId, kUncategorized);
      expect(pay.foreign, isNull);
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('"Visszavonás" takes it all back', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
      expect(await txs(tester), isEmpty);
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('"Visszavonás" says so when an entry was changed meanwhile', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      final one = (await txs(tester)).first;
      await tester.runAsync(() => repo.saveTx(one.copyWith(note: 'átírva')));
      await tester.tap(find.text('Visszavonás'));
      await tester.pumpAndSettle();
      expect(
        find.text('A visszavonás már nem lehetséges: közben megváltozott.'),
        findsOneWidget,
      );
      expect(await txs(tester), hasLength(4));
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('a second tap on the import finds the first at work', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-import')));
      await tester.tap(find.byKey(const Key('bank-import')));
      await tester.pumpAndSettle();
      expect(await txs(tester), hasLength(4));
      expect(find.text('Import megnyitása'), findsOneWidget);
      expect(find.text('4 tétel importálva'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('a failure is told, and the import can be tried again', (
      tester,
    ) async {
      await boot(tester);
      spy.failImports = 1;
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      expect(find.text('Az importálás nem sikerült.'), findsOneWidget);
      expect(await txs(tester), isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bank-import')))
            .onPressed,
        isNotNull,
      );
      await importIt(tester);
      expect(await txs(tester), hasLength(4));
      expect(find.text('Import megnyitása'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('a failure is not told again after a step back', (
      tester,
    ) async {
      await boot(tester);
      spy.failImports = 1;
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      expect(find.text('Az importálás nem sikerült.'), findsOneWidget);
      await back(tester);
      await next(tester);
      expect(find.text('Az importálás nem sikerült.'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('the same file again adds nothing', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      await tester.pump(const Duration(seconds: 11));
      await tester.tap(find.text('Import megnyitása'));
      await tester.pumpAndSettle();
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(find.text('0 tétel kerül be'), findsOneWidget);
      expect(find.textContaining('4 már megvan'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bank-import')))
            .onPressed,
        isNull,
      );
      final box = tester.widget<CheckboxListTile>(
        find.byKey(const Key('bank-row-3')),
      );
      expect(box.onChanged, isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('bank-row-3')),
          matching: find.textContaining('már megvan'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('an entry that was deleted does not come back with the file', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      await tester.pump(const Duration(seconds: 11));
      final one = (await txs(tester)).firstWhere((t) => t.merchant == 'LIDL');
      await tester.runAsync(() => repo.deleteTx(one.id));
      await tester.tap(find.text('Import megnyitása'));
      await tester.pumpAndSettle();
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      expect(find.text('0 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a file that goes on from the last one adds what is new', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await importIt(tester);
      await tester.pump(const Duration(seconds: 11));
      await tester.tap(find.text('Import megnyitása'));
      await tester.pumpAndSettle();
      await pick(
        tester,
        utf8Bytes('${otpLike}2026.11.16;Kártyavásárlás;COOP;;-900,00;HUF\n'),
      );
      await next(tester);
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      await importIt(tester);
      expect(await txs(tester), hasLength(5));
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('two columns: what went out and what came in', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(twoColumns));
      await next(tester);
      await importIt(tester);
      final all = await txs(tester);
      expect(all.map((t) => (t.merchant, t.kind, t.amount)).toSet(), {
        ('SPAR', FinKind.expense, 4500),
        ('Munkahely', FinKind.income, 300000),
      });
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('a file in the old code page is read, letters and all', (
      tester,
    ) async {
      await boot(tester);
      await pick(
        tester,
        cp1250Bytes(
          'Dátum;Partner neve;Összeg\n'
          '2026.11.13;Fűszer-Kert Bt. – Őrmező;-4 500\n',
        ),
      );
      expect(find.textContaining('Windows-1250'), findsOneWidget);
      await next(tester);
      expect(find.text('Fűszer-Kert Bt. – Őrmező'), findsOneWidget);
      await importIt(tester);
      expect((await txs(tester)).single.merchant, 'Fűszer-Kert Bt. – Őrmező');
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('the columns chosen by hand are there the next time', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      // (the note, which was the message, is made the merchant's place)
      await choose(tester, 'merchant', 'Tranzakció típusa');
      expect(column(tester, 'merchant'), 1);
      await next(tester);
      await importIt(tester);
      await tester.pump(const Duration(seconds: 11));
      await tester.tap(find.text('Import megnyitása'));
      await tester.pumpAndSettle();
      await pick(tester, utf8Bytes(otpLike));
      expect(column(tester, 'merchant'), 1);
      await shutdown(tester, db);
    });

    testWidgets('a failure is told, and nothing is half done', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      // (the database is gone)
      await tester.runAsync(db.close);
      await importIt(tester);
      expect(find.text('Az importálás nem sikerült.'), findsOneWidget);
      expect(find.byKey(const Key('bank-import')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('categories', () {
    testWidgets(
      'a merchant gets the category it had, and a new one can be given',
      (tester) async {
        await boot(tester);
        await tester.runAsync(() => repo.rememberMerchant('LIDL', 'cat-food'));
        await pick(tester, utf8Bytes(otpLike));
        await next(tester);
        await tester.tap(find.byKey(const Key('bank-merchants')));
        await tester.pumpAndSettle();
        expect(find.text('Kategóriák kereskedőnként (3)'), findsOneWidget);
        // the most rows first
        expect(find.text('2 tétel · Besorolatlan'), findsOneWidget);
        expect(find.text('1 tétel · Élelmiszer'), findsOneWidget);
        double top(String key) =>
            tester.getTopLeft(find.byKey(Key('bank-merchant-$key'))).dy;
        expect(top('spar magyarország kft'), lessThan(top('lidl')));
        await tester.tap(
          find.byKey(const Key('bank-merchant-spar magyarország kft')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Kategória: SPAR Magyarország Kft.'), findsOneWidget);
        await tester.tap(find.text('Élelmiszer').last);
        await tester.pumpAndSettle();
        expect(find.text('2 tétel · Élelmiszer'), findsOneWidget);
        await importIt(tester);
        final all = await txs(tester);
        expect(
          all
              .where((t) => t.categoryId == 'cat-food')
              .map((t) => t.merchant)
              .toSet(),
          {'SPAR Magyarország Kft.', 'LIDL'},
        );
        expect(
          all.firstWhere((t) => t.merchant == 'Munkahely Kft.').categoryId,
          kUncategorized,
        );
        // what was taught is remembered for the next file
        final remembered = await tester.runAsync(
          () => repo.merchantCategories(['SPAR Magyarország Kft.']),
        );
        expect(remembered, {'SPAR Magyarország Kft.': 'cat-food'});
        await tester.pump(const Duration(seconds: 11));
        await shutdown(tester, db);
      },
    );

    testWidgets('a category chosen now beats the one remembered', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(() => repo.rememberMerchant('LIDL', 'cat-food'));
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      expect(find.text('✓ Élelmiszer'), findsOneWidget);
      await tester.tap(find.text('Közlekedés').last);
      await tester.pumpAndSettle();
      // (asked again, the dialog marks what was chosen now, not what was)
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      expect(find.text('✓ Közlekedés'), findsOneWidget);
      expect(find.text('Élelmiszer'), findsOneWidget);
      await tester.tap(find.text('✓ Közlekedés'));
      await tester.pumpAndSettle();
      await importIt(tester);
      final lidl = (await txs(tester)).firstWhere((t) => t.merchant == 'LIDL');
      expect(lidl.categoryId, 'cat-transport');
      expect(await tester.runAsync(() => repo.merchantCategories(['LIDL'])), {
        'LIDL': 'cat-transport',
      });
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('merchants that are one by their key are given one category', (
      tester,
    ) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          'Dátum;Partner;Összeg\n'
          '2026.11.13;Spar Kft.;-100\n'
          '2026.11.14;SPAR kft;-200\n',
        ),
      );
      await next(tester);
      expect(find.text('Kategóriák kereskedőnként (1)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-spar kft')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Élelmiszer').last);
      await tester.pumpAndSettle();
      await importIt(tester);
      expect((await txs(tester)).map((t) => t.categoryId).toSet(), {
        'cat-food',
      });
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('a merchant none of whose rows is added is not remembered', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Közlekedés').last);
      await tester.pumpAndSettle();
      // (and then the one row of that merchant is left out)
      await tester.tap(find.byKey(const Key('bank-row-4')));
      await tester.pumpAndSettle();
      await importIt(tester);
      expect(await txs(tester), hasLength(3));
      expect(
        await tester.runAsync(() => repo.merchantCategories(['LIDL'])),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('no category is not a category to remember', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Közlekedés').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Besorolatlan'));
      await tester.pumpAndSettle();
      await importIt(tester);
      expect(
        await tester.runAsync(() => repo.merchantCategories(['LIDL'])),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets(
      'the dialog lists the categories in their order, and can be left',
      (tester) async {
        await boot(tester);
        await pick(tester, utf8Bytes(otpLike));
        await next(tester);
        await tester.tap(find.byKey(const Key('bank-merchants')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
        await tester.pumpAndSettle();
        final shown = [
          for (final o in tester.widgetList<SimpleDialogOption>(
            find.byType(SimpleDialogOption),
          ))
            (o.child! as Text).data,
        ];
        final cats = sortCategories((await tester.runAsync(repo.categories))!);
        expect(shown, ['✓ Besorolatlan', for (final c in cats) c.name]);
        // (left by the side: nothing is changed)
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.byType(SimpleDialogOption), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('bank-merchant-lidl')),
            matching: find.text('1 tétel · Besorolatlan'),
          ),
          findsOneWidget,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets('the dialog shows the category a merchant has', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(otpLike));
      await next(tester);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      expect(find.text('✓ Besorolatlan'), findsOneWidget);
      await tester.tap(find.text('Közlekedés').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-merchant-lidl')));
      await tester.pumpAndSettle();
      expect(find.text('✓ Közlekedés'), findsOneWidget);
      expect(find.text('Besorolatlan'), findsOneWidget);
      await tester.tap(find.text('Besorolatlan'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('bank-merchant-lidl')),
          matching: find.text('1 tétel · Besorolatlan'),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });
  });

  group('another currency', () {
    testWidgets('a rate is asked for, and the rows wait for it', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(cardLike));
      expect(column(tester, 'currency'), 7);
      expect(column(tester, 'date'), 3);
      await next(tester);
      expect(find.byKey(const Key('bank-rate-EUR')), findsOneWidget);
      expect(find.byKey(const Key('bank-rate-HUF')), findsNothing);
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      expect(find.text('2 sor vár az árfolyamra.'), findsOneWidget);
      // (rows that wait for a rate are not rows that are left out)
      expect(find.textContaining('kimarad'), findsNothing);
      expect(find.byKey(const Key('bank-issues')), findsNothing);
      await tester.enterText(find.byKey(const Key('bank-rate-EUR')), '399,5');
      await tester.pumpAndSettle();
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      expect(find.byKey(const Key('bank-waiting')), findsNothing);
      // what each row was paid in
      expect(
        find.textContaining(
          foreignLine(
            const FinForeign(currency: 'EUR', cents: 1240, rate: 399.5),
          ),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a rate that is no rate is told of', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(cardLike));
      await next(tester);
      final field = find.byKey(const Key('bank-rate-EUR'));
      String text() => tester.widget<TextField>(field).controller!.text;
      // (an empty field is not yet wrong)
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsNothing);
      // (letters cannot be typed into it at all, nor a minus)
      expect(find.text('Árfolyam (Ft / EUR)'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).keyboardType,
        const TextInputType.numberWithOptions(decimal: true),
      );
      await tester.enterText(field, 'abc');
      await tester.pumpAndSettle();
      expect(text(), isEmpty);
      await tester.enterText(field, '-5');
      await tester.pumpAndSettle();
      expect(text(), '5');
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsNothing);
      await tester.enterText(field, '0');
      await tester.pumpAndSettle();
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsOneWidget);
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      await tester.enterText(field, '400');
      await tester.pumpAndSettle();
      expect(find.text('Adj meg árfolyamot (pl. 400)'), findsNothing);
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      // a rate with three decimals is a rate with three decimals
      await tester.enterText(field, '2,512');
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          foreignLine(
            const FinForeign(currency: 'EUR', cents: 1240, rate: 2.512),
          ),
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets(
      'what is added keeps what it was paid in, and the rate is remembered',
      (tester) async {
        await boot(tester);
        await pick(tester, utf8Bytes(cardLike));
        await next(tester);
        await tester.enterText(find.byKey(const Key('bank-rate-EUR')), '399,5');
        await tester.pumpAndSettle();
        await importIt(tester);
        final all = await txs(tester);
        expect(all, hasLength(3));
        final spar = all.firstWhere((t) => t.merchant == 'Spar Wien');
        expect(spar.amount, 4954);
        expect(
          spar.foreign,
          const FinForeign(currency: 'EUR', cents: 1240, rate: 399.5),
        );
        expect(all.firstWhere((t) => t.merchant == 'Lidl').foreign, isNull);
        expect(await tester.runAsync(() => repo.lastRate('EUR')), 399.5);
        await tester.pump(const Duration(seconds: 11));
        await shutdown(tester, db);
      },
    );

    testWidgets('a rate taken away makes the rows wait again', (tester) async {
      await boot(tester);
      await pick(tester, utf8Bytes(cardLike));
      await next(tester);
      final field = find.byKey(const Key('bank-rate-EUR'));
      await tester.enterText(field, '400');
      await tester.pumpAndSettle();
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      await tester.enterText(field, '0');
      await tester.pumpAndSettle();
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      expect(find.text('2 sor vár az árfolyamra.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets(
      'every currency has its own rate, in the order of the letters',
      (tester) async {
        await boot(tester);
        await pick(
          tester,
          utf8Bytes(
            'Dátum;Partner;Összeg;Pénznem\n'
            '2026.11.13;Aaa;-10;USD\n'
            '2026.11.14;Bbb;-20;EUR\n'
            '2026.11.15;Ccc;-30;GBP\n',
          ),
        );
        await next(tester);
        expect(
          tester
              .widgetList<TextField>(find.byType(TextField))
              .map((f) => f.key),
          [
            const Key('bank-rate-EUR'),
            const Key('bank-rate-GBP'),
            const Key('bank-rate-USD'),
          ],
        );
        await tester.enterText(find.byKey(const Key('bank-rate-EUR')), '400');
        await tester.enterText(find.byKey(const Key('bank-rate-GBP')), '460');
        await tester.enterText(find.byKey(const Key('bank-rate-USD')), '350');
        await tester.pumpAndSettle();
        expect(find.text('3 tétel kerül be'), findsOneWidget);
        await importIt(tester);
        expect((await txs(tester)).map((t) => t.amount).toSet(), {
          3500,
          8000,
          13800,
        });
        await tester.pump(const Duration(seconds: 11));
        await shutdown(tester, db);
      },
    );

    testWidgets('a merchant that comes in with the rate has its category', (
      tester,
    ) async {
      await boot(tester);
      await tester.runAsync(
        () => repo.rememberMerchant('Spar Wien', 'cat-food'),
      );
      await pick(tester, utf8Bytes(cardLike));
      await next(tester);
      expect(find.textContaining('Élelmiszer'), findsNothing);
      await tester.enterText(find.byKey(const Key('bank-rate-EUR')), '399,5');
      await tester.pumpAndSettle();
      expect(find.textContaining('Élelmiszer'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the rate of rows that are not added is not remembered', (
      tester,
    ) async {
      await boot(tester);
      await pick(tester, utf8Bytes(cardLike));
      await next(tester);
      await tester.enterText(find.byKey(const Key('bank-rate-EUR')), '399,5');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bank-row-2')));
      await tester.tap(find.byKey(const Key('bank-row-3')));
      await tester.pumpAndSettle();
      expect(find.text('1 tétel kerül be'), findsOneWidget);
      await importIt(tester);
      expect(await txs(tester), hasLength(1));
      expect(await tester.runAsync(() => repo.lastRate('EUR')), isNull);
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });

    testWidgets('the rate of the last time is there already', (tester) async {
      await boot(tester);
      await tester.runAsync(() => repo.rememberRate('EUR', 401.25));
      await pick(tester, utf8Bytes(cardLike));
      await next(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('bank-rate-EUR')))
            .controller!
            .text,
        '401,25',
      );
      expect(find.text('3 tétel kerül be'), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('where it is', () {
    testWidgets('the Pénzügyek page has the way in', (tester) async {
      useSize(tester, size: const Size(900, 1400));
      db = await newDb();
      repo = FinanceRepository(db);
      await tester.pumpWidget(
        app(
          const FinancePage(),
          db,
          extra: [
            financeRepoProvider.overrideWithValue(repo),
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 18, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bank-kivonat importálása (CSV)'));
      await tester.pumpAndSettle();
      expect(find.text('Bank-kivonat importálása'), findsOneWidget);
      expect(find.byKey(const Key('bank-pick')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('an entry from a bank is told from the others in the list', (
      tester,
    ) async {
      useSize(tester, size: const Size(900, 1400));
      db = await newDb();
      repo = FinanceRepository(db);
      await tester.runAsync(() async {
        await repo.ensureDefaults();
        await repo.addImported([
          FinTx(
            id: 'imp-1',
            date: floating(2026, 11, 17),
            amount: 4500,
            kind: FinKind.expense,
            categoryId: 'cat-food',
            merchant: 'SPAR',
            source: FinSource.imported,
          ),
        ]);
      });
      await tester.pumpWidget(
        app(
          const FinancePage(),
          db,
          extra: [
            financeRepoProvider.overrideWithValue(repo),
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 18, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tételek'));
      await tester.pumpAndSettle();
      expect(find.text('SPAR'), findsOneWidget);
      expect(find.byIcon(Icons.account_balance_outlined), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('a small screen and big text', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('every step fits a phone (${scale}x)', (tester) async {
        await boot(tester, size: const Size(360, 800), textScale: scale);
        tester.takeException();
        expect(tester.takeException(), isNull);
        await pick(tester, utf8Bytes(otpLike));
        expect(tester.takeException(), isNull);
        await next(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('bank-merchants')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await back(tester);
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });

      testWidgets('two columns and a currency fit a phone (${scale}x)', (
        tester,
      ) async {
        await boot(tester, size: const Size(360, 800), textScale: scale);
        tester.takeException();
        await pick(tester, utf8Bytes(twoColumns));
        expect(tester.takeException(), isNull);
        await back(tester);
        await pick(tester, utf8Bytes(cardLike));
        await next(tester);
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    }
  });

  group('a long statement', () {
    testWidgets('sixty merchants are listed, and the title says how many', (
      tester,
    ) async {
      await boot(tester);
      await pick(
        tester,
        utf8Bytes(
          [
            'Dátum;Partner;Összeg',
            for (var i = 0; i < 70; i++) '2026.11.13;Bolt $i;-100',
          ].join('\n'),
        ),
      );
      await next(tester);
      expect(find.text('Kategóriák kereskedőnként (70)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bank-merchants')));
      await tester.pumpAndSettle();
      final listed = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('bank-merchant-'),
      );
      expect(listed, findsNWidgets(60));
      await shutdown(tester, db);
    });

    testWidgets(
      'a hundred rows that are left out are listed, and the rest is told',
      (tester) async {
        await boot(tester);
        await pick(
          tester,
          utf8Bytes(
            [
              'Dátum;Partner;Összeg',
              for (var i = 0; i < 50; i++) '2026.11.13;Bolt $i;-100',
              for (var i = 0; i < 105; i++) 'nem dátum;Rossz $i;-100',
            ].join('\n'),
          ),
        );
        await next(tester);
        expect(find.text('Kimaradó sorok (105)'), findsOneWidget);
        await tester.tap(find.byKey(const Key('bank-issues')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('a dátum nem olvasható'),
          findsNWidgets(100),
        );
        expect(find.text('… és még 5'), findsOneWidget);
        await shutdown(tester, db);
      },
    );

    testWidgets('two thousand rows are read and added', (tester) async {
      await boot(tester);
      final lines = [
        'Dátum;Partner;Összeg',
        for (var i = 0; i < 2000; i++)
          '2026.11.${(i % 28 + 1).toString().padLeft(2, '0')};Bolt ${i % 40};-${100 + i}',
      ];
      await pick(tester, utf8Bytes(lines.join('\n')));
      await next(tester);
      expect(find.text('2000 tétel kerül be'), findsOneWidget);
      await importIt(tester);
      expect(await txs(tester), hasLength(2000));
      await tester.pump(const Duration(seconds: 11));
      await shutdown(tester, db);
    });
  });
}
