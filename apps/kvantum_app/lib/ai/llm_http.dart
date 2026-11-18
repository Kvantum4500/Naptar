import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_provider.dart';

// (moved to the diagnostics code, which needs it too; the old import path of
// the two providers keeps working)
export '../diag/redact.dart' show redactSecrets;

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
  } on SocketException {
    throw const LlmNetwork('Nincs kapcsolat a szolgáltatással.');
  } on http.ClientException {
    throw const LlmNetwork('Nincs kapcsolat a szolgáltatással.');
  } on IOException {
    throw const LlmNetwork('Nincs kapcsolat a szolgáltatással.');
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
