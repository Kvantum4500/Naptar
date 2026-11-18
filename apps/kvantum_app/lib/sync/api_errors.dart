/// What a failed Google API call means for the sync, decided from the HTTP
/// status and the error detail Google sends. One place for both the Calendar
/// and the Drive adapter, so the rules cannot drift apart.
enum ApiFailure {
  /// 429 or a 403 usage limit: back off and try again later.
  throttled,

  /// A limit that lasts for the day (`dailyLimitExceeded`).
  dailyLimit,

  /// 5xx / request timeout: the server is having a bad moment.
  server,

  /// 401: the credentials were not accepted this time.
  auth,

  /// The call is wrong for THIS item (400, permissions): retrying the same
  /// request will not help, the item has to wait for an edit or a decision.
  itemRejected,

  /// 404 / 410: the thing is gone.
  gone,

  /// 412: the etag is stale.
  conflict,

  /// The sync token / page token is not valid any more.
  tokenInvalid,
}

/// Reasons Google uses for "too many requests" (Calendar and Drive).
const _throttleReasons = {
  'ratelimitexceeded',
  'userratelimitexceeded',
  'calendarusagelimitsexceeded',
  'quotaexceeded',
  'sharingratelimitexceeded',
};

/// Classifies an API error. [reason], [domain] and [location] are the first
/// error detail (`errors[0].reason` / `.domain` / `.location`), [message] the
/// human text.
ApiFailure classifyApiError({
  required int status,
  String? reason,
  String? domain,
  String? message,
  String? location,
}) {
  final r = (reason ?? '').toLowerCase();
  final d = (domain ?? '').toLowerCase();
  final m = (message ?? '').toLowerCase();
  final l = (location ?? '').toLowerCase();

  if (status == 401) return ApiFailure.auth;
  if (status == 412) return ApiFailure.conflict;
  if (status == 404) return ApiFailure.gone;
  if (status == 410) return ApiFailure.gone;
  if (status == 429) {
    return r == 'dailylimitexceeded'
        ? ApiFailure.dailyLimit
        : ApiFailure.throttled;
  }
  if (status == 408 || status >= 500) return ApiFailure.server;

  if (status == 403) {
    if (r == 'dailylimitexceeded') return ApiFailure.dailyLimit;
    if (_throttleReasons.contains(r) || d == 'usagelimits') {
      return ApiFailure.throttled;
    }
    return ApiFailure.itemRejected;
  }

  if (status == 400) {
    if (m.contains('sync token') ||
        m.contains('synctoken') ||
        m.contains('page') ||
        l.contains('synctoken') ||
        l.contains('pagetoken')) {
      return ApiFailure.tokenInvalid;
    }
    return ApiFailure.itemRejected;
  }

  return ApiFailure.itemRejected;
}

/// Whether the failure is a property of the moment (retry later) rather than
/// of the item.
bool isTransientFailure(ApiFailure f) => switch (f) {
  ApiFailure.throttled ||
  ApiFailure.dailyLimit ||
  ApiFailure.server ||
  ApiFailure.auth => true,
  _ => false,
};

/// Google refused THIS call for a reason that retrying will not change (a
/// malformed event, missing rights ...). The item waits for an edit or a
/// manual retry instead of being hammered.
class ItemRejectedError implements Exception {
  ItemRejectedError(this.status, this.reason, this.detail);
  final int status;
  final String? reason;
  final String? detail;

  @override
  String toString() {
    final d = (detail ?? '').replaceAll(RegExp(r'\s+'), ' ');
    final short = d.length > 120 ? d.substring(0, 120) : d;
    final r = reason == null || reason!.isEmpty ? '' : ' $reason';
    return 'http $status$r${short.isEmpty ? '' : ': $short'}';
  }
}

/// What a failed call tells the scheduler about when to try again.
abstract interface class RetryHint {
  /// The wait the server asked for (`Retry-After`), if any.
  Duration? get retryAfter;

  /// A rate / usage limit (as opposed to a network or server problem).
  bool get throttled;

  /// A limit that lasts for the day: waiting minutes will not help.
  bool get dailyLimit;
}
