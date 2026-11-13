import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/sync/sync_hold.dart';
import 'package:kvantum_app/ui/undo_service.dart';

import 'support/harness.dart';

class _Sync extends SyncController {
  int requests = 0;
  @override
  SyncState build() => SyncState(configured: true, signedIn: true);
  @override
  void requestSync() => requests++;
}

/// Two buttons that put an offer on the bar. [calls] records which undo ran.
class _Host extends ConsumerWidget {
  const _Host(this.calls, this.undoA, this.undoB);
  final List<String> calls;
  final Future<bool> Function() undoA;
  final Future<bool> Function() undoB;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Column(
      children: [
        for (final (key, id, msg, undo) in [
          ('offer-a', 'a', 'A törölve', undoA),
          ('offer-b', 'b', 'B törölve', undoB),
        ])
          ElevatedButton(
            key: Key(key),
            onPressed: () => ref
                .read(undoServiceProvider)
                .offer(
                  UndoSite.of(context),
                  message: msg,
                  hold: ref.read(syncHoldProvider).acquire([id]),
                  undo: () {
                    calls.add(id);
                    return undo();
                  },
                ),
            child: Text(key),
          ),
      ],
    ),
  );
}

/// Offers something and takes its own page off the screen in the same
/// breath: nothing is left to show the bar.
class _Vanishing extends ConsumerStatefulWidget {
  const _Vanishing();
  @override
  ConsumerState<_Vanishing> createState() => _VanishingState();
}

class _VanishingState extends ConsumerState<_Vanishing> {
  var _gone = false;

