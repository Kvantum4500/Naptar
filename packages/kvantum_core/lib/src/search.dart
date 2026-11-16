import 'event.dart';
import 'finance.dart';
import 'journal.dart';
import 'models.dart';
import 'recurrence.dart';
import 'shift_pattern.dart';
import 'text_safety.dart';

// Search over the calendar, the tasks, the money log and the diary. Pure functions: the
// app feeds them what it has in memory and shows what they return.
//
// A search reads like the assistant's requests do: lower case and without
// accents ("fogorvos" finds "Fogórvos"), every word must be somewhere in the
// text, in any order.

const _day = Duration(days: 1);

/// How far ahead the next occurrence of a series is looked for.
const _horizon = Duration(days: 731);

/// The words of [query]: lower case, no accents, split at spaces. Empty when
/// there is nothing to search for yet: at least one word needs two letters (a
/// single letter would match nearly everything).
List<String> searchTerms(String query) {
  final words = foldHu(query)
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  return words.any((w) => w.length >= 2) ? words : const [];
}

bool _hasAll(String haystack, List<String> terms) =>
    terms.every(haystack.contains);

// ------------------------------------------------------------------- events

/// One event found: the occurrence to show (and to open).
class EventHit {
  const EventHit(this.occurrence, {this.location = ''});
  final Occurrence occurrence;
  final String location;
}

class EventSearch {
  const EventSearch(this.hits, this.more);
  const EventSearch.none() : hits = const [], more = 0;

  /// Upcoming ones first (soonest first), then the past ones (latest first).
  final List<EventHit> hits;

  /// How many more matched than are listed.
  final int more;
}

/// What a search looks at in an event: title, place and notes. The marker the
/// shift planner writes into the notes is not text of the user's.
String _text(CalEvent e) => foldHu(
  '${e.title}\n${e.location}\n${isShiftNotes(e.notes) ? '' : e.notes}',
);

/// The occurrence that stands for a match: for a series the next one (one
/// that is still going on counts), or the last one if the series is over. An
/// instance that was renamed or moved on its own is passed over while a plain
/// one exists: the match was the series' text, not that instance's.
Occurrence? _representative(
  CalEvent e,
  List<CalEvent> overrides,
  DateTime nowUtc,
) {
  if (!e.isRecurring) {
    return expand(e, e.startUtc.subtract(_day), e.endUtc.add(_day)).firstOrNull;
  }
  final ahead = expand(e, nowUtc, nowUtc.add(_horizon), overrides: overrides);
  final next =
      ahead.where((o) => !o.isOverride).firstOrNull ?? ahead.firstOrNull;
  if (next != null) return next;
  final behind = expand(
    e,
    e.startUtc.subtract(_day),
    nowUtc,
    overrides: overrides,
  );
  return behind.where((o) => !o.isOverride).lastOrNull ?? behind.lastOrNull;
}

/// The occurrence of one exception instance (moved / renamed on its own).
Occurrence? _ofOverride(
  CalEvent master,
  CalEvent x,
  List<CalEvent> overrides,
) => expand(
  master,
  x.startUtc.subtract(_day),
  x.endUtc.add(_day),
  overrides: overrides,
).where((o) => o.eventId == x.id).firstOrNull;

