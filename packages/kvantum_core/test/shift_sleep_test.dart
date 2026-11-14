import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

// AI-19: the sleep after a night shift. 2026-05-04 is a Monday.
const bp = 'Europe/Budapest';
const rules = PlanRules();

DateTime at(int d, int h, [int m = 0]) =>
    resolveWallClock(bp, floating(2026, 5, d, h, m));

String hm(DateTime utc) {
  final w = toWallClock(bp, utc);
  return '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
}

Occurrence event(
  String title,
  DateTime start,
  DateTime end, {
  bool shift = true,
  bool allDay = false,
}) => Occurrence(
  eventId: '$title${start.millisecondsSinceEpoch}',
  title: title,
  startUtc: start,
  endUtc: end,
  originalStart: toWallClock(bp, start),
  allDay: allDay,
  tzid: bp,
  isShift: shift,
);

/// The usual night shift: day [d] 18:00 -> day [d]+1 06:00.
Occurrence night(int d) => event('Éjszakai műszak', at(d, 18), at(d + 1, 6));

ProposedBlock block(
  int d,
  int h, {
  int m = 0,
  int minutes = 60,
  String title = 'Gym',
}) => ProposedBlock(
  title: title,
  startUtc: at(d, h, m),
  endUtc: at(d, h, m).add(Duration(minutes: minutes)),
);

List<String> spans(Iterable<ShiftSleep> s) => [
  for (final x in s) '${hm(x.startUtc)}-${hm(x.endUtc)}',
];

List<String> codes(List<Violation> v) => [for (final x in v) x.code];

