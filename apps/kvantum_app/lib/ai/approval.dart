import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../data/event_change.dart';
import '../data/event_repository.dart';
import '../ui/delete_ops.dart';
import '../ui/event_editor.dart' show Scope;
import '../ui/move_ops.dart';
import 'assistant_service.dart' show DeletionProposal, MoveProposal;

// What happens when the user presses "Engedélyezem" / "Elfogadom".
//
// A proposal is a snapshot of the calendar at the time the model answered, and
// its card can wait on the page for hours. So nothing is carried out blindly:
// each item is looked up in the LIVE calendar, compared with the snapshot and
// checked for clashes inside the same transaction that writes it. What has
// gone stale is left out and named; the rest is done, all in one unit that can
// be taken back with "Visszavonás".

/// An approval is being carried out. The buttons wait, and a second tap (or a
/// tap on another card) does nothing: a double tap must not create the events
/// twice.
class AssistantApplying extends Notifier<bool> {
  @override
  bool build() => false;

  /// Takes the turn. False when another approval is already running.
  bool begin() {
    if (state) return false;
    state = true;
    return true;
  }

  void end() {
    if (ref.mounted) state = false;
  }
}

final assistantApplyingProvider = NotifierProvider<AssistantApplying, bool>(
  AssistantApplying.new,
);

/// Why a proposal was left out when it was approved.
enum SkipReason {
  /// The event is no longer there (deleted, moved, its series changed).
  gone,

  /// It is there, but not as it was proposed (renamed, rescheduled …).
  changed,

  /// The new time clashes with something that is in the calendar now.
  clash,

  /// A new event whose time is already over.
  over,
}

class Skipped {
  const Skipped(this.title, this.reason);
  final String title;
  final SkipReason reason;
}

/// What an approval did.
class ApplyResult {
  const ApplyResult({this.applied = 0, this.skipped = const [], this.changes});

  /// How many proposals were carried out.
  final int applied;
  final List<Skipped> skipped;

  /// What changed, to take it back; null when nothing did.
  final EventChangeSet? changes;
}

/// The sentence for the page about what was left out (null: nothing).
String? skippedNotice(List<Skipped> skipped) {
  if (skipped.isEmpty) return null;
  const why = {
    SkipReason.gone: 'közben eltűnt vagy elmozdult',
    SkipReason.changed: 'közben megváltozott',
    SkipReason.clash: 'közben ütközik valamivel',
    SkipReason.over: 'már véget ért',
  };
  String shorten(String t) {
    final s = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 40 ? '${s.substring(0, 39)}…' : s;
  }

  final parts = <String>[];
  for (final r in SkipReason.values) {
    final titles = [
      for (final s in skipped)
        if (s.reason == r) s.title,
    ];
    if (titles.isEmpty) continue;
    final shown = titles.take(4).map((t) => '„${shorten(t)}”').join(', ');
    final more = titles.length > 4 ? ' és még ${titles.length - 4}' : '';
    parts.add('Kimaradt, mert ${why[r]}: $shown$more.');
  }
  return parts.join(' ');
}

/// [snapshot] as the calendar has it NOW, or null when it is not there (it was
/// deleted, moved to another time, or its series changed). A deleted event
/// that has not been uploaded yet is not found either: the live calendar never
/// lists it.
Future<Occurrence?> liveOccurrence(
  EventRepository repo,
  Occurrence snapshot,
) async {
  final ref = occurrenceRef(snapshot);
  final around = await repo.occurrences(
    snapshot.originalStart.subtract(const Duration(days: 1)),
    snapshot.originalStart.add(const Duration(days: 2)),
  );
  return around.where((o) => occurrenceRef(o) == ref).firstOrNull;
}

/// Whether a block at [startUtc]–[endUtc] would run into something in the live
/// calendar (with the usual buffer), or has no sensible range: the test the
/// proposal passed when it was made. [ignore] lists occurrences that do not
/// count (the event being moved itself, events about to be deleted).
Future<bool> clashes(
  EventRepository repo, {
  required String title,
  required DateTime startUtc,
  required DateTime endUtc,
  Set<String> ignore = const {},
  PlanRules rules = const PlanRules(),
}) async {
  final others = [
    for (final o in await repo.occurrences(
      startUtc.subtract(const Duration(days: 1)),
      endUtc.add(const Duration(days: 1)),
    ))
      if (!ignore.contains(occurrenceRef(o))) o,
  ];
  return validateProposal(
    [
      ProposedBlock(
        title: title,
        startUtc: startUtc,
        endUtc: endUtc,
        isWorkout: false,
        isHard: false,
      ),
    ],
    existing: others,
    rules: rules,
  ).any((v) => v.code == 'conflict' || v.code == 'bad_range');
}

