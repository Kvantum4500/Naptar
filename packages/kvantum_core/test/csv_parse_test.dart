import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

void main() {
  group('reading rows and cells', () {
    test('cells at the delimiter, rows at the line breaks', () {
      expect(parseCsv('a;b;c\n1;2;3\n', ';'), [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('CR LF, LF and CR all end a line; the last line needs none', () {
      expect(parseCsv('a;b\r\nc;d\r\ne;f', ';'), [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ]);
      expect(parseCsv('a;b\rc;d', ';'), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
      expect(parseCsv('a;b\nc;d\n', ';'), hasLength(2));
      // (a CR LF is one line break, not two)
      expect(parseCsv('a\r\n\r\nb', ';'), [
        ['a'],
        ['b'],
      ]);
    });

    test('blank lines are no rows; empty cells are cells', () {
      expect(parseCsv('a;b\n\n   \n;\nc;d', ';'), [
        ['a', 'b'],
        ['', ''],
        ['c', 'd'],
      ]);
      expect(parseCsv('a;;c;', ';'), [
        ['a', '', 'c', ''],
      ]);
      expect(parseCsv('', ';'), isEmpty);
      expect(parseCsv('\n\n', ';'), isEmpty);
    });

    test('a byte-order mark at the start is left out', () {
      expect(parseCsv('${String.fromCharCode(0xFEFF)}Dátum;Összeg', ';'), [
        ['Dátum', 'Összeg'],
      ]);
    });

    test('the other delimiters', () {
      expect(parseCsv('a,b\tc|d', ','), [
        ['a', 'b\tc|d'],
      ]);
      expect(parseCsv('a\tb;c', '\t'), [
        ['a', 'b;c'],
      ]);
      expect(parseCsv('a|b,c', '|'), [
        ['a', 'b,c'],
      ]);
    });
  });

  group('quotes', () {
    test('a quoted cell holds the delimiter and a line break', () {
      expect(parseCsv('"a;b";c\n"d\ne";f', ';'), [
        ['a;b', 'c'],
        ['d\ne', 'f'],
      ]);
    });

    test('two quotes in quotes are one quote', () {
      expect(parseCsv('"say ""hi""";x', ';'), [
        ['say "hi"', 'x'],
      ]);
      expect(parseCsv('"""";x', ';'), [
        ['"', 'x'],
      ]);
    });

    test('a quote in the middle of a cell is just a quote', () {
      expect(parseCsv('5" pipe;x', ';'), [
        ['5" pipe', 'x'],
      ]);
    });

    test('spaces before the opening quote are not part of the cell', () {
      expect(parseCsv('  "a;b" ;c', ';'), [
        ['a;b ', 'c'],
      ]);
    });

    test('text after the closing quote goes on in the cell', () {
      expect(parseCsv('"ab"cd;e', ';'), [
        ['abcd', 'e'],
      ]);
    });

    test('a quote that is never closed takes the rest of the text', () {
      expect(parseCsv('a;"b;c\nd', ';'), [
        ['a', 'b;c\nd'],
      ]);
    });

    test('a quote that closes the text', () {
      expect(parseCsv('"a"', ';'), [
        ['a'],
      ]);
      expect(parseCsv('x;"b"', ';'), [
        ['x', 'b'],
      ]);
      expect(parseCsv('x;"b""', ';'), [
        ['x', 'b"'],
      ]);
    });

    test('an empty quoted cell is a cell', () {
      expect(parseCsv('a;"";c', ';'), [
        ['a', '', 'c'],
      ]);
    });
  });

  test('no more rows than asked for are read', () {
    expect(parseCsv('1\n2\n3\n4\n5', ';', maxRows: 3), [
      ['1'],
      ['2'],
      ['3'],
    ]);
    expect(parseCsv('1\n2\n3', ';', maxRows: 3), hasLength(3));
    expect(parseCsv('1\n2\n3', ';', maxRows: 2), hasLength(2));
  });

  group('finding the delimiter', () {
    test('a semicolon file with decimal commas', () {
      expect(
        detectDelimiter(
          'Dátum;Partner;Összeg\n2026.11.13;Spar;-4 500,50\n2026.11.14;Lidl;-1 200,00\n',
        ),
        ';',
      );
    });

    test('a comma file, with commas in quotes', () {
      expect(
        detectDelimiter(
          'Date,Description,Amount\n2026-11-13,"Spar, Wien",-4.50\n2026-11-14,"Lidl, Graz",-12.00\n',
        ),
        ',',
      );
    });

    test('a tab file and a bar file', () {
      expect(detectDelimiter('a\tb\tc\n1\t2\t3\n4\t5\t6'), '\t');
      expect(detectDelimiter('a|b|c\n1|2|3\n4|5|6'), '|');
    });

    test('a delimiter in quotes does not count', () {
      expect(detectDelimiter('"a;b;c","d"\n"e;f;g","h"'), ',');
      // (nor does a line break in quotes make a line of its own)
      expect(detectDelimiter('"a\nb;c;d";x\n"e";y'), ';');
    });

    test('lines above the table do not decide', () {
      expect(
        detectDelimiter(
          'Számlakivonat, 2026. november\nSzámla: 1234-5678\n\n'
          'Dátum;Partner;Összeg\n2026.11.13;Spar;-4500\n2026.11.14;Lidl;-1200\n'
          '2026.11.15;Tesco;-800\n',
        ),
        ';',
      );
    });

    test('the one that cuts into more cells wins when both are steady', () {
      expect(detectDelimiter('a;b;c,1\nd;e;f,2\ng;h;i,3'), ';');
      expect(detectDelimiter('a,b,c;1\nd,e,f;2\ng,h,i;3'), ',');
    });

    test('a tie of everything goes to the first in the order', () {
      expect(detectDelimiter('a;b,c\nd;e,f'), ';');
      expect(detectDelimiter('a\tb,c\nd\te,f'), '\t');
    });

    test('the one that is steady beats the one that is not', () {
      // (commas as decimals: one in some lines, none in others)
      expect(detectDelimiter('a;b\n1;2,5\n3;4\n5;6,5\n7;8'), ';');
    });

    test('only the first thirty lines are looked at', () {
      final first = List.filled(30, 'a;b;c').join('\n');
      final later = List.filled(60, 'a,b,c').join('\n');
      expect(detectDelimiter('$first\n$later'), ';');
    });

    test('lines with another count are outvoted', () {
      // (a semicolon is in no line at all: that must not win)
      expect(detectDelimiter('a,b,c\n1,2,3\n4,5,6\n7,8\n'), ',');
    });

    test('the thirtieth line counts, the thirty-first does not', () {
      final lines = [
        for (var i = 0; i < 14; i++) 'a;b',
        for (var i = 0; i < 15; i++) 'c,d',
        'a;b', // the 30th: a tie, so the first in the order
        'e,f', // the 31st: it would decide for the comma
        'e,f',
      ];
      expect(detectDelimiter(lines.join('\n')), ';');
    });

    test('a line without any of them does not use up the thirty', () {
      final blanks = List.filled(40, '   ').join('\n');
      expect(detectDelimiter('$blanks\na,b\nc,d'), ',');
      final words = List.filled(40, 'Számlakivonat').join('\n');
      expect(detectDelimiter('$words\na,b\nc,d'), ',');
      final quoted = List.filled(40, '"abc"').join('\n');
      expect(detectDelimiter('$quoted\na,b\nc,d'), ',');
    });

    test('a line with many cells does not outvote the lines that agree', () {
      expect(detectDelimiter('a;b\nc;d\ne;f\n1,2,3,4'), ';');
    });

    test('a text with none of them has the semicolon', () {
      expect(detectDelimiter('abc\ndef'), ';');
      expect(detectDelimiter(''), ';');
    });

    test('a last line without a line break counts', () {
      expect(detectDelimiter('a,b,c'), ',');
    });
  });
}