void main() {
  setUpAll(ensureTimeZones);

  group('shiftSleep: which shifts are followed by sleep', () {
    test('the usual night shift: sleep from 07:00 to 15:00', () {
      final z = shiftSleep([night(4)], rules);
      expect(spans(z), ['07:00-15:00']);
      expect(z.single.shiftTitle, 'Éjszakai műszak');
    });

    test('a day, an evening and a late-morning shift need no such sleep', () {
      expect(
        shiftSleep([event('Nappali műszak', at(4, 6), at(4, 18))], rules),
        isEmpty,
      );
      expect(
        shiftSleep([event('Délutáni műszak', at(4, 14), at(4, 22))], rules),
        isEmpty,
      );
      expect(
        shiftSleep([event('Műszak', at(4, 8), at(4, 16))], rules),
        isEmpty,
      );
    });

    test('judged by the real times: half of the window counts, less not', () {
      // 19:00 -> 03:00 covers 4 of the 8 hours of 23:00 -> 07:00
      expect(spans(shiftSleep([event('Műszak', at(4, 19), at(5, 3))], rules)), [
        '04:00-12:00',
      ]);
      // one minute less than half
      expect(
        shiftSleep([event('Műszak', at(4, 19), at(5, 2, 59))], rules),
        isEmpty,
      );
    });

    test('a shift that starts in the small hours counts for that night', () {
      // 00:00 -> 08:00 covers 7 of the 8 hours of the night that began the
      // evening before (the night of the day before the shift starts)
      expect(spans(shiftSleep([event('Műszak', at(5, 0), at(5, 8))], rules)), [
        '09:00-17:00',
      ]);
      // 03:00 -> 11:00 covers exactly half of it (03:00-07:00), 04:00 -> 12:00
      // less: the start of the shift is read on the wall clock, too
      expect(spans(shiftSleep([event('Műszak', at(5, 3), at(5, 11))], rules)), [
        '12:00-20:00',
      ]);
      expect(
        shiftSleep([event('Műszak', at(5, 4), at(5, 12))], rules),
        isEmpty,
      );
    });

    test('a title is no evidence: "Nappali" at night still counts', () {
      expect(
        spans(
          shiftSleep([event('Nappali műszak', at(4, 20), at(5, 6))], rules),
        ),
        ['07:00-15:00'],
      );
    });

    test('all-day events and what is not a shift are ignored', () {
      expect(
        shiftSleep([
          event('Éjszakai műszak', at(4, 18), at(5, 6), allDay: true),
          event('Buli', at(4, 18), at(5, 6), shift: false),
        ], rules),
        isEmpty,
      );
    });

    test('several night shifts give one sleep each, in order', () {
      final z = shiftSleep([night(6), night(4), night(5)], rules);
      expect(spans(z), ['07:00-15:00', '07:00-15:00', '07:00-15:00']);
      expect(z.map((x) => x.startUtc).toList(), [at(5, 7), at(6, 7), at(7, 7)]);
    });
  });

  group('shiftSleep: the rules decide when and how long', () {
    test('the delay after the shift is a rule', () {
      expect(
        spans(
          shiftSleep([night(4)], const PlanRules(shiftSleepDelayMinutes: 0)),
        ),
        ['06:00-14:00'],
      );
      expect(
        spans(
          shiftSleep([night(4)], const PlanRules(shiftSleepDelayMinutes: 90)),
        ),
        ['07:30-15:30'],
      );
    });

    test('it lasts as long as the usual sleep window', () {
      // 22:00 -> 04:00 is 6 hours; the shift covers all of it
      const six = PlanRules(sleepStartHour: 22, sleepEndHour: 4);
      expect(spans(shiftSleep([night(4)], six)), ['07:00-13:00']);
    });

    test('a window inside the day (01:00 -> 09:00) works the same way', () {
      const early = PlanRules(sleepStartHour: 1, sleepEndHour: 9);
      // 18:00 -> 06:00 covers 5 of its 8 hours (01:00 -> 06:00)
      expect(spans(shiftSleep([night(4)], early)), ['07:00-15:00']);
    });

    test('without a sleep window there is no such sleep either', () {
      const none = PlanRules(sleepStartHour: 7, sleepEndHour: 7);
      expect(shiftSleep([night(4)], none), isEmpty);
    });

    test(
      'a day sleeper (08:00 -> 16:00) has no night-shift sleep to derive',
      () {
        const day = PlanRules(sleepStartHour: 8, sleepEndHour: 16);
        expect(shiftSleep([night(4)], day), isEmpty);
      },
    );

    test('the clock change does not move it (29 March and 25 October)', () {
      for (final d in [
        (floating(2026, 3, 28, 18), floating(2026, 3, 29, 6)),
        (floating(2026, 10, 24, 18), floating(2026, 10, 25, 6)),
      ]) {
        final z = shiftSleep([
          event(
            'Éjszakai műszak',
            resolveWallClock(bp, d.$1),
            resolveWallClock(bp, d.$2),
          ),
        ], rules);
        expect(spans(z), ['07:00-15:00'], reason: '${d.$1}');
      }
    });
  });

  group('validateProposal: the sleep after a night shift', () {
    final n = night(4); // 4 May 18:00 -> 5 May 06:00, sleep 07:00 -> 15:00

    test('a workout in it is rejected with its own code and a reason', () {
      final v = validateProposal([block(5, 13)], existing: [n], rules: rules);
      expect(codes(v), ['shift_sleep', 'shift_rest']);
      expect(v.first.message, contains('07:00–15:00'));
      expect(v.first.message, contains('Éjszakai műszak'));
    });

    test('a short, light one is rejected too (no distance rule needed)', () {
      final v = validateProposal(
        [block(5, 13, minutes: 30, title: 'könnyű séta')],
        existing: [n],
        rules: rules,
      );
      expect(codes(v), ['shift_sleep']);
    });

    test('the last hour of the sleep is not free, the next hour is', () {
      expect(
        codes(validateProposal([block(5, 14)], existing: [n], rules: rules)),
        ['shift_sleep'],
      );
      expect(
        validateProposal([block(5, 15)], existing: [n], rules: rules),
        isEmpty,
      );
    });

    test('a block that only touches the border of the sleep is not in it', () {
      // with two hours of delay the sleep is 08:00 -> 16:00, outside the usual
      // window (until 07:00): a block that ends at 08:00 is not in it
      const slow = PlanRules(shiftSleepDelayMinutes: 120);
      expect(
        codes(validateProposal([block(5, 7)], existing: [n], rules: slow)),
        isNot(contains('shift_sleep')),
      );
      expect(
        codes(
          validateProposal([block(5, 7, m: 1)], existing: [n], rules: slow),
        ),
        contains('shift_sleep'),
      );
      expect(
        codes(validateProposal([block(5, 16)], existing: [n], rules: slow)),
        isNot(contains('shift_sleep')),
      );
    });

    test('a block in the sleep after two shifts is told once', () {
      // the long night's sleep (09:00 -> 17:00) and the usual one (07:00 -> 15:00)
      final long = event('Hosszú éjszaka', at(4, 20), at(5, 8));
      final v = validateProposal(
        [block(5, 10)],
        existing: [n, long],
        rules: rules,
      );
      expect(codes(v).where((c) => c == 'shift_sleep'), ['shift_sleep']);
    });

    test('the first minute is covered too (06:30 → 07:30 touches 07:00)', () {
      // 06:30 is inside the usual window (until 07:00): that rule speaks first
      final v = validateProposal(
        [block(5, 6, m: 30, minutes: 30, title: 'séta')],
        existing: [n],
        rules: rules,
      );
      expect(codes(v), ['sleep_window']);
      final w = validateProposal(
        [block(5, 7, minutes: 30, title: 'séta')],
        existing: [n],
        rules: rules,
      );
      expect(codes(w), ['shift_sleep']);
    });

    test('the usual window wins: never both for the same block', () {
      final v = validateProposal(
        [block(5, 6, m: 30, minutes: 90, title: 'séta')],
        existing: [n],
        rules: rules,
      );
      expect(codes(v).where((c) => c == 'sleep_window' || c == 'shift_sleep'), [
        'sleep_window',
      ]);
    });

    test('before the shift nothing changes: only the distance rule', () {
      expect(
        codes(validateProposal([block(4, 11)], existing: [n], rules: rules)),
        ['shift_rest'],
      );
    });

    test('a day shift is followed by no such sleep', () {
      final day = event('Nappali műszak', at(4, 6), at(4, 18));
      expect(
        validateProposal([block(5, 8)], existing: [day], rules: rules),
        isEmpty,
      );
    });

    test('a night shift that is not a shift event makes no sleep', () {
      final party = event('Buli', at(4, 18), at(5, 6), shift: false);
      expect(
        validateProposal([block(5, 13)], existing: [party], rules: rules),
        isEmpty,
      );
    });

    test('the delay rule moves the border', () {
      const rest0 = PlanRules(
        shiftSleepDelayMinutes: 0,
      ); // sleep 06:00 -> 14:00
      expect(
        codes(validateProposal([block(5, 13)], existing: [n], rules: rest0)),
        ['shift_sleep', 'shift_rest'],
      );
      expect(
        validateProposal([block(5, 14)], existing: [n], rules: rest0),
        isEmpty,
      );
    });

    test('the switched-off event source gets a generic sentence', () {
      final v = validateProposal([block(5, 13)], existing: [n], rules: rules);
      final sleep = v.firstWhere((x) => x.code == 'shift_sleep');
      final text = sleep.forModel(events: false, checkins: true);
      expect(text, isNot(contains('Éjszakai')));
      expect(text, isNot(contains('07:00')));
      expect(text, isNotEmpty);
      // with the source on, the reason stays (sanitised)
      expect(
        sleep.forModel(events: true, checkins: true),
        contains('07:00–15:00'),
      );
    });

    test('PlanRules.withHardFrom keeps the delay', () {
      const base = PlanRules(shiftSleepDelayMinutes: 25);
      expect(base.withHardFrom({'gym': 45}).shiftSleepDelayMinutes, 25);
    });
  });

  group('findFreeSlots: the sleep after a night shift is no free time', () {
    List<String> slots(List<Occurrence> busy, int fromDay, int toDay) => [
      for (final s in findFreeSlots(
        busy: busy,
        fromUtc: at(fromDay, 0),
        toUtc: at(toDay, 0),
        rules: rules,
      ))
        '${hm(s.startUtc)}-${hm(s.endUtc)}',
    ];

    test('the morning after is gone, the evening is free again', () {
      expect(slots([night(4)], 5, 6), ['15:00-23:00']);
    });

    test('before the shift the day is free until the buffer', () {
      expect(slots([night(4)], 4, 5), ['07:00-17:45']);
    });

    test('without a shift in the busy list nothing changes', () {
      expect(slots([], 5, 6), ['07:00-23:00']);
      expect(slots([event('Buli', at(4, 18), at(5, 6), shift: false)], 5, 6), [
        '07:00-23:00',
      ]);
    });

    test('three nights in a row leave only the afternoons and evenings', () {
      expect(slots([night(4), night(5), night(6)], 5, 8), [
        '15:00-17:45',
        '15:00-17:45',
        '15:00-23:00',
      ]);
    });

    test(
      'the sleep needs no buffer: it ends exactly where free time starts',
      () {
        final s = findFreeSlots(
          busy: [night(4)],
          fromUtc: at(5, 0),
          toUtc: at(6, 0),
          rules: rules,
        );
        expect(s.single.startUtc, at(5, 15));
      },
    );
  });
}
