import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/widget/widget_data.dart';
import 'package:kvantum_core/kvantum_core.dart';

const bp = 'Europe/Budapest';

DateTime at(int y, int mo, int d, int h, [int mi = 0]) =>
    resolveWallClock(bp, floating(y, mo, d, h, mi));

Occurrence occ(
  String title,
  DateTime startUtc,
  DateTime endUtc, {
  bool allDay = false,
  bool shift = false,
}) => Occurrence(
  eventId: '$title-${startUtc.millisecondsSinceEpoch}',
  title: title,
  startUtc: startUtc,
  endUtc: endUtc,
  originalStart: floating(2026, 11, 16),
  allDay: allDay,
  isShift: shift,
);

TaskView task(String title, {DateTime? due}) => TaskView(
  SyncRecord(id: title, kind: kindTask).edit(
    taskFields(title: title, due: due),
    ts: 1,
    dev: 'd',
  ),
);

Map<String, Object?> decode(String snapshot) =>
    jsonDecode(snapshot) as Map<String, Object?>;

List<Map<String, Object?>> daysOf(String snapshot) => [
  for (final d in decode(snapshot)['days'] as List) d as Map<String, Object?>,
];

List<String> linesOf(Map<String, Object?> day) => [
  for (final l in day['lines'] as List) l as String,
];

