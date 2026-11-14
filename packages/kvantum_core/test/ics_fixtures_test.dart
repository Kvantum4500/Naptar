import 'dart:convert';
import 'dart:io';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

// The samples in test/fixtures/ics are written by hand, after the files that
// Apple Calendar, Outlook for Windows and Google Calendar produce (see the
// README next to them). They are NOT exports of real calendars. Every
// expectation below was worked out by hand from the sample text, not by
// running the code and copying what came out.

List<int> bytesOf(String name) =>
    File('test/fixtures/ics/$name').readAsBytesSync();

String textOf(String name) => utf8.decode(bytesOf(name));

IcsImport read(String name) => parseIcs(textOf(name), calendarId: 'c');

CalEvent byId(IcsImport r, String id) =>
    r.events.singleWhere((e) => e.id == id, orElse: () => fail('no event $id'));

CalEvent byTitle(IcsImport r, String title) => r.events.singleWhere(
  (e) => e.title == title,
  orElse: () => fail('no event "$title"'),
);

List<Occurrence> occurrences(
  IcsImport r,
  CalEvent master,
  DateTime from,
  DateTime to,
) => expand(
  master,
  from,
  to,
  overrides: [
    for (final e in r.events)
      if (e.recurringEventId == master.id) e,
  ],
);

