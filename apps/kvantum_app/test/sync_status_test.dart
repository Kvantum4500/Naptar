import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/diag/diag_snapshot.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_app/ui/diagnostics_page.dart';
import 'package:kvantum_app/ui/sync_status.dart';
import 'package:kvantum_app/update/update_dialog.dart'
    show currentBuildProvider;

/// A controller that only records what the screen asks of it.
class _Ctl extends SyncController {
  _Ctl(this.initial, {this.events = 7});
  final SyncState initial;
  final int events;
  final calls = <String>[];

  @override
  SyncState build() => initial;
  @override
  Future<int> localEventCount() async => events;
  @override
  Future<void> syncNow({bool manual = false}) async =>
      calls.add(manual ? 'now-manual' : 'now');
  @override
  Future<void> resetSync() async => calls.add('reset');
  @override
  Future<void> keepLocalAfterMismatch() async => calls.add('keep');
  @override
  Future<void> startFreshAfterMismatch() async => calls.add('fresh');
  @override
  Future<void> signOut() async => calls.add('out');
}

const _old = RemoteIdentity(account: 'anna@gmail.com', calendar: 'cal-1');
const _new = RemoteIdentity(account: 'bela@gmail.com', calendar: 'cal-2');

SyncState _state({
  SyncBindingMismatch? mismatch,
  int parked = 0,
  DateTime? next,
  String? error,
}) => SyncState(
  configured: true,
  signedIn: true,
  lastSync: DateTime(2026, 11, 11, 12, 30),
  pending: parked,
  parked: parked,
  nextAttempt: next,
  mismatch: mismatch,
  error: error,
);

Future<_Ctl> _pump(
  WidgetTester tester,
  SyncState s, {
  int events = 7,
  List<Override> extra = const [],
}) async {
  final ctl = _Ctl(s, events: events);
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncControllerProvider.overrideWith(() => ctl),
        currentBuildProvider.overrideWith((ref) async => 54),
        ...extra,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: SyncStatusButton(onCheckUpdate: () {})),
        ),
      ),
    ),
  );
  await tester.pump();
  // the build number is read when the details open: have it ready
  final container = ProviderScope.containerOf(
    tester.element(find.byType(SyncStatusButton)),
  );
  await tester.runAsync(() => container.read(currentBuildProvider.future));
  return ctl;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
}

DiagSnapshot _snapshot() => DiagSnapshot(
  at: DateTime(2026, 11, 12, 14, 30),
  build: 54,
  platform: 'windows',
  schema: 4,
  dbBytes: null,
  counts: const {},
  signedIn: true,
  pending: 0,
  parked: 0,
  nextAttempt: null,
  needsDecision: false,
  channels: const {},
  failed: const [],
  requests: const {},
  warnings: const [],
  log: const [],
);

