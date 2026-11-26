import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const bp = 'Europe/Budapest';

/// Wednesday 2026-11-11, noon in Budapest.
final now = resolveWallClock(bp, floating(2026, 11, 11, 12));

CalEvent ev(
  String id,
  String title,
  DateTime start, {
  Duration len = const Duration(hours: 1),
  String location = '',
  String notes = '',
  String? rrule,
  bool allDay = false,
  bool cancelled = false,
  String? master,
  DateTime? original,
}) => CalEvent(
  id: id,
  calendarId: 'c',
  title: title,
  location: location,
  notes: notes,
  tzid: allDay ? null : bp,
  allDay: allDay,
  start: start,
  end: start.add(allDay ? const Duration(days: 1) : len),
  rrule: rrule,
  cancelled: cancelled,
  recurringEventId: master,
  originalStart: original,
);

TaskView task(
  String id,
  String title, {
  String notes = '',
  bool done = false,
  bool deleted = false,
}) => TaskView(
  SyncRecord(id: id, kind: kindTask).edit(
    {...taskFields(title: title, notes: notes, done: done), 'deleted': deleted},
    ts: 1,
    dev: 'd',
  ),
);

FinTx tx(
  String id,
  DateTime date,
  int amount, {
  String merchant = '',
  String note = '',
  String cat = 'cat-food',
  bool deleted = false,
  int updatedAt = 0,
}) => FinTx(
  id: id,
  date: date,
  amount: amount,
  kind: FinKind.expense,
  merchant: merchant,
  note: note,
  categoryId: cat,
  deleted: deleted,
  updatedAt: updatedAt,
);

String catName(String id) =>
    const {'cat-food': 'Élelmiszer', 'cat-fun': 'Szórakozás'}[id] ?? '';

List<String> titles(EventSearch s) => [
  for (final h in s.hits) h.occurrence.title,
];

