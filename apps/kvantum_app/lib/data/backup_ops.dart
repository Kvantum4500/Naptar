import 'package:kvantum_core/kvantum_core.dart';

import 'event_repository.dart';

/// All calendar events as an .ics text (the backup).
Future<String> exportBackup(EventRepository repo) async =>
    exportIcs(await repo.all());

class ImportResult {
  const ImportResult({
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.problems = const [],
  });
  final int added;
  final int updated;
  final int unchanged;
  final List<String> problems;
  int get total => added + updated;
}

bool _same(CalEvent a, CalEvent b) =>
    a.title == b.title &&
    a.notes == b.notes &&
    a.location == b.location &&
    a.start == b.start &&
    a.end == b.end &&
    a.tzid == b.tzid &&
    a.allDay == b.allDay &&
    a.rrule == b.rrule &&
    a.colorId == b.colorId &&
    a.aiGenerated == b.aiGenerated &&
    a.recurringEventId == b.recurringEventId &&
    a.originalStart == b.originalStart &&
    a.exdates.length == b.exdates.length &&
    a.exdates.every(b.exdates.contains);

/// Restores events from an .ics text. Events with a known id are updated in
/// place (their Google link is kept, so sync does not create duplicates);
/// unchanged ones are skipped; new ones are added. Nothing is ever deleted.
Future<ImportResult> importBackup(
  EventRepository repo,
  String text, {
  required String calendarId,
}) async {
  final parsed = parseIcs(text, calendarId: calendarId);
  final existing = {for (final e in await repo.all()) e.id: e};
  var added = 0, updated = 0, unchanged = 0;
  for (final e in parsed.events) {
    final old = existing[e.id];
    if (old == null) {
      await repo.saveLocal(e);
      added++;
    } else if (_same(old, e)) {
      unchanged++;
    } else {
      await repo.saveLocal(
        e.copyWith(
          googleId: old.googleId,
          etag: old.etag,
          iCalUid: old.iCalUid,
          version: old.version + 1,
        ),
      );
      updated++;
    }
  }
  return ImportResult(
    added: added,
    updated: updated,
    unchanged: unchanged,
    problems: parsed.problems,
  );
}
