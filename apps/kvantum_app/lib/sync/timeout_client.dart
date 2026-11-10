import 'dart:async';

import 'package:http/http.dart' as http;

/// Gives every HTTP call a deadline. Without one, a dead connection (a phone
/// that fell asleep mid-request, a captive portal that never answers) leaves
/// the call waiting forever, and the sync waiting for it would block every
/// later sync until the app is restarted.
///
/// [responseTimeout] is the time allowed until the response headers arrive,
/// [idleTimeout] the longest silence allowed while the body is streaming.
/// Both end in a [TimeoutException], which the callers already treat as a
/// transient network problem.
class TimeoutClient extends http.BaseClient {
  TimeoutClient(
    this._inner, {
    this.responseTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 30),
  });

  final http.Client _inner;
  final Duration responseTimeout;
  final Duration idleTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _inner.send(request).timeout(responseTimeout);
    return http.StreamedResponse(
      res.stream.timeout(idleTimeout),
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