  @override
  Widget build(BuildContext context) => _gone
      ? const SizedBox()
      : Scaffold(
          body: ElevatedButton(
            onPressed: () {
              ref
                  .read(undoServiceProvider)
                  .offer(
                    UndoSite.of(context),
                    message: 'A törölve',
                    hold: ref.read(syncHoldProvider).acquire(['a']),
                    undo: () async => true,
                  );
              setState(() => _gone = true);
            },
            child: const Text('offer'),
          ),
        );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async => initializeDateFormatting('hu'));

  late AppDatabase db;
  late _Sync sync;
  late List<String> calls;
  late ProviderContainer c;
  Future<bool> Function() undoA = () async => true;
  Future<bool> Function() undoB = () async => true;

  Future<void> boot(WidgetTester tester, {Size? size}) async {
    useSize(tester, size: size ?? const Size(400, 800));
    db = await newDb();
    sync = _Sync();
    calls = [];
    undoA = () async => true;
    undoB = () async => true;
    await tester.pumpWidget(
      app(
        _Host(calls, () => undoA(), () => undoB()),
        db,
        extra: [syncControllerProvider.overrideWith(() => sync)],
      ),
    );
    c = ProviderScope.containerOf(tester.element(find.byType(_Host)));
  }

  SyncHold hold() => c.read(syncHoldProvider);

  /// The visible card of the bar (the widget itself includes its margins).
  Rect card(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first,
  );

  Future<void> tapOffer(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump(); // the bar starts to slide in
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the bar', () {
    testWidgets('shows the message with a "Visszavonás" button', (
      tester,
    ) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      expect(find.text('A törölve'), findsOneWidget);
      expect(find.text('Visszavonás'), findsOneWidget);
      expect(hold().isHeld('a'), isTrue);
      await shutdown(tester, db);
    });

    testWidgets('closes by itself after ten seconds (Flutter 3.50 would keep '
        'a bar with an action for ever)', (tester) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('A törölve'), findsOneWidget);
      expect(hold().isHeld('a'), isTrue, reason: 'still on offer at 8 s');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('A törölve'), findsNothing);
      expect(hold().isHeld('a'), isFalse, reason: 'released when it ends');
      expect(sync.requests, 1, reason: 'what waited goes up');
      expect(calls, isEmpty);
      await shutdown(tester, db);
    });

    testWidgets('is not wider than a phone bar on a big window', (
      tester,
    ) async {
      await boot(tester, size: const Size(1280, 800));
      await tapOffer(tester, 'offer-a');
      expect(card(tester).width, lessThanOrEqualTo(560));
      await shutdown(tester, db);
    });

    testWidgets('fills a phone window apart from its margins', (tester) async {
      await boot(tester, size: const Size(400, 800));
      await tapOffer(tester, 'offer-a');
      expect(card(tester).width, 400 - 24);
      await shutdown(tester, db);
    });

    testWidgets('sits well above the bottom edge, clear of a round button', (
      tester,
    ) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      expect(card(tester).bottom, lessThanOrEqualTo(800 - 88));
      await shutdown(tester, db);
    });
  });

  group('"Visszavonás"', () {
    testWidgets('runs the undo once, then lets the hold go', (tester) async {
      await boot(tester);
      final done = Completer<bool>();
      undoA = () => done.future;
      await tapOffer(tester, 'offer-a');
      await tester.tap(find.text('Visszavonás'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, ['a']);
      expect(hold().isHeld('a'), isTrue, reason: 'held while it is undone');
      expect(sync.requests, 0);
      done.complete(true);
      await tester.pump();
      expect(hold().isHeld('a'), isFalse);
      expect(sync.requests, 1);
      expect(find.text('A visszavonás nem sikerült.'), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a second tap does not undo twice', (tester) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      await tester.tap(find.text('Visszavonás'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, ['a']);
      await shutdown(tester, db);
    });

    testWidgets('says so when the change cannot be taken back', (tester) async {
      await boot(tester);
      undoA = () async => false;
      await tapOffer(tester, 'offer-a');
      await tester.tap(find.text('Visszavonás'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('A visszavonás már nem lehetséges: közben megváltozott.'),
        findsOneWidget,
      );
      expect(hold().isHeld('a'), isFalse);
      expect(sync.requests, 1, reason: 'the deletion goes up after all');
      await shutdown(tester, db);
    });

    testWidgets('says so and survives when the undo throws', (tester) async {
      await boot(tester);
      undoA = () async => throw StateError('boom');
      await tapOffer(tester, 'offer-a');
      await tester.tap(find.text('Visszavonás'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('A visszavonás nem sikerült.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(hold().isHeld('a'), isFalse);
      await shutdown(tester, db);
    });
  });

  group('one offer at a time', () {
    testWidgets('a new one makes the previous one final', (tester) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      expect(hold().isHeld('a'), isTrue);
      await tester.tap(find.byKey(const Key('offer-b')));
      expect(
        hold().isHeld('a'),
        isFalse,
        reason: 'a is final the moment the next one is offered, not later',
      );
      await tester.pumpAndSettle(); // a slides out, b slides in
      expect(hold().isHeld('a'), isFalse, reason: 'a is final, goes up');
      expect(hold().isHeld('b'), isTrue);
      expect(sync.requests, 1);
      expect(find.text('B törölve'), findsOneWidget);
      expect(find.text('A törölve'), findsNothing);
      await tester.tap(find.text('Visszavonás'));
      await tester.pump();
      expect(calls, ['b'], reason: 'only the latest can be taken back');
      await shutdown(tester, db);
    });

    testWidgets('another message closing the bar ends the offer', (
      tester,
    ) async {
      await boot(tester);
      await tapOffer(tester, 'offer-a');
      final messenger = ScaffoldMessenger.of(
        tester.element(find.byType(_Host)),
      );
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('Valami más')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(hold().isHeld('a'), isFalse);
      expect(sync.requests, 1);
      await shutdown(tester, db);
    });
  });

  testWidgets('with no page left to show the bar, the hold is still released '
      'after the window (the bar itself never gets to time out)', (
    tester,
  ) async {
    useSize(tester, size: const Size(400, 800));
    db = await newDb();
    sync = _Sync();
    await tester.pumpWidget(
      app(
        const _Vanishing(),
        db,
        extra: [syncControllerProvider.overrideWith(() => sync)],
      ),
    );
    c = ProviderScope.containerOf(tester.element(find.byType(_Vanishing)));
    await tester.tap(find.text('offer'));
    await tester.pump();
    expect(hold().isHeld('a'), isTrue);
    await tester.pump(const Duration(seconds: 9));
    expect(hold().isHeld('a'), isTrue, reason: 'still inside the window');
    await tester.pump(const Duration(seconds: 3));
    expect(hold().isHeld('a'), isFalse, reason: 'the safety net let it go');
    expect(sync.requests, 1);
    await shutdown(tester, db);
  });

  testWidgets('closing the app with a bar on offer leaves nothing behind', (
    tester,
  ) async {
    await boot(tester);
    await tapOffer(tester, 'offer-a');
    final h = hold();
    await shutdown(tester, db); // no pending timer may be left over
    expect(h.isHeld('a'), isFalse);
  });
}
