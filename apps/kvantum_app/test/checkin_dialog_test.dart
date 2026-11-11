import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/checkin.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

/// The daily check-in: the bar, the form, and that the form fits a phone.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;

  Future<void> boot(WidgetTester tester, {Size? size}) async {
    useSize(tester, size: size ?? const Size(1280, 900));
    db = await newDb();
    await tester.pumpWidget(app(const Scaffold(body: CheckInBanner()), db));
    await tester.pumpAndSettle();
  }

  ProviderContainer ref0(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  testWidgets('without an answer the bar asks; the form needs at least one', (
    tester,
  ) async {
    await boot(tester);
    expect(find.textContaining('Hogy vagy ma?'), findsOneWidget);
    await tester.tap(find.text('Kitöltöm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    expect(find.text('Válaszolj legalább egy kérdésre.'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('the answers are saved under today', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Kitöltöm'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('physical-4')));
    await tester.tap(find.byKey(const Key('sleep-2')));
    await tester.pump();
    await tester.tap(find.text('Mentés'));
    await tester.pumpAndSettle();
    final n = DateTime.now();
    final rec = await tester.runAsync(
      () => ref0(tester)
          .read(recordRepoProvider)
          .get(kindCheckIn, checkInId(DateTime.utc(n.year, n.month, n.day))),
    );
    final v = CheckInView(rec!);
    expect((v.physical, v.sleep, v.mental, v.mood), (4, 2, null, null));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mai check-in: fizikai 4'), findsOneWidget);
    await shutdown(tester, db);
  });

  testWidgets('the form fits a phone screen: the scale labels wrap', (
    tester,
  ) async {
    await boot(tester, size: const Size(360, 700));
    await tester.tap(find.text('Kitöltöm'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sleep-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sleep-5')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shutdown(tester, db);
  });
}