void main() {
  setUpAll(ensureTimeZones);

  // Monday 16 November 2026, 06:00 in Budapest
  final now = at(2026, 11, 16, 6);

  String snapshot({
    DateTime? when,
    List<Occurrence> occurrences = const [],
    List<TaskView> tasks = const [],
    String tzid = bp,
  }) => widgetSnapshot(
    nowUtc: when ?? now,
    occurrences: occurrences,
    tasks: tasks,
    tzid: tzid,
  );

  group('the shape', () {
    test('has a version, the zone and seven days from today on', () {
      final j = decode(snapshot());
      expect(j['v'], 1);
      expect(j['tz'], bp);
      final days = daysOf(snapshot());
      expect(days.length, widgetDays + 1);
      expect(
        [for (final d in days) d['label']],
        [
          'hétfő, nov. 16.',
          'kedd, nov. 17.',
          'szerda, nov. 18.',
          'csütörtök, nov. 19.',
          'péntek, nov. 20.',
          'szombat, nov. 21.',
          'vasárnap, nov. 22.',
        ],
      );
      expect(j['shifts'], isEmpty);
    });

    test('the days follow each other, to the millisecond, in the zone', () {
      final days = daysOf(snapshot());
      expect(days.first['from'], at(2026, 11, 16, 0).millisecondsSinceEpoch);
      for (var i = 0; i + 1 < days.length; i++) {
        expect(days[i]['to'], days[i + 1]['from'], reason: 'day $i');
      }
      expect(days.last['to'], at(2026, 11, 23, 0).millisecondsSinceEpoch);
    });

    test('the day of the autumn clock change lasts 25 hours', () {
      // Sunday 25 October 2026: the clocks go back at 03:00
      final days = daysOf(snapshot(when: at(2026, 10, 24, 12)));
      expect(days[0]['label'], 'szombat, okt. 24.');
      expect(days[1]['label'], 'vasárnap, okt. 25.');
      const hour = 3600 * 1000;
      expect((days[0]['to'] as int) - (days[0]['from'] as int), 24 * hour);
      expect((days[1]['to'] as int) - (days[1]['from'] as int), 25 * hour);
    });

    test('the day of the spring clock change lasts 23 hours', () {
      // Sunday 28 March 2027: the clocks go forward at 02:00
      final days = daysOf(snapshot(when: at(2027, 3, 27, 12)));
      expect(days[1]['label'], 'vasárnap, márc. 28.');
      const hour = 3600 * 1000;
      expect((days[1]['to'] as int) - (days[1]['from'] as int), 23 * hour);
    });

    test('the days are those of the zone it is told, not of Budapest', () {
      // 16 Nov 2026 00:00 in Tokyo is 15 Nov 15:00 UTC
      final s = snapshot(
        when: DateTime.utc(2026, 11, 16, 1),
        tzid: 'Asia/Tokyo',
      );
      expect(decode(s)['tz'], 'Asia/Tokyo');
      expect(
        daysOf(s).first['from'],
        DateTime.utc(2026, 11, 15, 15).millisecondsSinceEpoch,
      );
    });
  });

  group('what a day says', () {
    test('events and tasks are the lines, as in the morning summary', () {
      final days = daysOf(
        snapshot(
          occurrences: [
            occ('Fogorvos', at(2026, 11, 16, 14), at(2026, 11, 16, 15)),
            occ(
              'Éjszakai műszak',
              at(2026, 11, 16, 18),
              at(2026, 11, 17, 6),
              shift: true,
            ),
            occ(
              'Konferencia',
              floating(2026, 11, 17),
              floating(2026, 11, 19),
              allDay: true,
            ),
          ],
          tasks: [task('Számla', due: floating(2026, 11, 16))],
        ),
      );
      expect(linesOf(days[0]), [
        '14:00 Fogorvos',
        '18:00 Éjszakai műszak',
        'Feladat: Számla',
      ]);
      expect(linesOf(days[1]), [
        'Egész nap: Konferencia',
        '06:00-ig: Éjszakai műszak',
      ]);
      expect(linesOf(days[2]), ['Egész nap: Konferencia']);
      expect(linesOf(days[3]), isEmpty);
    });

    test('a holiday is told apart from the lines, not repeated in them', () {
      // Sunday 1 November 2026 is All Saints' Day
      final days = daysOf(
        snapshot(
          when: at(2026, 10, 30, 6),
          occurrences: [occ('Séta', at(2026, 11, 1, 10), at(2026, 11, 1, 11))],
        ),
      );
      expect(days[0]['special'], isNull);
      expect(days[2]['label'], 'vasárnap, nov. 1.');
      expect(days[2]['special'], 'Munkaszüneti nap: Mindenszentek');
      expect(linesOf(days[2]), ['10:00 Séta']);
    });

    test('a holiday with nothing on it still has its day', () {
      final days = daysOf(snapshot(when: at(2026, 10, 30, 6)));
      expect(days[2]['special'], 'Munkaszüneti nap: Mindenszentek');
      expect(linesOf(days[2]), isEmpty);
    });

    test('the working Saturday is named', () {
      final days = daysOf(snapshot(when: at(2026, 8, 6, 6)));
      expect(days[2]['label'], 'szombat, aug. 8.');
      expect(days[2]['special'], 'Áthelyezett munkanap (szombat)');
    });

    test('an overdue task is on today only', () {
      final days = daysOf(
        snapshot(tasks: [task('Régi', due: floating(2026, 11, 10))]),
      );
      expect(linesOf(days[0]), ['Feladat (lejárt): Régi']);
      expect(linesOf(days[1]), isEmpty);
    });

    test('a long day is cut: five events and two tasks, the rest counted', () {
      final days = daysOf(
        snapshot(
          occurrences: [
            for (var h = 8; h < 14; h++)
              occ('Esemény $h', at(2026, 11, 16, h), at(2026, 11, 16, h, 30)),
          ],
          tasks: [
            task('A', due: floating(2026, 11, 16)),
            task('B', due: floating(2026, 11, 16)),
            task('C', due: floating(2026, 11, 16)),
          ],
        ),
      );
      expect(linesOf(days[0]), [
        '08:00 Esemény 8',
        '09:00 Esemény 9',
        '10:00 Esemény 10',
        '11:00 Esemény 11',
        '12:00 Esemény 12',
        '+1 további esemény',
        'Feladat: A',
        'Feladat: B',
        '+1 további feladat',
      ]);
    });

    test('what the user wrote is cleaned before it is handed over', () {
      // a right-to-left override, a zero-width space, a line break, markup
      final dirty =
          'Orvos${String.fromCharCode(0x202e)}${String.fromCharCode(0x200b)}'
          '\n<b>x</b>';
      final days = daysOf(
        snapshot(
          occurrences: [occ(dirty, at(2026, 11, 16, 9), at(2026, 11, 16, 10))],
        ),
      );
      expect(linesOf(days[0]), ['09:00 Orvos bx/b']);
    });
  });

  group('the next shifts', () {
    List<Map<String, Object?>> shiftsOf(String s) => [
      for (final x in decode(s)['shifts'] as List) x as Map<String, Object?>,
    ];

    Occurrence shift(int day, int hour, {String title = 'Éjszakai műszak'}) =>
        occ(
          title,
          at(2026, 11, day, hour),
          at(2026, 11, day, hour).add(const Duration(hours: 12)),
          shift: true,
        );

    test('are the next three that have not begun, in order', () {
      final s = snapshot(
        occurrences: [
          shift(20, 18),
          shift(17, 18),
          shift(15, 18), // already over
          shift(19, 18),
          shift(18, 18),
          shift(16, 5), // began before now (06:00)
        ],
      );
      final shifts = shiftsOf(s);
      expect(
        [for (final x in shifts) x['text']],
        [
          'kedd, nov. 17. 18:00 Éjszakai műszak',
          'szerda, nov. 18. 18:00 Éjszakai műszak',
          'csütörtök, nov. 19. 18:00 Éjszakai műszak',
        ],
      );
      expect(shifts.first['at'], at(2026, 11, 17, 18).millisecondsSinceEpoch);
    });

    test('are shifts only, and not all-day ones', () {
      final s = snapshot(
        occurrences: [
          occ('Fogorvos', at(2026, 11, 17, 9), at(2026, 11, 17, 10)),
          occ(
            'Szabadság',
            floating(2026, 11, 17),
            floating(2026, 11, 18),
            allDay: true,
            shift: true,
          ),
        ],
      );
      expect(shiftsOf(s), isEmpty);
    });

    test('are told by the clock of the zone', () {
      // 23:30 UTC on the 17th is 00:30 on the 18th in Budapest
      final s = snapshot(
        occurrences: [
          occ(
            'Éjszakai',
            DateTime.utc(2026, 11, 17, 23, 30),
            DateTime.utc(2026, 11, 18, 6),
            shift: true,
          ),
        ],
      );
      expect(shiftsOf(s).single['text'], 'szerda, nov. 18. 00:30 Éjszakai');
    });

    test('have their title cleaned and cut', () {
      final s = snapshot(
        occurrences: [
          shift(
            17,
            18,
            title: 'Műszak${String.fromCharCode(0x202e)}${'x' * 80}',
          ),
        ],
      );
      final text = shiftsOf(s).single['text'] as String;
      expect(text, startsWith('kedd, nov. 17. 18:00 Műszakx'));
      expect(text.contains(String.fromCharCode(0x202e)), isFalse);
      expect(text, endsWith('…'));
      expect(
        text.length,
        lessThanOrEqualTo('kedd, nov. 17. 18:00 '.length + 40 + 1),
      );
    });
  });

  group('the text is stable', () {
    final data = [
      occ('Fogorvos', at(2026, 11, 16, 14), at(2026, 11, 16, 15)),
      occ('Műszak', at(2026, 11, 17, 18), at(2026, 11, 18, 6), shift: true),
    ];

    test('the same calendar gives the same text, at any time of the day', () {
      final a = snapshot(when: at(2026, 11, 16, 6), occurrences: data);
      final b = snapshot(when: at(2026, 11, 16, 13, 41), occurrences: data);
      expect(b, a);
      expect(snapshot(when: at(2026, 11, 16, 6), occurrences: data), a);
    });

    test('a change of one event changes it', () {
      final a = snapshot(occurrences: data);
      final b = snapshot(
        occurrences: [
          occ('Fogorvos', at(2026, 11, 16, 15), at(2026, 11, 16, 16)),
          data.last,
        ],
      );
      expect(b, isNot(a));
    });

    test('the next day brings the next days', () {
      final a = daysOf(snapshot());
      final b = daysOf(snapshot(when: at(2026, 11, 17, 6)));
      expect(b.first['label'], 'kedd, nov. 17.');
      expect(b.first['from'], a[1]['from']);
    });

    test('a full week stays small enough for a preference value', () {
      final busy = [
        for (var d = 16; d <= 22; d++)
          for (var h = 6; h < 14; h++)
            occ(
              'Egy meglehetősen hosszú eseménycím a hét $d. napján, $h óra',
              at(2026, 11, d, h),
              at(2026, 11, d, h, 30),
            ),
      ];
      final s = snapshot(
        occurrences: busy,
        tasks: [
          for (var i = 0; i < 20; i++)
            task('Feladat $i ${'x' * 60}', due: floating(2026, 11, 16)),
        ],
      );
      expect(utf8.encode(s).length, lessThan(8 * 1024));
    });
  });
}
