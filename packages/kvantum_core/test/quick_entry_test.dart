import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// One line and what it must turn into. The clock stands on Monday
/// 16 November 2026, 10:00.
class Case {
  const Case(
    this.input,
    this.kind,
    this.title, {
    this.date,
    this.start,
    this.minutes,
    this.allDay = false,
    this.rrule,
    this.note,
  });

  final String input;
  final QuickKind kind;
  final String title;

  /// 'yyyy-mm-dd' or null.
  final String? date;

  /// 'HH:MM' or null.
  final String? start;
  final int? minutes;
  final bool allDay;
  final String? rrule;

  /// A part of one of the assumptions, when there must be one.
  final String? note;
}

const e = QuickKind.event;
const t = QuickKind.task;

final now = floating(2026, 11, 16, 10);

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String hm(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

void check(Case c) {
  final q = parseQuickEntry(c.input, now: now);
  expect(q.kind, c.kind, reason: 'kind of "${c.input}": $q');
  expect(q.title, c.title, reason: 'title of "${c.input}": $q');
  expect(q.date == null ? null : ymd(q.date!), c.date, reason: 'date: $q');
  expect(
    q.startMinute == null ? null : hm(q.startMinute!),
    c.start,
    reason: 'start: $q',
  );
  expect(q.durationMinutes, c.minutes, reason: 'length: $q');
  expect(q.allDay, c.allDay, reason: 'all day: $q');
  expect(q.rrule, c.rrule, reason: 'rule: $q');
  if (c.note != null) {
    expect(
      q.assumptions.any((a) => a.contains(c.note!)),
      isTrue,
      reason: 'a note with "${c.note}": ${q.assumptions}',
    );
  }
}

void main() {
  group('the day, relative', () {
    final cases = [
      const Case(
        'holnap 18:00 edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'ma 15:00 meeting',
        e,
        'Meeting',
        date: '2026-11-16',
        start: '15:00',
        minutes: 60,
      ),
      const Case(
        'ma 9:00 reggeli',
        e,
        'Reggeli',
        date: '2026-11-16',
        start: '09:00',
        minutes: 60,
        note: 'már elmúlt',
      ),
      const Case(
        'holnapután 7:30 futás',
        e,
        'Futás',
        date: '2026-11-18',
        start: '07:30',
        minutes: 60,
      ),
      const Case(
        'holnap reggel 8-kor futás',
        e,
        'Futás',
        date: '2026-11-17',
        start: '08:00',
        minutes: 60,
      ),
      const Case(
        'ma este 8-kor film',
        e,
        'Film',
        date: '2026-11-16',
        start: '20:00',
        minutes: 60,
      ),
      const Case(
        'holnap délután 3-kor fogorvos',
        e,
        'Fogorvos',
        date: '2026-11-17',
        start: '15:00',
        minutes: 60,
      ),
      const Case(
        'holnap este 6 vacsora',
        e,
        'Vacsora',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'holnap délben ebéd',
        e,
        'Ebéd',
        date: '2026-11-17',
        start: '12:00',
        minutes: 60,
      ),
      const Case(
        'két nap múlva vizsga',
        e,
        'Vizsga',
        date: '2026-11-18',
        allDay: true,
      ),
      const Case(
        '3 nap múlva számlát fizetni',
        t,
        'Számlát fizetni',
        date: '2026-11-19',
      ),
      const Case(
        'egy hét múlva fogorvos',
        e,
        'Fogorvos',
        date: '2026-11-23',
        allDay: true,
      ),
      const Case(
        'két hét múlva 10:00 megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-30',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'egy hónap múlva szülinap',
        e,
        'Szülinap',
        date: '2026-12-16',
        allDay: true,
      ),
      const Case('3 napon belül befizetni', t, 'Befizetni', date: '2026-11-19'),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('the hour', () {
    final cases = [
      const Case(
        'holnap 5-kor tárgyalás',
        e,
        'Tárgyalás',
        date: '2026-11-17',
        start: '17:00',
        minutes: 60,
        note: '17:00',
      ),
      const Case(
        'holnap 9-kor tárgyalás',
        e,
        'Tárgyalás',
        date: '2026-11-17',
        start: '09:00',
        minutes: 60,
      ),
      const Case(
        'ma 6 órakor kávé',
        e,
        'Kávé',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        note: '18:00',
      ),
      const Case(
        'holnap 14 órakor megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-17',
        start: '14:00',
        minutes: 60,
      ),
      const Case(
        'holnap 14.30 megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-17',
        start: '14:30',
        minutes: 60,
      ),
      const Case(
        'holnap 14:30-kor megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-17',
        start: '14:30',
        minutes: 60,
      ),
      const Case(
        'holnap fél 3 megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-17',
        start: '14:30',
        minutes: 60,
        note: '14:30',
      ),
      const Case(
        'holnap negyed 9 reggeli',
        e,
        'Reggeli',
        date: '2026-11-17',
        start: '08:15',
        minutes: 60,
      ),
      const Case(
        'holnap háromnegyed 10 értekezlet',
        e,
        'Értekezlet',
        date: '2026-11-17',
        start: '09:45',
        minutes: 60,
      ),
      const Case(
        'holnap fél 8 ébresztő',
        e,
        'Ébresztő',
        date: '2026-11-17',
        start: '07:30',
        minutes: 60,
      ),
      const Case(
        'holnap nyolc órakor ébresztő',
        e,
        'Ébresztő',
        date: '2026-11-17',
        start: '08:00',
        minutes: 60,
      ),
      const Case(
        'ma négy órakor tea',
        e,
        'Tea',
        date: '2026-11-16',
        start: '16:00',
        minutes: 60,
      ),
      const Case(
        'holnap 7:05 vonat',
        e,
        'Vonat',
        date: '2026-11-17',
        start: '07:05',
        minutes: 60,
      ),
      const Case(
        'holnap 19.45 vonat',
        e,
        'Vonat',
        date: '2026-11-17',
        start: '19:45',
        minutes: 60,
      ),
      const Case(
        'holnap 6:30 futás',
        e,
        'Futás',
        date: '2026-11-17',
        start: '06:30',
        minutes: 60,
      ),
      const Case(
        '14.15 óra tárgyalás holnap',
        e,
        'Tárgyalás',
        date: '2026-11-17',
        start: '14:15',
        minutes: 60,
      ),
      const Case(
        'reggel 7-kor ébresztő',
        e,
        'Ébresztő',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        note: 'holnapra',
      ),
      const Case(
        'este 7-kor vacsora',
        e,
        'Vacsora',
        date: '2026-11-16',
        start: '19:00',
        minutes: 60,
      ),
      const Case(
        'délután 4 órakor tea',
        e,
        'Tea',
        date: '2026-11-16',
        start: '16:00',
        minutes: 60,
      ),
      const Case(
        'hajnali 5-kor indulás',
        e,
        'Indulás',
        date: '2026-11-17',
        start: '05:00',
        minutes: 60,
        note: 'holnapra',
      ),
      const Case(
        'éjjel 11-kor lefekvés',
        e,
        'Lefekvés',
        date: '2026-11-16',
        start: '23:00',
        minutes: 60,
      ),
      const Case(
        'du. 3-kor fogorvos',
        e,
        'Fogorvos',
        date: '2026-11-16',
        start: '15:00',
        minutes: 60,
      ),
      const Case(
        'de. 11-kor értekezlet',
        e,
        'Értekezlet',
        date: '2026-11-16',
        start: '11:00',
        minutes: 60,
      ),
      const Case(
        'este 6:30 edzés',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:30',
        minutes: 60,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('the weekday', () {
    final cases = [
      const Case(
        'kedden 9-kor megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-17',
        start: '09:00',
        minutes: 60,
      ),
      const Case(
        'hétfőn 12:00 ebéd',
        e,
        'Ebéd',
        date: '2026-11-23',
        start: '12:00',
        minutes: 60,
        note: 'következő hétfőt',
      ),
      const Case(
        'szombaton 10:00 piac',
        e,
        'Piac',
        date: '2026-11-21',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'vasárnap 18:30 vacsora',
        e,
        'Vacsora',
        date: '2026-11-22',
        start: '18:30',
        minutes: 60,
      ),
      const Case(
        'csütörtökön 17:00 edzés',
        e,
        'Edzés',
        date: '2026-11-19',
        start: '17:00',
        minutes: 60,
      ),
      const Case(
        'pénteken 18-kor sör',
        e,
        'Sör',
        date: '2026-11-20',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'jövő kedd 9-kor megbeszélés',
        e,
        'Megbeszélés',
        date: '2026-11-24',
        start: '09:00',
        minutes: 60,
      ),
      const Case(
        'jövő héten szerdán 10:00 orvos',
        e,
        'Orvos',
        date: '2026-11-25',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'jövő hét péntek 14:00 fogorvos',
        e,
        'Fogorvos',
        date: '2026-11-27',
        start: '14:00',
        minutes: 60,
      ),
      const Case(
        'e héten szombaton 10:00 piac',
        e,
        'Piac',
        date: '2026-11-21',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'a héten csütörtökön 9:00 ügyfél',
        e,
        'Ügyfél',
        date: '2026-11-19',
        start: '09:00',
        minutes: 60,
      ),
      const Case(
        'hétvégén kirándulás',
        e,
        'Kirándulás',
        date: '2026-11-21',
        allDay: true,
        note: 'szombat',
      ),
      const Case(
        'kedd 8-10 műszak',
        e,
        'Műszak',
        date: '2026-11-17',
        start: '08:00',
        minutes: 120,
      ),
      const Case(
        'pénteken 20:00 mozi Annával',
        e,
        'Mozi Annával',
        date: '2026-11-20',
        start: '20:00',
        minutes: 60,
      ),
      const Case(
        'Anyák napja vasárnap',
        e,
        'Anyák napja',
        date: '2026-11-22',
        allDay: true,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('the date', () {
    final cases = [
      const Case(
        'nov. 20. 10:00 orvos',
        e,
        'Orvos',
        date: '2026-11-20',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'november 25 14:00 értekezlet',
        e,
        'Értekezlet',
        date: '2026-11-25',
        start: '14:00',
        minutes: 60,
      ),
      const Case(
        '2026.12.24. 18:00 szenteste',
        e,
        'Szenteste',
        date: '2026-12-24',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        '2026-12-31 22:00 szilveszter',
        e,
        'Szilveszter',
        date: '2026-12-31',
        start: '22:00',
        minutes: 60,
      ),
      const Case(
        '12.24. 18:00 ünnep',
        e,
        'Ünnep',
        date: '2026-12-24',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        '20-án 10:00 orvos',
        e,
        'Orvos',
        date: '2026-11-20',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        '5-én 10:00 orvos',
        e,
        'Orvos',
        date: '2026-12-05',
        start: '10:00',
        minutes: 60,
        note: 'következő hónapra',
      ),
      const Case(
        'dec. 5-én 9:00 értekezlet',
        e,
        'Értekezlet',
        date: '2026-12-05',
        start: '09:00',
        minutes: 60,
      ),
      const Case(
        'január 10-én 8:00 műszak',
        e,
        'Műszak',
        date: '2027-01-10',
        start: '08:00',
        minutes: 60,
        note: 'jövő évit',
      ),
      const Case(
        '21-én fizetés',
        e,
        'Fizetés',
        date: '2026-11-21',
        allDay: true,
      ),
      const Case(
        'péntek, nov. 20. 10:00 orvos',
        e,
        'Orvos',
        date: '2026-11-20',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        '2026. november 20. 10:00 orvos',
        e,
        'Orvos',
        date: '2026-11-20',
        start: '10:00',
        minutes: 60,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('a task', () {
    final cases = [
      const Case(
        'feladat: számla befizetése péntekig',
        t,
        'Számla befizetése',
        date: '2026-11-20',
      ),
      const Case(
        'számla befizetése péntekig',
        t,
        'Számla befizetése',
        date: '2026-11-20',
      ),
      const Case('tejet venni holnap', t, 'Tejet venni', date: '2026-11-17'),
      const Case('tejet venni', t, 'Tejet venni'),
      const Case(
        'határidő: pénteken jelentés',
        t,
        'Jelentés',
        date: '2026-11-20',
      ),
      const Case(
        'teendő: orvoshoz időpontot kérni',
        t,
        'Orvoshoz időpontot kérni',
      ),
      const Case(
        'fogorvos időpontot foglalni jövő hétfőig',
        t,
        'Fogorvos időpontot foglalni',
        date: '2026-11-23',
      ),
      const Case('november 30-ig jelentés', t, 'Jelentés', date: '2026-11-30'),
      const Case(
        'péntekig kész legyen a prezentáció',
        t,
        'Kész legyen a prezentáció',
        date: '2026-11-20',
      ),
      const Case('holnapig válaszolni', t, 'Válaszolni', date: '2026-11-17'),
      const Case('fogorvos', t, 'Fogorvos'),
      const Case('iPhone 15 pro vásárlása', t, 'IPhone 15 pro vásárlása'),
      const Case(
        'feladat: holnap 18:00 felhívni Annát',
        t,
        'Felhívni Annát',
        date: '2026-11-17',
        note: 'nincs időpontja',
      ),
      const Case(
        'esemény: karácsonyi vásár',
        e,
        'Karácsonyi vásár',
        date: '2026-11-16',
        allDay: true,
        note: 'mai napra',
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('how long', () {
    final cases = [
      const Case(
        'holnap 18:00-19:30 edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 90,
      ),
      const Case(
        'holnap 18-20 edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
      const Case(
        'holnap 18-tól 20-ig edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
      const Case(
        'holnap 18:00 másfél órás edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 90,
      ),
      const Case(
        'holnap 18:00 fél órás hívás',
        e,
        'Hívás',
        date: '2026-11-17',
        start: '18:00',
        minutes: 30,
      ),
      const Case(
        'holnap 18:00 2 órára meeting',
        e,
        'Meeting',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
      const Case(
        'holnap 18:00 90 perc meeting',
        e,
        'Meeting',
        date: '2026-11-17',
        start: '18:00',
        minutes: 90,
      ),
      const Case(
        'holnap 18:00 1,5 órás meeting',
        e,
        'Meeting',
        date: '2026-11-17',
        start: '18:00',
        minutes: 90,
      ),
      const Case(
        'holnap 22:00-06:00 éjszakai műszak',
        e,
        'Éjszakai műszak',
        date: '2026-11-17',
        start: '22:00',
        minutes: 480,
      ),
      const Case(
        'holnap 8:00 negyed órás stand-up',
        e,
        'Stand-up',
        date: '2026-11-17',
        start: '08:00',
        minutes: 15,
      ),
      const Case(
        'holnap 19:00 háromnegyed óra séta',
        e,
        'Séta',
        date: '2026-11-17',
        start: '19:00',
        minutes: 45,
      ),
      const Case(
        'holnap 18:00 két órán át tanulás',
        e,
        'Tanulás',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
      const Case(
        'ma 15:00 2 órára meeting',
        e,
        'Meeting',
        date: '2026-11-16',
        start: '15:00',
        minutes: 120,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('all day', () {
    final cases = [
      const Case(
        'holnapután egész nap konferencia',
        e,
        'Konferencia',
        date: '2026-11-18',
        allDay: true,
      ),
      const Case(
        'holnap egész nap konferencia',
        e,
        'Konferencia',
        date: '2026-11-17',
        allDay: true,
      ),
      const Case(
        'pénteken egésznapos kirándulás',
        e,
        'Kirándulás',
        date: '2026-11-20',
        allDay: true,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('how often', () {
    final cases = [
      const Case(
        'minden hétfőn 18:00 edzés',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        'minden kedden és csütörtökön 7:00 futás',
        e,
        'Futás',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=TU,TH',
      ),
      const Case(
        'hétfőnként 18:00 edzés',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        'naponta 8:00 gyógyszer',
        e,
        'Gyógyszer',
        date: '2026-11-17',
        start: '08:00',
        minutes: 60,
        rrule: 'FREQ=DAILY',
      ),
      const Case(
        'minden nap 20:00 napló',
        e,
        'Napló',
        date: '2026-11-16',
        start: '20:00',
        minutes: 60,
        rrule: 'FREQ=DAILY',
      ),
      const Case(
        'hetente 10:00 takarítás',
        e,
        'Takarítás',
        date: '2026-11-23',
        start: '10:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        'kéthetente szombaton 9:00 piac',
        e,
        'Piac',
        date: '2026-11-21',
        start: '09:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=SA',
      ),
      const Case(
        'havonta 5-én számla befizetése',
        t,
        'Számla befizetése',
        date: '2026-12-05',
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=5',
        note: 'ismétlődő feladat',
      ),
      const Case(
        'minden hónap 15-én 9:00 bérszámfejtés',
        e,
        'Bérszámfejtés',
        date: '2026-12-15',
        start: '09:00',
        minutes: 60,
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=15',
      ),
      const Case(
        'évente március 15-én megemlékezés',
        e,
        'Megemlékezés',
        date: '2027-03-15',
        allDay: true,
        rrule: 'FREQ=YEARLY',
      ),
      const Case(
        'hétköznapokon 6:30 ébresztő',
        e,
        'Ébresztő',
        date: '2026-11-17',
        start: '06:30',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      ),
      const Case(
        'munkanapokon 7:00 futás',
        e,
        'Futás',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      ),
      const Case(
        '2 naponta 20:00 öntözés',
        e,
        'Öntözés',
        date: '2026-11-16',
        start: '20:00',
        minutes: 60,
        rrule: 'FREQ=DAILY;INTERVAL=2',
      ),
      const Case(
        'minden második héten pénteken 14:00 sprint',
        e,
        'Sprint',
        date: '2026-11-20',
        start: '14:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=FR',
      ),
      const Case(
        'hetente öntözni',
        t,
        'Öntözni',
        date: '2026-11-16',
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        'minden szombaton 9:00 piac',
        e,
        'Piac',
        date: '2026-11-21',
        start: '09:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=SA',
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('the minutes of an hour are not the count of a repeat', () {
    // "18:00 hetente": the "00" before "hetente" is part of the hour, not
    // "0 hetente" (a repeat that never happens)
    final cases = [
      const Case(
        '18:00 hetente edzés',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        '18:00 naponta edzés',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=DAILY',
      ),
      const Case(
        'edzés 18.30 hetente',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:30',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=MO',
      ),
      const Case(
        'edzés 8:10 naponta',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '08:10',
        minutes: 60,
        rrule: 'FREQ=DAILY',
      ),
      // a real count after an hour is still a count
      const Case(
        'edzés 18:00 2 hetente',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
      ),
      const Case(
        'edzés 18:00 3 naponta',
        e,
        'Edzés',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=DAILY;INTERVAL=3',
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }

    test('a count of zero is no repeat count and breaks nothing', () {
      for (final line in ['0 naponta edzés', '0 hetente edzés']) {
        final q = parseQuickEntry(line, now: now);
        expect(q.rrule, isNotNull, reason: line);
        expect(q.rrule, isNot(contains('INTERVAL')), reason: line);
      }
    });
  });

  group('the title', () {
    final cases = [
      const Case(
        '  holnap   18:00    edzés  ',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'holnap, 18:00, edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'edzés holnap 18:00',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'Holnap 18:00 – edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'holnap 10:00 Dr. Nagy János rendelő',
        e,
        'Dr. Nagy János rendelő',
        date: '2026-11-17',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        '5. emeleti iroda takarítása holnap',
        e,
        '5. emeleti iroda takarítása',
        date: '2026-11-17',
        allDay: true,
      ),
      const Case(
        'Bluetooth 5 hangszóró vétele pénteken',
        e,
        'Bluetooth 5 hangszóró vétele',
        date: '2026-11-20',
        allDay: true,
      ),
      const Case(
        'holnap 18:00',
        e,
        '',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('what looks like a time but is not', () {
    final cases = [
      // a town is not a Saturday, a version is not an hour
      const Case(
        'szombathelyi út 5-kor',
        e,
        'Szombathelyi út',
        date: '2026-11-16',
        start: '17:00',
        minutes: 60,
        note: '17:00',
      ),
      const Case(
        '3 napos kirándulás pénteken',
        e,
        '3 napos kirándulás',
        date: '2026-11-20',
        allDay: true,
      ),
      const Case(
        'Windows 11 frissítés pénteken',
        e,
        'Windows 11 frissítés',
        date: '2026-11-20',
        allDay: true,
      ),
      const Case(
        'A5 papír vétele holnap',
        e,
        'A5 papír vétele',
        date: '2026-11-17',
        allDay: true,
      ),
      const Case('Bluetooth 5 hangszóró', t, 'Bluetooth 5 hangszóró'),
      const Case(
        'holnap 25:00 buli',
        e,
        '25:00 buli',
        date: '2026-11-17',
        allDay: true,
      ),
      const Case(
        'szerdai ebéd 12-kor',
        e,
        'Ebéd',
        date: '2026-11-18',
        start: '12:00',
        minutes: 60,
      ),
      const Case(
        'hétfői értekezlet',
        e,
        'Értekezlet',
        date: '2026-11-23',
        allDay: true,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('in so many minutes, from this very moment', () {
    final cases = [
      const Case(
        '10 perc múlva felhívni anyut',
        e,
        'Felhívni anyut',
        date: '2026-11-16',
        start: '10:10',
        minutes: 60,
      ),
      const Case(
        'fél óra múlva kávé',
        e,
        'Kávé',
        date: '2026-11-16',
        start: '10:30',
        minutes: 60,
      ),
      const Case(
        '2 óra múlva tea',
        e,
        'Tea',
        date: '2026-11-16',
        start: '12:00',
        minutes: 60,
      ),
      const Case(
        'másfél óra múlva ebéd',
        e,
        'Ebéd',
        date: '2026-11-16',
        start: '11:30',
        minutes: 60,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }

    test('past midnight it is tomorrow', () {
      final late = floating(2026, 11, 16, 23, 30);
      final q = parseQuickEntry('1 óra múlva vonat', now: late);
      expect(ymd(q.date!), '2026-11-17');
      expect(hm(q.startMinute!), '00:30');
    });
  });

  group('from – to', () {
    final cases = [
      const Case(
        'holnap 6 órától 8 óráig edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
        note: '18:00',
      ),
      const Case(
        'holnap 6-tól 8-ig edzés',
        e,
        'Edzés',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
      const Case(
        'holnap 9-től 11-ig tárgyalás',
        e,
        'Tárgyalás',
        date: '2026-11-17',
        start: '09:00',
        minutes: 120,
      ),
      const Case(
        'holnap 22-6 éjszakai',
        e,
        'Éjszakai',
        date: '2026-11-17',
        start: '22:00',
        minutes: 480,
      ),
      const Case(
        'kedd 18:00-20:00 kórus',
        e,
        'Kórus',
        date: '2026-11-17',
        start: '18:00',
        minutes: 120,
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('more ways to repeat', () {
    final cases = [
      const Case(
        'keddenként 18:00 jóga',
        e,
        'Jóga',
        date: '2026-11-17',
        start: '18:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=TU',
      ),
      const Case(
        'csütörtökönként 17:00 edzés',
        e,
        'Edzés',
        date: '2026-11-19',
        start: '17:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=TH',
      ),
      const Case(
        'mindennap 7:00 vitamin',
        e,
        'Vitamin',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=DAILY',
      ),
      const Case(
        'havonta 31-én számla',
        t,
        'Számla',
        date: '2026-12-31',
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=31',
      ),
      const Case(
        'január 1. újév',
        e,
        'Újév',
        date: '2027-01-01',
        allDay: true,
        note: 'jövő évit',
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }
  });

  group('what it hands over', () {
    test('a timed event knows its start and end', () {
      final q = parseQuickEntry('holnap 18:00-19:30 edzés', now: now);
      expect(q.start, floating(2026, 11, 17, 18));
      expect(q.end, floating(2026, 11, 17, 19, 30));
    });

    test('an all-day event or a task has neither', () {
      expect(parseQuickEntry('holnap egész nap X', now: now).start, isNull);
      expect(parseQuickEntry('tejet venni holnap', now: now).start, isNull);
      expect(parseQuickEntry('tejet venni holnap', now: now).end, isNull);
    });

    test('the kind can be turned over, nothing else changes', () {
      final q = parseQuickEntry('holnap egész nap kirándulás', now: now);
      final task = q.withKind(QuickKind.task);
      expect(task.kind, QuickKind.task);
      expect(task.title, q.title);
      expect(task.date, q.date);
      expect(identical(q.withKind(QuickKind.event), q), isTrue);
    });

    test('a recurring line says which words made it recurring', () {
      final q = parseQuickEntry('minden hétfőn 18:00 edzés', now: now);
      expect(q.repeats, isTrue);
      expect(q.repeatText, 'minden hétfőn');
    });

    test('the rule is the rule of the editor: it reads back', () {
      final q = parseQuickEntry(
        'minden kedden és csütörtökön 7:00 futás',
        now: now,
      );
      final back = RecurrenceSpec.fromRrule(q.rrule!, q.date!)!;
      expect(back.freq, RepeatFreq.weekly);
      expect(back.weekdays, {2, 4});
    });

    test('an empty line has no title and is a task without a day', () {
      for (final s in ['', '   ', '\n']) {
        final q = parseQuickEntry(s, now: now);
        expect(q.hasTitle, isFalse);
        expect(q.date, isNull);
        expect(q.kind, QuickKind.task);
      }
    });

    test('what the user typed is cleaned like any title', () {
      final q = parseQuickEntry(
        'holnap 10:00 ${String.fromCharCode(0x202e)}Orvos<b>${String.fromCharCode(0x200b)}',
        now: now,
      );
      expect(q.title, 'Orvosb');
    });

    test('a very long title is cut', () {
      final q = parseQuickEntry('holnap 10:00 ${'x' * 200}', now: now);
      expect(q.title.length, lessThanOrEqualTo(81));
    });
  });

  group('edges that were never tried', () {
    final cases = [
      const Case('to-do: tej venni', t, 'Tej venni'),
      const Case('todo számla befizetése', t, 'Számla befizetése'),
      const Case('teendő: ablakpucolás', t, 'Ablakpucolás'),
      const Case(
        'találkozó: Kata holnap 10:00',
        e,
        'Kata',
        date: '2026-11-17',
        start: '10:00',
        minutes: 60,
      ),
      const Case(
        'hétvégenként 9:00 futás',
        e,
        'Futás',
        date: '2026-11-21',
        start: '09:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=SA,SU',
      ),
      const Case(
        'minden hétvégén 9:00 futás',
        e,
        'Futás',
        date: '2026-11-21',
        start: '09:00',
        minutes: 60,
        rrule: 'FREQ=WEEKLY;BYDAY=SA,SU',
      ),
      const Case(
        'minden második nap 7:00 gyógyszer',
        e,
        'Gyógyszer',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=DAILY;INTERVAL=2',
      ),
      const Case(
        'minden harmadik nap 7:00 gyógyszer',
        e,
        'Gyógyszer',
        date: '2026-11-17',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=DAILY;INTERVAL=3',
      ),
      const Case('holnapig jelentés', t, 'Jelentés', date: '2026-11-17'),
      // today's own date is today, not next year
      const Case(
        'nov. 16. ebéd',
        e,
        'Ebéd',
        date: '2026-11-16',
        allDay: true,
        note: 'egész napos',
      ),
      const Case(
        'holnap hajnal 12 indulás',
        e,
        'Indulás',
        date: '2026-11-17',
        start: '00:00',
        minutes: 60,
      ),
      const Case(
        'délután 12 ebéd',
        e,
        'Ebéd',
        date: '2026-11-16',
        start: '12:00',
        minutes: 60,
      ),
      // the night: from 6 on it is the evening, before that it is as written
      const Case(
        'éjjel 6 buli',
        e,
        'Buli',
        date: '2026-11-16',
        start: '18:00',
        minutes: 60,
      ),
      const Case(
        'éjjel 5 ébresztő',
        e,
        'Ébresztő',
        date: '2026-11-17',
        start: '05:00',
        minutes: 60,
        note: 'holnapra',
      ),
      // 24:00 ends a day, 25:00 and 24:30 are no times
      const Case(
        'holnap 22:00-24:00 műszak',
        e,
        'Műszak',
        date: '2026-11-17',
        start: '22:00',
        minutes: 120,
      ),
      const Case(
        'holnap 22:00-25:00 műszak',
        e,
        'Műszak',
        date: '2026-11-17',
        start: '22:00',
        minutes: 60,
      ),
      const Case(
        'holnap 24:30 teendők',
        e,
        '24:30 teendők',
        date: '2026-11-17',
        allDay: true,
      ),
      // the hour that is this very minute has gone by
      const Case(
        '10:00 értekezlet',
        e,
        'Értekezlet',
        date: '2026-11-17',
        start: '10:00',
        minutes: 60,
        note: 'holnapra',
      ),
      // the day of a monthly rule is the one it names, whatever the date
      const Case(
        'nov. 20. minden hónap 5-én bérlet',
        t,
        'Bérlet',
        date: '2026-11-20',
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=5',
      ),
      // a monthly rule whose hour has gone by today starts next month
      const Case(
        'minden hónap 16-án 7:00 számla',
        e,
        'Számla',
        date: '2026-12-16',
        start: '07:00',
        minutes: 60,
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=16',
      ),
      const Case(
        'minden hónap 16-án 11:00 számla',
        e,
        'Számla',
        date: '2026-11-16',
        start: '11:00',
        minutes: 60,
        rrule: 'FREQ=MONTHLY;BYMONTHDAY=16',
      ),
    ];
    for (final c in cases) {
      test(c.input, () => check(c));
    }

    QuickEntry at(DateTime clock, String line) =>
        parseQuickEntry(line, now: clock);

    test(
      'a day of this week that has gone by is said so; one to come is not',
      () {
        final wednesday = floating(2026, 11, 18, 10);
        final gone = at(wednesday, 'ezen a héten hétfőn 9:00 megbeszélés');
        expect(ymd(gone.date!), '2026-11-16');
        expect(gone.assumptions, ['Ez a nap már elmúlt a héten.']);
        final coming = at(wednesday, 'a héten pénteken 9:00 megbeszélés');
        expect(ymd(coming.date!), '2026-11-20');
        expect(coming.assumptions, isEmpty);
      },
    );

    test('the 5th said in late December is the 5th of January', () {
      final q = at(floating(2026, 12, 20, 10), '5-én 10:00 orvos');
      expect(ymd(q.date!), '2027-01-05');
      expect(q.assumptions, hasLength(1));
      expect(q.assumptions.single, contains('következő hónapra'));
    });

    test('a month from the 31st is the end of the next month', () {
      expect(
        ymd(at(floating(2026, 1, 31, 10), '1 hónap múlva orvos').date!),
        '2026-02-28',
      );
      expect(
        ymd(at(floating(2026, 3, 31, 10), '1 hónap múlva orvos').date!),
        '2026-04-30',
      );
      expect(
        ymd(at(floating(2026, 1, 31, 10), '12 hónap múlva orvos').date!),
        '2027-01-31',
      );
    });

    test('half an hour after 23:30 is midnight, of the next day', () {
      final q = at(floating(2026, 11, 16, 23, 30), 'fél óra múlva teendő');
      expect(ymd(q.date!), '2026-11-17');
      expect(hm(q.startMinute!), '00:00');
    });
  });

  group('the notes are good Hungarian', () {
    // the named day is today: the next one is taken, and the note says it
    // with the right ending for each day
    const days = [
      ('hétfőn', 'hétfőt'),
      ('kedden', 'keddet'),
      ('szerdán', 'szerdát'),
      ('csütörtökön', 'csütörtököt'),
      ('pénteken', 'pénteket'),
      ('szombaton', 'szombatot'),
      ('vasárnap', 'vasárnapot'),
    ];
    for (var i = 0; i < days.length; i++) {
      final (said, object) = days[i];
      test('"$said 17:00 edzés" on that very day', () {
        // (2026-11-16 is a Monday)
        final today = floating(2026, 11, 16 + i, 10);
        final q = parseQuickEntry('$said 17:00 edzés', now: today);
        expect(ymd(q.date!), ymd(floating(2026, 11, 23 + i)));
        expect(q.assumptions, [
          'A mai nap helyett a következő $object vettem.',
        ]);
      });
    }
  });
}