/// Events matching [query]. A series is ONE hit (its next occurrence); an
/// instance of it that was renamed on its own is a hit of its own, if only it
/// matches. An event the app cannot expand (unreadable rule) is left out
/// rather than failing the search.
EventSearch searchEvents(
  List<CalEvent> events,
  String query, {
  required DateTime now,
  int limit = 50,
}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const EventSearch.none();
  final nowUtc = now.toUtc();

  // (a cancelled instance is kept: expand() needs it to leave that day out)
  final overrides = <String, List<CalEvent>>{};
  for (final e in events) {
    if (e.isException) (overrides[e.recurringEventId!] ??= []).add(e);
  }

  final hits = <EventHit>[];
  for (final e in events) {
    if (e.isException || e.cancelled) continue;
    final mine = overrides[e.id] ?? const <CalEvent>[];
    try {
      if (_hasAll(_text(e), terms)) {
        final o = _representative(e, mine, nowUtc);
        if (o != null) hits.add(EventHit(o, location: e.location));
      } else {
        for (final x in mine) {
          if (x.cancelled || !_hasAll(_text(x), terms)) continue;
          final o = _ofOverride(e, x, mine);
          if (o != null) hits.add(EventHit(o, location: x.location));
        }
      }
    } catch (_) {
      // an unreadable rule or zone hides that event only
    }
  }

  int byStart(EventHit a, EventHit b) {
    final c = a.occurrence.startUtc.compareTo(b.occurrence.startUtc);
    if (c != 0) return c;
    final t = a.occurrence.title.compareTo(b.occurrence.title);
    return t != 0 ? t : a.occurrence.eventId.compareTo(b.occurrence.eventId);
  }

  final upcoming = [
    for (final h in hits)
      if (h.occurrence.endUtc.isAfter(nowUtc)) h,
  ]..sort(byStart);
  final past = [
    for (final h in hits)
      if (!h.occurrence.endUtc.isAfter(nowUtc)) h,
  ]..sort((a, b) => byStart(b, a));
  final all = [...upcoming, ...past];
  return EventSearch(
    all.take(limit).toList(),
    all.length > limit ? all.length - limit : 0,
  );
}

// -------------------------------------------------------------------- tasks

class TaskSearch {
  const TaskSearch(this.hits, this.more);
  const TaskSearch.none() : hits = const [], more = 0;
  final List<TaskView> hits;
  final int more;
}

/// Tasks whose title or notes match, in the order they were given (the list
/// the app keeps puts the open ones first).
TaskSearch searchTasks(List<TaskView> tasks, String query, {int limit = 30}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const TaskSearch.none();
  final found = [
    for (final t in tasks)
      if (!t.deleted && _hasAll(foldHu('${t.title}\n${t.notes}'), terms)) t,
  ];
  return TaskSearch(
    found.take(limit).toList(),
    found.length > limit ? found.length - limit : 0,
  );
}

// ------------------------------------------------------------- transactions

class TxSearch {
  const TxSearch(this.hits, this.more);
  const TxSearch.none() : hits = const [], more = 0;
  final List<FinTx> hits;
  final int more;
}

final _digits = RegExp(r'^\d+$');

/// Money log entries matching [query]: merchant, note and category name; a
/// word made of digits also matches the amount ("5000" finds 25 000 Ft too).
/// Newest first.
TxSearch searchTx(
  List<FinTx> txs,
  String query, {
  required String Function(String categoryId) categoryName,
  int limit = 30,
}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const TxSearch.none();
  final found = <FinTx>[];
  for (final t in txs) {
    if (t.deleted) continue;
    final text = foldHu(
      '${t.merchant}\n${t.note}\n${categoryName(t.categoryId)}',
    );
    final amount = '${t.amount}';
    final ok = terms.every(
      (w) => text.contains(w) || (_digits.hasMatch(w) && amount.contains(w)),
    );
    if (ok) found.add(t);
  }
  found.sort((a, b) {
    final c = b.date.compareTo(a.date);
    return c != 0 ? c : b.updatedAt.compareTo(a.updatedAt);
  });
  return TxSearch(
    found.take(limit).toList(),
    found.length > limit ? found.length - limit : 0,
  );
}

// -------------------------------------------------------------------- diary

class JournalSearch {
  const JournalSearch(this.hits, this.more);
  const JournalSearch.none() : hits = const [], more = 0;
  final List<JournalEntry> hits;
  final int more;
}

/// Diary entries whose title or text match, in the order they were given (the
/// list the app keeps has the newest first). The pictures are not searched: a
/// picture has no words.
JournalSearch searchJournal(
  List<JournalEntry> entries,
  String query, {
  int limit = 30,
}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const JournalSearch.none();
  final found = [
    for (final e in entries)
      if (_hasAll(foldHu('${e.title}\n${e.text}'), terms)) e,
  ];
  return JournalSearch(
    found.take(limit).toList(),
    found.length > limit ? found.length - limit : 0,
  );
}
