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

/// The days of each series that are gone, by the id of the series: its
/// EXDATEs, and the original days of its cancelled occurrences. A cancelled
/// occurrence (what Google sends when one day is deleted there) is a row of its
/// own on the device, while a file writes it as an EXDATE of the series: both
/// say "that day is gone", and only that is compared.
Map<String, Set<DateTime>> _goneDays(Iterable<CalEvent> events) {
  final gone = <String, Set<DateTime>>{};
  for (final e in events) {
    if (e.isException) {
      if (e.cancelled && e.originalStart != null) {
        (gone[e.recurringEventId!] ??= {}).add(e.originalStart!);
      }
    } else {
      (gone[e.id] ??= {}).addAll(e.exdates);
    }
  }
  return gone;
}

bool _same(
  CalEvent a,
  CalEvent b, {
  required Set<DateTime> goneA,
  required Set<DateTime> goneB,
}) =>
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
    goneA.length == goneB.length &&
    goneA.containsAll(goneB);

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
  final onDevice = await repo.all();
  final existing = {for (final e in onDevice) e.id: e};
  final problems = [...parsed.problems];
  final incoming = _asTheDeviceKnowsThem(
    parsed.events,
    onDevice,
    existing,
    problems,
  );
  final goneHere = _goneDays(onDevice);
  final goneInFile = _goneDays(incoming);
  final fresh = <CalEvent>[];
  final changes = <ImportChange>[];
  var unchanged = 0;
  for (final e in incoming) {
    final old = existing[e.id];
    if (old == null) {
      fresh.add(e);
    } else if (_same(
      old,
      e,
      goneA: goneHere[old.id] ?? const {},
      goneB: goneInFile[e.id] ?? const {},
    )) {
      unchanged++;
    } else {
      changes.add(ImportChange(old, e));
    }
  }
  return ImportPlan(
    fresh: fresh,
    changes: changes,
    unchanged: unchanged,
    problems: problems,
  );
}

/// The events of a file under the ids and series of this device.
///
/// A file from Google carries, as the UID of an event, what the device keeps as
/// the event's iCalUID (the device's own id is another one): such an event is
/// that same event, not a new one, and a moved day of its series stays with the
/// series under the device's id.
///
/// A moved day (a row with a RECURRENCE-ID) whose series is neither in the
/// file nor on the device would be stored, but never seen (a day is only shown
/// through its series). It is taken over as an event of its own instead, and
/// the problems say so; a cancelled one is left out.
List<CalEvent> _asTheDeviceKnowsThem(
  List<CalEvent> events,
  List<CalEvent> onDevice,
  Map<String, CalEvent> existing,
  List<String> problems,
) {
  final byUid = {
    for (final e in onDevice)
      if (!e.isException && e.iCalUid != null) e.iCalUid!: e,
  };
  // the id, on the device, of each event and series of the file
  final deviceId = <String, String>{};
  for (final e in events) {
    if (e.isException) continue;
    final own = existing.containsKey(e.id) ? e.id : byUid[e.id]?.id;
    if (own != null) deviceId[e.id] = own;
  }
  final inFile = {
    for (final e in events)
      if (!e.isException) e.id,
  };
  final out = <CalEvent>[];
  for (final e in events) {
    if (!e.isException) {
      final id = deviceId[e.id];
      out.add(id == null || id == e.id ? e : e.copyWith(id: id));
      continue;
    }
    final uid = e.recurringEventId!;
    final series = deviceId[uid] ?? (existing.containsKey(uid) ? uid : null);
    if (series == null && !inFile.contains(uid)) {
      if (e.cancelled) {
        problems.add(
          '„${e.title}”: egy olyan sorozat lemondott napja, amely sem a '
          'fájlban, sem az eszközön nincs, kihagytam.',
        );
      } else {
        problems.add(
          '„${e.title}”: a sorozata sem a fájlban, sem az eszközön nincs, '
          'ezért önálló eseményként vettem át.',
        );
        out.add(_standalone(e));
      }
      continue;
    }
    if (series == null || series == uid) {
      out.add(e);
      continue;
    }
    // the device calls the series by another id, and so it does the moved day
    final row = onDevice
        .where(
          (x) =>
              x.recurringEventId == series &&
              x.originalStart == e.originalStart,
        )
        .firstOrNull;
    out.add(
      e.copyWith(
        recurringEventId: series,
        id: row?.id ?? '$series#${e.originalStart!.toIso8601String()}',
      ),
    );
  }
  return out;
}

/// [e] (a moved day of a series) as an event of its own, at its moved time.
CalEvent _standalone(CalEvent e) => CalEvent(
  id: e.id,
  calendarId: e.calendarId,
  title: e.title,
  notes: e.notes,
  location: e.location,
  start: e.start,
  end: e.end,
  tzid: e.tzid,
  allDay: e.allDay,
  colorId: e.colorId,
  aiGenerated: e.aiGenerated,
);

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
