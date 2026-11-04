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
}
