import '../data/event_repository.dart';
import '../data/record_repository.dart';
import 'remote.dart';
import 'sync_engine.dart' show syncBindingKey;

/// Ways to start the sync over without losing anything.
///
/// Google's side is never deleted from here. What a reset does is forget the
/// *links* (which Google event belongs to which local event, where the listing
/// stopped) and queue everything again; the uploads find the existing Google
/// events by their own id (`appEventId`), so nothing is duplicated.
class SyncResetOps {
  SyncResetOps({
    required this.events,
    required this.records,
    required this.resetMailbox,
  });

  final EventRepository events;
  final RecordRepository records;

  /// Makes the finance mailbox greet everybody again.
  final Future<void> Function() resetMailbox;

  static String _tokenKey(String calendarId) => 'syncToken:$calendarId';

  /// "Szinkron alaphelyzetbe": same account, everything re-linked.
  /// Returns how many events were queued for upload.
  Future<int> resetAll(String calendarId) async {
    final queued = await events.atomically(() async {
      await events.unlinkLive(calendarId);
      await events.setMeta(_tokenKey(calendarId), null);
      return events.requeueLive(calendarId);
    });
    await events.resetAttempts();
    await records.resetSync();
    await resetMailbox();
    return queued;
  }

  /// Another account / calendar, local events are kept: they go up to the new
  /// one. Deletions that were waiting for the old calendar are forgotten.
  Future<int> rebindKeepLocal(String calendarId, RemoteIdentity to) async {
    final queued = await events.atomically(() async {
      await events.dropTombstones(calendarId);
      await events.unlinkLive(calendarId);
      await events.setMeta(_tokenKey(calendarId), null);
      final n = await events.requeueLive(calendarId);
      await events.setMeta(syncBindingKey, to.key);
      return n;
    });
    await events.resetAttempts();
    await records.resetSync();
    await resetMailbox();
    return queued;
  }

  /// Another account / calendar, start with ITS events: the local calendar
  /// events (and what was queued for them) are removed. Tasks, check-ins and
  /// finance data are not calendar events and stay.
  Future<void> rebindFresh(String calendarId, RemoteIdentity to) async {
    await events.atomically(() async {
      await events.clearCalendar(calendarId);
      await events.setMeta(_tokenKey(calendarId), null);
      await events.setMeta(syncBindingKey, to.key);
    });
    await records.resetSync();
    await resetMailbox();
  }
}
