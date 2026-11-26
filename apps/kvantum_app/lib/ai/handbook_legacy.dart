import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-1 of every default text these handbook files have shipped with so far
/// (trimmed, `\n` line ends). A copy the user saved that is byte-for-byte one
/// of them was never edited, so the newer default applies instead (the
/// defaults were rewritten shorter; an unedited copy must not keep the old,
/// longer text alive). A file the user really changed is never touched.
const kLegacyHandbookHashes = <String, Set<String>>{
  'rules': {
    '483987903761dc012aa38822daf1e7b2fbda146d',
    '962f6a0bd1e25b467b45424c8793e27bc0130718',
    '90a578b513f3c667612dccc2ca7e4db1ed1bdad7',
    '19a18573d1b8cdac048b6d0f6caacfcf0d0ed1e6',
    'e443413fda379195f35a53f6e5cd71baf2260cd3',
    'dcdb11a078435108059f77001f1b2c5f275daa4a',
    '4cf8df4f499f89822519866d1c023aef88829ccc',
  },
  'output-format': {
    '05d0857ee8e8bdefbf5119818fedd78b1e8f0c01',
    'cf72dd24ccab81045eda0d527ba8a472b4872cc8',
  },
  'relations': {'c2f2d1d3470144b1a3929f749e6582f5f193e499'},
  'calendar-semantics': {
    'df6f0502524fa1967c9aa456de9a5a2183433aba',
    'f53022933d3ed5c8d0a9ebb4aeb3d8259ed3d875',
  },
  'profile': {
    'b9586c61395fc345eb03863988f6ddcaaaac720a',
    'e3d57150878d10e7e7546db3f139c5f5250769f7',
    '2ee30032f4cbd10b126805cd63d093cc5329b520',
  },
};

String _normalise(String text) => text.replaceAll('\r\n', '\n').trim();

/// Whether [text] is one of the retired default texts of handbook file [id].
bool isLegacyHandbookDefault(String id, String text) {
  final known = kLegacyHandbookHashes[id];
  if (known == null) return false;
  return known.contains(sha1.convert(utf8.encode(_normalise(text))).toString());
}
