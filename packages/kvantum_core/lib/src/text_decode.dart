/// Text from the bytes of a file that a bank, a spreadsheet or a text editor
/// wrote: UTF-8 (with or without a byte-order mark), UTF-16 (the "Unicode text"
/// of a spreadsheet) or, when it is neither, Windows-1250 (the Central European
/// code page that Hungarian banks and older programs still write; it has every
/// Hungarian letter where ISO 8859-2 has it, too).
library;

import 'dart:convert';

enum TextEncoding { utf8, utf16le, utf16be, windows1250 }

class DecodedText {
  const DecodedText(this.text, this.encoding);
  final String text;
  final TextEncoding encoding;
}

/// Reads [bytes] as text; never throws.
DecodedText decodeText(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return DecodedText(
      _utf16(bytes, 2, littleEndian: true),
      TextEncoding.utf16le,
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return DecodedText(
      _utf16(bytes, 2, littleEndian: false),
      TextEncoding.utf16be,
    );
  }
  try {
    // (the decoder leaves out a byte-order mark by itself)
    return DecodedText(utf8.decode(bytes), TextEncoding.utf8);
  } on FormatException {
    return DecodedText(_windows1250(bytes), TextEncoding.windows1250);
  }
}

String _utf16(List<int> bytes, int from, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = from; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

String _windows1250(List<int> bytes) => String.fromCharCodes([
  for (final b in bytes) b < 0x80 ? b : windows1250High[b - 0x80],
]);

/// What the bytes 0x80 to 0xFF of Windows-1250 stand for (U+FFFD where the code
/// page has nothing).
const windows1250High = <int>[
  // 0x80
  0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021,
  0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
  // 0x90
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
  // 0xA0
  0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7,
  0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
  // 0xB0
  0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
  0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
  // 0xC0
  0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
  0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
  // 0xD0
  0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
  0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
  // 0xE0
  0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
  0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
  // 0xF0
  0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
  0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
];
