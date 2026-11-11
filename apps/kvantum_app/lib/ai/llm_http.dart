import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

/// A service message without anything that looks like a key, bounded. [key] is
/// the key in use: it is removed wherever it appears, whatever it looks like.
String redactSecrets(String message, {String? key, int max = 400}) {
  var m = message;
  if (key != null && key.length >= 6) m = m.replaceAll(key, '[kulcs]');
  final clean = m
      .replaceAll(RegExp(r'(sk-|gsk_|AIza)[0-9A-Za-z_\-]{10,}'), '[kulcs]')
      .replaceAll(
        RegExp(r'Bearer\s+[0-9A-Za-z._\-]{10,}', caseSensitive: false),
        'Bearer [kulcs]',
      )
      .replaceAll(RegExp(r'\b[0-9A-Za-z]{32,}\b'), '[kulcs]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.length > max ? '${clean.substring(0, max)}…' : clean;
}

/// Runs one HTTP call. Every way it can fail on the wire (no connection, a
/// broken TLS handshake, a closed client, no answer in time) becomes an
/// [LlmNetwork].
Future<http.Response> sendGuarded(
  Future<http.Response> Function() call,
  Duration timeout,
) async {
  try {
    return await call().timeout(timeout);
  } on TimeoutException {
    throw const LlmNetwork('A modell nem válaszolt időben.', timeout: true);
  } on SocketException catch (e) {
    throw LlmNetwork('Nincs kapcsolat: ${e.message}');
  } on http.ClientException catch (e) {
    throw LlmNetwork('Nincs kapcsolat: ${e.message}');
  } on IOException catch (e) {
    throw LlmNetwork('Nincs kapcsolat: $e');
  }
}

/// [sendGuarded] plus the shared handling of the answer: a 2xx body becomes a
/// JSON object ([notJson] is the message when it is none), anything else is
/// turned into the service-specific exception by [errorFor].
Future<Map<String, dynamic>> sendJson(
  Future<http.Response> Function() call, {
  required Duration timeout,
  required LlmException Function(
    int status,
    String body,
    Map<String, String> headers,
  )
  errorFor,
  required String notJson,
}) async {
  final res = await sendGuarded(call, timeout);
  final text = utf8.decode(res.bodyBytes, allowMalformed: true);
  if (res.statusCode >= 200 && res.statusCode < 300) {
    try {
      final j = jsonDecode(text);
      if (j is Map<String, dynamic>) return j;
    } on FormatException {
      // falls through
    }
    throw LlmBadResponse(notJson);
  }
  throw errorFor(res.statusCode, text, res.headers);
}
