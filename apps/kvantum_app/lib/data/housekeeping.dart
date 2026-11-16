import 'dart:convert';

import 'event_repository.dart';
import 'finance_repository.dart';

/// How long the marker of a deleted record is kept. A marker has to outlive
/// the device that has been away the longest; a device away for longer than
/// this would bring a deleted record back, which is the price of not keeping
/// markers for ever.
const tombstoneRetention = Duration(days: 365);

/// What one round of upkeep removed or put right.
class HousekeepingReport {
  const HousekeepingReport({
    this.finance = 0,
    this.requeued = 0,
    this.removed = 0,
    this.staleQueue = 0,
    this.photos = 0,
  });

  /// Markers of deleted finance records that were old enough to go.
  final int finance;

  /// Deleted events whose deletion was queued again.
  final int requeued;

  /// Deletion markers without a Google link, removed.
  final int removed;

  /// Queue entries of events that no longer exist, removed.
  final int staleQueue;

  /// Pictures of the diary that no entry refers to any more, removed.
  final int photos;

  bool get any => finance + requeued + removed + staleQueue + photos > 0;

  Map<String, int> toJson() => {
    'finance': finance,
    'requeued': requeued,
    'removed': removed,
    'staleQueue': staleQueue,
    'photos': photos,
  };
}

/// Quiet upkeep of the local data, at most once a day and only after the
/// first screen is up (see the root shell). It never touches anything that
/// still has to be uploaded.
class Housekeeping {
  Housekeeping({
    required this.events,
    required this.finance,
    required this.now,
    this.sweepPhotos,
  });

  final EventRepository events;
  final FinanceRepository finance;

  /// Removes the pictures of the diary nobody refers to (and says how many);
  /// null where there are none to tidy. A failure here does not stop the rest.
  final Future<int> Function(DateTime now)? sweepPhotos;

  /// The clock (replaced by tests).
  final DateTime Function() now;

  /// The day (UTC date) of the last round, and what it did.
  static const dayKey = 'housekeepingDay';
  static const lastKey = 'housekeepingLast';

  /// Null when today's round has been done already.
  Future<HousekeepingReport?> runIfDue() async {
    final at = now().toUtc();
    final day = at.toIso8601String().substring(0, 10);
    if (await events.meta(dayKey) == day) return null;
    final fin = await finance.purgeTombstones(
      at.millisecondsSinceEpoch - tombstoneRetention.inMilliseconds,
    );
    final ev = await events.purgeOrphans();
    var photos = 0;
    try {
      photos = await sweepPhotos?.call(at) ?? 0;
    } catch (_) {
      // (a folder that cannot be read is tried again tomorrow)
    }
    final report = HousekeepingReport(
      finance: fin,
      requeued: ev.requeued,
      removed: ev.removed,
      staleQueue: ev.stale,
      photos: photos,
    );
    await events.setMeta(lastKey, jsonEncode({'day': day, ...report.toJson()}));
    await events.setMeta(dayKey, day);
    return report;
  }
}
