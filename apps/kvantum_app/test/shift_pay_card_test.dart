import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/shift_page.dart';
import 'package:kvantum_app/ui/shift_pay_card.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

typedef Ev = ({String title, String notes, DateTime start, DateTime end});

Ev night(int y, int mo, int d) => (
  title: 'Éjszakai műszak',
  notes: kShiftMarker,
  start: floating(y, mo, d, 18),
  end: floating(y, mo, d, 18).add(const Duration(hours: 12)),
);

Ev day(int y, int mo, int d, {int hours = 12, int extra = 0}) => (
  title: 'Nappali műszak',
  notes: kShiftMarker,
  start: floating(y, mo, d, 6),
  end: floating(y, mo, d, 6).add(Duration(hours: hours, minutes: extra)),
);

const set = PaySettings(
  hourly: 2000,
  eveningPct: 30,
  nightPct: 40,
  saturdayPct: 20,
  sundayPct: 50,
  holidayPct: 100,
);

class _Day extends SelectedDay {
  _Day(this.d);
  final DateTime d;
  @override
  DateTime build() => d;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('the card', () {
    late AppDatabase db;
    late ProviderContainer c;

    /// The card alone, on a page of its own, with [stored] on the device.
    Future<void> mount(
      WidgetTester tester, {
      PaySettings? stored,
      List<Ev> events = const [],
      int year = 2026,
      int month = 11,
      Size size = const Size(700, 1600),
      double? textScale,
    }) async {
      useSize(tester, size: size);
      db = await newDb();
      if (stored != null) {
        await tester.runAsync(
          () => RecordRepository(db).setMeta(paySettingsKey, stored.encode()),
        );
      }
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: ShiftPayCard(events: events, year: year, month: month),
            ),
          ),
          db,
          textScale: textScale,
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(ShiftPayCard)));
    }

    Future<String?> meta(WidgetTester tester) async {
      String? value;
      await tester.runAsync(() async {
        value = await c.read(recordRepoProvider).meta(paySettingsKey);
      });
      return value;
    }

    Future<void> done(WidgetTester tester) => shutdown(tester, db);

    testWidgets('with nothing set it invites the user to set it', (
      tester,
    ) async {
      await mount(tester, events: [night(2026, 11, 10)]);
      expect(find.text('Bérbecslés: 2026. november'), findsOneWidget);
      expect(find.textContaining('Add meg az órabéredet'), findsOneWidget);
      expect(find.byKey(const Key('pay-set')), findsOneWidget);
      expect(find.byKey(const Key('pay-total')), findsNothing);
      await done(tester);
    });

    testWidgets('set, but no shift that month: nothing to count', (
      tester,
    ) async {
      await mount(tester, stored: set, events: [night(2026, 10, 10)]);
      expect(
        find.text('Ebben a hónapban nincs műszak, nincs mit számolni.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pay-total')), findsNothing);
      await done(tester);
    });

    testWidgets('the lines of a night, and the total', (tester) async {
      await mount(tester, stored: set, events: [night(2026, 11, 10)]);
      String hu(int n) => formatHuf(n);
      expect(find.text('Alapbér'), findsOneWidget);
      expect(find.text('12 óra'), findsOneWidget);
      expect(find.text(hu(24000)), findsOneWidget);
      expect(find.text('Esti pótlék (18–22)'), findsOneWidget);
      expect(find.text('4 óra × 30%'), findsOneWidget);
      expect(find.text(hu(2400)), findsOneWidget);
      expect(find.text('Éjszakai pótlék (22–6)'), findsOneWidget);
      expect(find.text('8 óra × 40%'), findsOneWidget);
      expect(find.text(hu(6400)), findsOneWidget);
      expect(find.text('Összesen (bruttó becslés)'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('pay-total'))).data,
        hu(32800),
      );
      // it says what it is, and where the data stays
      expect(find.textContaining('nem bérszámfejtés'), findsOneWidget);
      expect(find.textContaining('nem szinkronizálódnak'), findsOneWidget);
      await done(tester);
    });

    testWidgets('minutes are told as hours and minutes', (tester) async {
      await mount(
        tester,
        stored: set,
        events: [day(2026, 11, 10, hours: 7, extra: 30)],
      );
      expect(find.text('Alapbér'), findsOneWidget);
      expect(find.text('7 ó 30 p'), findsOneWidget);
      expect(payHoursLabel(720), '12 óra');
      expect(payHoursLabel(450), '7 ó 30 p');
      expect(payHoursLabel(61), '1 ó 1 p');
      expect(payHoursLabel(0), '0 óra');
      await done(tester);
    });

    testWidgets('Sundays and holidays have their own lines', (tester) async {
      await mount(
        tester,
        stored: set,
        events: [day(2026, 11, 15), day(2026, 11, 1)],
      );
      expect(find.text('Vasárnapi pótlék'), findsOneWidget);
      expect(find.text('12 óra × 50%'), findsOneWidget);
      expect(find.text('Ünnepnapi pótlék'), findsOneWidget);
      expect(find.text('12 óra × 100%'), findsOneWidget);
      expect(find.text('24 óra'), findsOneWidget); // the base pay of both
      await done(tester);
    });

    testWidgets('the month it is asked about is the month it counts', (
      tester,
    ) async {
      await mount(
        tester,
        stored: set,
        events: [night(2026, 11, 10), day(2026, 12, 3)],
        month: 12,
      );
      expect(find.text('Bérbecslés: 2026. december'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('pay-total'))).data,
        formatHuf(24000),
      );
      await done(tester);
    });

    group('the dialog', () {
      Future<void> open(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('pay-open')));
        await tester.pumpAndSettle();
      }

      TextField field(WidgetTester tester, String key) =>
          tester.widget<TextField>(find.byKey(Key(key)));

      testWidgets('empty fields at first, then what was saved', (tester) async {
        await mount(tester);
        await open(tester);
        for (final k in [
          'pay-hourly',
          'pay-evening',
          'pay-night',
          'pay-saturday',
          'pay-sunday',
          'pay-holiday',
        ]) {
          expect(field(tester, k).controller!.text, '', reason: k);
        }
        await tester.tap(find.text('Mégse'));
        await tester.pumpAndSettle();
        await done(tester);
      });

      testWidgets('it shows what is set', (tester) async {
        await mount(tester, stored: set);
        await open(tester);
        expect(field(tester, 'pay-hourly').controller!.text, '2000');
        expect(field(tester, 'pay-evening').controller!.text, '30');
        expect(field(tester, 'pay-night').controller!.text, '40');
        expect(field(tester, 'pay-saturday').controller!.text, '20');
        expect(field(tester, 'pay-sunday').controller!.text, '50');
        expect(field(tester, 'pay-holiday').controller!.text, '100');
        await tester.tap(find.text('Mégse'));
        await tester.pumpAndSettle();
        await done(tester);
      });

      testWidgets('the rules are folded away until they are asked for', (
        tester,
      ) async {
        await mount(tester);
        await open(tester);
        expect(find.text('Hogyan számol?'), findsOneWidget);
        expect(
          find.textContaining('A pótlék a sávban ledolgozott órákra'),
          findsNothing,
        );
        await tester.tap(find.text('Hogyan számol?'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('A pótlék a sávban ledolgozott órákra'),
          findsOneWidget,
        );
        expect(
          find.textContaining('írd be mindkét sávba ugyanazt'),
          findsOneWidget,
        );
        await tester.tap(find.text('Mégse'));
        await tester.pumpAndSettle();
        await done(tester);
      });

      testWidgets('saving keeps it on the device, and the card follows', (
        tester,
      ) async {
        await mount(tester, events: [night(2026, 11, 10)]);
        await open(tester);
        await tester.enterText(find.byKey(const Key('pay-hourly')), '2000');
        await tester.enterText(find.byKey(const Key('pay-evening')), '30');
        await tester.enterText(find.byKey(const Key('pay-night')), '40');
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const Key('pay-total'))).data,
          formatHuf(32800),
        );
        expect(
          PaySettings.decode(await meta(tester)),
          const PaySettings(hourly: 2000, eveningPct: 30, nightPct: 40),
        );
        await done(tester);
      });

      testWidgets('only digits can be typed', (tester) async {
        await mount(tester);
        await open(tester);
        await tester.enterText(find.byKey(const Key('pay-hourly')), 'a2,5 0b');
        expect(field(tester, 'pay-hourly').controller!.text, '250');
        await tester.tap(find.text('Mégse'));
        await tester.pumpAndSettle();
        await done(tester);
      });

      testWidgets('too much is refused and says so, nothing is saved', (
        tester,
      ) async {
        await mount(tester, stored: set);
        await open(tester);
        await tester.enterText(find.byKey(const Key('pay-hourly')), '1000001');
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pay-error')), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(PaySettings.decode(await meta(tester)), set);

        // the same for a premium, and the largest values are fine
        await tester.enterText(find.byKey(const Key('pay-hourly')), '1000000');
        await tester.enterText(find.byKey(const Key('pay-night')), '1001');
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pay-error')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('pay-night')), '1000');
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final saved = PaySettings.decode(await meta(tester));
        expect((saved.hourly, saved.nightPct), (1000000, 1000));
        await done(tester);
      });

      testWidgets('cancelling changes nothing', (tester) async {
        await mount(tester, stored: set);
        await open(tester);
        await tester.enterText(find.byKey(const Key('pay-hourly')), '1');
        await tester.tap(find.text('Mégse'));
        await tester.pumpAndSettle();
        expect(PaySettings.decode(await meta(tester)), set);
        await done(tester);
      });

      testWidgets('clearing takes it all off the device', (tester) async {
        await mount(tester, stored: set, events: [night(2026, 11, 10)]);
        await open(tester);
        await tester.tap(find.byKey(const Key('pay-clear')));
        await tester.pumpAndSettle();
        expect(await meta(tester), isNull);
        expect(find.byKey(const Key('pay-set')), findsOneWidget);
        expect(find.byKey(const Key('pay-total')), findsNothing);
        await done(tester);
      });

      testWidgets('empty fields are zero', (tester) async {
        await mount(tester, stored: set);
        await open(tester);
        await tester.enterText(find.byKey(const Key('pay-night')), '');
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pumpAndSettle();
        expect(
          PaySettings.decode(await meta(tester)),
          set.copyWith(nightPct: 0),
        );
        await done(tester);
      });

      testWidgets(
        'on a narrow screen with the largest text nothing overflows',
        (tester) async {
          await mount(
            tester,
            stored: set,
            events: [night(2026, 11, 14), day(2026, 11, 15)],
            size: const Size(360, 800),
            textScale: 2.0,
          );
          expect(tester.takeException(), isNull);
          await open(tester);
          expect(find.byKey(const Key('pay-hourly')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Mégse'));
          await tester.pumpAndSettle();
          await done(tester);
        },
      );
    });
  });

  group('on the Shifts page', () {
    late AppDatabase db;

    Future<void> boot(WidgetTester tester, {PaySettings? stored}) async {
      useSize(tester, size: const Size(900, 2200));
      db = await newDb();
      await tester.runAsync(() async {
        final repo = EventRepository(db);
        for (final e in [
          night(2026, 11, 10),
          day(2026, 11, 15),
          day(2026, 12, 3),
        ]) {
          await repo.saveLocal(
            CalEvent(
              id: '${e.title}-${e.start.toIso8601String()}',
              calendarId: kNaptarCalendar,
              title: e.title,
              notes: e.notes,
              start: e.start,
              end: e.end,
              tzid: bp,
            ),
          );
        }
        if (stored != null) {
          await RecordRepository(db).setMeta(paySettingsKey, stored.encode());
        }
      });
      await tester.pumpWidget(
        app(
          const ShiftPage(),
          db,
          extra: [
            selectedDayProvider.overrideWith(
              () => _Day(floating(2026, 11, 12)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    Finder total() => find.byKey(const Key('pay-total'));

    testWidgets('it is under the summary and follows its month', (
      tester,
    ) async {
      await boot(tester, stored: set);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pay-card')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Bérbecslés: 2026. november'), findsOneWidget);
      // the night of the 10th and the Sunday of the 15th
      expect(
        tester.widget<Text>(total()).data,
        formatHuf(32800 + 24000 + 12000),
      );
      // the summary comes first, then the card
      expect(
        tester.getTopLeft(find.textContaining('Havi összesítő')).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('pay-card'))).dy),
      );

      await tester.tap(find.byTooltip('Következő hónap'));
      await tester.pumpAndSettle();
      expect(find.text('Bérbecslés: 2026. december'), findsOneWidget);
      expect(tester.widget<Text>(total()).data, formatHuf(24000));

      await tester.tap(find.byTooltip('Előző hónap'));
      await tester.tap(find.byTooltip('Előző hónap'));
      await tester.pumpAndSettle();
      expect(find.text('Bérbecslés: 2026. október'), findsOneWidget);
      expect(
        find.text('Ebben a hónapban nincs műszak, nincs mit számolni.'),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('without settings it only invites', (tester) async {
      await boot(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pay-card')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('pay-set')), findsOneWidget);
      expect(total(), findsNothing);
      await shutdown(tester, db);
    });
  });

  group('the data stays on the device', () {
    test('only the Shifts page and its card know of the pay settings', () {
      // (a structural guard: whatever reads them could send them somewhere)
      final lib = Directory('lib');
      final users = <String>[];
      for (final f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        if (text.contains('paySettingsKey') ||
            text.contains('paySettingsProvider') ||
            text.contains('pay.settings') ||
            text.contains('PaySettings')) {
          users.add(f.path.replaceAll('\\', '/'));
        }
      }
      expect(users..sort(), ['lib/ui/shift_pay_card.dart']);
    });

    test('the key is the one of the notes kept only here', () {
      expect(paySettingsKey, 'pay.settings');
    });
  });
}