/// Creates the accepted proposals as events (all in ONE transaction), giving
/// them the [ids] (item `i` gets `ids[i]`; the ids are known beforehand so the
/// upload can be held back while "Visszavonás" is on offer). An item whose time
/// is over by now, or that clashes with something in the calendar now, is left
/// out. [doomed] lists occurrences the user is also asked to delete: they do
/// not count as a clash, as when the proposal was made.
Future<ApplyResult> applyNew(
  EventRepository repo,
  List<ProposalItem> items,
  List<String> ids, {
  required DateTime now,
  required CalEvent Function(ProposalItem item, String id) build,
  Set<String> doomed = const {},
}) => repo.atomically(() async {
  final fresh = <CalEvent>[];
  final skipped = <Skipped>[];
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final start = resolveWallClock(it.tzid, it.startWall);
    final end = resolveWallClock(it.tzid, it.endWall);
    if (!end.isAfter(now)) {
      skipped.add(Skipped(it.title, SkipReason.over));
    } else if (await clashes(
      repo,
      title: it.title,
      startUtc: start,
      endUtc: end,
      ignore: doomed,
    )) {
      skipped.add(Skipped(it.title, SkipReason.clash));
    } else {
      fresh.add(build(it, ids[i]));
    }
  }
  if (fresh.isEmpty) return ApplyResult(skipped: skipped);
  final changes = await repo.tracked(
    existing: const [],
    created: [for (final f in fresh) f.id],
    change: () => repo.saveAll(fresh),
  );
  return ApplyResult(applied: fresh.length, skipped: skipped, changes: changes);
});

/// Deletes the confirmed events (all in ONE transaction), each as the calendar
/// has it now: one that is gone, or no longer what the card said, is left out.
/// [scopes] says, per card line, how much of a recurring event goes.
Future<ApplyResult> applyDeletions(
  EventRepository repo,
  List<DeletionProposal> deletions,
  Map<int, Scope> scopes,
) => repo.atomically(() async {
  var changes = const EventChangeSet();
  var applied = 0;
  final skipped = <Skipped>[];
  for (var i = 0; i < deletions.length; i++) {
    final snapshot = deletions[i].occurrence;
    final live = await liveOccurrence(repo, snapshot);
    if (live == null) {
      // (gone because an earlier line of this very card took the series with
      // it: nothing is left out, it was deleted)
      if (!changes.ids.contains(snapshot.eventId)) {
        skipped.add(Skipped(snapshot.title, SkipReason.gone));
      }
      continue;
    }
    if (!sameOccurrence(snapshot, live)) {
      skipped.add(Skipped(snapshot.title, SkipReason.changed));
      continue;
    }
    final c = await deleteEvent(
      repo,
      eventId: live.eventId,
      originalStart: live.originalStart,
      recurring: live.recurring,
      scope: live.recurring ? (scopes[i] ?? Scope.only) : Scope.only,
    );
    if (c == null) {
      skipped.add(Skipped(snapshot.title, SkipReason.gone));
      continue;
    }
    changes = changes.merge(c);
    applied++;
  }
  return ApplyResult(
    applied: applied,
    skipped: skipped,
    changes: changes.isEmpty ? null : changes,
  );
});

/// Moves the confirmed occurrences (all in ONE transaction), each as the
/// calendar has it now. One that is gone or changed, or whose new time clashes
/// with something in the calendar now (also with a move made a moment ago on
/// the same card), is left out. [doomed] lists occurrences the user is also
/// asked to delete: they do not count as a clash.
Future<ApplyResult> applyMoves(
  EventRepository repo,
  List<MoveProposal> moves, {
  Set<String> doomed = const {},
  PlanRules rules = const PlanRules(),
}) => repo.atomically(() async {
  var changes = const EventChangeSet();
  var applied = 0;
  final skipped = <Skipped>[];
  for (final m in moves) {
    final snapshot = m.occurrence;
    final live = await liveOccurrence(repo, snapshot);
    if (live == null) {
      skipped.add(Skipped(snapshot.title, SkipReason.gone));
      continue;
    }
    if (!sameOccurrence(snapshot, live)) {
      skipped.add(Skipped(snapshot.title, SkipReason.changed));
      continue;
    }
    // the new times are written in the event's own zone (see moveOccurrence),
    // so that is the zone they are checked in
    final tz = live.tzid ?? rules.tzid;
    if (await clashes(
      repo,
      title: live.title,
      startUtc: resolveWallClock(tz, m.newStart),
      endUtc: resolveWallClock(tz, m.newEnd),
      ignore: {...doomed, occurrenceRef(live)},
      rules: rules,
    )) {
      skipped.add(Skipped(snapshot.title, SkipReason.clash));
      continue;
    }
    final c = await moveOccurrence(repo, live, m.newStart, m.newEnd);
    if (c == null) {
      skipped.add(Skipped(snapshot.title, SkipReason.gone));
      continue;
    }
    changes = changes.merge(c);
    applied++;
  }
  return ApplyResult(
    applied: applied,
    skipped: skipped,
    changes: changes.isEmpty ? null : changes,
  );
});
