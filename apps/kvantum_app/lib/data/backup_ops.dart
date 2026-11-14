import 'dart:isolate';

import 'package:kvantum_core/kvantum_core.dart';

import 'event_repository.dart';

/// All calendar events as an .ics text (the backup).
Future<String> exportBackup(EventRepository repo) async =>
    exportIcs(await repo.all());

/// A backup text longer than this is read on another isolate, so a large file
/// does not freeze the screen while it is parsed.
const isolateParseThreshold = 200000;

/// Runs [job] somewhere else (by default on a new isolate).
typedef IcsRunner = Future<IcsImport> Function(IcsImport Function() job);

Future<IcsImport> _onIsolate(IcsImport Function() job) => Isolate.run(job);

/// Reads an .ics text. Small texts are read right here, large ones through
/// [runner] (an isolate), because reading is the slow part.
Future<IcsImport> readBackupText(
  String text, {
  required String calendarId,
  int threshold = isolateParseThreshold,
  IcsRunner runner = _onIsolate,
}) {
  if (text.length <= threshold) {
    return Future.value(parseIcs(text, calendarId: calendarId));
  }
  return runner(() => parseIcs(text, calendarId: calendarId));
}

/// An event of the file that differs from the one on this device.
class ImportChange {
  const ImportChange(this.current, this.incoming);
  final CalEvent current;
  final CalEvent incoming;
}

/// What restoring a file would do, worked out before anything is written.
class ImportPlan {
  const ImportPlan({
    this.fresh = const [],
    this.changes = const [],
    this.unchanged = 0,
    this.problems = const [],
  });

  /// Events the device does not have.
  final List<CalEvent> fresh;

  /// Events the device has, but changed since the file was written; restoring
  /// them would overwrite what is on the device now.
  final List<ImportChange> changes;
  final int unchanged;
  final List<String> problems;

  /// Nothing usable was found in the file.
  bool get empty => fresh.isEmpty && changes.isEmpty && unchanged == 0;
}

class ImportResult {
  const ImportResult({
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.kept = 0,
    this.problems = const [],
  });
  final int added;
  final int updated;
  final int unchanged;

  /// Changed events left as they are (the user chose "only the new ones").
  final int kept;
  final List<String> problems;
  int get total => added + updated;
}

/// The rule of [e] in one fixed spelling, so that two spellings of the same
/// series compare equal. The rule editor writes the limit of a series as the
/// end of a day (`…T235959Z`); a file carries the UTC instant of the LAST
/// occurrence, which reads back as the wall-clock time of that occurrence
/// (`…T090000Z`). The same occurrences, spelled differently: without this the
/// device's own fresh backup would show its series as "changed". Only used for
/// comparing, never stored. A rule the recurrence engine refuses cannot be
/// converted: it is compared as plain text.
String? _canonicalRule(CalEvent e) {
  final rule = e.rrule;
  if (rule == null) return null;
  final bare = rule.replaceFirst(RegExp('^RRULE:', caseSensitive: false), '');
  try {
    return rruleFromGoogle(
      rruleToGoogle(bare, e.start, e.tzid, allDay: e.allDay),
      e.tzid,
      allDay: e.allDay,
    );
  } catch (_) {
    return bare;
  }
}

bool _same(CalEvent a, CalEvent b) =>
    a.title == b.title &&
    a.notes == b.notes &&
    a.location == b.location &&
    a.start == b.start &&
    a.end == b.end &&
    a.tzid == b.tzid &&
    a.allDay == b.allDay &&
    _canonicalRule(a) == _canonicalRule(b) &&
    a.colorId == b.colorId &&
    a.aiGenerated == b.aiGenerated &&
    a.recurringEventId == b.recurringEventId &&
    a.originalStart == b.originalStart &&
    a.cancelled == b.cancelled &&
    a.exdates.length == b.exdates.length &&
    a.exdates.every(b.exdates.contains);

/// Reads a backup and compares it with the events on this device. Writes
/// nothing: the caller shows [ImportPlan.changes] and asks before
/// [applyBackup] overwrites them (the file carries no per-event modification
/// time, so "the newer one wins" cannot be decided here).
Future<ImportPlan> previewBackup(
  EventRepository repo,
  String text, {
  required String calendarId,
  int threshold = isolateParseThreshold,
  IcsRunner runner = _onIsolate,
}) async {
  final parsed = await readBackupText(
    text,
    calendarId: calendarId,
    threshold: threshold,
    runner: runner,
  );
  final existing = {for (final e in await repo.all()) e.id: e};
  final fresh = <CalEvent>[];
  final changes = <ImportChange>[];
  var unchanged = 0;
  for (final e in parsed.events) {
    final old = existing[e.id];
    if (old == null) {
      fresh.add(e);
    } else if (_same(old, e)) {
      unchanged++;
    } else {
      changes.add(ImportChange(old, e));
    }
  }
  return ImportPlan(
    fresh: fresh,
    changes: changes,
    unchanged: unchanged,
    problems: parsed.problems,
  );
}

/// Writes [plan]: the new events always, and the changed ones only when
/// [overwrite] is true. A restored event keeps its Google link, so sync does
/// not create duplicates. Nothing is ever deleted.
Future<ImportResult> applyBackup(
  EventRepository repo,
  ImportPlan plan, {
  required bool overwrite,
}) async {
  final toSave = <CalEvent>[...plan.fresh];
  if (overwrite) {
    // (saving keeps the stored Google link of an event, so sync updates the
    // event over there instead of creating a second one)
    for (final c in plan.changes) {
      toSave.add(c.incoming.copyWith(version: c.current.version + 1));
    }
  }
  // one unit: a long import is not left half done, and the screens change once
  await repo.saveAll(toSave);
  return ImportResult(
    added: plan.fresh.length,
    updated: overwrite ? plan.changes.length : 0,
    unchanged: plan.unchanged,
    kept: overwrite ? 0 : plan.changes.length,
    problems: plan.problems,
  );
}

/// Restores events from an .ics text in one go (preview + apply). [overwrite]
/// has no default on purpose: a caller must say whether changed events may be
/// replaced.
Future<ImportResult> importBackup(
  EventRepository repo,
  String text, {
  required String calendarId,
  required bool overwrite,
}) async => applyBackup(
  repo,
  await previewBackup(repo, text, calendarId: calendarId),
  overwrite: overwrite,
);