void main() {
  setUpAll(ensureTimeZones);

  group('searchTerms', () {
    test('words are lower case and without accents', () {
      expect(searchTerms(' Fog  Orv '), ['fog', 'orv']);
      expect(searchTerms('Fogórvos'), ['fogorvos']);
      expect(searchTerms('ŐŰÜÖ'), ['ouuo']);
    });

    test('needs at least one word of two letters', () {
      expect(searchTerms(''), isEmpty);
      expect(searchTerms('   '), isEmpty);
      expect(searchTerms('a'), isEmpty);
      expect(searchTerms('a b'), isEmpty);
      expect(searchTerms('ab'), ['ab']);
      // a lone letter is kept once there is a real word beside it
      expect(searchTerms('a bc'), ['a', 'bc']);
    });
  });

  group('searchEvents', () {
    test('finds by title, place and notes, ignoring case and accents', () {
      final events = [
        ev('1', 'Fogorvos', floating(2026, 11, 20, 9)),
        ev('2', 'Edzés', floating(2026, 11, 21, 18), location: 'Városliget'),
        ev(
          '3',
          'Értekezlet',
          floating(2026, 11, 22, 10),
          notes: 'Hozd a számlát',
        ),
      ];
      expect(titles(searchEvents(events, 'FOGÓRVOS', now: now)), ['Fogorvos']);
      expect(titles(searchEvents(events, 'varosliget', now: now)), ['Edzés']);
      expect(titles(searchEvents(events, 'szamlak', now: now)), isEmpty);
      expect(titles(searchEvents(events, 'szamla', now: now)), ['Értekezlet']);
      final hit = searchEvents(events, 'varosliget', now: now).hits.single;
      expect(hit.location, 'Városliget');
      expect(hit.occurrence.eventId, '2');
    });

    test('every word has to be in it, in any order', () {
      final events = [
        ev('1', 'Edzés', floating(2026, 11, 20, 9), location: 'Városliget'),
        ev('2', 'Edzés', floating(2026, 11, 21, 9), location: 'Margitsziget'),
      ];
      expect(searchEvents(events, 'edzes varos', now: now).hits, hasLength(1));
      expect(searchEvents(events, 'varos edzes', now: now).hits, hasLength(1));
      expect(searchEvents(events, 'edzes varos x', now: now).hits, isEmpty);
      expect(searchEvents(events, 'edzes fogorvos', now: now).hits, isEmpty);
    });

    test('a query that is too short finds nothing', () {
      final events = [ev('1', 'Edzés', floating(2026, 11, 20, 9))];
      for (final q in ['', ' ', 'e', 'e d']) {
        final s = searchEvents(events, q, now: now);
        expect(s.hits, isEmpty, reason: q);
        expect(s.more, 0);
      }
    });

    test('a cancelled event is not found', () {
      final events = [
        ev('1', 'Edzés', floating(2026, 11, 20, 9), cancelled: true),
      ];
      expect(searchEvents(events, 'edzes', now: now).hits, isEmpty);
    });

    test('the marker of generated shifts is not searched, their title is', () {
      final events = [
        ev(
          '1',
          'Éjszaka',
          floating(2026, 11, 20, 18),
          notes: kShiftMarker,
          len: const Duration(hours: 12),
        ),
        ev(
          '2',
          'Nappal',
          floating(2026, 11, 21, 6),
          notes: kShiftEditedMarker,
          len: const Duration(hours: 12),
        ),
        ev('3', 'Beosztás megbeszélés', floating(2026, 11, 22, 9)),
      ];
      expect(titles(searchEvents(events, 'beosztas', now: now)), [
        'Beosztás megbeszélés',
      ]);
      expect(titles(searchEvents(events, 'ejszaka', now: now)), ['Éjszaka']);
      expect(titles(searchEvents(events, 'generator', now: now)), isEmpty);
      expect(titles(searchEvents(events, 'modositva', now: now)), isEmpty);
    });

    test('an all-day event is found with its date', () {
      final events = [
        ev('1', 'Szabadság', floating(2026, 11, 25), allDay: true),
      ];
      final hit = searchEvents(events, 'szabadsag', now: now).hits.single;
      expect(hit.occurrence.allDay, isTrue);
      expect(hit.occurrence.startUtc, floating(2026, 11, 25));
    });

    test('upcoming come first, soonest first; then the past, latest first', () {
      final events = [
        ev('past-old', 'Edzés régi', floating(2026, 11, 4, 18)),
        ev('past-new', 'Edzés tegnap', floating(2026, 11, 10, 18)),
        // started before "now" and still going on: counts as upcoming
        ev('going', 'Edzés most', floating(2026, 11, 11, 11, 30)),
        ev('later', 'Edzés később', floating(2026, 11, 14, 18)),
        ev('soon', 'Edzés holnap', floating(2026, 11, 12, 18)),
      ];
      expect(titles(searchEvents(events, 'edzes', now: now)), [
        'Edzés most',
        'Edzés holnap',
        'Edzés később',
        'Edzés tegnap',
        'Edzés régi',
      ]);
    });

    test('one that ended a minute ago is already in the past', () {
      final events = [
        ev('ended', 'Edzés vége', floating(2026, 11, 11, 10, 59)),
        ev('ahead', 'Edzés előre', floating(2026, 11, 11, 13)),
      ];
      expect(titles(searchEvents(events, 'edzes', now: now)), [
        'Edzés előre',
        'Edzés vége',
      ]);
    });

    test('a series is ONE hit: its next occurrence', () {
      final events = [
        ev(
          'm',
          'Edzés',
          floating(2026, 5, 4, 9), // a Monday, months ago
          rrule: 'FREQ=WEEKLY',
        ),
      ];
      final s = searchEvents(events, 'edzes', now: now);
      expect(s.hits, hasLength(1));
      final o = s.hits.single.occurrence;
      expect(o.recurring, isTrue);
      expect(o.originalStart, floating(2026, 11, 16, 9)); // next Monday
    });

    test('a series that is over shows its last occurrence', () {
      final events = [
        ev('m', 'Edzés', floating(2026, 5, 4, 9), rrule: 'FREQ=WEEKLY;COUNT=3'),
      ];
      final s = searchEvents(events, 'edzes', now: now);
      expect(s.hits, hasLength(1));
      expect(s.hits.single.occurrence.originalStart, floating(2026, 5, 18, 9));
    });

    test('a series that has not begun shows its first occurrence', () {
      final events = [
        ev('m', 'Edzés', floating(2027, 1, 4, 9), rrule: 'FREQ=WEEKLY'),
      ];
      final o = searchEvents(events, 'edzes', now: now).hits.single.occurrence;
      expect(o.originalStart, floating(2027, 1, 4, 9));
    });

    test('a renamed instance is passed over for the plain next one', () {
      final events = [
        ev('m', 'Edzés', floating(2026, 5, 4, 9), rrule: 'FREQ=WEEKLY'),
        ev(
          'x',
          'Orvosi vizsgálat',
          floating(2026, 11, 16, 14),
          master: 'm',
          original: floating(2026, 11, 16, 9),
        ),
      ];
      final s = searchEvents(events, 'edzes', now: now);
      expect(s.hits, hasLength(1));
      expect(s.hits.single.occurrence.title, 'Edzés');
      expect(s.hits.single.occurrence.isOverride, isFalse);
      // 16th is renamed: the next plain Monday is the 23rd
      expect(s.hits.single.occurrence.originalStart, floating(2026, 11, 23, 9));
    });

    test('an instance that alone matches is a hit of its own', () {
      final events = [
        ev('m', 'Edzés', floating(2026, 5, 4, 9), rrule: 'FREQ=WEEKLY'),
        ev(
          'x',
          'Orvosi vizsgálat',
          floating(2026, 11, 16, 14),
          master: 'm',
          original: floating(2026, 11, 16, 9),
        ),
      ];
      final s = searchEvents(events, 'orvosi', now: now);
      expect(s.hits, hasLength(1));
      final o = s.hits.single.occurrence;
      expect(o.isOverride, isTrue);
      expect(o.eventId, 'x');
      expect(o.startUtc, resolveWallClock(bp, floating(2026, 11, 16, 14)));
    });

    test('a cancelled instance is not a hit', () {
      final events = [
        ev('m', 'Edzés', floating(2026, 5, 4, 9), rrule: 'FREQ=WEEKLY'),
        ev(
          'x',
          'Orvosi vizsgálat',
          floating(2026, 11, 16, 14),
          master: 'm',
          original: floating(2026, 11, 16, 9),
          cancelled: true,
        ),
      ];
      expect(searchEvents(events, 'orvosi', now: now).hits, isEmpty);
    });

    test(
      'a cancelled instance is left out when the next one is looked for',
      () {
        final events = [
          ev('m', 'Edzés', floating(2026, 5, 4, 9), rrule: 'FREQ=WEEKLY'),
          // the Monday after "now" was cancelled
          ev(
            'x',
            'Edzés',
            floating(2026, 11, 16, 9),
            master: 'm',
            original: floating(2026, 11, 16, 9),
            cancelled: true,
          ),
        ];
        final s = searchEvents(events, 'edzes', now: now);
        expect(s.hits, hasLength(1));
        expect(
          s.hits.single.occurrence.originalStart,
          floating(2026, 11, 23, 9),
        );
      },
    );

    test('the listing is cut at the limit and says how many more', () {
      final events = [
        for (var i = 0; i < 5; i++)
          ev('e$i', 'Edzés $i', floating(2026, 11, 12 + i, 18)),
      ];
      final s = searchEvents(events, 'edzes', now: now, limit: 3);
      expect(titles(s), ['Edzés 0', 'Edzés 1', 'Edzés 2']);
      expect(s.more, 2);
      final all = searchEvents(events, 'edzes', now: now, limit: 5);
      expect(all.hits, hasLength(5));
      expect(all.more, 0);
    });

    test('an event with an unreadable rule is left out, the rest is found', () {
      final events = [
        ev(
          'bad',
          'Edzés rossz',
          floating(2026, 11, 20, 9),
          rrule: 'FREQ=BOGUS',
        ),
        ev('ok', 'Edzés jó', floating(2026, 11, 21, 9)),
      ];
      expect(titles(searchEvents(events, 'edzes', now: now)), ['Edzés jó']);
    });

    test('events with the same start are ordered by title, then by id', () {
      final events = [
        // the ids run the other way round than the titles
        ev('y', 'Edzés B', floating(2026, 11, 20, 9)),
        ev('z', 'Edzés A', floating(2026, 11, 20, 9)),
        ev('x', 'Edzés A', floating(2026, 11, 20, 9)),
      ];
      final ids = [
        for (final h in searchEvents(events, 'edzes', now: now).hits)
          h.occurrence.eventId,
      ];
      expect(ids, ['x', 'z', 'y']);
    });
  });

  group('searchTasks', () {
    test('finds by title and notes, ignoring accents; keeps the order', () {
      final tasks = [
        task('1', 'Számla befizetése'),
        task('2', 'Bevásárlás', notes: 'a számla mellé tejet is'),
        task('3', 'Autó szerviz'),
      ];
      final s = searchTasks(tasks, 'SZAMLA');
      expect([for (final t in s.hits) t.id], ['1', '2']);
      expect(s.more, 0);
    });

    test('a deleted task is not found; a done one is', () {
      final tasks = [
        task('1', 'Számla', deleted: true),
        task('2', 'Számla régi', done: true),
      ];
      expect([for (final t in searchTasks(tasks, 'szamla').hits) t.id], ['2']);
    });

    test('short query finds nothing; the limit says how many more', () {
      final tasks = [for (var i = 0; i < 4; i++) task('$i', 'Számla $i')];
      expect(searchTasks(tasks, 's').hits, isEmpty);
      final s = searchTasks(tasks, 'szamla', limit: 3);
      expect(s.hits, hasLength(3));
      expect(s.more, 1);
    });
  });

  group('searchTx', () {
    final day = floating(2026, 11, 3);
    final list = [
      tx('1', day, 25000, merchant: 'Tesco', note: 'heti bevásárlás'),
      tx('2', floating(2026, 11, 9), 1200, merchant: 'Mozi', cat: 'cat-fun'),
      tx('3', floating(2026, 10, 1), 5000, note: 'ajándék 2026'),
    ];

    List<String> ids(TxSearch s) => [for (final t in s.hits) t.id];

    test('finds by merchant, note and category name', () {
      expect(ids(searchTx(list, 'TESCO', categoryName: catName)), ['1']);
      expect(ids(searchTx(list, 'bevasarlas', categoryName: catName)), ['1']);
      expect(ids(searchTx(list, 'szorakozas', categoryName: catName)), ['2']);
      expect(ids(searchTx(list, 'elelmiszer', categoryName: catName)), [
        '1',
        '3',
      ]);
    });

    test('a word of digits also matches the amount', () {
      expect(ids(searchTx(list, '25000', categoryName: catName)), ['1']);
      expect(ids(searchTx(list, '5000', categoryName: catName)), ['1', '3']);
      // and the text, as for any word
      expect(ids(searchTx(list, '2026', categoryName: catName)), ['3']);
      // a word with letters in it is not an amount
      expect(ids(searchTx(list, 'x25000', categoryName: catName)), isEmpty);
    });

    test('every word counts, in any order, text and amount mixed', () {
      expect(ids(searchTx(list, 'tesco 25000', categoryName: catName)), ['1']);
      expect(ids(searchTx(list, '25000 tesco', categoryName: catName)), ['1']);
      expect(
        ids(searchTx(list, 'tesco 99999', categoryName: catName)),
        isEmpty,
      );
    });

    test('newest first; deleted ones are left out', () {
      final more = [
        ...list,
        tx('4', floating(2026, 11, 20), 700, merchant: 'Tesco'),
        tx('5', floating(2026, 11, 20), 800, merchant: 'Tesco', updatedAt: 9),
        tx('6', floating(2026, 11, 21), 900, merchant: 'Tesco', deleted: true),
      ];
      expect(ids(searchTx(more, 'tesco', categoryName: catName)), [
        '5', // the same day: the later edit first
        '4',
        '1',
      ]);
    });

    test('short query finds nothing; the limit says how many more', () {
      expect(searchTx(list, 't', categoryName: catName).hits, isEmpty);
      final s = searchTx(list, 'elelmiszer', categoryName: catName, limit: 1);
      expect(s.hits, hasLength(1));
      expect(s.more, 1);
    });
  });
}
