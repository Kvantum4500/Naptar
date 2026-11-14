import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

CalEvent ev(
  String id,
  String title,
  DateTime s,
  DateTime e, {
  String? rrule,
  List<DateTime> ex = const [],
  String notes = '',
  bool allDay = false,
}) => CalEvent(
  id: id,
  calendarId: 'naptar',
  title: title,
  notes: notes,
  start: s,
  end: e,
  tzid: allDay ? null : 'Europe/Budapest',
  allDay: allDay,
  rrule: rrule,
  exdates: ex,
);

void main() {
  setUpAll(ensureTimeZones);
  final t0 = DateTime.utc(2026, 11, 20, 9);

  test('round trip keeps every field', () {
    final master = ev(
      'm1',
      'Edzés; kemény, nagyon',
      t0,
      t0.add(const Duration(hours: 1)),
      rrule: 'FREQ=DAILY;COUNT=5',
      ex: [DateTime.utc(2026, 11, 22, 9)],
      notes: 'sor1\nsor2 \\ vége',
    ).copyWith(colorId: '4', aiGenerated: true, bumpVersion: false);
    final over = CalEvent(
      id: 'o1',
      calendarId: 'naptar',
      title: 'Edzés (áthelyezve)',
      start: DateTime.utc(2026, 11, 21, 19),
      end: DateTime.utc(2026, 11, 21, 20),
      tzid: 'Europe/Budapest',
      recurringEventId: 'm1',
      originalStart: DateTime.utc(2026, 11, 21, 9),
    );
    final day = ev(
      'd1',
      'Szabadnap',
      DateTime.utc(2026, 12, 24),
      DateTime.utc(2026, 12, 26),
      allDay: true,
    );
    final text = exportIcs([master, over, day]);
    final back = parseIcs(text, calendarId: 'naptar');
    expect(back.problems, isEmpty);
    expect(back.events.length, 3);
    final m = back.events.firstWhere((e) => e.id == 'm1');
    expect(m.title, master.title);
    expect(m.notes, master.notes);
    expect(m.start, master.start);
    expect(m.end, master.end);
    expect(m.rrule, 'FREQ=DAILY;COUNT=5');
    expect(m.exdates, master.exdates);
    expect(m.colorId, '4');
    expect(m.aiGenerated, isTrue);
    final o = back.events.firstWhere((e) => e.id == 'o1');
    expect(o.recurringEventId, 'm1');
    expect(o.originalStart, over.originalStart);
    expect(o.start, over.start);
    final d = back.events.firstWhere((e) => e.id == 'd1');
    expect(d.allDay, isTrue);
    expect(d.start, DateTime.utc(2026, 12, 24));
    expect(d.end, DateTime.utc(2026, 12, 26));
    expect(d.tzid, isNull);
  });

  test('lines are folded to 75 octets and unfolded again (UTF-8 safe)', () {
    final long = 'Árvíztűrő tükörfúrógép ' * 12;
    final text = exportIcs([
      ev('x', long, t0, t0.add(const Duration(hours: 1))),
    ]);
    for (final l in text.split('\r\n')) {
      expect(l.codeUnits.length, lessThan(80));
    }
    final back = parseIcs(text, calendarId: 'naptar').events.single;
    expect(back.title, long.trim());
  });

  test('cancelled events are not exported', () {
    final c = ev(
      'c',
      'Törölt',
      t0,
      t0.add(const Duration(hours: 1)),
    ).copyWith(cancelled: true);
    expect(exportIcs([c]), isNot(contains('VEVENT')));
  });

  test('foreign files: UTC times, floating times, durations, alarms', () {
    const text = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:a@example.com
DTSTART:20260720T100000Z
DURATION:PT90M
SUMMARY:UTC esemény
BEGIN:VALARM
TRIGGER:-PT10M
ACTION:DISPLAY
END:VALARM
END:VEVENT
BEGIN:VEVENT
UID:b@example.com
DTSTART:20260105T080000
SUMMARY:Lebegő
END:VEVENT
END:VCALENDAR
''';
    final r = parseIcs(text, calendarId: 'naptar');
    expect(r.problems, isEmpty);
    final a = r.events.firstWhere((e) => e.id == 'a@example.com');
    // 10:00Z in July = 12:00 Budapest wall clock (CEST)
    expect(a.start, DateTime.utc(2026, 7, 20, 12));
    expect(a.end, DateTime.utc(2026, 7, 20, 13, 30));
    final b = r.events.firstWhere((e) => e.id == 'b@example.com');
    expect(b.start, DateTime.utc(2026, 1, 5, 8));
    expect(b.end, DateTime.utc(2026, 1, 5, 9));
  });

  test('garbage never throws and is explained', () {
    final r = parseIcs(
      'nem ics\nBEGIN:VEVENT\nSUMMARY:Idő nélkül\nEND:VEVENT\n'
      'BEGIN:VEVENT\nDTSTART:hülye\nSUMMARY:Rossz\nEND:VEVENT\n'
      'BEGIN:VEVENT\nDTSTART;TZID=Nincs/Zona:20260105T080000\nSUMMARY:Zóna\nEND:VEVENT\n',
      calendarId: 'naptar',
    );
    expect(r.events.length, 1); // the unknown zone falls back
    expect(r.problems.length, 3);
    expect(parseIcs('', calendarId: 'n').events, isEmpty);
  });

  test('event count is capped', () {
    final one = exportIcs([ev('x', 'T', t0, t0.add(const Duration(hours: 1)))]);
    final body = one.split('\r\n').where((l) => l.isNotEmpty).toList();
    final vevent = body.sublist(
      body.indexOf('BEGIN:VEVENT'),
      body.indexOf('END:VEVENT') + 1,
    );
    final big = [
      'BEGIN:VCALENDAR',
      for (var i = 0; i < 10; i++)
        ...vevent.map((l) => l.startsWith('UID:') ? 'UID:u$i' : l),
      'END:VCALENDAR',
    ].join('\r\n');
    final r = parseIcs(big, calendarId: 'n', maxEvents: 4);
    expect(r.events.length, 4);
    expect(r.problems, isNotEmpty);
  });

  group('UNTIL: a UTC instant in the file, a wall-clock limit in the app', () {
    String file(String dtstart, String rrule, {String extra = ''}) =>
        'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:u1\r\n'
        '$dtstart\r\nDTEND;TZID=Europe/Budapest:20260504T100000\r\n'
        'SUMMARY:Edzés\r\nRRULE:$rrule\r\n$extra'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';

    Future<int> count(CalEvent e) async =>
        expand(e, DateTime.utc(2026, 5, 1), DateTime.utc(2026, 6, 1)).length;

    test('a timed series ends on the day the file says (not one early)', () async {
      // 07:00 UTC is 09:00 in Budapest in May: the fifth occurrence is the last
      final imp = parseIcs(
        file(
          'DTSTART;TZID=Europe/Budapest:20260504T090000',
          'FREQ=DAILY;UNTIL=20260508T070000Z',
        ),
        calendarId: 'c',
      );
      final e = imp.events.single;
      expect(e.rrule, 'FREQ=DAILY;UNTIL=20260508T090000Z');
      expect(await count(e), 5);
    });

    test('an all-day series includes its last day', () async {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u2\r\n'
        'DTSTART;VALUE=DATE:20260504\r\nDTEND;VALUE=DATE:20260505\r\n'
        'SUMMARY:Szabi\r\nRRULE:FREQ=DAILY;UNTIL=20260508\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      final e = imp.events.single;
      expect(e.rrule, 'FREQ=DAILY;UNTIL=20260508T235959Z');
      expect(await count(e), 5);
    });

    test(
      'the file we write says UTC, and reads back as the same series',
      () async {
        final series = ev(
          's',
          'Edzés',
          floating(2026, 5, 4, 9),
          floating(2026, 5, 4, 10),
          rrule: 'FREQ=DAILY;UNTIL=20260508T090000Z',
        );
        final text = exportIcs([series]);
        expect(text, contains('UNTIL=20260508T070000Z'));
        final back = parseIcs(text, calendarId: 'c').events.single;
        expect(back.rrule, series.rrule);
        expect(await count(back), 5);
      },
    );

    test('a COUNT rule is left as it is', () {
      final imp = parseIcs(
        file(
          'DTSTART;TZID=Europe/Budapest:20260504T090000',
          'FREQ=DAILY;COUNT=3',
        ),
        calendarId: 'c',
      );
      expect(imp.events.single.rrule, 'FREQ=DAILY;COUNT=3');
    });
  });

  group('one series the rule engine refuses does not stop the backup', () {
    // A rule can reach the store from outside (a file, Google) in a form the
    // recurrence engine rejects: both UNTIL and COUNT, or a frequency it does
    // not know. Writing the file must not fail because of one such series.
    for (final bad in [
      'FREQ=DAILY;COUNT=3;UNTIL=20261231T235959Z',
      'FREQ=SOMETIMES;UNTIL=20261231T235959Z',
    ]) {
      test('"$bad" is written as it is stored; the others come through', () {
        final broken = ev(
          'bad',
          'Rossz szabály',
          t0,
          t0.add(const Duration(hours: 1)),
          rrule: bad,
        );
        final fine = ev(
          'good',
          'Jó sorozat',
          t0,
          t0.add(const Duration(hours: 1)),
          rrule: 'FREQ=DAILY;COUNT=2',
        );
        final single = ev(
          'one',
          'Egyedi',
          t0,
          t0.add(const Duration(hours: 1)),
        );
        final text = exportIcs([broken, fine, single]);
        expect(text, contains('RRULE:$bad'));
        final back = parseIcs(text, calendarId: 'naptar');
        expect(back.events.map((e) => e.id), ['bad', 'good', 'one']);
        expect(back.events[1].rrule, 'FREQ=DAILY;COUNT=2');
      });
    }

    test('a good rule next to a broken one is still written in UTC form', () {
      final broken = ev(
        'bad',
        'Rossz',
        t0,
        t0.add(const Duration(hours: 1)),
        rrule: 'FREQ=NEVER;UNTIL=20261231T235959Z',
      );
      final fine = ev(
        'good',
        'Jó',
        floating(2026, 5, 4, 9),
        floating(2026, 5, 4, 10),
        rrule: 'FREQ=DAILY;UNTIL=20260508T090000Z',
      );
      expect(exportIcs([broken, fine]), contains('UNTIL=20260508T070000Z'));
    });
  });

  group('deleted occurrences travel as EXDATEs of their series', () {
    CalEvent series() => ev(
      'm',
      'Edzés',
      floating(2026, 5, 4, 9),
      floating(2026, 5, 4, 10),
      rrule: 'FREQ=DAILY;COUNT=5',
      ex: [floating(2026, 5, 5, 9)],
    );
    CalEvent cancelled(DateTime at) => CalEvent(
      id: 'x-${at.day}',
      calendarId: 'naptar',
      title: 'Edzés',
      tzid: 'Europe/Budapest',
      start: at,
      end: at.add(const Duration(hours: 1)),
      recurringEventId: 'm',
      originalStart: at,
      cancelled: true,
    );

    test(
      'the cancelled row is not an event of its own, the series says it',
      () {
        final text = exportIcs([series(), cancelled(floating(2026, 5, 6, 9))]);
        expect('BEGIN:VEVENT'.allMatches(text), hasLength(1));
        expect(text, contains('EXDATE;TZID=Europe/Budapest:20260505T090000'));
        expect(text, contains('EXDATE;TZID=Europe/Budapest:20260506T090000'));
      },
    );

    test('after reading it back the occurrence is still gone', () {
      final text = exportIcs([series(), cancelled(floating(2026, 5, 6, 9))]);
      final back = parseIcs(text, calendarId: 'c').events.single;
      final days = expand(
        back,
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 6, 1),
      ).map((o) => toWallClock('Europe/Budapest', o.startUtc).day);
      expect(days, [4, 7, 8]);
    });

    test('a date listed twice is written once', () {
      final text = exportIcs([series(), cancelled(floating(2026, 5, 5, 9))]);
      expect('EXDATE'.allMatches(text), hasLength(1));
    });

    test('an exception that is NOT cancelled is still an event of its own', () {
      final moved = cancelled(floating(2026, 5, 6, 9))
          .copyWith(cancelled: false, title: 'Átrakva', bumpVersion: false);
      final text = exportIcs([series(), moved]);
      expect('BEGIN:VEVENT'.allMatches(text), hasLength(2));
      expect(
        text,
        contains('RECURRENCE-ID;TZID=Europe/Budapest:20260506T090000'),
      );
    });
  });

  group('what is refused, with a reason', () {
    String one(
      String start,
      String end, {
      String tz = ';TZID=Europe/Budapest',
    }) =>
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n'
        'DTSTART$tz:$start\r\nDTEND$tz:$end\r\nSUMMARY:Valami\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';

    test('a timed event of years (an end date of 9999) is skipped', () {
      final imp = parseIcs(
        one('20260504T090000', '99990504T090000'),
        calendarId: 'c',
      );
      expect(imp.events, isEmpty);
      expect(imp.problems.single, contains('túl hosszú'));
    });

    test(
      'a year or two of timed event is skipped, a normal long one is kept',
      () {
        expect(
          parseIcs(
            one('20260504T090000', '20270910T090000'),
            calendarId: 'c',
          ).events,
          isEmpty,
        );
        expect(
          parseIcs(
            one('20260504T090000', '20260801T090000'),
            calendarId: 'c',
          ).events,
          hasLength(1),
          reason: 'a three-month event is fine',
        );
      },
    );

    test('all-day: up to ten years is fine, more is skipped', () {
      String allDay(String a, String b) => one(a, b, tz: ';VALUE=DATE');
      expect(
        parseIcs(allDay('20260504', '20300504'), calendarId: 'c').events,
        hasLength(1),
      );
      final imp = parseIcs(allDay('20260504', '20400504'), calendarId: 'c');
      expect(imp.events, isEmpty);
      expect(imp.problems.single, contains('túl hosszú'));
    });

    test('dates far from this century are skipped', () {
      for (final y in ['18500101', '21500101']) {
        final imp = parseIcs(
          one('${y}T090000', '${y}T100000'),
          calendarId: 'c',
        );
        expect(imp.events, isEmpty, reason: y);
        expect(imp.problems.single, contains('időpont'));
      }
    });

    test('a file beyond the size limit is not read at all', () {
      final text = one('20260504T090000', '20260504T100000');
      final imp = parseIcs(text, calendarId: 'c', maxChars: 100);
      expect(imp.events, isEmpty);
      expect(imp.problems.single, contains('túl nagy'));
      expect(parseIcs(text, calendarId: 'c').events, hasLength(1));
    });
  });

  group('long folded lines', () {
    test(
      'a description of megabytes in 75-octet pieces is read in moments',
      () {
        final b = StringBuffer(
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:big\r\n'
          'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
          'DTEND;TZID=Europe/Budapest:20260504T100000\r\nSUMMARY:Nagy\r\n'
          'DESCRIPTION:start',
        );
        for (var i = 0; i < 30000; i++) {
          b.write('\r\n ${'x' * 73}');
        }
        b.write('\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n');
        final sw = Stopwatch()..start();
        final imp = parseIcs(b.toString(), calendarId: 'c');
        sw.stop();
        expect(imp.events.single.notes.length, 5 + 30000 * 73);
        expect(sw.elapsedMilliseconds, lessThan(3000));
      },
    );

    test('a folded title is joined back together', () {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:f\r\n'
        'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
        'SUMMARY:Hosszú\r\n  cím\r\n\tfolytatás\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      expect(imp.events.single.title, 'Hosszú címfolytatás');
    });
  });
}
