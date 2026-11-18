import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/update/update_signature.dart';

// Two signatures made by the real tool the release workflow uses (OpenSSL 3,
// `openssl pkeyutl -sign -rawin`), each by its own throwaway key (the private
// halves were thrown away): they prove that what the workflow signs is what the
// app checks. The text signed is `build-<N>|<sha256 of the package>`.
const keyA = 'L13WEzLmbA+wpgyOjCnoZq9BhqS5PKNPsJe1ruq+K2I=';
const buildA = 85;
const hashA =
    'e00dc5bcc97b33e03863bfe0c422174411347a85966f259d79906c529abdd711';
const sigA =
    'x45A52GtqDCig1bEnAsGe7Azt1xtDYd0Lpwhe+lEKcbKIdfdmpCHmWFGNxpkVD5cQ8WSz/nCDbRfoGokkGkeCA==';

const keyB = 'IY5J70ZiGvcPpYq8WVrx+QAvak+MTwuZtK2Bzki0M34=';
const buildB = 86;
const hashB =
    'f3d76851ee60a61ae31a1706ecd63dabefe7b860c4f5e886cef3c975bac76f8a';
const sigB =
    '5hFI/HvO0uyn0OJ+wNxStIbpuHtStWalwYZHec5AUBlS0YLeuU/HXVr1/M9ex9qtwC0WAN5Oda8ES/M7XD+qCQ==';

bool verify({
  List<String> keys = const [keyA],
  int build = buildA,
  String hash = hashA,
  String sig = sigA,
}) => verifyUpdateSignature(
  publicKeys: keys,
  build: build,
  sha256Hex: hash,
  signatureB64: sig,
);

/// [sig] with one bit of byte [index] flipped.
String flipped(String sig, int index) {
  final bytes = base64.decode(sig);
  bytes[index] ^= 0x01;
  return base64.encode(bytes);
}

