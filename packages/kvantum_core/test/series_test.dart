import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const bp = 'Europe/Budapest';
CalEvent series(String rrule, {DateTime? start, List<DateTime> ex = const []}) {
  final s = start ?? floating(2026, 5, 4, 9); // Monday
  return CalEvent(
    id: 'm',
    calendarId: 'c',
    title: 'Edzés',
    tzid: bp,
    start: s,
    end: s.add(const Duration(hours: 1)),
    rrule: rrule,
    exdates: ex,
  );
}

List<DateTime> days(
  CalEvent e, {
  List<CalEvent> ov = const [],
  int months = 6,
}) => expand(
  e,
  DateTime.utc(2026, 5, 1),
  DateTime.utc(2026, 5 + months, 1),
  overrides: ov,
).map((o) => o.originalStart).toList();

void main() {
  setUpAll(ensureTimeZones);

  group('RecurrenceSpec', () {
    final start = floating(2026, 5, 4, 9); // Monday, 1st Monday of May
    String rule(RecurrenceSpec s) => s.toRrule(start);

    test('builds every supported rule shape', () {
      expect(rule(const RecurrenceSpec(freq: RepeatFreq.daily)), 'FREQ=DAILY');
      expect(
        rule(const RecurrenceSpec(freq: RepeatFreq.daily, interval: 3)),
        'FREQ=DAILY;INTERVAL=3',
      );
      expect(
        rule(
          const RecurrenceSpec(
            freq: RepeatFreq.weekly,
            interval: 2,
            weekdays: {4, 1},
          ),
        ),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH',
      );
      expect(
        rule(const RecurrenceSpec(freq: RepeatFreq.weekly)),
        'FREQ=WEEKLY;BYDAY=MO',
      );
      expect(
        rule(const RecurrenceSpec(freq: RepeatFreq.monthly)),
        'FREQ=MONTHLY;BYMONTHDAY=4',
      );
      expect(
        rule(
          const RecurrenceSpec(
            freq: RepeatFreq.monthly,
            monthlyMode: MonthlyMode.nthWeekday,
          ),
        ),
        'FREQ=MONTHLY;BYDAY=1MO',
      );
      expect(
        rule(
          const RecurrenceSpec(
            freq: RepeatFreq.monthly,
            monthlyMode: MonthlyMode.lastWeekday,
          ),
        ),
        'FREQ=MONTHLY;BYDAY=-1MO',
      );
      expect(
        rule(
          const RecurrenceSpec(
            freq: RepeatFreq.yearly,
            end: RepeatEnd.count,
            count: 3,
          ),
        ),
        'FREQ=YEARLY;COUNT=3',
      );
    });
    test('5th weekday of a month becomes "last"', () {
      final s = floating(2026, 3, 30, 9); // 5th Monday of March 2026
      expect(
        const RecurrenceSpec(
          freq: RepeatFreq.monthly,
          monthlyMode: MonthlyMode.nthWeekday,
        ).toRrule(s),
        'FREQ=MONTHLY;BYDAY=-1MO',
      );
    });
    test('parse -> build round trip', () {
      for (final r in [
        'FREQ=DAILY;INTERVAL=3',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH',
        'FREQ=MONTHLY;BYMONTHDAY=4',
        'FREQ=MONTHLY;BYDAY=1MO',
        'FREQ=MONTHLY;BYDAY=-1MO',
        'FREQ=YEARLY;COUNT=3',
        'FREQ=DAILY;UNTIL=20260601T235959Z',
      ]) {
        final spec = RecurrenceSpec.fromRrule(r, start)!;
        expect(spec.toRrule(start), r, reason: r);
      }
    });
    test('unsupported rules parse to null instead of being mangled', () {
      expect(RecurrenceSpec.fromRrule('FREQ=YEARLY;BYMONTH=2', start), isNull);
      expect(
        RecurrenceSpec.fromRrule('FREQ=MONTHLY;BYDAY=MO,FR;BYSETPOS=-1', start),
        isNull,
      );
      expect(RecurrenceSpec.fromRrule('FREQ=HOURLY', start), isNull);
      expect(RecurrenceSpec.fromRrule('garbage', start), isNull);
    });
    test('validation messages', () {
      expect(
        const RecurrenceSpec(
          freq: RepeatFreq.daily,
          end: RepeatEnd.count,
          count: 0,
        ).validate(),
        isNotNull,
      );
      expect(
        const RecurrenceSpec(
          freq: RepeatFreq.daily,
          end: RepeatEnd.until,
        ).validate(),
        isNotNull,
      );
      expect(
        const RecurrenceSpec(freq: RepeatFreq.daily, interval: 1000).validate(),
        isNotNull,
      );
      expect(const RecurrenceSpec(freq: RepeatFreq.daily).validate(), isNull);
    });
    test('preview lists the next occurrences; UNTIL day is inclusive', () {
      final spec = RecurrenceSpec(
        freq: RepeatFreq.weekly,
        weekdays: {1, 4},
        end: RepeatEnd.until,
        until: DateTime.utc(2026, 5, 11),
      );
      final p = spec.preview(start);
      expect(p.map((d) => d.day), [4, 7, 11]);
    });
    test('endless rule keeps producing (preview of 10)', () {
      expect(
        const RecurrenceSpec(freq: RepeatFreq.daily).preview(start).length,
        10,
      );
    });
    test('describeRrule is readable', () {
      expect(
        describeRrule('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', start),
        ' 2 hetente (hétfő, csütörtök)'.trim(),
      );
      expect(
        describeRrule('FREQ=MONTHLY;BYDAY=-1MO', start),
        'Havonta (utolsó hétfő)',
      );
      expect(describeRrule(null, start), 'Nem ismétlődik');
      expect(
        describeRrule('FREQ=YEARLY;BYMONTH=2', start),
        'Egyedi ismétlődés',
      );
    });
  });

  group('series edits', () {
    test('only this instance: override replaces one, others untouched', () {
      final m = series('FREQ=WEEKLY;BYDAY=MO;COUNT=4');
      final o = makeOverride(
        master: m,
        originalStart: floating(2026, 5, 11, 9),
        newId: 'o1',
        edited: m.copyWith(
          start: floating(2026, 5, 12, 18),
          end: floating(2026, 5, 12, 19),
          title: 'Áthelyezve',
        ),
      );
      final occ = expand(
        m,
        DateTime.utc(2026, 5, 1),
        DateTime.utc(2026, 7, 1),
        overrides: [o],
      );
      expect(occ.length, 4);
      expect(occ.where((x) => x.isOverride).single.title, 'Áthelyezve');
    });
    test('delete one instance via EXDATE (idempotent)', () {
      final m = series('FREQ=DAILY;COUNT=5');
      final once = deleteInstance(m, floating(2026, 5, 6, 9));
      expect(deleteInstance(once, floating(2026, 5, 6, 9)).exdates.length, 1);
      expect(days(once).length, 4);
    });
    test('this and following delete: UNTIL series; first instance -> null', () {
      final m = series('FREQ=DAILY;COUNT=10');
      expect(days(deleteFollowing(m, floating(2026, 5, 8, 9))!).length, 4);
      expect(deleteFollowing(m, floating(2026, 5, 4, 9)), isNull);
    });
    test(
      'this and following edit (endless): old stops, new continues forever',
      () {
        final m = series('FREQ=WEEKLY;BYDAY=MO');
        final edited = m.copyWith(
          start: floating(2026, 5, 18, 18),
          end: floating(2026, 5, 18, 19),
          title: 'Esti edzés',
        );
        final r = splitSeries(
          master: m,
          splitAt: floating(2026, 5, 18, 9),
          edited: edited,
          newId: 'n',
        );
        expect(days(r.truncated!).map((d) => d.day), [4, 11]);
        final tail = expand(
          r.newSeries,
          DateTime.utc(2026, 5, 1),
          DateTime.utc(2026, 8, 1),
        );
        expect(tail.first.title, 'Esti edzés');
        expect(toWallClock(bp, tail.first.startUtc), floating(2026, 5, 18, 18));
        expect(tail.length, greaterThan(10)); // keeps going
      },
    );
    test('this and following edit with COUNT: total stays correct', () {
      final m = series('FREQ=DAILY;COUNT=10');
      final r = splitSeries(
        master: m,
        splitAt: floating(2026, 5, 8, 9),
        edited: m.copyWith(
          title: 'X',
          start: floating(2026, 5, 8, 9),
          end: floating(2026, 5, 8, 10),
        ),
        newId: 'n',
      );
      expect(days(r.truncated!).length + days(r.newSeries).length, 10);
    });
    test(
      'split at the first instance replaces the series (no truncated part)',
      () {
        final m = series('FREQ=DAILY;COUNT=3');
        final r = splitSeries(
          master: m,
          splitAt: m.start,
          edited: m.copyWith(title: 'Új'),
          newId: 'n',
        );
        expect(r.truncated, isNull);
      },
    );
    test('split moves later EXDATEs with the shifted series and drops tail overrides', () {
      final m = series(
        'FREQ=DAILY;COUNT=10',
        ex: [floating(2026, 5, 6, 9), floating(2026, 5, 10, 9)],
      );
      final tailOv = makeOverride(
        master: m,
        originalStart: floating(2026, 5, 9, 9),
        newId: 'o',
        edited: m,
      );
      final r = splitSeries(
        master: m,
        splitAt: floating(2026, 5, 8, 9),
        overrides: [tailOv],
        edited: m.copyWith(
          start: floating(2026, 5, 8, 18),
          end: floating(2026, 5, 8, 19),
        ),
        newId: 'n',
      );
      expect(r.newSeries.exdates, [floating(2026, 5, 10, 18)]);
      expect(r.truncated!.exdates, [floating(2026, 5, 6, 9)]);
      expect(r.droppedOverrides.single.id, 'o');
    });
    test(
      'edit all: time change shifts EXDATEs and overrides with the series',
      () {
        final m = series('FREQ=DAILY;COUNT=5', ex: [floating(2026, 5, 6, 9)]);
        final o = makeOverride(
          master: m,
          originalStart: floating(2026, 5, 7, 9),
          newId: 'o',
          edited: m.copyWith(title: 'moved'),
        );
        final res = editAll(
          master: m,
          overrides: [o],
          edited: m.copyWith(
            start: floating(2026, 5, 4, 10),
            end: floating(2026, 5, 4, 11),
          ),
        );
        expect(res.master.exdates, [floating(2026, 5, 6, 10)]);
        expect(res.overrides.single.originalStart, floating(2026, 5, 7, 10));
        expect(days(res.master, ov: res.overrides).length, 4);
      },
    );
    test('edit all can switch a series to a single event', () {
      final m = series('FREQ=DAILY;COUNT=5');
      final res = editAll(master: m, edited: m.copyWith(clearRrule: true));
      expect(res.master.isRecurring, isFalse);
    });
  });
}
