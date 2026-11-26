import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Signed updates (SEC-3).
///
/// A release is accepted on the strength of its SHA-256 alone only as long as
/// whoever can change the release can change the checksum next to it. The
/// signature closes that: it is made with a private key that lives only in the
/// repository's secrets, and the app checks it with the public key built into
/// it.
///
/// What is signed is a text like `build-85|e00dc5...` (the build number, a
/// bar, the SHA-256 of the package in lowercase hex) with Ed25519 (RFC 8032,
/// "pure": the text itself, not a hash of it - what `openssl pkeyutl -sign
/// -rawin` makes). The build number is in the text so that a signature made
/// for one build cannot be passed off for another (an old, vulnerable release
/// put back under a new tag); the hash ties it to the file.

/// The text that is signed for the package of build [build] whose SHA-256 is
/// [sha256Hex].
String updateSignatureMessage(int build, String sha256Hex) =>
    'build-$build|${sha256Hex.trim().toLowerCase()}';

/// Base64 as people and tools write it: the standard or the URL-safe alphabet,
/// with or without the `=` padding, with line breaks anywhere. Null when it is
/// not base64 at all.
Uint8List? decodeLenientBase64(String text) {
  var s = text.replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return null;
  // (Dart's decoder reads both alphabets, but wants the padding)
  s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
  try {
    return base64.decode(s);
  } on FormatException {
    return null;
  }
}

/// The keys in a `UPDATE_PUBLIC_KEY` value: one or more, separated by commas
/// (white space and semicolons do as well). Several keys let a key be replaced
/// without stranding the apps that have the old one: a build that trusts both
/// is released first.
List<String> parseUpdatePublicKeys(String raw) =>
    raw.split(RegExp(r'[\s,;]+')).where((k) => k.isNotEmpty).toList();

/// The usable keys among [keys] (raw 32-byte Ed25519 public keys in base64);
/// what is not one is left out.
List<ed.PublicKey> decodeUpdatePublicKeys(Iterable<String> keys) {
  final out = <ed.PublicKey>[];
  for (final k in keys) {
    final bytes = decodeLenientBase64(k);
    if (bytes != null && bytes.length == ed.PublicKeySize) {
      out.add(ed.PublicKey(bytes));
    }
  }
  return out;
}

/// Whether [signatureB64] (the 64 raw bytes of an Ed25519 signature in base64)
/// is a valid signature of build [build]'s package with checksum [sha256Hex]
/// by any of [publicKeys]. Never throws: whatever is wrong - a key or a
/// signature that is no base64, the wrong length, another build, another file,
/// another key - is "no".
bool verifyUpdateSignature({
  required Iterable<String> publicKeys,
  required int build,
  required String sha256Hex,
  required String signatureB64,
}) {
  try {
    final sig = decodeLenientBase64(signatureB64);
    // (a signature that is not 64 bytes long is no signature: verify says no)
    if (sig == null) return false;
    final message = Uint8List.fromList(
      utf8.encode(updateSignatureMessage(build, sha256Hex)),
    );
    for (final key in decodeUpdatePublicKeys(publicKeys)) {
      if (ed.verify(key, message, sig)) return true;
    }
  } catch (_) {
    // (a library that objects to its input is "no" as well)
  }
  return false;
}
