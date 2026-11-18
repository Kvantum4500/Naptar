import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

DateTime w(int y, int m, int d, [int h = 0, int mi = 0]) =>
    floating(y, m, d, h, mi);

final monday = floating(2026, 11, 16);

SummaryEvent ev(String title, int h, int m, {int len = 60}) => SummaryEvent(
  title: title,
  start: w(2026, 11, 16, h, m),
  end: w(2026, 11, 16, h, m).add(Duration(minutes: len)),
);

void main() {
  group('the Hungarian date', () {
    test('weekday and month by name', () {
      expect(huDateLabel(w(2026, 11, 16)), 'hétfő, nov. 16.');
      expect(huDateLabel(w(2026, 1, 1)), 'csütörtök, jan. 1.');
      expect(huDateLabel(w(2026, 12, 26)), 'szombat, dec. 26.');
      expect(huDateLabel(w(2027, 3, 28)), 'vasárnap, márc. 28.');
    });

    test('all seven weekdays and twelve months are different words', () {
      final days = {
        for (var i = 0; i < 7; i++)
          huDateLabel(w(2026, 11, 16 + i)).split(',')[0],
      };
      expect(days.length, 7);
      final months = {
        for (var m = 1; m <= 12; m++) huDateLabel(w(2026, m, 1)).split(' ')[1],
      };
      expect(months.length, 12);
    });
  });

  group('when there is something to say', () {
    test('nothing: no summary', () {
      expect(buildDaySummary(day: monday, events: const []), isNull);
    });

    test('the weather alone is no reason for a notification', () {
      expect(
        buildDaySummary(
          day: monday,
          events: const [],
          weather: 'felhős, 8–17 °C',
        ),
        isNull,
      );
    });

    test('an event, a task, or a special day is', () {
      expect(
        buildDaySummary(day: monday, events: [ev('Fogorvos', 14, 0)]),
        isNotNull,
      );
      expect(
        buildDaySummary(
          day: monday,
          events: const [],
          tasks: const [SummaryTask('Adóbevallás')],
        ),
        isNotNull,
      );
      expect(
        buildDaySummary(
          day: floating(2026, 1, 1),
          events: const [],
          special: huDayInfo(floating(2026, 1, 1)),
        ),
        isNotNull,
      );
    });
  });

  group('the text', () {
    test('title and lines', () {
      final s = buildDaySummary(
        day: monday,
        events: [ev('Fogorvos', 14, 0), ev('Éjszakai műszak', 6, 30)],
        tasks: const [SummaryTask('Számla befizetése')],
        weather: 'felhős, 8–17 °C',
      )!;
      expect(s.title, 'Ma: hétfő, nov. 16.');
      expect(s.body.split('\n'), [
        'Időjárás: felhős, 8–17 °C',
        '06:30 Éjszakai műszak',
        '14:00 Fogorvos',
        'Feladat: Számla befizetése',
      ]);
    });

    test('the special day comes first', () {
      final s = buildDaySummary(
        day: floating(2026, 12, 24),
        events: [
          SummaryEvent(
            title: 'Vacsora',
            start: w(2026, 12, 24, 18),
            end: w(2026, 12, 24, 20),
          ),
        ],
        special: huDayInfo(floating(2026, 12, 24)),
      )!;
      expect(s.body.split('\n'), [
        'Munkaszüneti nap: Szenteste',
        '18:00 Vacsora',
      ]);
    });

    test('a working Saturday is told too', () {
      final s = buildDaySummary(
        day: floating(2026, 1, 10),
        events: const [],
        special: huDayInfo(floating(2026, 1, 10)),
      )!;
      expect(s.body, 'Áthelyezett munkanap (szombat)');
    });

    test('all-day events first, then by time, ties by title', () {
      final s = buildDaySummary(
        day: monday,
        events: [
          ev('B', 9, 0),
          ev('A', 9, 0),
          SummaryEvent(
            title: 'Névnap',
            start: w(2026, 11, 16),
            end: w(2026, 11, 17),
            allDay: true,
          ),
          ev('Reggeli', 7, 45),
        ],
      )!;
      expect(s.body.split('\n'), [
        'Egész nap: Névnap',
        '07:45 Reggeli',
        '09:00 A',
        '09:00 B',
      ]);
    });

    test('at most four events, then how many more', () {
      final s = buildDaySummary(
        day: monday,
        events: [for (var i = 0; i < 7; i++) ev('E$i', 8 + i, 0)],
      )!;
      final lines = s.body.split('\n');
      expect(lines.length, 5);
      expect(lines.sublist(0, 4), [
        '08:00 E0',
        '09:00 E1',
        '10:00 E2',
        '11:00 E3',
      ]);
      expect(lines.last, '+3 további esemény');
    });

    test('exactly four events: no "more" line', () {
      final s = buildDaySummary(
        day: monday,
        events: [for (var i = 0; i < 4; i++) ev('E$i', 8 + i, 0)],
      )!;
      expect(s.body.split('\n').length, 4);
      expect(s.body, isNot(contains('további')));
    });

    test('exactly three tasks: no "more" line', () {
      final s = buildDaySummary(
        day: monday,
        events: const [],
        tasks: const [SummaryTask('A'), SummaryTask('B'), SummaryTask('C')],
      )!;
      expect(s.body.split('\n'), ['Feladat: A', 'Feladat: B', 'Feladat: C']);
    });

    test('an event that begins at midnight sharp is told with its time', () {
      final s = buildDaySummary(day: monday, events: [ev('Éjféli', 0, 0)])!;
      expect(s.body, '00:00 Éjféli');
    });

    test('at most three tasks; an overdue one says so', () {
      final s = buildDaySummary(
        day: monday,
        events: const [],
        tasks: const [
          SummaryTask('Régi', overdue: true),
          SummaryTask('Mai 1'),
          SummaryTask('Mai 2'),
          SummaryTask('Mai 3'),
          SummaryTask('Mai 4'),
        ],
      )!;
      expect(s.body.split('\n'), [
        'Feladat (lejárt): Régi',
        'Feladat: Mai 1',
        'Feladat: Mai 2',
        '+2 további feladat',
      ]);
    });

    test('a night shift that began yesterday: until when', () {
      final s = buildDaySummary(
        day: monday,
        events: [
          SummaryEvent(
            title: 'Éjszakai műszak',
            start: w(2026, 11, 15, 18),
            end: w(2026, 11, 16, 6),
          ),
        ],
      )!;
      expect(s.body, '06:00-ig: Éjszakai műszak');
    });

    test('an event that spans the whole day is "all day"', () {
      final s = buildDaySummary(
        day: monday,
        events: [
          SummaryEvent(
            title: 'Konferencia',
            start: w(2026, 11, 15, 9),
            end: w(2026, 11, 17, 17),
          ),
        ],
      )!;
      expect(s.body, 'Egész nap: Konferencia');
    });

    test('an event that ends exactly at midnight is on its own day only', () {
      // (the caller does not hand it over for the next day; the line for the
      // day it began on shows the start)
      final s = buildDaySummary(
        day: monday,
        events: [
          SummaryEvent(
            title: 'Késő este',
            start: w(2026, 11, 16, 22),
            end: w(2026, 11, 17),
          ),
        ],
      )!;
      expect(s.body, '22:00 Késő este');
    });
  });

  group('the titles are somebody\'s text', () {
    test('control and invisible characters go, whitespace collapses', () {
      // (built from code points: the invisible ones must not sit in the source)
      final bell = String.fromCharCode(7);
      final zeroWidth = String.fromCharCode(0x200b);
      final rightToLeft = String.fromCharCode(0x202e);
      final dirty = 'Bor${bell}os\n\n  kérdés$zeroWidth$rightToLeft';
      final s = buildDaySummary(day: monday, events: [ev(dirty, 10, 0)])!;
      expect(s.body, '10:00 Bor os kérdés');
    });

    test('a long title is cut with an ellipsis', () {
      final s = buildDaySummary(day: monday, events: [ev('x' * 100, 10, 0)])!;
      final line = s.body;
      expect(line.length, '10:00 '.length + 40 + 1);
      expect(line, endsWith('…'));
    });

    test('the limit can be changed', () {
      final s = buildDaySummary(
        day: monday,
        events: [ev('abcdefghij', 10, 0)],
        maxTitle: 5,
      )!;
      expect(s.body, '10:00 abcde…');
    });

    test('a task title is cleaned the same way', () {
      final s = buildDaySummary(
        day: monday,
        events: const [],
        tasks: const [SummaryTask('Sor1\nSor2')],
      )!;
      expect(s.body, 'Feladat: Sor1 Sor2');
    });

    test('the weather text is trimmed', () {
      final s = buildDaySummary(
        day: monday,
        events: [ev('X', 8, 0)],
        weather: '  napos, 8–17 °C \n',
      )!;
      expect(s.body.split('\n'), ['Időjárás: napos, 8–17 °C', '08:00 X']);
    });

    test('empty weather text is left out', () {
      final s = buildDaySummary(
        day: monday,
        events: [ev('X', 8, 0)],
        weather: '   ',
      )!;
      expect(s.body, '08:00 X');
    });

    test('equal summaries are equal', () {
      const a = DaySummary('t', 'b');
      expect(a, const DaySummary('t', 'b'));
      expect(a, isNot(const DaySummary('t', 'c')));
      expect(a.hashCode, const DaySummary('t', 'b').hashCode);
    });
  });
}
