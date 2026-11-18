import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The edges of the settings records and of the names of the record files that
/// nothing held until the deliberate breakage round of the 8th round: every
/// limit of the pay settings, the weekly wish of the planner, and the exact
/// names under which the records travel.
void main() {
  SyncRecord rec(String id, Map<String, Object?> fields) =>
      SyncRecord(id: id, kind: kindSettings).edit(fields, ts: 1, dev: 'A');

  group('the pay settings', () {
    PaySettings pay(Map<String, Object?> f) =>
        PaySettings.fromRecord(rec(settingsPayId, f));

    test('an hourly wage is taken up to a million, not beyond', () {
      expect(pay({'hourly': 500000}).hourly, 500000);
      expect(pay({'hourly': 1000000}).hourly, 1000000);
      expect(pay({'hourly': 1000001}).hourly, 1000000);
      expect(pay({'hourly': 5000000}).hourly, 1000000);
    });

    test('a premium is taken up to a thousand percent, not beyond', () {
      for (final f in ['evening', 'night', 'saturday', 'sunday', 'holiday']) {
        expect(pay({f: 100}).toJson()[f], 100, reason: f);
        expect(pay({f: 500}).toJson()[f], 500, reason: f);
        expect(pay({f: 1000}).toJson()[f], 1000, reason: f);
        // (a premium of 5000 percent is a slip of a finger, not a wage)
        expect(pay({f: 1001}).toJson()[f], 1000, reason: f);
        expect(pay({f: 5000}).toJson()[f], 1000, reason: f);
      }
    });

    test('the limits are the ones the form tells', () {
      expect(PaySettings.maxHourly, 1000000);
      expect(PaySettings.maxPercent, 1000);
    });
  });

  group('the wishes of the planner', () {
    LocalPlanPrefs plan(Object? perWeek) =>
        LocalPlanPrefs.fromRecord(rec(settingsPlanId, {'perWeek': perWeek}));

    test('a weekly wish is a whole number of 1 to 7', () {
      for (var n = 1; n <= 7; n++) {
        expect(plan(n).perWeek, n);
      }
      expect(plan(0).perWeek, 1);
      expect(plan(9).perWeek, 7);
    });

    test('a weekly wish that is no whole number is the usual three', () {
      // (refused, not rounded: a damaged field is the default)
      expect(plan(2.4).perWeek, 3);
      expect(plan(4.6).perWeek, 3);
      expect(plan('4').perWeek, 3);
      expect(plan(null).perWeek, 3);
    });
  });

  group('the record files', () {
    test('the kinds that travel are these seven, under these names', () {
      expect(syncedKinds.toSet(), {
        'task',
        'checkin',
        'handbook',
        'workoutlog',
        'intake',
        'journal',
        'settings',
      });
      expect(syncedKinds, hasLength(7));
      expect(kindHandbook, 'handbook');
      expect(recordFileName(kindHandbook, 'a'), 'handbook-a.json');
    });

    test('the handbook has its file recognised, whatever the id', () {
      for (final p in [recordFileNamePattern, safeRecordFileNamePattern]) {
        final m = p.firstMatch('handbook-main.json')!;
        expect((m[1], m[2]), ('handbook', 'main'));
        expect(p.hasMatch('handbooks-main.json'), isFalse);
      }
    });

    test('a file name needs an id', () {
      for (final p in [recordFileNamePattern, safeRecordFileNamePattern]) {
        expect(p.hasMatch('task-.json'), isFalse);
        expect(p.hasMatch('handbook-.json'), isFalse);
        expect(p.hasMatch('task-a.json'), isTrue);
      }
    });

    test('a dot is safe in an id, other marks are not', () {
      expect(safeRecordFileNamePattern.hasMatch('task-a.b.json'), isTrue);
      expect(
        safeRecordFileNamePattern.hasMatch('workoutlog-a.b-c_d.json'),
        isTrue,
      );
      for (final bad in ['task-a b.json', 'task-a/b.json', 'task-á.json']) {
        expect(safeRecordFileNamePattern.hasMatch(bad), isFalse, reason: bad);
      }
    });
  });
}