void main() {
  group('what is signed', () {
    test('the build and the checksum, joined', () {
      expect(updateSignatureMessage(85, 'abc123'), 'build-85|abc123');
    });

    test(
      'the checksum is lower case and trimmed (the same text either way)',
      () {
        expect(updateSignatureMessage(7, '  ABCDEF12 \n'), 'build-7|abcdef12');
      },
    );

    test('the sample hashes are those of the sample "packages"', () {
      expect(sha256.convert(utf8.encode('package-85')).toString(), hashA);
      expect(sha256.convert(utf8.encode('package-86')).toString(), hashB);
    });
  });

  group('the signature of the real tool', () {
    test('is valid for its build, its file and its key', () {
      expect(verify(), isTrue);
      expect(
        verify(keys: [keyB], build: buildB, hash: hashB, sig: sigB),
        isTrue,
      );
    });

    test('is not valid for another build (an old release under a new tag)', () {
      expect(verify(build: buildA + 1), isFalse);
      expect(verify(build: buildA - 1), isFalse);
      expect(verify(build: 8), isFalse);
    });

    test('is not valid for another file', () {
      expect(verify(hash: hashB), isFalse);
      expect(
        verify(
          hash: '${hashA.substring(0, 63)}${hashA[63] == '0' ? '1' : '0'}',
        ),
        isFalse,
      );
      expect(verify(hash: ''), isFalse);
    });

    test('is not valid for another key', () {
      expect(verify(keys: [keyB]), isFalse);
    });

    test('a checksum in capitals or with spaces round it is the same file', () {
      expect(verify(hash: hashA.toUpperCase()), isTrue);
      expect(verify(hash: ' $hashA\n'), isTrue);
    });

    test('any one bit changed anywhere in the signature breaks it', () {
      for (var i = 0; i < 64; i++) {
        expect(verify(sig: flipped(sigA, i)), isFalse, reason: 'byte $i');
      }
    });

    test('one signature does not do for the other build\'s release', () {
      expect(verify(sig: sigB), isFalse);
      expect(
        verify(keys: [keyB], build: buildB, hash: hashB, sig: sigA),
        isFalse,
      );
    });
  });

  group('more than one key', () {
    test('a signature by any of them is accepted', () {
      expect(verify(keys: [keyA, keyB]), isTrue);
      expect(verify(keys: [keyB, keyA]), isTrue);
      expect(
        verify(keys: [keyA, keyB], build: buildB, hash: hashB, sig: sigB),
        isTrue,
      );
    });

    test('a signature by none of them is not', () {
      expect(verify(keys: [keyB, keyB, keyB]), isFalse);
    });

    test('a key that is no key is skipped, the others still count', () {
      expect(verify(keys: ['not a key', keyA]), isTrue);
      expect(verify(keys: ['AAAA', '', keyA, '!!!!']), isTrue);
    });

    test('with no usable key nothing is valid', () {
      expect(verify(keys: const []), isFalse);
      expect(verify(keys: ['', '   ']), isFalse);
      expect(verify(keys: ['AAAA']), isFalse); // 3 bytes
      // 31 and 33 bytes (a key one byte short or long)
      expect(verify(keys: [base64.encode(Uint8List(31))]), isFalse);
      expect(verify(keys: [base64.encode(Uint8List(33))]), isFalse);
    });
  });

  group('the signature as text', () {
    test('what the base64 tool writes (a line break at the end) is fine', () {
      expect(verify(sig: '$sigA\n'), isTrue);
      expect(verify(sig: '\r\n  $sigA \n\n'), isTrue);
    });

    test('without padding, or in the URL-safe alphabet, it is the same', () {
      final bare = sigA.replaceAll('=', '');
      expect(verify(sig: bare), isTrue);
      final urlSafe = sigA.replaceAll('+', '-').replaceAll('/', '_');
      expect(urlSafe, isNot(sigA));
      expect(verify(sig: urlSafe), isTrue);
    });

    test('broken across lines (as base64 wraps at 76) it is the same', () {
      final wrapped = '${sigA.substring(0, 40)}\n${sigA.substring(40)}';
      expect(verify(sig: wrapped), isTrue);
    });

    test('the key may be written the same ways', () {
      expect(verify(keys: [keyA.replaceAll('=', '')]), isTrue);
      expect(verify(keys: ['$keyA\n']), isTrue);
      expect(verify(keys: [keyA.replaceAll('+', '-')]), isTrue);
    });

    test('a signature of the wrong length is no signature', () {
      final bytes = base64.decode(sigA);
      expect(verify(sig: base64.encode(bytes.sublist(0, 63))), isFalse);
      expect(verify(sig: base64.encode([...bytes, 0])), isFalse);
      expect(verify(sig: base64.encode(Uint8List(64))), isFalse);
      expect(verify(sig: base64.encode(Uint8List(128))), isFalse);
    });

    test('what is not base64 is "no", never an error', () {
      for (final junk in [
        '',
        ' ',
        '\n',
        '!!!!',
        'A',
        '====',
        'x45A52Gtq DCig1bE',
        'ä' * 100,
        sigA.substring(1, 3),
        'x' * 100000,
      ]) {
        expect(
          verify(sig: junk),
          isFalse,
          reason: junk.length > 20 ? junk.substring(0, 20) : junk,
        );
      }
    });
  });

  group('base64 as it is written', () {
    test('standard, unpadded, URL-safe and wrapped forms decode alike', () {
      final bytes = Uint8List.fromList([251, 255, 190, 0, 1, 2, 3]);
      final std = base64.encode(bytes); // contains + and /
      expect(std, contains(RegExp(r'[+/]')));
      for (final form in [
        std,
        std.replaceAll('=', ''),
        base64Url.encode(bytes),
        base64Url.encode(bytes).replaceAll('=', ''),
        '${std.substring(0, 4)}\n${std.substring(4)}',
        ' $std ',
      ]) {
        expect(decodeLenientBase64(form), bytes, reason: form);
      }
    });

    test('nothing, or something that cannot be base64, is null', () {
      expect(decodeLenientBase64(''), isNull);
      expect(decodeLenientBase64('  \n'), isNull);
      expect(decodeLenientBase64('A'), isNull);
      expect(decodeLenientBase64('AAAAA'), isNull);
      expect(decodeLenientBase64('AB=C'), isNull);
      expect(decodeLenientBase64('AB*C'), isNull);
      expect(decodeLenientBase64('QQ==='), isNull, reason: 'too much padding');
      expect(decodeLenientBase64('=QQ'), isNull);
    });

    test('lengths that are valid without padding decode', () {
      expect(decodeLenientBase64('QQ'), [0x41]);
      expect(decodeLenientBase64('QUI'), [0x41, 0x42]);
      expect(decodeLenientBase64('QUJD'), [0x41, 0x42, 0x43]);
    });
  });

  group('the keys of the setting', () {
    test('one, or several separated by commas, white space or semicolons', () {
      expect(parseUpdatePublicKeys(keyA), [keyA]);
      expect(parseUpdatePublicKeys('$keyA,$keyB'), [keyA, keyB]);
      expect(parseUpdatePublicKeys('$keyA, $keyB'), [keyA, keyB]);
      expect(parseUpdatePublicKeys('$keyA\n$keyB\n'), [keyA, keyB]);
      expect(parseUpdatePublicKeys('$keyA;$keyB'), [keyA, keyB]);
      expect(parseUpdatePublicKeys(' , ,$keyA,, '), [keyA]);
    });

    test('nothing is no key', () {
      expect(parseUpdatePublicKeys(''), isEmpty);
      expect(parseUpdatePublicKeys('  \n '), isEmpty);
      expect(parseUpdatePublicKeys(',,;'), isEmpty);
    });

    test('only 32-byte keys are usable', () {
      expect(decodeUpdatePublicKeys([keyA, keyB]), hasLength(2));
      expect(decodeUpdatePublicKeys([keyA, 'AAAA', '', '???']), hasLength(1));
      expect(decodeUpdatePublicKeys([keyA]).single.bytes, base64.decode(keyA));
    });
  });

  group('the library, known answers (RFC 8032, section 7.1)', () {
    void vector(String message, String seed, String pub, String sig) {
      final privateKey = ed.newKeyFromSeed(
        Uint8List.fromList(hex.decode(seed)),
      );
      final publicKey = ed.public(privateKey);
      expect(hex.encode(publicKey.bytes), pub);
      final m = Uint8List.fromList(hex.decode(message));
      expect(hex.encode(ed.sign(privateKey, m)), sig);
      expect(
        ed.verify(publicKey, m, Uint8List.fromList(hex.decode(sig))),
        isTrue,
      );
      // and not a different message
      expect(
        ed.verify(
          publicKey,
          Uint8List.fromList([...m, 0]),
          Uint8List.fromList(hex.decode(sig)),
        ),
        isFalse,
      );
    }

    test('TEST 1 (the empty message)', () {
      vector(
        '',
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
    });

    test('TEST 2 (one byte)', () {
      vector(
        '72',
        '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
    });

    test('TEST 3 (two bytes)', () {
      vector(
        'af82',
        'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
        'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
      );
    });
  });

  group('the whole chain with a key made here', () {
    // (the key of RFC 8032 TEST 1: the private half is public on purpose)
    final privateKey = ed.newKeyFromSeed(
      Uint8List.fromList(
        hex.decode(
          '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
        ),
      ),
    );
    final key = base64.encode(ed.public(privateKey).bytes);

    String sign(int build, String hash) => base64.encode(
      ed.sign(
        privateKey,
        Uint8List.fromList(utf8.encode(updateSignatureMessage(build, hash))),
      ),
    );

    test('a signature made for a build is valid for that build only', () {
      final sig = sign(12, hashA);
      expect(verify(keys: [key], build: 12, hash: hashA, sig: sig), isTrue);
      expect(verify(keys: [key], build: 13, hash: hashA, sig: sig), isFalse);
      expect(verify(keys: [key], build: 12, hash: hashB, sig: sig), isFalse);
      expect(verify(keys: [keyA], build: 12, hash: hashA, sig: sig), isFalse);
    });

    test('the text signed is exactly build-N|hash', () {
      final sig = base64.decode(sign(5, hashB));
      expect(
        ed.verify(
          ed.public(privateKey),
          Uint8List.fromList(utf8.encode('build-5|$hashB')),
          sig,
        ),
        isTrue,
      );
      // (not with a space, a colon, or no "build-")
      for (final other in ['build-5 $hashB', 'build-5:$hashB', '5|$hashB']) {
        expect(
          ed.verify(
            ed.public(privateKey),
            Uint8List.fromList(utf8.encode(other)),
            sig,
          ),
          isFalse,
          reason: other,
        );
      }
    });
  });

  test('nothing the verifier is given makes it throw', () {
    for (final keys in [
      <String>[],
      [''],
      ['x' * 10000],
      [keyA, 'ä', '\u0000'],
    ]) {
      for (final sig in ['', 'x' * 50000, sigA, '\u0000\u0001', 'ä' * 90]) {
        for (final hash in ['', hashA, 'ü' * 80, 'z' * 100000]) {
          for (final build in [0, -1, 85, 1 << 40]) {
            expect(
              () => verify(keys: keys, build: build, hash: hash, sig: sig),
              returnsNormally,
            );
          }
        }
      }
    }
  });
}
