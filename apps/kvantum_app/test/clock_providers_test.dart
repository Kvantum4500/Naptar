import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/workout_providers.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// One clock for the app: a test that sets [appClockProvider] sets the time of
/// everything that has a clock of its own by default (the assistant, the sync,
/// the workout questions), and of the stores that stamp their records, so what
/// a test says about "now" is the same everywhere. Each of them can still be
/// given a clock of its own.
void main() {
  // (a change of a finance row asks the sync to run: it looks at the lifecycle)
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixed = DateTime.utc(2030, 5, 6, 7, 8, 9);
  final fixedMs = fixed.millisecondsSinceEpoch;

  late AppDatabase db;
  setUp(() async => db = await newDb());
  tearDown(() => db.close());

  ProviderContainer container([List<Override> extra = const []]) {
    final c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        googleConfiguredProvider.overrideWithValue(false),
        ...extra,
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('the clocks follow the app clock', () {
    test('the assistant, the sync and the workout questions', () {
      final c = container([appClockProvider.overrideWithValue(() => fixed)]);
      expect(c.read(appClockProvider)(), fixed);
      expect(c.read(aiClockProvider)(), fixed);
      expect(c.read(syncClockProvider)(), fixed);
      expect(c.read(workoutClockProvider)(), fixed);
    });

    test('and each can be given one of its own', () {
      final other = DateTime.utc(2031, 1, 1);
      final c = container([
        appClockProvider.overrideWithValue(() => fixed),
        aiClockProvider.overrideWithValue(() => other),
      ]);
      expect(c.read(aiClockProvider)(), other);
      expect(c.read(syncClockProvider)(), fixed);
      expect(c.read(workoutClockProvider)(), fixed);
      final d = container([syncClockProvider.overrideWithValue(() => other)]);
      expect(d.read(syncClockProvider)(), other);
      expect(
        d.read(aiClockProvider)().difference(DateTime.now()).abs(),
        lessThan(const Duration(minutes: 1)),
        reason: 'with nothing set, the real clock',
      );
    });
  });

  group('the stores stamp with the app clock', () {
    test('a record of the Drive-synced kinds', () async {
      final c = container([appClockProvider.overrideWithValue(() => fixed)]);
      final r = await c.read(recordRepoProvider).edit(kindTask, 't1', {
        'title': 'Fogorvos',
      });
      expect(r.updatedAt, fixedMs);
    });

    test('a finance row', () async {
      final c = container([appClockProvider.overrideWithValue(() => fixed)]);
      final repo = c.read(financeRepoProvider);
      await repo.saveTx(
        FinTx(
          id: 'x1',
          date: floating(2030, 5, 6),
          amount: 1200,
          kind: FinKind.expense,
        ),
      );
      expect((await repo.txs()).single.updatedAt, fixedMs);
    });

    test('and never goes back, whatever the clock says', () async {
      final c = container([appClockProvider.overrideWithValue(() => fixed)]);
      final repo = c.read(recordRepoProvider);
      final first = await repo.edit(kindTask, 't1', {'title': 'A'});
      final second = await repo.edit(kindTask, 't1', {'title': 'B'});
      expect(second.updatedAt, greaterThan(first.updatedAt));
    });
  });

  test('epochMillisOf reads a clock as milliseconds since the epoch', () {
    expect(epochMillisOf(() => fixed)(), fixedMs);
    // (a clock in local time says the same moment)
    expect(epochMillisOf(() => fixed.toLocal())(), fixedMs);
  });
}
