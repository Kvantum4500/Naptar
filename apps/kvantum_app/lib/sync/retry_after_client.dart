import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;

import '../diag/request_stats.dart';

/// The longest wait a server can impose on us: whatever it asks for, we look
/// again after at most this long.
const maxRetryAfter = Duration(hours: 1);

/// Reads a `Retry-After` header: delay seconds or an HTTP date.
Duration? parseRetryAfter(String? value, {required DateTime now}) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return null;
  final seconds = int.tryParse(v);
  if (seconds != null) {
    if (seconds < 0) return null;
    final d = Duration(seconds: seconds);
    return d > maxRetryAfter ? maxRetryAfter : d;
  }
  try {
    final wait = HttpDate.parse(v).difference(now.toUtc());
    if (wait.isNegative) return null;
    return wait > maxRetryAfter ? maxRetryAfter : wait;
  } catch (_) {
    return null;
  }
}

/// Remembers the `Retry-After` header of the most recent failed response.
///
/// The Google client libraries turn an error response into an exception that
/// carries only the decoded body, so the header would be lost; the adapters
/// ask this wrapper for it right after a failure ([takeRetryAfter]). Calls run
/// one after the other, so "the most recent failure" is the one being handled.
///
/// It also counts the calls and how they ended, per service ([stats]).
class RetryAfterClient extends http.BaseClient {
  RetryAfterClient(this._inner, {DateTime Function()? now, this._stats})
    : _now = now ?? DateTime.now;

  final http.Client _inner;
  final DateTime Function() _now;
  final RequestStats? _stats;
  Duration? _last;

  /// The wait the server asked for with its latest failure (once).
  Duration? takeRetryAfter() {
    final r = _last;
    _last = null;
    return r;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final service = serviceOfPath(request.url.path);
    final http.StreamedResponse res;
    try {
      res = await _inner.send(request);
    } on Object {
      _stats?.record(service, failed: true);
      rethrow;
    }
    _stats?.record(service, status: res.statusCode);
    _last = res.statusCode >= 400
        ? parseRetryAfter(res.headers['retry-after'], now: _now())
        : null;
    return res;
  }

  @override
  void close() => _inner.close();
}

/// The hint of [client], if it is a [RetryAfterClient].
Duration? retryAfterOf(http.Client client) =>
    client is RetryAfterClient ? client.takeRetryAfter() : null;