void main() {
  setUpAll(ensureTimeZones);

  group('the samples are the bytes they claim to be', () {
    test('CRLF line ends, no line over 75 octets, no bare LF', () {
      for (final name in [
        'apple_calendar.ics',
        'outlook_windows_tz.ics',
        'google_export.ics',
      ]) {
        final b = bytesOf(name);
        final text = latin1.decode(b);
        expect(
          text.replaceAll('\r\n', '').contains('\n'),
          isFalse,
          reason: name,
        );
        for (final line in text.split('\r\n')) {
          expect(line.length, lessThanOrEqualTo(75), reason: '$name: $line');
        }
      }
    });

    test('the Outlook sample starts with a UTF-8 byte order mark', () {
      expect(bytesOf('outlook_windows_tz.ics').take(3), [0xEF, 0xBB, 0xBF]);
      expect(bytesOf('apple_calendar.ics').take(3), isNot([0xEF, 0xBB, 0xBF]));
    });

    test('a byte order mark in front of the text does no harm', () {
      final plain = parseIcs(textOf('apple_calendar.ics'), calendarId: 'c');
      final marked = parseIcs(
        '﻿${textOf('apple_calendar.ics')}',
        calendarId: 'c',
      );
      expect(marked.events.map((e) => e.id), plain.events.map((e) => e.id));
      expect(marked.problems, plain.problems);
    });
  });

  group('Apple Calendar sample', () {
    late IcsImport r;
    const uid = '6F3C2A1E-8B7D-4E5F-9A10-2B3C4D5E6F70';
    setUp(() => r = read('apple_calendar.ics'));

    test('six events, nothing to complain about', () {
      expect(r.problems, isEmpty);
      expect(r.events.length, 6);
    });

    test('the weekly series: zone, times, limit, the two excluded days', () {
      final m = byId(r, uid);
      expect(m.title, 'Heti megbeszélés');
      expect(m.tzid, 'Europe/Budapest');
      expect(m.start, floating(2026, 5, 4, 9));
      expect(m.end, floating(2026, 5, 4, 10));
      // the file's UNTIL is 22:59:59 UTC = the end of Monday 26 Oct in Budapest
      expect(m.rrule, 'FREQ=WEEKLY;UNTIL=20261026T235959Z;BYDAY=MO');
      expect(m.exdates, [floating(2026, 5, 18, 9), floating(2026, 6, 1, 9)]);
      expect(m.recurringEventId, isNull);
    });

    test('the moved occurrence belongs to the series', () {
      final o = byTitle(r, 'Heti megbeszélés (áthelyezve)');
      expect(o.recurringEventId, uid);
      expect(o.originalStart, floating(2026, 5, 11, 9));
      expect(o.start, floating(2026, 5, 12, 14));
      expect(o.end, floating(2026, 5, 12, 15));
      expect(o.id, '$uid#2026-05-11T09:00:00.000Z');
    });

    test('24 occurrences from May to October, 09:00 in Budapest all along', () {
      final m = byId(r, uid);
      final occ = occurrences(
        r,
        m,
        DateTime.utc(2026, 5),
        DateTime.utc(2026, 11),
      );
      // 26 Mondays from 4 May to 26 Oct, 2 excluded; the moved one is still one
      expect(occ.length, 24);
      expect(occ.first.startUtc, DateTime.utc(2026, 5, 4, 7)); // summer time
      expect(occ.last.startUtc, DateTime.utc(2026, 10, 26, 8)); // winter time
      final moved = occ.singleWhere(
        (o) => o.originalStart == floating(2026, 5, 11, 9),
      );
      expect(moved.startUtc, DateTime.utc(2026, 5, 12, 12));
      expect(moved.isOverride, isTrue);
      expect(
        occ.map((o) => o.originalStart),
        isNot(containsAll([floating(2026, 5, 18, 9), floating(2026, 6, 1, 9)])),
      );
    });

    test('a single event with an escaped comma and a line break', () {
      final e = byTitle(r, 'Fogorvos');
      expect(e.start, floating(2026, 6, 3, 16, 30));
      expect(e.end, floating(2026, 6, 3, 17, 15));
      expect(e.location, 'Budapest, Andrássy út 10.');
      expect(e.notes, 'Hozd a kártyát.\nMásodik sor');
      expect(e.rrule, isNull);
    });

    test('an all-day event of three days has an exclusive end', () {
      final e = byTitle(r, 'Konferencia');
      expect(e.allDay, isTrue);
      expect(e.tzid, isNull);
      expect(e.start, floating(2026, 6, 12));
      expect(e.end, floating(2026, 6, 15));
    });

    test('a yearly all-day event comes back every year', () {
      final e = byTitle(r, 'Anyu születésnapja');
      expect(e.rrule, 'FREQ=YEARLY');
      final occ = expand(e, DateTime.utc(2026), DateTime.utc(2029));
      expect(occ.map((o) => o.startUtc), [
        DateTime.utc(2026, 3, 21),
        DateTime.utc(2027, 3, 21),
        DateTime.utc(2028, 3, 21),
      ]);
    });

    test('a night shift over the end of summer time lasts nine real hours', () {
      final e = byTitle(r, 'Éjszakai műszak');
      expect(e.start, floating(2026, 10, 24, 22));
      expect(e.end, floating(2026, 10, 25, 6));
      expect(e.endUtc.difference(e.startUtc), const Duration(hours: 9));
    });
  });

  group('Google Calendar sample', () {
    late IcsImport r;
    setUp(() => r = read('google_export.ics'));

    test('eight events (two things are said: RDATE and the UTC series)', () {
      expect(r.problems.length, 2);
      expect(r.events.length, 8);
    });

    test('a single event in UTC is shown in Budapest time', () {
      final e = byId(r, '7k3m9q2p4r5s6t7u8v9w0x1y2z@google.com');
      expect(e.title, 'Fogorvos');
      expect(e.tzid, 'Europe/Budapest');
      // 14:30 UTC in June is 16:30 in Budapest
      expect(e.start, floating(2026, 6, 3, 16, 30));
      expect(e.end, floating(2026, 6, 3, 17, 15));
      expect(e.location, 'Budapest, Andrássy út 10.');
    });

    test('escapes are undone and the folded line is one again', () {
      final e = byTitle(r, 'Fogorvos');
      expect(
        e.notes,
        'Hozd a kártyát.\nMásodik sor, vesszővel; pontosvesszővel és \\ per '
        'jellel, hogy a sor tovább is hosszabb legyen a 75 oktetnél.',
      );
    });

    test('an empty DESCRIPTION and LOCATION are just empty', () {
      final e = byTitle(r, 'Kétheti edzés');
      expect(e.notes, '');
      expect(e.location, '');
    });

    test('every second Monday, one of them excluded', () {
      final e = byTitle(r, 'Kétheti edzés');
      expect(e.rrule, 'FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO');
      expect(e.exdates, [floating(2026, 5, 18, 9)]);
      final occ = expand(e, DateTime.utc(2026, 5), DateTime.utc(2026, 8));
      expect(occ.map((o) => o.originalStart), [
        floating(2026, 5, 4, 9),
        floating(2026, 6, 1, 9),
        floating(2026, 6, 15, 9),
        floating(2026, 6, 29, 9),
        floating(2026, 7, 13, 9),
        floating(2026, 7, 27, 9),
      ]);
    });

    test('the second Monday and the last Friday of the month', () {
      final second = byTitle(r, 'Havi tervezés');
      final last = byTitle(r, 'Hónap utolsó pénteke');
      final from = DateTime.utc(2026, 5);
      final to = DateTime.utc(2027);
      expect(expand(second, from, to).map((o) => o.originalStart.day), [
        11,
        8,
        13,
        10,
        14,
        12,
        9,
        14,
      ]);
      expect(expand(last, from, to).map((o) => o.originalStart.day), [
        29,
        26,
        31,
        28,
        25,
        30,
        27,
        25,
      ]);
    });

    test('an all-day single event', () {
      final e = byTitle(r, 'Augusztus 1.');
      expect(e.allDay, isTrue);
      expect(e.start, floating(2026, 8, 1));
      expect(e.end, floating(2026, 8, 2));
    });
  });

  group('Outlook sample (what does not depend on the Windows zone names)', () {
    late IcsImport r;
    setUp(() => r = read('outlook_windows_tz.ics'));

    test('a long UID that was folded is read back whole', () {
      final e = r.events.firstWhere(
        (e) =>
            e.title == 'Heti projekt egyeztetés' && e.recurringEventId == null,
      );
      expect(
        e.id,
        '040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F501000000000000000010'
        '0000009D1E2F3A4B5C6D7E8F901A2B3C4D5E6F',
      );
    });

    test('a property with a parameter (SUMMARY;LANGUAGE=hu) is read', () {
      expect(r.events.map((e) => e.title), contains('Szabadság'));
    });

    test('an all-day leave of five days', () {
      final e = byTitle(r, 'Szabadság');
      expect(e.allDay, isTrue);
      expect(e.start, floating(2026, 7, 13));
      expect(e.end, floating(2026, 7, 18));
    });

    test('a weekly all-day series with an EXDATE;VALUE=DATE', () {
      final e = byTitle(r, 'Szemétszállítás');
      expect(e.allDay, isTrue);
      expect(e.rrule, 'FREQ=WEEKLY;UNTIL=20260626T235959Z;INTERVAL=1;BYDAY=FR');
      expect(e.exdates, [floating(2026, 6, 12)]);
      final occ = expand(e, DateTime.utc(2026, 5), DateTime.utc(2026, 8));
      expect(occ.map((o) => o.startUtc), [
        DateTime.utc(2026, 5, 29),
        DateTime.utc(2026, 6, 5),
        DateTime.utc(2026, 6, 19),
        DateTime.utc(2026, 6, 26),
      ]);
    });
  });

  group('zones: Windows names, and a zone of its own on every time', () {
    late IcsImport r;
    setUp(() => r = read('outlook_windows_tz.ics'));

    CalEvent master(String title) => r.events.firstWhere(
      (e) => e.title == title && e.recurringEventId == null,
    );

    test('"W. Europe Standard Time" is a zone the app knows', () {
      final e = master('Heti projekt egyeztetés');
      expect(e.tzid, 'Europe/Berlin');
      expect(e.start, floating(2026, 5, 6, 13));
      expect(e.end, floating(2026, 5, 6, 14, 30));
      expect(e.exdates, [floating(2026, 5, 20, 13)]);
      expect(r.problems.where((p) => p.contains('időzóna')), isEmpty);
    });

    test('a meeting in San Francisco time is where it is in the world', () {
      final e = master('Webinar (San Francisco)');
      expect(e.tzid, 'America/Los_Angeles');
      expect(e.start, floating(2026, 5, 11, 9));
      expect(e.end, floating(2026, 5, 11, 10));
      // 09:00 in San Francisco (summer time) is 16:00 UTC
      expect(e.startUtc, DateTime.utc(2026, 5, 11, 16));
    });

    test('the end of a flight is told in the zone of the landing', () {
      final e = master('Repülőút Londonba');
      expect(e.tzid, 'Europe/Berlin');
      expect(e.start, floating(2026, 6, 20, 8, 15));
      // 09:30 in London (summer time) is 10:30 in Berlin: a flight of 2 h 15 min
      expect(e.end, floating(2026, 6, 20, 10, 30));
      expect(
        e.endUtc.difference(e.startUtc),
        const Duration(hours: 2, minutes: 15),
      );
    });

    test('a name nobody knows is said so, and the default zone is used', () {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:z\r\n'
        'DTSTART;TZID="Bogus Standard Time":20260504T090000\r\n'
        'DTEND;TZID="Bogus Standard Time":20260504T100000\r\n'
        'SUMMARY:Ismeretlen\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      final e = imp.events.single;
      expect(e.tzid, 'Europe/Budapest');
      expect(e.start, floating(2026, 5, 4, 9));
      expect(imp.problems, [contains('Bogus Standard Time')]);
    });

    test('a path in front of the name (Thunderbird) is taken off', () {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:t\r\n'
        'DTSTART;TZID=/mozilla.org/20070129_1/America/New_York:20260504T090000\r\n'
        'DTEND;TZID=/mozilla.org/20070129_1/America/New_York:20260504T100000\r\n'
        'SUMMARY:Thunderbird\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      expect(imp.problems, isEmpty);
      expect(imp.events.single.tzid, 'America/New_York');
    });

    String series(String extra) =>
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n'
        'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
        'DTEND;TZID=Europe/Budapest:20260504T100000\r\n'
        'RRULE:FREQ=DAILY;COUNT=20\r\nSUMMARY:S\r\n'
        'END:VEVENT\r\n$extra'
        'END:VCALENDAR\r\n';

    test('an EXDATE in the zone of its own is turned into the event zone', () {
      // 03:00 in New York in May is 07:00 UTC, which is 09:00 in Budapest
      final imp = parseIcs(
        series('').replaceFirst(
          'SUMMARY:S\r\n',
          'SUMMARY:S\r\nEXDATE;TZID=America/New_York:20260518T030000\r\n',
        ),
        calendarId: 'c',
      );
      expect(imp.events.single.exdates, [floating(2026, 5, 18, 9)]);
    });

    test('an EXDATE in UTC is turned into the event zone', () {
      final imp = parseIcs(
        series('').replaceFirst(
          'SUMMARY:S\r\n',
          'SUMMARY:S\r\nEXDATE:20260518T070000Z\r\n',
        ),
        calendarId: 'c',
      );
      expect(imp.events.single.exdates, [floating(2026, 5, 18, 9)]);
    });

    test('a date-only EXDATE of a timed series takes out that day', () {
      final imp = parseIcs(
        series('').replaceFirst(
          'SUMMARY:S\r\n',
          'SUMMARY:S\r\nEXDATE;VALUE=DATE:20260518\r\n',
        ),
        calendarId: 'c',
      );
      final e = imp.events.single;
      expect(e.exdates, [floating(2026, 5, 18, 9)]);
      final occ = expand(
        e,
        DateTime.utc(2026, 5, 17),
        DateTime.utc(2026, 5, 20),
      );
      expect(occ.map((o) => o.originalStart.day), [17, 19]);
    });

    test('a RECURRENCE-ID in the zone of its own points at the occurrence', () {
      final imp = parseIcs(
        series(
          'BEGIN:VEVENT\r\nUID:u\r\n'
          'RECURRENCE-ID;TZID=America/New_York:20260518T030000\r\n'
          'DTSTART;TZID=Europe/Budapest:20260518T110000\r\n'
          'DTEND;TZID=Europe/Budapest:20260518T120000\r\n'
          'SUMMARY:S (később)\r\nEND:VEVENT\r\n',
        ),
        calendarId: 'c',
      );
      final o = imp.events.singleWhere((e) => e.recurringEventId != null);
      expect(o.originalStart, floating(2026, 5, 18, 9));
    });
  });

  group('cancelled (STATUS:CANCELLED)', () {
    late IcsImport r;
    setUp(() => r = read('outlook_windows_tz.ics'));

    test('a cancelled meeting is left out, and the file says so', () {
      expect(
        r.events.map((e) => e.title),
        isNot(contains('Lemondott megbeszélés')),
      );
      expect(r.problems, [
        allOf(contains('Lemondott megbeszélés'), contains('lemondott')),
      ]);
    });

    test('a cancelled occurrence stays as a row that hides that day', () {
      final master = r.events.firstWhere(
        (e) =>
            e.title == 'Heti projekt egyeztetés' && e.recurringEventId == null,
      );
      final gone = r.events.singleWhere((e) => e.recurringEventId == master.id);
      expect(gone.cancelled, isTrue);
      expect(gone.originalStart, floating(2026, 5, 27, 13));
      final occ = occurrences(
        r,
        master,
        DateTime.utc(2026, 5),
        DateTime.utc(2026, 7),
      );
      // Wednesdays 6 May .. 24 June are eight; the 20th is an EXDATE, the 27th
      // is cancelled
      expect(occ.map((o) => o.originalStart.day), [6, 13, 3, 10, 17, 24]);
      expect(occ.any((o) => o.isOverride), isFalse);
    });

    test('a cancelled series is left out as a whole', () {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\nBEGIN:VEVENT\r\nUID:c\r\n'
        'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
        'DTEND;TZID=Europe/Budapest:20260504T100000\r\n'
        'RRULE:FREQ=DAILY;COUNT=5\r\nSTATUS:CANCELLED\r\nSUMMARY:Vége\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      expect(imp.events, isEmpty);
      expect(imp.problems, [contains('Vége')]);
    });

    test('the status is read in any case, and CONFIRMED does nothing', () {
      String one(String status) =>
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:c\r\n'
          'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
          'DTEND;TZID=Europe/Budapest:20260504T100000\r\n'
          'STATUS:$status\r\nSUMMARY:Valami\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      expect(parseIcs(one('cancelled'), calendarId: 'c').events, isEmpty);
      expect(parseIcs(one('CONFIRMED'), calendarId: 'c').events.length, 1);
      expect(parseIcs(one('TENTATIVE'), calendarId: 'c').events.length, 1);
    });

    test('a cancelled occurrence is written as an EXDATE of its series', () {
      final text = exportIcs(r.events);
      final back = parseIcs(text, calendarId: 'c');
      final master = back.events.firstWhere(
        (e) =>
            e.title == 'Heti projekt egyeztetés' && e.recurringEventId == null,
      );
      expect(master.exdates, contains(floating(2026, 5, 27, 13)));
      expect(master.exdates, contains(floating(2026, 5, 20, 13)));
    });
  });

  group('the zone names', () {
    test('a known IANA name stays, a Windows name becomes one', () {
      expect(ianaZoneOf('Europe/Budapest'), 'Europe/Budapest');
      expect(ianaZoneOf('Central Europe Standard Time'), 'Europe/Budapest');
      expect(ianaZoneOf('W. Europe Standard Time'), 'Europe/Berlin');
      expect(ianaZoneOf('GMT Standard Time'), 'Europe/London');
      expect(ianaZoneOf('Pacific Standard Time'), 'America/Los_Angeles');
      expect(ianaZoneOf('UTC'), 'UTC');
    });

    test(
      'case and spaces around the name do not matter for a Windows name',
      () {
        expect(ianaZoneOf('  w. europe standard time '), 'Europe/Berlin');
      },
    );

    test('a path in front of the name is taken off', () {
      expect(
        ianaZoneOf('/mozilla.org/20070129_1/Europe/Berlin'),
        'Europe/Berlin',
      );
      expect(
        ianaZoneOf(
          '/freeassociation.sourceforge.net/Tzfile/America/Argentina/Buenos_Aires',
        ),
        'America/Argentina/Buenos_Aires',
      );
    });

    test('what nobody knows is null', () {
      expect(ianaZoneOf('Bogus Standard Time'), isNull);
      expect(ianaZoneOf(''), isNull);
      expect(ianaZoneOf('/'), isNull);
    });

    test('every Windows name of the table is a zone the database knows', () {
      expect(windowsZoneNames, isNotEmpty);
      windowsZoneNames.forEach((windows, iana) {
        expect(() => locationOf(iana), returnsNormally, reason: windows);
        expect(ianaZoneOf(windows), iana, reason: windows);
      });
    });
  });

  group('what is written from these samples reads back the same', () {
    // A file that went through the app once (read, written, read) must be a
    // fixed point: reading the written file again changes nothing, and the
    // series still has the same occurrences.
    for (final name in ['apple_calendar.ics', 'google_export.ics']) {
      test(name, () {
        final first = read(name);
        final second = parseIcs(exportIcs(first.events), calendarId: 'c');
        final third = parseIcs(exportIcs(second.events), calendarId: 'c');
        expect(second.problems, isEmpty);
        expect(third.events.length, first.events.length);
        for (var i = 0; i < second.events.length; i++) {
          final a = second.events[i], b = third.events[i];
          expect(
            [a.id, a.title, a.notes, a.location, a.start, a.end, a.tzid],
            [b.id, b.title, b.notes, b.location, b.start, b.end, b.tzid],
            reason: a.title,
          );
          expect(a.allDay, b.allDay, reason: a.title);
          expect(a.rrule, b.rrule, reason: a.title);
          expect(a.exdates, b.exdates, reason: a.title);
          expect(a.recurringEventId, b.recurringEventId, reason: a.title);
          expect(a.originalStart, b.originalStart, reason: a.title);
        }
        // the first reading and the second agree on what happens when
        final from = DateTime.utc(2026), to = DateTime.utc(2027, 6);
        List<DateTime> instants(IcsImport x) => [
          for (final e in x.events)
            if (e.recurringEventId == null)
              for (final o in expand(
                e,
                from,
                to,
                overrides: [
                  for (final o in x.events)
                    if (o.recurringEventId == e.id) o,
                ],
              ))
                o.startUtc,
        ]..sort();
        expect(instants(second), instants(first));
      });
    }
  });

  group('what the app does not take over is said, not hidden', () {
    // These files are still read; what a line of the file means beyond what
    // the app can do is told in the problems, so that nobody wonders later why
    // a day is missing or an hour is off.
    String one(
      String extra, {
      String dtstart = 'DTSTART;TZID=Europe/Budapest:20260503T090000',
    }) =>
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:w\r\n$dtstart\r\n'
        'DTEND;TZID=Europe/Budapest:20260503T100000\r\n$extra'
        'SUMMARY:Valami\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

    test('RDATE: the extra dates of a series', () {
      final r = read('google_export.ics');
      expect(r.problems.where((p) => p.contains('RDATE')), [
        allOf(contains('Hétfői ebéd'), contains('nem vettem át')),
      ]);
    });

    test('EXRULE: a rule of excluded days', () {
      final imp = parseIcs(
        one('RRULE:FREQ=DAILY;COUNT=7\r\nEXRULE:FREQ=WEEKLY;BYDAY=SA,SU\r\n'),
        calendarId: 'c',
      );
      expect(imp.events.length, 1);
      expect(imp.problems, [allOf(contains('Valami'), contains('EXRULE'))]);
    });

    test('RANGE=THISANDFUTURE: a change of this and all later days', () {
      final imp = parseIcs(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s\r\n'
        'RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=Europe/Budapest:20260518T090000\r\n'
        'DTSTART;TZID=Europe/Budapest:20260518T100000\r\n'
        'DTEND;TZID=Europe/Budapest:20260518T110000\r\n'
        'SUMMARY:Sor (késve)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
        calendarId: 'c',
      );
      expect(imp.events.length, 1);
      expect(imp.problems, [
        allOf(contains('Sor (késve)'), contains('THISANDFUTURE')),
      ]);
    });

    test('a week start that is not Monday, where it can change the days', () {
      final imp = parseIcs(
        one('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU\r\n'),
        calendarId: 'c',
      );
      expect(imp.problems, [allOf(contains('Valami'), contains('WKST=SU'))]);
    });

    test('a week start that changes nothing is not mentioned', () {
      // one day of the week, every week or every second week: the weeks may
      // start on any day
      for (final rule in [
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU',
        'FREQ=WEEKLY;BYDAY=SU,MO;WKST=SU',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=MO',
        'FREQ=DAILY;INTERVAL=2;WKST=SU',
      ]) {
        final imp = parseIcs(one('RRULE:$rule\r\n'), calendarId: 'c');
        expect(imp.problems, isEmpty, reason: rule);
      }
    });

    test('a series that starts in UTC: the hour moves with summer time', () {
      final r = read('google_export.ics');
      expect(r.problems.where((p) => p.contains('UTC')), [
        allOf(contains('Reggeli áttekintés'), contains('nyári')),
      ]);
    });

    test('a single event in UTC is nothing to say', () {
      final imp = parseIcs(
        one('', dtstart: 'DTSTART:20260503T070000Z'),
        calendarId: 'c',
      );
      expect(imp.problems, isEmpty);
    });

    test('the samples that are in order say nothing', () {
      expect(read('apple_calendar.ics').problems, isEmpty);
      expect(read('google_export.ics').problems.length, 2); // RDATE, UTC series
    });
  });

  group('known limits: how these things are read today', () {
    // Not mistakes that are being hidden: each of these is something the app
    // does not do (yet). Written down so that a change shows up in a test.

    test('RDATE (an extra date of a series) is not taken over', () {
      final e = byTitle(read('google_export.ics'), 'Hétfői ebéd');
      final occ = expand(e, DateTime.utc(2026, 5), DateTime.utc(2026, 8));
      // COUNT=3 Mondays (1, 8, 15 June); the file also lists Wednesday 17 June
      expect(occ.map((o) => o.originalStart.day), [1, 8, 15]);
    });

    test('a series fixed in UTC keeps its wall-clock hour through the year', () {
      final e = byTitle(
        read('google_export.ics'),
        'Reggeli áttekintés (UTC-ben rögzítve)',
      );
      expect(e.start, floating(2026, 5, 4, 9)); // 07:00 UTC in summer time
      final winter = expand(
        e,
        DateTime.utc(2026, 11),
        DateTime.utc(2026, 11, 8),
      );
      // the file means 07:00 UTC every week, i.e. 08:00 in Budapest in winter;
      // the app keeps 09:00 on the wall, which is 08:00 UTC
      expect(winter.single.startUtc, DateTime.utc(2026, 11, 2, 8));
    });

    test('with another week start the weeks are counted from Monday', () {
      // A fortnightly series on Sundays and Mondays, weeks starting on Sunday:
      // 3+4 May, 17+18 May. Read with weeks from Monday it is 3 May, then 11
      // and 17 May, then 25 and 31 May.
      const text =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:w\r\n'
          'DTSTART;TZID=Europe/Budapest:20260503T090000\r\n'
          'DTEND;TZID=Europe/Budapest:20260503T100000\r\n'
          'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU\r\n'
          'SUMMARY:Hétvégi\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final e = parseIcs(text, calendarId: 'c').events.single;
      final occ = expand(e, DateTime.utc(2026, 5), DateTime.utc(2026, 6));
      expect(occ.map((o) => o.originalStart.day), [3, 11, 17, 25, 31]);
    });

    test('RANGE=THISANDFUTURE is read as a change of one occurrence only', () {
      const text =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s\r\n'
          'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
          'DTEND;TZID=Europe/Budapest:20260504T100000\r\n'
          'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=6\r\nSUMMARY:Sor\r\n'
          'END:VEVENT\r\nBEGIN:VEVENT\r\nUID:s\r\n'
          'RECURRENCE-ID;RANGE=THISANDFUTURE;TZID=Europe/Budapest:20260518T090000\r\n'
          'DTSTART;TZID=Europe/Budapest:20260518T100000\r\n'
          'DTEND;TZID=Europe/Budapest:20260518T110000\r\n'
          'SUMMARY:Sor (késve)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final r = parseIcs(text, calendarId: 'c');
      final master = r.events.firstWhere((e) => e.recurringEventId == null);
      final occ = occurrences(
        r,
        master,
        DateTime.utc(2026, 5),
        DateTime.utc(2026, 7),
      );
      // the file means: from 18 May on, every Monday an hour later
      expect(occ.where((o) => o.isOverride).length, 1);
      expect(occ.length, 6);
    });

    test('EXRULE (a rule of excluded days) is ignored', () {
      const text =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n'
          'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
          'DTEND;TZID=Europe/Budapest:20260504T100000\r\n'
          'RRULE:FREQ=DAILY;COUNT=7\r\nEXRULE:FREQ=WEEKLY;BYDAY=SA,SU\r\n'
          'SUMMARY:Napi\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final e = parseIcs(text, calendarId: 'c').events.single;
      expect(expand(e, DateTime.utc(2026, 5), DateTime.utc(2026, 6)).length, 7);
    });
  });
}
