import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/notify/budget_alerts.dart';
import 'package:kvantum_app/notify/budget_notify.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_budget_notifier.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// The notes of the device, with a count of what is written to them.
class _SpyRecords extends RecordRepository {
  _SpyRecords(super.db);
  final writes = <String>[];

  @override
  Future<void> setMeta(String key, String? value) {
    writes.add(key);
    return super.setMeta(key, value);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the alerts', () {
    late AppDatabase db;
    late FakeBudgetNotifier fake;
    late ManualTimers timers;
    late ProviderContainer c;
    late FinanceRepository fin;
    late MemoryDiagSink sink;
    var now = DateTime.utc(2026, 11, 12, 9);

    ProviderContainer container(FakeBudgetNotifier notifier) =>
        ProviderContainer(
          overrides: [
            ...baseOverrides(db),
            budgetNotifierProvider.overrideWithValue(notifier),
            budgetAlertTimerProvider.overrideWithValue(timers.make),
            appClockProvider.overrideWithValue(() => now),
            diagLogProvider.overrideWithValue(DiagLog()..attach(sink)),
          ],
        );

    setUp(() async {
      db = await newDb();
      fake = FakeBudgetNotifier();
      timers = ManualTimers();
      sink = MemoryDiagSink();
      now = DateTime.utc(2026, 11, 12, 9);
      c = container(fake);
      fin = FinanceRepository(db);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    Future<void> budgetOf(String cat, int limit) =>
        fin.saveBudget(FinBudget(categoryId: cat, limit: limit));

    Future<void> spend(
      String id,
      int amount, {
      String cat = 'cat-food',
      int month = 11,
      bool deleted = false,
    }) => fin.saveTx(
      FinTx(
        id: id,
        date: floating(2026, month, 10),
        amount: amount,
        kind: FinKind.expense,
        categoryId: cat,
        deleted: deleted,
      ),
    );

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 200 && !ok(); i++) {
        await pumpEventQueue(times: 3);
      }
    }

    /// The provider has seen [n] transactions (and rebuilt because of them).
    Future<void> sawTx(int n) async {
      await until(() => c.read(finTxProvider).value?.length == n);
      await pumpEventQueue();
    }

    Future<String?> meta(String key) => c.read(recordRepoProvider).meta(key);

    Future<void> turnOn() async {
      await c.read(budgetAlertsSettingProvider.future);
      expect(
        await c.read(budgetAlertsSettingProvider.notifier).enable(),
        BudgetAlertsStart.on,
      );
      c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
      await c.read(finTxProvider.future);
      await c.read(finBudgetsProvider.future);
      await pumpEventQueue();
    }

    /// The wait is over; the look at the finances is done when this returns.
    Future<void> look() async {
      await pumpEventQueue();
      timers.current.fire(); // (exactly one wait is running)
      await c.read(budgetAlertRunsProvider).last;
    }

    test('nothing happens until it is switched on', () async {
      await budgetOf('cat-food', 10000);
      c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
      await spend('a', 12000);
      await sawTx(1);
      expect(timers.made, isEmpty);
      expect(fake.shown, isEmpty);
      expect(await meta(budgetAlertsKey), isNull);
    });

    test('the switch is read from the device', () async {
      expect(await c.read(budgetAlertsSettingProvider.future), isFalse);
      c.dispose();
      c = container(fake);
      await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'on');
      expect(await c.read(budgetAlertsSettingProvider.future), isTrue);
      c.dispose();
      c = container(fake);
      await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'off');
      expect(await c.read(budgetAlertsSettingProvider.future), isFalse);
    });

    test('where no notification can be shown, nothing is watched', () async {
      final none = FakeBudgetNotifier(isSupported: false);
      c.dispose();
      c = container(none);
      await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'on');
      await c.read(budgetAlertsSettingProvider.future);
      c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
      await pumpEventQueue();
      expect(timers.made, isEmpty);
    });

    group('switching on', () {
      test('asks the device, and the answer no leaves it off', () async {
        fake.grant = false;
        await c.read(budgetAlertsSettingProvider.future);
        final r = await c.read(budgetAlertsSettingProvider.notifier).enable();
        expect(r, BudgetAlertsStart.denied);
        expect(fake.permissionAsks, 1);
        expect(c.read(budgetAlertsSettingProvider).value, isFalse);
        expect(await meta(budgetAlertsKey), isNull);
        expect(await meta('bud.alert.2026-11'), isNull);
      });

      test('a device that cannot show is not even asked', () async {
        final none = FakeBudgetNotifier(isSupported: false);
        c.dispose();
        c = container(none);
        await c.read(budgetAlertsSettingProvider.future);
        expect(
          await c.read(budgetAlertsSettingProvider.notifier).enable(),
          BudgetAlertsStart.denied,
        );
        expect(none.permissionAsks, 0);
        expect(await meta(budgetAlertsKey), isNull);
      });

      test('what is over already is remembered, not told', () async {
        await budgetOf('cat-food', 10000);
        await budgetOf('cat-fun', 10000);
        await spend('a', 12000);
        await spend('b', 8200, cat: 'cat-fun');
        await spend('c', 100, cat: 'cat-sport'); // (no budget)
        await turnOn();
        expect(c.read(budgetAlertsSettingProvider).value, isTrue);
        expect(await meta(budgetAlertsKey), 'on');
        expect(await meta('bud.alert.2026-11'), '{"cat-food":2,"cat-fun":1}');
        expect(fake.permissionAsks, 1);

        await look();
        expect(fake.shown, isEmpty);
        // more of the same: still over, still close
        await spend('d', 500);
        await spend('e', 50, cat: 'cat-fun');
        await sawTx(5);
        await look();
        expect(fake.shown, isEmpty);
      });

      test('switching off forgets the switch and stops the watching', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        expect(timers.live, 1);
        await c.read(budgetAlertsSettingProvider.notifier).disable();
        expect(c.read(budgetAlertsSettingProvider).value, isFalse);
        expect(await meta(budgetAlertsKey), isNull);
        await pumpEventQueue();
        expect(timers.live, 0);

        await spend('a', 12000);
        await sawTx(1);
        expect(timers.live, 0);
        expect(fake.shown, isEmpty);
      });
    });

    group('telling', () {
      test('a category reaching 80 % is told with name and numbers', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        await look();
        expect(fake.shown, isEmpty, reason: 'nothing spent yet');

        await spend('a', 8500);
        await sawTx(1);
        expect(fake.shown, isEmpty, reason: 'not before the wait is over');
        await look();
        expect(fake.shown, [
          (
            id: budgetNotificationId('2026-11', 'cat-food'),
            title: 'Költségkeret: Élelmiszer',
            body:
                'A keret 85%-a elfogyott: ${formatHuf(8500)} / '
                '${formatHuf(10000)}.',
          ),
        ]);
        expect(await meta('bud.alert.2026-11'), '{"cat-food":1}');
      });

      test('then only a higher level is news', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        await spend('a', 8500);
        await sawTx(1);
        await look();
        expect(fake.shown, hasLength(1));

        await spend('b', 600);
        await sawTx(2);
        await look();
        expect(fake.shown, hasLength(1), reason: '91 %: still close');

        await spend('c', 1500);
        await sawTx(3);
        await look();
        expect(fake.shown, hasLength(2));
        expect(
          fake.shown.last.body,
          'Túllépted a keretet: ${formatHuf(10600)} / ${formatHuf(10000)} '
          '(+${formatHuf(600)}).',
        );
        // the same news in the same month replaces itself on the device
        expect(fake.shown.last.id, fake.shown.first.id);
        expect(await meta('bud.alert.2026-11'), '{"cat-food":2}');
      });

      test('crossing again after a fall is news again', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        await spend('a', 8500);
        await sawTx(1);
        await look();
        expect(fake.shown, hasLength(1));

        await spend('a', 8500, deleted: true);
        await sawTx(0);
        await look();
        expect(await meta('bud.alert.2026-11'), isNull);

        await spend('b', 9000);
        await sawTx(1);
        await look();
        expect(fake.shown, hasLength(2));
      });

      test('a burst of changes waits, and then makes one look', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        for (var i = 0; i < 5; i++) {
          await spend('t$i', 100);
          await sawTx(i + 1);
        }
        expect(timers.made.length, greaterThan(2));
        expect(timers.live, 1);
        expect(timers.made.last.wait, const Duration(milliseconds: 1500));
        expect(fake.shown, isEmpty);
        // one more row that brings the total to 80 %
        await spend('big', 7500);
        await sawTx(6);
        expect(timers.live, 1);
        await look();
        expect(fake.shown, hasLength(1));
      });

      test('a changed budget is looked at as well', () async {
        // 12 000 of 20 000 is 60 %: fine
        await budgetOf('cat-food', 20000);
        await spend('a', 12000);
        await turnOn();
        await look();
        expect(fake.shown, isEmpty, reason: '60 %');

        // the limit is lowered: now it is over
        await budgetOf('cat-food', 10000);
        await until(
          () => c.read(finBudgetsProvider).value?.single.limit == 10000,
        );
        await pumpEventQueue();
        await look();
        expect(fake.shown.single.body, startsWith('Túllépted a keretet'));
      });

      test('a look that finds nothing new writes nothing', () async {
        final spy = _SpyRecords(db);
        c.dispose();
        c = ProviderContainer(
          overrides: [
            ...baseOverrides(db),
            recordRepoProvider.overrideWithValue(spy),
            budgetNotifierProvider.overrideWithValue(fake),
            budgetAlertTimerProvider.overrideWithValue(timers.make),
            appClockProvider.overrideWithValue(() => now),
          ],
        );
        await budgetOf('cat-food', 10000);
        await turnOn();
        await spend('a', 8500);
        await sawTx(1);
        await look();
        expect(spy.writes, contains('bud.alert.2026-11'));

        // the same state looked at again: nothing is written, nothing told
        spy.writes.clear();
        await spend('a', 8600); // (still close)
        await sawTx(1);
        await look();
        expect(spy.writes, isEmpty);
        expect(fake.shown, hasLength(1));
      });

      test('leaving cancels the wait', () async {
        await budgetOf('cat-food', 10000);
        await turnOn();
        expect(timers.live, 1);
        c.dispose();
        expect(timers.live, 0);
        expect(fake.shown, isEmpty);
      });

      test('what is remembered from the last run counts', () async {
        await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'on');
        await c
            .read(recordRepoProvider)
            .setMeta('bud.alert.2026-11', '{"cat-food":1}');
        await budgetOf('cat-food', 10000);
        await spend('a', 8500); // close, as remembered
        c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
        await c.read(budgetAlertsSettingProvider.future);
        await sawTx(1);
        await look();
        expect(fake.shown, isEmpty);

        await spend('b', 2000);
        await sawTx(2);
        await look();
        expect(fake.shown.single.body, startsWith('Túllépted a keretet'));
      });

      test(
        'the rent a rule makes is no news, what is spent on top is',
        () async {
          await budgetOf('cat-housing', 150000);
          await turnOn();
          await fin.saveTx(
            FinTx(
              id: recurringTxId('rent', 2026, 11),
              date: floating(2026, 11, 1),
              amount: 150000,
              kind: FinKind.expense,
              categoryId: 'cat-housing',
              source: FinSource.recurring,
            ),
          );
          await sawTx(1);
          await look();
          expect(fake.shown, isEmpty);
          expect(await meta('bud.alert.2026-11'), '{"cat-housing":1}');

          await spend('x', 5000, cat: 'cat-housing');
          await sawTx(2);
          await look();
          expect(fake.shown.single.title, 'Költségkeret: Lakás');
          expect(
            fake.shown.single.body,
            'Túllépted a keretet: ${formatHuf(155000)} / ${formatHuf(150000)} '
            '(+${formatHuf(5000)}).',
          );
        },
      );

      test('several at once are one message', () async {
        final cats = ['cat-food', 'cat-fun', 'cat-health', 'cat-sport'];
        for (final cat in cats) {
          await budgetOf(cat, 1000);
        }
        await turnOn();
        for (final (i, cat) in cats.indexed) {
          await spend('s$i', 1100 + i * 100, cat: cat);
        }
        await sawTx(4);
        await look();
        final m = fake.shown.single;
        expect(m.id, budgetNotificationId('2026-11', '*'));
        expect(m.title, 'Költségkeret: 4 kategória');
        expect(m.body.split('\n'), [
          'Sport: túllépve',
          'Egészség: túllépve',
          'Szórakozás: túllépve',
          'Élelmiszer: túllépve',
        ]);
      });

      test('three are told one by one', () async {
        final cats = ['cat-food', 'cat-fun', 'cat-health'];
        for (final cat in cats) {
          await budgetOf(cat, 1000);
        }
        await turnOn();
        for (final (i, cat) in cats.indexed) {
          await spend('s$i', 900 + i * 200, cat: cat);
        }
        await sawTx(3);
        await look();
        expect(fake.shown.map((m) => m.title), [
          'Költségkeret: Egészség',
          'Költségkeret: Szórakozás',
          'Költségkeret: Élelmiszer',
        ]);
        expect(fake.shown.map((m) => m.id).toSet(), hasLength(3));
      });
    });

    group('names', () {
      test(
        'a category of the user\'s own, or one that replaces a default',
        () async {
          await fin.saveCategory(
            const FinCategory(
              id: 'cat-dog',
              name: 'Kutya',
              kind: FinKind.expense,
            ),
          );
          await fin.saveCategory(
            const FinCategory(
              id: 'cat-food',
              name: 'Kaja',
              kind: FinKind.expense,
            ),
          );
          await budgetOf('cat-dog', 1000);
          await budgetOf('cat-food', 1000);
          await turnOn();
          await spend('a', 900, cat: 'cat-dog');
          await spend('b', 900);
          await sawTx(2);
          await look();
          expect(fake.shown.map((m) => m.title).toSet(), {
            'Költségkeret: Kutya',
            'Költségkeret: Kaja',
          });
        },
      );

      test('a category nobody knows is just "Kategória"', () async {
        await budgetOf('cat-gone', 1000);
        await turnOn();
        await spend('a', 900, cat: 'cat-gone');
        await sawTx(1);
        await look();
        expect(fake.shown.single.title, 'Költségkeret: Kategória');
      });
    });

    group('months', () {
      test(
        'a new month has a memory of its own, and the old ones go',
        () async {
          await budgetOf('cat-food', 10000);
          // memory the program wrote two and three months ago
          final repo = c.read(recordRepoProvider);
          await repo.setMeta('bud.alert.2026-09', '{"cat-food":2}');
          await repo.setMeta('bud.alert.2026-10', '{"cat-food":1}');
          await turnOn();
          await spend('a', 8500);
          await sawTx(1);
          await look();
          expect(fake.shown, hasLength(1));
          expect(await meta('bud.alert.2026-11'), '{"cat-food":1}');
          expect(await meta('bud.alert.2026-09'), isNull);
          expect(await meta('bud.alert.2026-10'), '{"cat-food":1}');

          // midnight: December has begun, and nothing is spent in it
          now = DateTime.utc(2026, 12, 1, 9);
          c.read(todayProvider.notifier).refresh();
          await pumpEventQueue();
          await look();
          expect(fake.shown, hasLength(1));
          expect(await meta('bud.alert.2026-12'), isNull);
          expect(await meta('bud.alert.2026-10'), isNull);
          expect(await meta('bud.alert.2026-11'), '{"cat-food":1}');

          await spend('b', 9000, month: 12);
          await sawTx(2);
          await look();
          expect(fake.shown, hasLength(2));
          expect(
            fake.shown.last.id,
            budgetNotificationId('2026-12', 'cat-food'),
          );
          expect(await meta('bud.alert.2026-12'), '{"cat-food":1}');
        },
      );

      test('a year change reaches back to November', () async {
        now = DateTime.utc(2027, 1, 4, 9);
        final repo = c.read(recordRepoProvider);
        await repo.setMeta('bud.alert.2026-11', '{"cat-food":2}');
        await repo.setMeta('bud.alert.2026-12', '{"cat-food":2}');
        await turnOn();
        await look();
        expect(await meta('bud.alert.2026-11'), isNull);
        expect(await meta('bud.alert.2026-12'), '{"cat-food":2}');
      });
    });

    group('when things go wrong', () {
      test(
        'a device that refuses does not break it, and it is written down',
        () async {
          await budgetOf('cat-food', 10000);
          await turnOn();
          fake.failShow = true;
          await spend('a', 8500);
          await sawTx(1);
          await look();
          expect(fake.shown, isEmpty);
          // the news is lost, but not told again on every later look
          expect(await meta('bud.alert.2026-11'), '{"cat-food":1}');
          await c.read(diagLogProvider).flush();
          expect(sink.lines.join('\n'), contains('budget.alert_failed'));

          fake.failShow = false;
          await spend('b', 100);
          await sawTx(2);
          await look();
          expect(fake.shown, isEmpty);
        },
      );

      test('one that fails does not keep back the memory', () async {
        // (every show fails here; the loop must go on to the memory)
        for (final cat in ['cat-food', 'cat-fun']) {
          await budgetOf(cat, 1000);
        }
        await turnOn();
        fake.failShow = true;
        await spend('a', 900);
        await spend('b', 900, cat: 'cat-fun');
        await sawTx(2);
        await look();
        expect(await meta('bud.alert.2026-11'), '{"cat-food":1,"cat-fun":1}');
      });

      test(
        'transactions that have not arrived are not "nothing spent"',
        () async {
          final never = StreamController<List<FinTx>>();
          addTearDown(never.close);
          c.dispose();
          c = ProviderContainer(
            overrides: [
              ...baseOverrides(db),
              budgetNotifierProvider.overrideWithValue(fake),
              budgetAlertTimerProvider.overrideWithValue(timers.make),
              appClockProvider.overrideWithValue(() => now),
              finTxProvider.overrideWith((ref) => never.stream),
            ],
          );
          await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'on');
          await c
              .read(recordRepoProvider)
              .setMeta('bud.alert.2026-11', '{"cat-food":2}');
          await budgetOf('cat-food', 10000);
          await c.read(budgetAlertsSettingProvider.future);
          c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
          await c.read(finBudgetsProvider.future);
          await pumpEventQueue();
          await look();
          expect(fake.shown, isEmpty);
          // the memory was not wiped as if everything had been deleted
          expect(await meta('bud.alert.2026-11'), '{"cat-food":2}');
        },
      );

      test('an unreadable memory is no memory', () async {
        await c.read(recordRepoProvider).setMeta(budgetAlertsKey, 'on');
        await c
            .read(recordRepoProvider)
            .setMeta('bud.alert.2026-11', 'nem json');
        await budgetOf('cat-food', 10000);
        await spend('a', 8500);
        c.listen(budgetAlertsProvider, (_, _) {}, fireImmediately: true);
        await c.read(budgetAlertsSettingProvider.future);
        await sawTx(1);
        await look();
        expect(fake.shown, hasLength(1));
        expect(await meta('bud.alert.2026-11'), '{"cat-food":1}');
      });
    });

    test('the keys are the ones the notes are kept under', () {
      expect(budgetAlertsKey, 'bud.alerts');
      expect(budgetMemoryKey(2026, 3), 'bud.alert.2026-03');
      expect(budgetMemoryKey(2026, 11), 'bud.alert.2026-11');
    });
  });

  group('the home page', () {
    testWidgets('keeps the alerts running', (tester) async {
      useSize(tester, size: const Size(900, 900));
      final db = await newDb();
      final fake = FakeBudgetNotifier();
      final timers = ManualTimers();
      await tester.runAsync(() async {
        final fin = FinanceRepository(db);
        await fin.saveBudget(
          const FinBudget(categoryId: 'cat-food', limit: 10000),
        );
        await fin.saveTx(
          FinTx(
            id: 'a',
            date: floating(2026, 11, 10),
            amount: 8500,
            kind: FinKind.expense,
            categoryId: 'cat-food',
          ),
        );
      });
      await tester.pumpWidget(
        app(
          const HomePage(),
          db,
          extra: [
            budgetNotifierProvider.overrideWithValue(fake),
            budgetAlertTimerProvider.overrideWithValue(timers.make),
            budgetAlertsSettingProvider.overrideWith(_On.new),
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
          ],
        ),
      );
      await tester.pumpAndSettle();
      // the transactions have arrived; the wait that follows is the alerts'
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(timers.live, 1);
      timers.current.fire();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      await tester.runAsync(() => c.read(budgetAlertRunsProvider).last);
      expect(fake.shown.single.title, 'Költségkeret: Élelmiszer');

      await shutdown(tester, db);
    });
  });
}

/// The alerts, switched on without asking anybody.
class _On extends BudgetAlertsSetting {
  @override
  Future<bool> build() async => true;
}
