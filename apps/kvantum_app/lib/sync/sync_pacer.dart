import 'dart:math';

/// When to look at Google again.
///
/// While things are happening the app checks every minute; when nothing has
/// changed for a while it slows down (a phone should not wake the radio every
/// minute for an unchanged calendar); after a failure it backs off, the
/// longer the more often it failed, and never sooner than the server asked.
class SyncPacer {
  SyncPacer({Random? random}) : _random = random ?? Random();
  final Random _random;

  /// The normal beat.
  static const base = Duration(seconds: 60);

  /// Longest wait after a network / server problem.
  static const maxNetworkBackoff = Duration(minutes: 5);

  /// Longest wait after Google said "too many requests".
  static const maxThrottleBackoff = Duration(minutes: 15);

  /// Shortest wait after a daily limit: waiting a few minutes cannot help.
  static const dailyBackoff = Duration(minutes: 30);

  /// When there is more to upload than one run does (see
  /// `SyncEngine.maxPushPerRun`): carry on soon, but not in a burst.
  static const followUp = Duration(seconds: 5);

  /// After a run that went well. [quietRuns] counts the runs in a row that
  /// found nothing to pull and nothing to push.
  Duration afterSuccess({required int quietRuns}) {
    if (quietRuns < 3) return base;
    if (quietRuns < 6) return const Duration(minutes: 3);
    if (quietRuns < 12) return const Duration(minutes: 5);
    return const Duration(minutes: 10);
  }

  /// After the [failures]-th failed run in a row (1 = the first).
  ///
  /// 60 s, 2, 4, 8 minutes ... up to the cap, spread by ±20 % so several
  /// devices do not come back at the same second, and at least [retryAfter]
  /// when the server named a time.
  Duration afterFailure({
    required int failures,
    Duration? retryAfter,
    bool throttled = false,
    bool dailyLimit = false,
  }) {
    final cap = throttled ? maxThrottleBackoff : maxNetworkBackoff;
    final steps = (failures < 1 ? 1 : failures) - 1;
    var seconds = base.inSeconds * pow(2, steps > 10 ? 10 : steps).toInt();
    if (seconds > cap.inSeconds) seconds = cap.inSeconds;
    final jittered = (seconds * (0.8 + 0.4 * _random.nextDouble())).round();
    var wait = Duration(seconds: jittered);
    // the floors come after the spreading: they are promises, not averages
    if (dailyLimit && wait < dailyBackoff) wait = dailyBackoff;
    if (retryAfter != null && retryAfter > wait) wait = retryAfter;
    return wait;
  }
}
