import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

void main() {
  const sentence = 'Árvíztűrő tükörfúrógép';

  // (the same sentence as Windows-1250 writes it)
  const sentence1250 = [
    0xC1, 0x72, 0x76, 0xED, 0x7A, 0x74, 0xFB, 0x72, 0xF5, 0x20, //
    0x74, 0xFC, 0x6B, 0xF6, 0x72, 0x66, 0xFA, 0x72, 0xF3, 0x67, 0xE9, 0x70,
  ];

  group('UTF-8', () {
    test('plain text and text with a byte-order mark', () {
      final plain = decodeText(utf8.encode(sentence));
      expect(plain.text, sentence);
      expect(plain.encoding, TextEncoding.utf8);
      final marked = decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode(sentence)]);
      expect(marked.text, sentence);
      expect(marked.encoding, TextEncoding.utf8);
    });

    test('a mark and nothing else', () {
      expect(decodeText([0xEF, 0xBB, 0xBF]).text, '');
      // (half of one is not one)
      final half = decodeText([0xEF, 0xBB]);
      expect(half.text, 'ď»');
      expect(half.encoding, TextEncoding.windows1250);
    });

    test('text of ASCII only, and nothing', () {
      final a = decodeText(utf8.encode('Date;Amount\n1;2'));
      expect(a.text, 'Date;Amount\n1;2');
      expect(a.encoding, TextEncoding.utf8);
      final none = decodeText(const []);
      expect(none.text, '');
      expect(none.encoding, TextEncoding.utf8);
    });
  });

  group('Windows-1250', () {
    test('what is not UTF-8 is read as the Central European code page', () {
      final d = decodeText(sentence1250);
      expect(d.text, sentence);
      expect(d.encoding, TextEncoding.windows1250);
    });

    test('every Hungarian letter', () {
      expect(
        decodeText([0xC1, 0xC9, 0xCD, 0xD3, 0xD6, 0xD5, 0xDA, 0xDC, 0xDB]).text,
        'ÁÉÍÓÖŐÚÜŰ',
      );
      expect(
        decodeText([0xE1, 0xE9, 0xED, 0xF3, 0xF6, 0xF5, 0xFA, 0xFC, 0xFB]).text,
        'áéíóöőúüű',
      );
    });

    test('punctuation and the euro sign', () {
      expect(decodeText([0x80, 0x20, 0x31]).text, '€ 1');
      expect(decodeText([0x96, 0x97]).text, '–—');
      expect(decodeText([0x84, 0x93, 0x94, 0x85]).text, '„“”…');
      expect(decodeText([0xA0]).text, ' ');
      expect(decodeText([0xF7, 0xD7, 0xB0]).text, '÷×°');
    });

    test('a byte the code page has nothing for is a replacement character', () {
      expect(decodeText([0x81, 0x83, 0x88, 0x90, 0x98, 0xE1]).text, '�����á');
    });

    test('a lone high byte, and a cut multi-byte sequence', () {
      expect(decodeText([0x61, 0xE9]).text, 'aé');
      final cut = decodeText([0x61, 0xE2, 0x82]);
      expect(cut.encoding, TextEncoding.windows1250);
      expect(cut.text, 'aâ‚');
    });

    test('the byte 0x7F is itself, in text that is not UTF-8', () {
      expect(decodeText([0x7F, 0xE9]).text, '\u007Fé');
      expect(decodeText([0x7F, 0xE9]).encoding, TextEncoding.windows1250);
    });

    test('a byte that starts like a UTF-16 mark but is not one', () {
      expect(decodeText([0xFF, 0x41]).text, '\u02D9A');
      expect(decodeText([0xFE, 0x41]).text, '\u0163A');
      expect(decodeText([0x41, 0xFE]).text, 'A\u0163');
      expect(decodeText([0xFF, 0x41]).encoding, TextEncoding.windows1250);
    });

    test('every byte from 0x80 up, by a table written out in letters', () {
      // (a "_" stands for the seven that cannot be shown here: five bytes the
      // code page has nothing for, the no-break space and the soft hyphen)
      const rows = [
        '€_‚_„…†‡_‰Š‹ŚŤŽŹ',
        '_‘’“”•–—_™š›śťžź',
        '_ˇ˘Ł¤Ą¦§¨©Ş«¬_®Ż',
        '°±˛ł´µ¶·¸ąş»Ľ˝ľż',
        'ŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎ',
        'ĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢß',
        'ŕáâăäĺćçčéęëěíîď',
        'đńňóôőö÷řůúűüýţ˙',
      ];
      final text = decodeText([for (var b = 0x80; b <= 0xFF; b++) b]).text;
      expect(text.runes, hasLength(128));
      final chars = text.runes.toList();
      for (var i = 0; i < 128; i++) {
        final want = rows[i ~/ 16][i % 16];
        if (want == '_') continue;
        expect(
          String.fromCharCode(chars[i]),
          want,
          reason: 'byte 0x${(0x80 + i).toRadixString(16)}',
        );
      }
      for (final b in [0x81, 0x83, 0x88, 0x90, 0x98]) {
        expect(chars[b - 0x80], 0xFFFD, reason: '$b');
      }
      expect(chars[0xA0 - 0x80], 0x00A0);
      expect(chars[0xAD - 0x80], 0x00AD);
    });

    test('the table is whole: 128 entries, each letter once', () {
      expect(windows1250High, hasLength(128));
      final real = windows1250High.where((u) => u != 0xFFFD).toList();
      expect(real, hasLength(123));
      expect(real.toSet(), hasLength(123));
      // (bytes 0x80 and 0xFF, the two ends)
      expect(windows1250High.first, 0x20AC);
      expect(windows1250High.last, 0x02D9);
    });
  });

  group('UTF-16', () {
    test('little endian, with its mark', () {
      final bytes = [0xFF, 0xFE];
      for (final u in 'Á1;ő'.codeUnits) {
        bytes
          ..add(u & 0xFF)
          ..add(u >> 8);
      }
      final d = decodeText(bytes);
      expect(d.text, 'Á1;ő');
      expect(d.encoding, TextEncoding.utf16le);
    });

    test('big endian, with its mark', () {
      final bytes = [0xFE, 0xFF];
      for (final u in 'Á1;ő'.codeUnits) {
        bytes
          ..add(u >> 8)
          ..add(u & 0xFF);
      }
      final d = decodeText(bytes);
      expect(d.text, 'Á1;ő');
      expect(d.encoding, TextEncoding.utf16be);
    });

    test('a mark and nothing else, big endian too', () {
      final d = decodeText([0xFE, 0xFF]);
      expect(d.text, '');
      expect(d.encoding, TextEncoding.utf16be);
      expect(decodeText([0xFE, 0xFF, 0xD8, 0x3D, 0xDE, 0x00]).text, '😀');
    });

    test('a pair of surrogates, and a stray last byte', () {
      expect(decodeText([0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE]).text, '😀');
      expect(decodeText([0xFF, 0xFE, 0x41, 0x00, 0x42]).text, 'A');
      expect(decodeText([0xFF, 0xFE]).text, '');
    });
  });
}