void main() {
  setUpAll(() => initializeDateFormatting('hu'));

  group('the menu', () {
    testWidgets('"Diagnosztika" opens the diagnostics page', (tester) async {
      await _pump(
        tester,
        _state(),
        extra: [diagSnapshotProvider.overrideWith((ref) async => _snapshot())],
      );
      await _openMenu(tester);
      await tester.tap(find.text('Diagnosztika'));
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      expect(find.text('Verzió: build 54'), findsOneWidget);
    });

    testWidgets('without Google the help speaks plainly, not in file names', (
      tester,
    ) async {
      await _pump(tester, const SyncState());
      await tester.tap(find.text('Nincs Google'));
      await tester.pumpAndSettle();
      expect(find.text('Nincs Google-hozzáférés'), findsOneWidget);
      expect(
        find.textContaining('nincs beállítva a Google-bejelentkezés'),
        findsOneWidget,
      );
      expect(find.textContaining('secrets.json'), findsNothing);
      expect(find.textContaining('flutter run'), findsNothing);
    });

    testWidgets('"Szinkron most" is a manual sync', (tester) async {
      final ctl = await _pump(tester, _state());
      await _openMenu(tester);
      await tester.tap(find.text('Szinkron most'));
      await tester.pumpAndSettle();
      expect(ctl.calls, ['now-manual']);
    });

    testWidgets('"Szinkron alaphelyzetbe…" asks first, and only then does it', (
      tester,
    ) async {
      final ctl = await _pump(tester, _state());
      await _openMenu(tester);
      await tester.tap(find.text('Szinkron alaphelyzetbe…'));
      await tester.pumpAndSettle();
      expect(find.text('Szinkron alaphelyzetbe?'), findsOneWidget);
      expect(find.textContaining('Helyben semmi nem törlődik'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reset-cancel')));
      await tester.pumpAndSettle();
      expect(ctl.calls, isEmpty);

      await _openMenu(tester);
      await tester.tap(find.text('Szinkron alaphelyzetbe…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reset-go')));
      await tester.pumpAndSettle();
      expect(ctl.calls, ['reset']);
    });

    testWidgets('no decision is offered while there is nothing to decide', (
      tester,
    ) async {
      await _pump(tester, _state());
      await _openMenu(tester);
      expect(find.textContaining('döntés kell'), findsNothing);
      expect(find.text('Szinkronban 12:30'), findsNothing);
    });

    testWidgets('the details tell when the next try is and what was given up', (
      tester,
    ) async {
      await _pump(
        tester,
        _state(parked: 2, next: DateTime(2026, 11, 11, 12, 45)),
      );
      await _openMenu(tester);
      await tester.tap(find.text('Részletek'));
      // the build number arrives on the real event loop
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Következő automatikus próba: 12:45'),
        findsOneWidget,
      );
      expect(find.textContaining('Ebből feladva: 2'), findsOneWidget);
      expect(find.textContaining('build 54'), findsOneWidget);
    });
  });

  group('another account or calendar', () {
    testWidgets('the button says a decision is needed', (tester) async {
      await _pump(
        tester,
        _state(
          mismatch: const SyncBindingMismatch(stored: _old, current: _new),
        ),
      );
      expect(find.text('Döntés kell'), findsOneWidget);
      expect(find.text('Szinkronban 12:30'), findsNothing);
    });

    testWidgets(
      'the question names both accounts, hidden, and offers three ways',
      (tester) async {
        await _pump(
          tester,
          _state(
            mismatch: const SyncBindingMismatch(stored: _old, current: _new),
          ),
        );
        await _openMenu(tester);
        await tester.tap(
          find.textContaining('Másik fiók / naptár: döntés kell'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Másik Google-fiók'), findsOneWidget);
        expect(find.textContaining('a***@gmail.com'), findsOneWidget);
        expect(find.textContaining('b***@gmail.com'), findsOneWidget);
        expect(find.textContaining('anna'), findsNothing, reason: 'masked');
        expect(find.textContaining('bela'), findsNothing, reason: 'masked');
        expect(find.byKey(const Key('binding-later')), findsOneWidget);
        expect(find.byKey(const Key('binding-fresh')), findsOneWidget);
        expect(find.byKey(const Key('binding-keep')), findsOneWidget);
      },
    );

    testWidgets(
      'a calendar change in the same account is called by its own name',
      (tester) async {
        const sameAccount = RemoteIdentity(
          account: 'anna@gmail.com',
          calendar: 'cal-9',
        );
        await _pump(
          tester,
          _state(
            mismatch: const SyncBindingMismatch(
              stored: _old,
              current: sameAccount,
            ),
          ),
        );
        await _openMenu(tester);
        await tester.tap(find.textContaining('döntés kell'));
        await tester.pumpAndSettle();
        expect(find.text('A Google-naptár megváltozott'), findsOneWidget);
        expect(
          find.textContaining('törölték vagy újra létrehozták'),
          findsOneWidget,
        );
      },
    );

    testWidgets('keeping the local events is one tap and deletes nothing', (
      tester,
    ) async {
      final ctl = await _pump(
        tester,
        _state(
          mismatch: const SyncBindingMismatch(stored: _old, current: _new),
        ),
      );
      await _openMenu(tester);
      await tester.tap(find.textContaining('döntés kell'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('binding-keep')));
      await tester.pumpAndSettle();
      expect(ctl.calls, ['keep']);
    });

    testWidgets('"Később" does nothing', (tester) async {
      final ctl = await _pump(
        tester,
        _state(
          mismatch: const SyncBindingMismatch(stored: _old, current: _new),
        ),
      );
      await _openMenu(tester);
      await tester.tap(find.textContaining('döntés kell'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('binding-later')));
      await tester.pumpAndSettle();
      expect(ctl.calls, isEmpty);
    });

    testWidgets(
      'a fresh start names the number of events and needs a second yes',
      (tester) async {
        final ctl = await _pump(
          tester,
          _state(
            mismatch: const SyncBindingMismatch(stored: _old, current: _new),
          ),
          events: 12,
        );
        await _openMenu(tester);
        await tester.tap(find.textContaining('döntés kell'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('binding-fresh')));
        await tester.pumpAndSettle();
        expect(find.textContaining('12 esemény törlődik'), findsOneWidget);
        expect(ctl.calls, isEmpty, reason: 'not yet');

        await tester.tap(find.byKey(const Key('fresh-cancel')));
        await tester.pumpAndSettle();
        expect(ctl.calls, isEmpty);

        await _openMenu(tester);
        await tester.tap(find.textContaining('döntés kell'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('binding-fresh')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('fresh-go')));
        await tester.pumpAndSettle();
        expect(ctl.calls, ['fresh']);
      },
    );

    testWidgets('with no local events there is nothing to confirm', (
      tester,
    ) async {
      final ctl = await _pump(
        tester,
        _state(
          mismatch: const SyncBindingMismatch(stored: _old, current: _new),
        ),
        events: 0,
      );
      await _openMenu(tester);
      await tester.tap(find.textContaining('döntés kell'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('binding-fresh')));
      await tester.pumpAndSettle();
      expect(ctl.calls, ['fresh']);
    });

    testWidgets('on a phone-width screen the question fits', (tester) async {
      final ctl = _Ctl(
        _state(
          mismatch: const SyncBindingMismatch(stored: _old, current: _new),
        ),
      );
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncControllerProvider.overrideWith(() => ctl),
            currentBuildProvider.overrideWith((ref) async => 54),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SyncStatusButton(onCheckUpdate: () {}, compact: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await _openMenu(tester);
      await tester.tap(find.textContaining('döntés kell'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('binding-keep')), findsOneWidget);
    });
  });
}
