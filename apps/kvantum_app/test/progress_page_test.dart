import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/charts.dart';
import 'package:kvantum_app/ui/progress_page.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';

/// Wednesday 2026-11-18, 10:00 in Budapest.
DateTime clock() => DateTime.utc(2026, 11, 18, 9);

DateTime d(int y, int m, int day) => floating(y, m, day);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  late AppDatabase db;
  late RecordRepository records;

  Future<void> boot(
    WidgetTester tester, {
    Widget home = const ProgressPage(),
    Size size = const Size(900, 1600),
    double? textScale,
    ThemeData? theme,
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    records = RecordRepository(db);
    await tester.pumpWidget(
      app(
        home,
        db,
        textScale: textScale,
        theme: theme,
        extra: [
          appClockProvider.overrideWithValue(clock),
          midnightTimerProvider.overrideWithValue(ManualTimers().make),
          walletBridgeProvider.overrideWithValue(FakeWallet()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> workout(
    WidgetTester tester,
    String id,
    DateTime day, {
    int minutes = 60,
    String sport = 'gym',
    bool done = true,
    int? body,
    int? mind,
    int? energyStart,
    int? energyEnd,
    int? experience,
  }) async {
    await tester.runAsync(
      () => records.edit(
        kindWorkoutLog,
        id,
        workoutLogFields(
          title: 'Edzés',
          date: day,
          minutes: minutes,
          sport: sport,
          done: done,
          bodyLoad: body,
          mindLoad: mind,
          energyStart: energyStart,
          energyEnd: energyEnd,
          experience: experience,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> checkIn(
    WidgetTester tester,
    DateTime day, {
    int? physical,
    int? mental,
    int? mood,
    int? sleep,
  }) async {
    await tester.runAsync(
      () => records.edit(
        kindCheckIn,
        checkInId(day),
        checkInFields(
          physical: physical,
          mental: mental,
          mood: mood,
          sleep: sleep,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A fortnight of training and check-ins.
  Future<void> seed(WidgetTester tester) async {
    await workout(
      tester,
      'a',
      d(2026, 11, 16),
      body: 4,
      mind: 2,
      energyStart: 4,
      energyEnd: 2,
      experience: 5,
    );
    await workout(tester, 'b', d(2026, 11, 17), minutes: 45, sport: 'futas');
    await workout(tester, 'c', d(2026, 11, 10), minutes: 90, body: 3, mind: 3);
    await workout(tester, 'd', d(2026, 11, 11), done: false);
    for (var i = 0; i < 6; i++) {
      await checkIn(
        tester,
        d(2026, 11, 12 + i),
        physical: 2 + i % 3,
        sleep: 3 + i % 2,
        mood: 4,
      );
    }
  }

  String semanticsOf(WidgetTester tester, Finder f) =>
      tester.getSemantics(f).label;

  group('a week in the table', () {
    WeekVolume week({
      int sessions = 0,
      int skipped = 0,
      int minutes = 0,
      double? body,
      double? mind,
      double? es,
      double? ee,
    }) => WeekVolume(
      monday: d(2026, 11, 16),
      sessions: sessions,
      skipped: skipped,
      minutes: minutes,
      bodyLoad: body,
      mindLoad: mind,
      energyStart: es,
      energyEnd: ee,
    );

    test('a week with nothing', () {
      expect(weekRow(week()), '11.16. héttől: nem volt edzés');
    });

    test('a week with skipped workouts only is not a week with nothing', () {
      expect(
        weekRow(week(skipped: 1)),
        '11.16. héttől: 0 edzés, 0 perc · 1 kihagyva',
      );
    });

    test('one skipped workout is told too', () {
      expect(
        weekRow(week(sessions: 1, minutes: 60, skipped: 1)),
        '11.16. héttől: 1 edzés, 1 óra · 1 kihagyva',
      );
    });

    test('the difficulty of one kind only has a dash for the other', () {
      expect(
        weekRow(week(sessions: 1, minutes: 60, body: 3)),
        '11.16. héttől: 1 edzés, 1 óra · nehézség 3,0 / –',
      );
      expect(
        weekRow(week(sessions: 1, minutes: 60, mind: 2)),
        '11.16. héttől: 1 edzés, 1 óra · nehézség – / 2,0',
      );
    });

    test('the energy needs both ends', () {
      expect(
        weekRow(week(sessions: 1, minutes: 60, es: 4)),
        isNot(contains('energia')),
      );
      expect(
        weekRow(week(sessions: 1, minutes: 60, ee: 2)),
        isNot(contains('energia')),
      );
      expect(
        weekRow(week(sessions: 1, minutes: 60, es: 4, ee: 2.5)),
        '11.16. héttől: 1 edzés, 1 óra · energia 4,0 → 2,5',
      );
    });

    test('the days are written month first, with two digits', () {
      expect(progressDay(d(2026, 3, 5)), '03.05.');
      expect(progressDay(d(2026, 11, 16)), '11.16.');
    });
  });

  group('with nothing to show', () {
    testWidgets('it says so, and draws no chart', (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('progress-empty')), findsOneWidget);
      expect(
        find.text(
          'Még nincs elég adat. A napi check-in és az edzés utáni '
          'visszajelzés kitöltése után itt látod a heti edzésmennyiséget és a trendeket.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('progress-bars')), findsNothing);
      expect(find.byKey(const Key('progress-lines')), findsNothing);
      expect(find.text('Ez a hét'), findsNothing);
      // the periods can be chosen all the same
      expect(find.byKey(const Key('range-12')), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('with a fortnight of data', () {
    testWidgets('the week, the bars, the days, the difficulty, the table', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      expect(find.byKey(const Key('progress-empty')), findsNothing);
      for (final title in [
        'Ez a hét',
        'Heti edzésmennyiség',
        'Hogyan érezted magad',
        'Az edzések nehézsége',
        'Adatok szövegesen',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.byKey(const Key('progress-bars')), findsOneWidget);
      expect(find.byKey(const Key('progress-lines')), findsOneWidget);
      expect(find.byKey(const Key('progress-difficulty')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('the title of the page, and of each section as a heading', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Haladás'),
        ),
        findsOneWidget,
      );
      final type = Theme.of(tester.element(find.byType(ProgressPage)))
          .textTheme;
      for (final title in [
        'Ez a hét',
        'Heti edzésmennyiség',
        'Hogyan érezted magad',
        'Az edzések nehézsége',
        'Adatok szövegesen',
      ]) {
        expect(
          tester.getSemantics(find.text(title)),
          matchesSemantics(label: title, isHeader: true),
          reason: title,
        );
        expect(tester.widget<Text>(find.text(title)).style, type.titleMedium);
      }
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the first line of the week stands out from the rest', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      final type = Theme.of(tester.element(find.byType(ProgressPage)))
          .textTheme;
      expect(
        tester
            .widget<Text>(
              find.text(
                '2 edzés, összesen 1 óra 45 perc (az előző héten 1 edzés, 1 óra 30 perc).',
              ),
            )
            .style,
        type.titleSmall,
      );
      expect(
        tester.widget<Text>(find.text('Az élmény átlaga 5,0/5.')).style,
        type.bodyMedium,
      );
      await shutdown(tester, db);
    });

    testWidgets('on a wide window the page keeps a readable width', (
      tester,
    ) async {
      await boot(tester, size: const Size(1600, 1200));
      await seed(tester);
      expect(tester.getSize(find.byType(ListView)).width, 720);
      await shutdown(tester, db);
    });

    testWidgets(
      'the legend of the difficulty has the shape and colour of each line',
      (tester) async {
        await boot(tester);
        await seed(tester);
        final scheme = Theme.of(tester.element(find.byType(ProgressPage)))
            .colorScheme;
        for (final (name, marker, color) in [
          ('Fizikai nehézség', LineMarker.circle, scheme.primary),
          ('Mentális nehézség', LineMarker.square, scheme.tertiary),
        ]) {
          final row = find.ancestor(
            of: find.text(name),
            matching: find.byWidgetPredicate(
              (w) => w is Row && w.mainAxisSize == MainAxisSize.min,
            ),
          );
          expect(row, findsOneWidget, reason: name);
          final icon = tester.widget<Icon>(
            find.descendant(of: row, matching: find.byType(Icon)),
          );
          expect(icon.icon, marker.icon, reason: name);
          expect(icon.color, color, reason: name);
        }
        await shutdown(tester, db);
      },
    );

    testWidgets('they come in this order, one under the other', (tester) async {
      await boot(tester, size: const Size(900, 4000));
      await seed(tester);
      final tops = [
        for (final title in [
          'Ez a hét',
          'Heti edzésmennyiség',
          'Hogyan érezted magad',
          'Az edzések nehézsége',
          'Adatok szövegesen',
        ])
          tester.getTopLeft(find.text(title)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(5));
      await shutdown(tester, db);
    });

    testWidgets('the bars: the minutes of each week on a round scale', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      final bars = tester.widget<BarChart>(
        find.byKey(const Key('progress-bars')),
      );
      // twelve weeks, the oldest first: from 08.31. to the week of 11.16.
      expect(bars.values, [for (var i = 0; i < 10; i++) 0, 90, 105]);
      expect(bars.maxValue, 120);
      expect(bars.maxLabel, '2 óra');
      expect(bars.firstLabel, '08.31.');
      expect(bars.lastLabel, 'ez a hét');
      expect(
        find.text(
          'Percek hetenként; a jobb szélső oszlop a mostani hét, még nem kész.',
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('a long week stretches the scale to the next full hour', (
      tester,
    ) async {
      await boot(tester);
      await workout(tester, 'a', d(2026, 11, 17), minutes: 150);
      final bars = tester.widget<BarChart>(
        find.byKey(const Key('progress-bars')),
      );
      expect(bars.values.last, 150);
      expect(bars.maxValue, 180);
      expect(bars.maxLabel, '3 óra');
      await shutdown(tester, db);
    });

    testWidgets('this week is told in words, against the one before', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      expect(
        find.text(
          '2 edzés, összesen 1 óra 45 perc (az előző héten 1 edzés, 1 óra 30 perc).',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Kihagyott edzés: 0'), findsNothing);
      expect(
        find.text(
          'Az edzések nehézsége átlagosan: fizikailag 4,0/5, szellemileg 2,0/5.',
        ),
        findsOneWidget,
      );
      await shutdown(tester, db);
    });

    testWidgets('the pictures are described to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-bars'))),
        'Heti edzésmennyiség az utolsó 12 hétben: összesen 3 edzés, '
        '3 óra 15 perc. Ebben a héten 2 edzés, 1 óra 45 perc.',
      );
      final lines = semanticsOf(
        tester,
        find.byKey(const Key('progress-lines')),
      );
      expect(
        lines,
        'Napi közérzet 08.31. és 11.18. között. '
        'Fizikai energia: 6 válasz, átlag 3,0/5, a legutóbbi napokban 3,0/5; '
        'Alvás: 6 válasz, átlag 3,5/5, a legutóbbi napokban 3,5/5.',
      );
      expect(lines, startsWith('Napi közérzet 08.31. és 11.18. között.'));
      expect(lines, contains('Fizikai energia: 6 válasz'));
      expect(lines, contains('Alvás: 6 válasz'));
      expect(lines, isNot(contains('Hangulat')));
      final difficulty = semanticsOf(
        tester,
        find.byKey(const Key('progress-difficulty')),
      );
      expect(difficulty, contains('Fizikai: 2 héten, átlag 3,5/5'));
      expect(difficulty, contains('Mentális: 2 héten, átlag 2,5/5'));
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets(
      'the lines: the answers as dots, their 7-day average as a line',
      (tester) async {
        await boot(tester);
        await seed(tester);
        final context = tester.element(find.byType(ProgressPage));
        final chart = tester.widget<LineChart>(
          find.byKey(const Key('progress-lines')),
        );
        expect(chart.from, d(2026, 8, 31));
        expect(chart.to, d(2026, 11, 18));
        expect(chart.firstLabel, '08.31.');
        expect(chart.lastLabel, 'ma');
        expect(chart.series.map((s) => s.label), ['Fizikai energia', 'Alvás']);
        final physical = chart.series.first;
        expect(physical.marker, LineMarker.circle);
        expect(physical.color, colorOf(context, CheckInMetric.physical));
        expect(physical.markAll, isFalse);
        expect(physical.dots.map((p) => p.value), [2, 3, 4, 2, 3, 4]);
        expect(physical.dots.first.day, d(2026, 11, 12));
        expect(physical.line.map((p) => p.value), [2, 2.5, 3, 2.75, 2.8, 3]);
        final sleep = chart.series.last;
        expect(sleep.marker, LineMarker.diamond);
        expect(sleep.color, colorOf(context, CheckInMetric.sleep));
        expect(
          find.text(
            'A pont egy nap válasza (1 rossz … 5 kiváló), a vonal az utolsó 7 nap átlaga.',
          ),
          findsOneWidget,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets(
      'the difficulty: the weekly averages of the body and the mind',
      (tester) async {
        await boot(tester);
        await seed(tester);
        final scheme = Theme.of(tester.element(find.byType(ProgressPage)))
            .colorScheme;
        final chart = tester.widget<LineChart>(
          find.byKey(const Key('progress-difficulty')),
        );
        expect(chart.from, d(2026, 8, 31));
        expect(chart.to, d(2026, 11, 16));
        expect(chart.firstLabel, '08.31.');
        expect(chart.lastLabel, '11.16.');
        final body = chart.series[0], mind = chart.series[1];
        expect(body.label, 'Fizikai nehézség');
        expect(body.marker, LineMarker.circle);
        expect(body.color, scheme.primary);
        expect(body.markAll, isTrue);
        expect(body.dots, isEmpty);
        expect(body.line, [
          DayValue(d(2026, 11, 9), 3),
          DayValue(d(2026, 11, 16), 4),
        ]);
        expect(mind.label, 'Mentális nehézség');
        expect(mind.marker, LineMarker.square);
        expect(mind.color, scheme.tertiary);
        expect(mind.markAll, isTrue);
        expect(mind.dots, isEmpty);
        expect(mind.line, [
          DayValue(d(2026, 11, 9), 3),
          DayValue(d(2026, 11, 16), 2),
        ]);
        // the legend, and the note under the chart
        expect(find.text('Fizikai nehézség'), findsOneWidget);
        expect(find.text('Mentális nehézség'), findsOneWidget);
        expect(
          find.text(
            'A heti átlag az edzés utáni visszajelzésekből; 1 könnyű, 5 nagyon nehéz.',
          ),
          findsOneWidget,
        );
        await shutdown(tester, db);
      },
    );

    testWidgets('the table gives the weeks with their numbers, newest first', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      await tester.scrollUntilVisible(find.text('Hetek számokkal'), 300);
      await tester.tap(find.text('Hetek számokkal'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '11.16. héttől: 2 edzés, 1 óra 45 perc · nehézség 4,0 / 2,0 · energia 4,0 → 2,0',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '11.09. héttől: 1 edzés, 1 óra 30 perc · 1 kihagyva · nehézség 3,0 / 3,0',
        ),
        findsOneWidget,
      );
      expect(find.text('11.02. héttől: nem volt edzés'), findsOneWidget);
      // newest first
      final tops = [
        for (final monday in ['11.16.', '11.09.', '11.02.'])
          tester.getTopLeft(find.textContaining('$monday héttől')).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(3));
      await shutdown(tester, db);
    });
  });

  group('the period', () {
    testWidgets('four weeks, twelve weeks, half a year', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-bars'))),
        contains('az utolsó 12 hétben'),
      );
      await tester.tap(find.byKey(const Key('range-4')));
      await tester.pumpAndSettle();
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-bars'))),
        contains('az utolsó 4 hétben'),
      );
      await tester.tap(find.byKey(const Key('range-26')));
      await tester.pumpAndSettle();
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-bars'))),
        contains('az utolsó 26 hétben'),
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('the chips say how long', (tester) async {
      await boot(tester);
      for (final (weeks, label) in [
        (4, '4 hét'),
        (12, '12 hét'),
        (26, 'Fél év'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('range-$weeks')),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }
      await shutdown(tester, db);
    });

    testWidgets('the one chosen is marked', (tester) async {
      await boot(tester);
      bool selected(int weeks) =>
          tester.widget<ChoiceChip>(find.byKey(Key('range-$weeks'))).selected;
      expect([selected(4), selected(12), selected(26)], [false, true, false]);
      await tester.tap(find.byKey(const Key('range-4')));
      await tester.pumpAndSettle();
      expect([selected(4), selected(12), selected(26)], [true, false, false]);
      await shutdown(tester, db);
    });
  });

  group('the days that felt', () {
    testWidgets('two metrics to start with, any can be added or taken off', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      bool on(CheckInMetric m) => tester
          .widget<FilterChip>(find.byKey(Key('metric-${m.name}')))
          .selected;
      expect(
        [for (final m in CheckInMetric.values) on(m)],
        [true, false, false, true],
      );

      await tester.tap(find.byKey(const Key('metric-mood')));
      await tester.pumpAndSettle();
      expect(on(CheckInMetric.mood), isTrue);
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-lines'))),
        contains('Hangulat: 6 válasz, átlag 4,0/5'),
      );

      await tester.tap(find.byKey(const Key('metric-sleep')));
      await tester.pumpAndSettle();
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-lines'))),
        isNot(contains('Alvás')),
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('with none chosen it asks for one', (tester) async {
      await boot(tester);
      await seed(tester);
      await tester.tap(find.byKey(const Key('metric-physical')));
      await tester.tap(find.byKey(const Key('metric-sleep')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress-no-metric')), findsOneWidget);
      expect(find.text('Válassz legalább egy mutatót.'), findsOneWidget);
      expect(find.byKey(const Key('progress-lines')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a metric nobody answered says so', (tester) async {
      await boot(tester);
      await seed(tester);
      await tester.tap(find.byKey(const Key('metric-physical')));
      await tester.tap(find.byKey(const Key('metric-sleep')));
      await tester.tap(find.byKey(const Key('metric-mental')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress-no-answer')), findsOneWidget);
      expect(find.text('Ebben az időszakban nem volt válasz.'), findsOneWidget);
      expect(find.byKey(const Key('progress-lines')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('a metric nobody answered is told so to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await seed(tester);
      await tester.tap(find.byKey(const Key('metric-mental')));
      await tester.pumpAndSettle();
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-lines'))),
        contains(
          'Fizikai energia: 6 válasz, átlag 3,0/5, a legutóbbi napokban 3,0/5; '
          'Mentális energia: nincs válasz; Alvás: 6 válasz',
        ),
      );
      handle.dispose();
      await shutdown(tester, db);
    });

    testWidgets('one metric with answers is enough for the lines', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      // (nobody answered the mental energy; the physical energy and the
      // sleep were answered)
      await tester.tap(find.byKey(const Key('metric-mental')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress-lines')), findsOneWidget);
      expect(find.byKey(const Key('progress-no-answer')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('each metric has its own shape, not only its colour', (
      tester,
    ) async {
      await boot(tester);
      await seed(tester);
      final context = tester.element(find.byType(ProgressPage));
      Icon shapeOf(CheckInMetric m) => tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('metric-${m.name}')),
          matching: find.byType(Icon),
        ),
      );
      expect({
        for (final m in CheckInMetric.values) shapeOf(m).icon,
      }, hasLength(4));
      // the shape and the colour of its line
      for (final m in CheckInMetric.values) {
        expect(shapeOf(m).icon, markerOf(m).icon, reason: m.label);
        expect(shapeOf(m).color, colorOf(context, m), reason: m.label);
        // (in the label, not in an avatar: the check mark of a chip that is
        // on would cover it)
        expect(
          tester.widget<FilterChip>(find.byKey(Key('metric-${m.name}'))).avatar,
          isNull,
          reason: m.label,
        );
      }
      await shutdown(tester, db);
    });
  });

  group('only what there is', () {
    testWidgets('no ratings, no difficulty chart', (tester) async {
      await boot(tester);
      await workout(tester, 'a', d(2026, 11, 17));
      expect(find.byKey(const Key('progress-bars')), findsOneWidget);
      expect(find.text('Az edzések nehézsége'), findsNothing);
      expect(find.byKey(const Key('progress-difficulty')), findsNothing);
      await shutdown(tester, db);
    });

    testWidgets('one kind of rating is enough for the difficulty chart', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await boot(tester);
      await workout(tester, 'a', d(2026, 11, 17), body: 3);
      expect(find.byKey(const Key('progress-difficulty')), findsOneWidget);
      expect(
        semanticsOf(tester, find.byKey(const Key('progress-difficulty'))),
        'Az edzések nehézsége hetenként (1 könnyű … 5 nagyon nehéz). '
        'Fizikai: 1 héten, átlag 3,0/5; Mentális: nincs adat.',
      );
      handle.dispose();
      await workout(tester, 'b', d(2026, 11, 10), mind: 4);
      expect(find.byKey(const Key('progress-difficulty')), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a check-in alone is data: the bars stay empty', (
      tester,
    ) async {
      await boot(tester);
      await checkIn(tester, d(2026, 11, 17), mood: 4, physical: 3);
      expect(find.byKey(const Key('progress-empty')), findsNothing);
      expect(find.text('Ebben a héten még nem volt edzés.'), findsOneWidget);
      await shutdown(tester, db);
    });

    testWidgets('a deleted feedback is not counted', (tester) async {
      await boot(tester);
      await workout(tester, 'a', d(2026, 11, 17));
      await tester.runAsync(() => records.delete(kindWorkoutLog, 'a'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress-empty')), findsOneWidget);
      await shutdown(tester, db);
    });
  });

  group('the colours', () {
    testWidgets('each metric has its own colour from the theme', (
      tester,
    ) async {
      await boot(tester);
      final context = tester.element(find.byType(ProgressPage));
      final scheme = Theme.of(context).colorScheme;
      final status = statusColorsOf(context);
      expect(colorOf(context, CheckInMetric.physical), scheme.primary);
      expect(colorOf(context, CheckInMetric.mental), scheme.tertiary);
      expect(colorOf(context, CheckInMetric.mood), status.warn);
      expect(colorOf(context, CheckInMetric.sleep), status.ok);
      expect(markerOf(CheckInMetric.physical), LineMarker.circle);
      expect(markerOf(CheckInMetric.mental), LineMarker.square);
      expect(markerOf(CheckInMetric.mood), LineMarker.triangle);
      expect(markerOf(CheckInMetric.sleep), LineMarker.diamond);
      await shutdown(tester, db);
    });

    for (final dark in [false, true]) {
      testWidgets('the lines can be told from the background, 3 : 1 '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        await boot(
          tester,
          theme: appTheme(dark ? Brightness.dark : Brightness.light),
        );
        final context = tester.element(find.byType(ProgressPage));
        final surface = Theme.of(context).colorScheme.surface;
        for (final m in CheckInMetric.values) {
          expect(
            contrastRatio(colorOf(context, m), surface),
            greaterThanOrEqualTo(3),
            reason: m.label,
          );
        }
        final scheme = Theme.of(context).colorScheme;
        expect(contrastRatio(scheme.primary, surface), greaterThanOrEqualTo(3));
        expect(
          contrastRatio(scheme.tertiary, surface),
          greaterThanOrEqualTo(3),
        );
        await shutdown(tester, db);
      });
    }
  });

  group('big text and the dark theme', () {
    for (final dark in [false, true]) {
      testWidgets('at twice the size on a phone nothing overflows '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        await boot(
          tester,
          size: const Size(360, 640),
          textScale: 2.0,
          theme: appTheme(dark ? Brightness.dark : Brightness.light),
        );
        await seed(tester);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const Key('metric-mood')),
          300,
        );
        await tester.tap(find.byKey(const Key('metric-mood')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Hetek számokkal'), 300);
        await tester.tap(find.text('Hetek számokkal'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await shutdown(tester, db);
      });
    }

    testWidgets('and with nothing to show', (tester) async {
      await boot(tester, size: const Size(360, 640), textScale: 2.0);
      expect(tester.takeException(), isNull);
      await shutdown(tester, db);
    });
  });

  group('the way in', () {
    testWidgets('"Több" has "Haladás", and it opens the page', (tester) async {
      await boot(tester, home: const RootShell(), size: const Size(360, 800));
      await tester.tap(find.byKey(const Key('nav-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-progress')), findsOneWidget);
      expect(find.text('Haladás'), findsOneWidget);
      // after the quick entry, before the shifts and the settings
      final tops = [
        for (final name in ['quick', 'progress', 'shifts', 'settings'])
          tester.getTopLeft(find.byKey(Key('more-$name'))).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(4));
      expect(
        (tester
                    .widget<ListTile>(find.byKey(const Key('more-progress')))
                    .leading!
                as Icon)
            .icon,
        Icons.show_chart,
      );
      await tester.tap(find.byKey(const Key('more-progress')));
      await tester.pumpAndSettle();
      expect(find.byType(ProgressPage), findsOneWidget);
      expect(find.byKey(const Key('progress-empty')), findsOneWidget);
      await shutdown(tester, db);
    });
  });
}
