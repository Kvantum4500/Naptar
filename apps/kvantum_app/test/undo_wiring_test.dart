import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_app/ui/delete_ops.dart';
import 'package:kvantum_app/ui/event_editor.dart' show Scope;
import 'package:kvantum_app/ui/undo_service.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'controller_test.dart' show FakeAuth;
import 'support/fake_drive.dart';
import 'support/fake_remote.dart';
import 'support/harness.dart';

CalEvent ev(String id) => CalEvent(
  id: id,
  calendarId: 'naptar',
  title: 'Edzés',
  tzid: 'Europe/Budapest',
  start: floating(2026, 5, 4, 9),
  end: floating(2026, 5, 4, 10),
);

/// The pieces really are connected: the hold the undo bar places is the one
/// the sync engine of the controller looks at.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  test('the controller\'s engine leaves a held deletion alone until the hold '
      'is released', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final remote = FakeRemote();
    final c = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        googleConfiguredProvider.overrideWithValue(true),
        authGatewayProvider.overrideWithValue(FakeAuth()),
        remoteFactoryProvider.overrideWithValue((_) => remote),
        driveFactoryProvider.overrideWithValue((_) => FakeDrive()),
        syncPaceProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(db.close);

    final repo = EventRepository(db);
    await repo.saveLocal(ev('a'));
    final ctl = c.read(syncControllerProvider.notifier);
    await ctl.signIn(); // uploads the event
    final g = (await repo.byId('a'))!.googleId!;

    final token = c.read(syncHoldProvider).acquire(['a']);
    await repo.deleteLocal('a');
    await ctl.syncNow(manual: true);
    expect(
      remote.pushLog.where((p) => p.$1 == 'delete'),
      isEmpty,
      reason: 'the user can still take it back',
    );
    expect(remote.isCancelled(g), isFalse);

    token.release();
    await ctl.syncNow(manual: true);
    expect(remote.isCancelled(g), isTrue, reason: 'now it goes up');
  });

  testWidgets('run(): holds the series while the bar is up, deletes, and the '
      'button puts it back', (tester) async {
    useSize(tester, size: const Size(400, 800));
    final db = await newDb();
    final repo = EventRepository(db);
    await tester.runAsync(() => repo.saveLocal(ev('a')));
    late SyncHold hold;
    var heldWhileChanging = false;
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  hold = ref.read(syncHoldProvider);
                  ref
                      .read(undoServiceProvider)
                      .run(
                        UndoSite.of(context),
                        holdIds: ['a'],
                        change: () {
                          heldWhileChanging = hold.isHeld('a');
                          return deleteEvent(
                            repo,
                            eventId: 'a',
                            originalStart: floating(2026, 5, 4, 9),
                            recurring: false,
                            scope: Scope.only,
                          );
                        },
                        message: (_) => 'Esemény törölve',
                      );
                },
                child: const Text('törlés'),
              ),
            ),
          ),
        ),
        db,
      ),
    );
    await tester.tap(find.text('törlés'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Esemény törölve'), findsOneWidget);
    expect(
      heldWhileChanging,
      isTrue,
      reason: 'the hold is placed BEFORE the change, or a sync could slip in',
    );
    expect(hold.isHeld('a'), isTrue, reason: 'and kept while the bar is up');
    expect(await tester.runAsync(repo.all), isEmpty);

    await tester.tap(find.text('Visszavonás'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(hold.isHeld('a'), isFalse, reason: 'released after the undo');
    expect((await tester.runAsync(repo.all))!.single.title, 'Edzés');
    await shutdown(tester, db);
  });

  testWidgets('run(): a failing change lets the hold go and passes the error '
      'on', (tester) async {
    useSize(tester, size: const Size(400, 800));
    final db = await newDb();
    late SyncHold hold;
    Object? caught;
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                hold = ref.read(syncHoldProvider);
                try {
                  await ref
                      .read(undoServiceProvider)
                      .run(
                        UndoSite.of(context),
                        holdIds: ['a'],
                        change: () async => throw StateError('boom'),
                        message: (_) => 'Esemény törölve',
                      );
                } catch (e) {
                  caught = e;
                }
              },
              child: const Text('törlés'),
            ),
          ),
        ),
        db,
      ),
    );
    await tester.tap(find.text('törlés'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(caught, isA<StateError>());
    expect(hold.isEmpty, isTrue, reason: 'a failed change holds nothing');
    expect(find.text('Esemény törölve'), findsNothing);
    await shutdown(tester, db);
  });

  testWidgets('run(): holding an exception holds its whole series', (
    tester,
  ) async {
    useSize(tester, size: const Size(400, 800));
    final db = await newDb();
    final repo = EventRepository(db);
    final master = ev('m').copyWith(rrule: 'FREQ=DAILY;COUNT=5');
    final x = makeOverride(
      master: master,
      originalStart: floating(2026, 5, 5, 9),
      edited: master.copyWith(
        start: floating(2026, 5, 5, 10),
        end: floating(2026, 5, 5, 11),
      ),
      newId: 'x',
    );
    await tester.runAsync(() => repo.saveAll([master, x]));
    late SyncHold hold;
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: ElevatedButton(
              onPressed: () {
                hold = ref.read(syncHoldProvider);
                ref
                    .read(undoServiceProvider)
                    .run(
                      UndoSite.of(context),
                      holdIds: ['x'],
                      change: () => deleteEvent(
                        repo,
                        eventId: 'x',
                        originalStart: floating(2026, 5, 5, 9),
                        recurring: true,
                        scope: Scope.only,
                      ),
                      message: (_) => 'Az előfordulás törölve',
                    );
              },
              child: const Text('törlés'),
            ),
          ),
        ),
        db,
      ),
    );
    await tester.tap(find.text('törlés'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(hold.isHeld('m'), isTrue, reason: 'the series is what is held');
    // ... which covers the master's upload of the EXDATE and any exception
    expect(hold.isHeld('another-exception', seriesId: 'm'), isTrue);
    await shutdown(tester, db);
  });

  testWidgets('run(): nothing to take back means no bar and no hold', (
    tester,
  ) async {
    useSize(tester, size: const Size(400, 800));
    final db = await newDb();
    final repo = EventRepository(db);
    late SyncHold hold;
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: ElevatedButton(
              onPressed: () {
                hold = ref.read(syncHoldProvider);
                ref
                    .read(undoServiceProvider)
                    .run(
                      UndoSite.of(context),
                      holdIds: ['nincs'],
                      change: () => deleteEvent(
                        repo,
                        eventId: 'nincs',
                        originalStart: floating(2026, 5, 4, 9),
                        recurring: false,
                        scope: Scope.only,
                      ),
                      message: (_) => 'Esemény törölve',
                    );
              },
              child: const Text('törlés'),
            ),
          ),
        ),
        db,
      ),
    );
    await tester.tap(find.text('törlés'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Esemény törölve'), findsNothing);
    expect(hold.isEmpty, isTrue);
    await shutdown(tester, db);
  });
}
