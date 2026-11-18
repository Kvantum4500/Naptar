import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_change.dart';
import '../data/event_repository.dart' show kNaptarCalendar;
import '../providers.dart';
import '../sync/sync_hold.dart';
import 'agenda_view.dart' show relativeDayName;
import 'day_utils.dart';
import 'format.dart';

/// The calendar event a quick entry stands for. Needs a date (the caller has
/// checked); an entry without a time becomes an all-day event.
CalEvent quickEvent(QuickEntry e, String id) {
  final date = e.date!;
  final allDay = e.allDay || e.startMinute == null;
  return CalEvent(
    id: id,
    calendarId: kNaptarCalendar,
    title: e.title,
    start: allDay ? date : e.start!,
    end: allDay ? date.add(const Duration(days: 1)) : e.end!,
    allDay: allDay,
    tzid: allDay ? null : defaultTz,
    rrule: e.rrule,
  );
}

/// What a quick entry made, and how to take it back.
class QuickCreated {
  const QuickCreated({
    required this.kind,
    required this.id,
    required this.title,
    required this.message,
    required this.undo,
    this.hold,
  });

  final QuickKind kind;
  final String id;
  final String title;

  /// For the bar: "Esemény felvéve: …".
  final String message;

  /// Puts things back as they were; false: it could not be done (somebody
  /// changed the new item meanwhile).
  final Future<bool> Function() undo;

  /// Keeps a new event from going up to Google while it can still be taken
  /// back; released when the offer ends.
  final SyncHoldToken? hold;
}

/// When an entry is, in words: "Holnap · péntek, nov. 13. · 18:00–19:00",
/// "Ma · csütörtök, nov. 12. · egész nap", "Határidő: holnap · péntek, nov.
/// 13.", "Határidő nélkül". [today] is the display-zone day.
String quickWhen(QuickEntry e, DateTime today) {
  final date = e.date;
  if (e.kind == QuickKind.task) {
    return date == null
        ? 'Határidő nélkül'
        : 'Határidő: ${_day(date, today).toLowerCase()}';
  }
  if (date == null) return 'Nincs időpont';
  if (e.allDay || e.startMinute == null) {
    return '${_day(date, today)} · egész nap';
  }
  final end = e.end!;
  final span = '${fmtTime(e.start!)}–${fmtTime(end)}';
  // an event over midnight says so
  final endDay = dateOnly(end);
  final over = endDay == date
      ? ''
      : endDay.difference(date).inDays == 1
      ? ' (másnap)'
      : ' (${fmtDateLong(endDay)})';
  return '${_day(date, today)} · $span$over';
}

/// "Holnap · péntek, nov. 13." (the year only when it is not this one).
String _day(DateTime d, DateTime today) {
  final rel = relativeDayName(d, today);
  final date = d.year == today.year
      ? DateFormat(
          'EEEE, MMM d.',
          'hu',
        ).format(DateTime(d.year, d.month, d.day))
      : fmtDateLong(d);
  return rel == null ? date : '$rel · $date';
}

/// Creates what a quick entry says, as a calendar event or as a task.
class QuickEntryOps {
  QuickEntryOps(this._ref);
  final Ref _ref;
  static const _uuid = Uuid();

  /// Throws [ArgumentError] (a sentence for the user) when there is nothing to
  /// make of it: no title, an event without a day.
  Future<QuickCreated> create(QuickEntry entry) async {
    if (!entry.hasTitle) {
      throw ArgumentError('Adj meg egy címet.');
    }
    return switch (entry.kind) {
      QuickKind.event => _event(entry),
      QuickKind.task => _task(entry),
    };
  }

  Future<QuickCreated> _event(QuickEntry entry) async {
    if (entry.date == null) {
      throw ArgumentError(
        'Az eseményhez nap kell. Írj mellé napot vagy időpontot, '
        'vagy vedd fel feladatnak.',
      );
    }
    final repo = _ref.read(repoProvider);
    final today = _ref.read(todayProvider);
    final id = _uuid.v4();
    final event = quickEvent(entry, id);
    // The new event stays off Google while it can be taken back: an undone
    // entry never leaves the device.
    final token = _ref.read(syncHoldProvider).acquire([id]);
    try {
      final changes = await repo.tracked(
        existing: const [],
        created: [id],
        change: () => repo.saveLocal(event),
      );
      return QuickCreated(
        kind: QuickKind.event,
        id: id,
        title: event.title,
        message: 'Esemény felvéve: ${event.title} – ${quickWhen(entry, today)}',
        undo: () => repo.undoChange(changes),
        hold: token,
      );
    } catch (_) {
      token.release();
      rethrow;
    }
  }

  Future<QuickCreated> _task(QuickEntry entry) async {
    final records = _ref.read(recordRepoProvider);
    final today = _ref.read(todayProvider);
    final id = _uuid.v4();
    final fields = taskFields(
      title: entry.title,
      due: entry.date,
      // a rule is anchored on the due date: without one there is none
      repeat: entry.date == null ? null : entry.rrule,
    );
    final made = await records.edit(kindTask, id, fields);
    return QuickCreated(
      kind: QuickKind.task,
      id: id,
      title: entry.title,
      message: 'Feladat felvéve: ${entry.title} – ${quickWhen(entry, today)}',
      undo: () async {
        // only the task as it was made: one the user has edited, ticked off
        // or deleted meanwhile stays (every such change moves the stamp)
        final now = await records.get(kindTask, id);
        if (now == null || now.updatedAt != made.updatedAt) return false;
        await records.delete(kindTask, id);
        return true;
      },
    );
  }
}

final quickEntryOpsProvider = Provider<QuickEntryOps>(QuickEntryOps.new);
