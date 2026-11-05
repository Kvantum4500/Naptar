import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

void main() {
  summaryTests();
  editedShiftTests();
  String d(DateTime t) => t.toIso8601String().substring(0, 16);

  test('default cycle: 3 nights, 3 off, 3 days, 3 off, then repeats', () {
    final p = generateShiftPlan(
      defaultShiftCycle,
      startDay: floating(2026, 11, 12),
      untilDay: floating(2026, 12, 8), // 26 days = 2 cycles + 2 days
    );
    expect(p.length, 14); // 6 + 6 + 2 nights of the third cycle
    expect(
      [for (final s in p.take(3)) d(s.start)],
      ['2026-11-12T18:00', '2026-11-13T18:00', '2026-11-14T18:00'],
    );
    // a night shift ends next morning
    expect(d(p.first.end), '2026-11-13T06:00');
    // days 6..8 (nov 18-20) are day shifts 06-18
    expect(p[3].title, 'Nappali műszak');
    expect(d(p[3].start), '2026-11-18T06:00');
    expect(d(p[3].end), '2026-11-18T18:00');
    // second cycle starts after 12 days
    expect(d(p[6].start), '2026-11-24T18:00');
  });

  test(
    'crosses the year change and the DST change without shifting clock times',
    () {
      final p = generateShiftPlan(
        defaultShiftCycle,
        startDay: floating(
          2026,
          10,
          22,
        ), // nights 22,23,24 around DST end (Oct 25)
        untilDay: floating(2027, 1, 20),
      );
      expect(p.every((s) => s.start.hour == 18 || s.start.hour == 6), isTrue);
      expect(p.any((s) => s.start.year == 2027), isTrue);
      // the night of Oct 24 -> 25 still ends at 06:00 wall clock
      final night = p.firstWhere((s) => d(s.start) == '2026-10-24T18:00');
      expect(d(night.end), '2026-10-25T06:00');
    },
  );

  test('empty or zero-day cycles produce nothing; until is exclusive', () {
    expect(
      generateShiftPlan(
        const [],
        startDay: floating(2026, 1, 1),
        untilDay: floating(2026, 2, 1),
      ),
      isEmpty,
    );
    expect(
      generateShiftPlan(
        [const ShiftStep.off(0)],
        startDay: floating(2026, 1, 1),
        untilDay: floating(2026, 2, 1),
      ),
      isEmpty,
    );
    final one = generateShiftPlan(
      defaultShiftCycle,
      startDay: floating(2026, 11, 12),
      untilDay: floating(2026, 11, 13),
    );
    expect(one.length, 1);
  });
}

void summaryTests() {
  test('month summary counts shifts by their start day and sums hours', () {
    final plan = generateShiftPlan(
      defaultShiftCycle,
      startDay: floating(2026, 11, 12),
      untilDay: floating(2027, 1, 1),
    );
    final ev = [
      for (final s in plan)
        (title: s.title, notes: kShiftMarker, start: s.start, end: s.end),
      // a hand-typed event is ignored
      (
        title: 'Fogorvos',
        notes: '',
        start: floating(2026, 11, 20, 9),
        end: floating(2026, 11, 20, 10),
      ),
    ];
    final nov = summarizeShifts(ev, year: 2026, month: 11);
    // nights 12,13,14 ; days 18,19,20 ; nights 24,25,26 ; days 30
    expect(nov.counts['Éjszakai műszak'], 6);
    expect(nov.counts['Nappali műszak'], 4);
    expect(nov.hours, 10 * 12);
    expect(nov.workDays, 10);
    expect(nov.offDays, 30 - 10);
    // night of 31 Dec 18:00 -> 1 Jan counts for December only
    final dec = summarizeShifts(ev, year: 2026, month: 12);
    final jan = summarizeShifts(ev, year: 2027, month: 1);
    expect(jan.counts, isEmpty);
    expect(dec.workDays + dec.offDays, 31);
  });
}

void editedShiftTests() {
  test('modified shifts are still shifts', () {
    expect(isShiftNotes(kShiftMarker), isTrue);
    expect(isShiftNotes(kShiftEditedMarker), isTrue);
    expect(isShiftNotes(''), isFalse);
    expect(isShiftNotes('Beosztás-generátor valami'), isFalse);
    expect(isEditedShiftNotes(kShiftEditedMarker), isTrue);
    expect(isEditedShiftNotes(kShiftMarker), isFalse);
  });

  test('an expanded modified shift carries isShift', () {
    ensureTimeZones();
    final e = CalEvent(
      id: 'x',
      calendarId: 'naptar',
      title: 'Nappali műszak',
      notes: kShiftEditedMarker,
      start: floating(2026, 11, 18, 6),
      end: floating(2026, 11, 18, 18),
      tzid: 'Europe/Budapest',
    );
    final o = expand(e, floating(2026, 11, 18), floating(2026, 11, 19));
    expect(o.single.isShift, isTrue);
  });

  test('summary counts modified shifts too', () {
    final s = summarizeShifts(
      [
        (
          title: 'Nappali műszak',
          notes: kShiftEditedMarker,
          start: floating(2026, 11, 18, 6),
          end: floating(2026, 11, 18, 18),
        ),
      ],
      year: 2026,
      month: 11,
    );
    expect(s.counts['Nappali műszak'], 1);
    expect(s.hours, 12);
  });
}
