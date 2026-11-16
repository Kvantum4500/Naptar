import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/assistant_page.dart';
import 'package:kvantum_app/ai/handbook_page.dart';
import 'package:kvantum_app/ai/handbook_store.dart';
import 'package:kvantum_app/ai/llm_provider.dart';
import 'package:kvantum_app/ai/provider_catalog.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/ai/workout_providers.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/data/finance_repository.dart';
import 'package:kvantum_app/data/record_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/checkin.dart';
import 'package:kvantum_app/ui/diagnostics_page.dart';
import 'package:kvantum_app/ui/finance/finance_page.dart';
import 'package:kvantum_app/ui/home_page.dart';
import 'package:kvantum_app/ui/intake/intake_page.dart';
import 'package:kvantum_app/ui/journal/journal_tab.dart';
import 'package:kvantum_app/ui/root_shell.dart';
import 'package:kvantum_app/ui/search_page.dart';
import 'package:kvantum_app/ui/setup_guide.dart';
import 'package:kvantum_app/ui/shift_page.dart';
import 'package:kvantum_app/ui/sync_status.dart';
import 'package:kvantum_app/ui/tasks_page.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_app/ui/workout_feedback.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/fake_llm.dart';
import 'support/fake_wallet.dart';
import 'support/harness.dart';
import 'support/manual_timers.dart';
import 'support/real_fonts.dart';

// Everything on screen with the system's font size at its largest (200 %),
// in Roboto (the font Android draws the app in; the test font, Ahem, is a
// square per letter and says nothing about heights). A fixed height or a Row
// without room for its text shows up as a layout error; none may.

const _scale = 2.0;
const _phone = Size(360, 800);
const _small = Size(360, 640);
const _phoneTall = Size(360, 4200);
const _wide = Size(1280, 900);
const _wideTall = Size(1280, 3200);

final _skip = robotoAvailable
    ? null
    : 'Roboto not found in the Flutter SDK cache: the check needs real text '
          'metrics';

/// Every layout error [body] reported, one line each (the first line says how
/// far, the rest where).
Future<List<String>> layoutErrors(Future<void> Function() body) async {
  final found = <String>{};
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => found.add(_brief(d));
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return found.toList()..sort();
}

String _brief(FlutterErrorDetails d) {
  final text = d.toDiagnosticsNode().toStringDeep();
  final over = RegExp(r'overflowed by ([\d.]+) pixels on the (\w+)')
      .firstMatch(text);
  final where = RegExp(r'error-causing widget was:\s*\n\s*(.+)\n\s*(.+)')
      .firstMatch(text);
  final head = over?.group(0) ?? text.split('\n').take(4).join(' | ');
  final at = where == null
      ? ''
      : ' -- ${where.group(1)} ${where.group(2)?.trim()}'.replaceAll(
          RegExp(r'file:///[^ ]*?/lib/'),
          'lib/',
        );
  return '$head$at';
}

/// A model that lists one model (the assistant needs one to ask).
class _Llm extends FakeLlm {
  _Llm(super.script);

  @override
  Future<List<LlmModel>> listModels() async => const [
    LlmModel('gemini-2.5-flash', 'Flash'),
  ];
}

/// With KVANTUM_SHOTS set to a folder, every scene also leaves a picture of the
/// screen there (Roboto, the real icons): a way to look at what the layout
/// check passes.
final _shotKey = GlobalKey();

Future<void> _shoot(WidgetTester tester, String name) async {
  final dir = Platform.environment['KVANTUM_SHOTS'];
  if (dir == null || dir.isEmpty) return;
  final boundary = _shotKey.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9×@._-]+'), '_');
    File('$dir/$safe.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes.buffer.asUint8List());
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
    if (robotoAvailable) await loadRoboto();
  });

  late AppDatabase db;
  late EventRepository events;
  late RecordRepository records;
  late FinanceRepository fin;

  /// A busy week around Thursday 2026-11-12, with long Hungarian names.
  Future<void> seedAll() async {
    await fin.ensureDefaults();
    await events.saveAll([
      evt(
        'e1',
        'Reggeli edzés és nyújtás a Duna-parton',
        floating(2026, 11, 12, 7),
        len: const Duration(minutes: 90),
      ).copyWith(location: 'Margitsziget, a futókör bejáratánál'),
      evt('e2', 'Megbeszélés a lakásfelújításról', floating(2026, 11, 12, 10)),
      evt('e3', 'Ebéd Gáborral és Katival', floating(2026, 11, 12, 12)),
      evt('e4', 'Fogorvosi kontroll és fogkő', floating(2026, 11, 12, 14)),
      evt('e5', 'Hétvégi bevásárlás tervezése', floating(2026, 11, 12, 16)),
      evt(
        'e6',
        'Szabadnap – családi program',
        floating(2026, 11, 12),
        allDay: true,
        len: const Duration(days: 1),
      ),
      evt(
        'e7',
        'Éjszakás műszak a kórházban',
        floating(2026, 11, 12, 18),
        len: const Duration(hours: 12),
      ),
      evt('e8', 'Heti bevásárlás és főzés', floating(2026, 11, 13, 17)),
      evt(
        'e9',
        'Konferencia utazással együtt',
        floating(2026, 11, 14),
        allDay: true,
        len: const Duration(days: 3),
      ),
      evt(
        'e10',
        'Kajak edzés a Dunán, hosszú táv',
        floating(2026, 11, 15, 9),
        rrule: 'FREQ=WEEKLY;BYDAY=SU',
        len: const Duration(hours: 2),
      ),
    ]);
    for (final (id, title, due, done) in [
      (
        't1',
        'Számla befizetése a közműszolgáltatónak',
        floating(2026, 11, 9),
        false,
      ),
      ('t2', 'Gyógyszertár: receptek kiváltása', floating(2026, 11, 12), false),
      (
        't3',
        'Útlevél megújítása és fotók elkészítése',
        floating(2026, 11, 20),
        false,
      ),
      ('t4', 'Ötletek gyűjtése a nyaraláshoz', null, false),
      ('t5', 'Régi dolgok kidobása', null, true),
    ]) {
      await records.edit(
        kindTask,
        id,
        taskFields(title: title, due: due, done: done),
      );
    }
    await records.edit(
      kindCheckIn,
      '2026-11-11',
      checkInFields(
        physical: 2,
        mental: 4,
        mood: 3,
        sleep: 5,
        note: 'Kicsit fáradt voltam az éjszakás műszak után',
      ),
    );
    // the food and fluid log: a long name, macros, drinks, goals
    final today = DateTime.utc(2026, 11, 12);
    for (final f in [
      FoodEntry.checked(
        id: 'f1',
        day: today,
        minute: 7 * 60 + 30,
        meal: Meal.breakfast,
        name: 'Zabkása tejjel, banánnal és mogyoróvajjal',
        kcal: 520,
        protein: 22,
        carbs: 68,
        fat: 18,
      ),
      FoodEntry.checked(
        id: 'f2',
        day: today,
        minute: 12 * 60 + 15,
        meal: Meal.lunch,
        name: 'Töltött káposzta tejföllel és friss kenyérrel',
        kcal: 950,
      ),
      FoodEntry.checked(
        id: 'f3',
        day: today,
        minute: 16 * 60,
        meal: Meal.snack,
        kcal: 180,
      ),
      FoodEntry.checked(
        id: 'f4',
        day: DateTime.utc(2026, 11, 11),
        minute: 19 * 60,
        meal: Meal.dinner,
        name: 'Rakott krumpli',
        kcal: 2300,
      ),
    ]) {
      await records.edit(kindIntake, intakeMonthId(f.day), f.fields);
    }
    for (final w in [
      FluidEntry.checked(id: 'w1', day: today, minute: 8 * 60, ml: 300),
      FluidEntry.checked(
        id: 'w2',
        day: today,
        minute: 9 * 60 + 40,
        ml: 250,
        kind: DrinkKind.coffee,
      ),
      FluidEntry.checked(
        id: 'w3',
        day: today,
        minute: 14 * 60,
        ml: 500,
        kind: DrinkKind.tea,
      ),
    ]) {
      await records.edit(kindIntake, intakeMonthId(w.day), w.fields);
    }
    await records.edit(
      kindSettings,
      settingsGoalsId,
      const IntakeGoals(
        kcal: 2200,
        protein: 150,
        carbs: 250,
        fat: 70,
        ml: 2500,
      ).toFields(),
    );
    final food = {'cat-food': 'Nagybevásárlás a hétvégére', 'cat-fun': 'Mozi'};
    var n = 0;
    for (final e in food.entries) {
      await fin.saveTx(
        FinTx(
          id: 'x${n++}',
          date: floating(2026, 11, 3 + n),
          amount: 8500 * n,
          kind: FinKind.expense,
          categoryId: e.key,
          merchant: e.value,
          note: 'Megjegyzés egy hosszabb szöveggel, hogy lássuk a sortörést',
        ),
      );
    }
    await fin.saveTx(
      FinTx(
        id: 'inc',
        date: floating(2026, 11, 5),
        amount: 520000,
        kind: FinKind.income,
        categoryId: 'cat-salary',
        merchant: 'Munkahelyi fizetés és pótlékok',
      ),
    );
    await fin.saveBudget(const FinBudget(categoryId: 'cat-food', limit: 40000));
    await fin.saveBudget(const FinBudget(categoryId: 'cat-fun', limit: 10000));
    await fin.saveRecurring(
      FinRecurring(
        id: 'r1',
        title: 'Lakbér és közös költség havonta',
        amount: 120000,
        kind: FinKind.expense,
        categoryId: 'cat-housing',
        dayOfMonth: 5,
        fromMonth: floating(2026, 1, 1),
      ),
    );
    await fin.saveGoal(
      FinGoal(
        id: 'g1',
        name: 'Nyaralás a tengerparton jövő nyáron',
        target: 600000,
        deadline: floating(2027, 6, 1),
      ),
    );
    await fin.saveDeposit(
      FinDeposit(
        id: 'd1',
        goalId: 'g1',
        date: floating(2026, 11, 2),
        amount: 150000,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    Size size = _wide,
    bool dark = false,
    bool seed = true,
    bool guide = false,
    String? apiKey,
    LLMProvider? llm,
  }) async {
    useSize(tester, size: size);
    db = await newDb();
    events = EventRepository(db);
    records = RecordRepository(db);
    fin = FinanceRepository(db);
    if (seed) await tester.runAsync(seedAll);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: app(
          home,
          db,
          textScale: _scale,
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          extra: [
            // Thursday 2026-11-12, 10:00 in Budapest
            appClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            aiClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 11, 12, 9),
            ),
            midnightTimerProvider.overrideWithValue(ManualTimers().make),
            setupGuideProvider.overrideWithValue(guide),
            walletBridgeProvider.overrideWithValue(FakeWallet()),
            apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(apiKey)),
            if (llm != null) llmFactoryProvider.overrideWithValue((cfg) => llm),
            currentBuildProvider.overrideWith((ref) async => 7),
            handbookStoreProvider.overrideWith(
              (ref) => HandbookStore(
                ref.watch(recordRepoProvider),
                loader: (p) async => 'ALAP[$p]',
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Runs one scene at the large text size, at each of [sizes], and expects
  /// no layout error.
  void sceneAt(
    String name,
    Future<void> Function(WidgetTester tester, Size size) body, {
    List<Size> sizes = const [_phone, _wide],
  }) {
    for (final size in sizes) {
      testWidgets('$name @ ${size.width.toInt()}×${size.height.toInt()}', (
        tester,
      ) async {
        final errors = await layoutErrors(() async {
          await body(tester, size);
          // (one more frame: layout errors come with the paint)
          await tester.pump(const Duration(milliseconds: 50));
          await _shoot(
            tester,
            '$name @ ${size.width.toInt()}×${size.height.toInt()}',
          );
        });
        expect(errors, isEmpty, reason: errors.join('\n'));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(db.close);
      }, skip: _skip != null);
    }
  }

  ProviderContainer containerOf(WidgetTester tester, Type page) =>
      ProviderScope.containerOf(tester.element(find.byType(page)));

  /// A tab of the money page (the bar scrolls: bring the tab into view first).
  Future<void> openTab(WidgetTester tester, String name) async {
    final tab = find.text(name).first;
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  group('the calendar', () {
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      sceneAt('month, $mode', (tester, size) async {
        await show(tester, const HomePage(), size: size, dark: dark);
      }, sizes: dark ? const [_phone, _wide] : const [_small, _phone, _wide]);
    }
    sceneAt('month with the first-run guide', (tester, size) async {
      await show(tester, const HomePage(), size: size, guide: true);
    }, sizes: const [_small, _phone, _wide]);
    sceneAt('week', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      containerOf(
        tester,
        HomePage,
      ).read(viewModeProvider.notifier).set(CalView.week);
      await tester.pumpAndSettle();
    }, sizes: const [_small, _phone, _wide]);
    sceneAt('day', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      containerOf(
        tester,
        HomePage,
      ).read(viewModeProvider.notifier).set(CalView.day);
      await tester.pumpAndSettle();
    });
    sceneAt('agenda', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      containerOf(
        tester,
        HomePage,
      ).read(viewModeProvider.notifier).set(CalView.agenda);
      await tester.pumpAndSettle();
    });
    sceneAt('search', (tester, size) async {
      await show(tester, const SearchPage(), size: size);
      await tester.enterText(find.byType(TextField), 'edzés');
      await tester.pumpAndSettle();
    });
    sceneAt('the shift page', (tester, size) async {
      await show(tester, const ShiftPage(), size: size);
    }, sizes: const [_phoneTall, _wideTall]);
  });

  group('the shell', () {
    sceneAt('bottom bar / rail', (tester, size) async {
      await show(tester, const RootShell(), size: size);
    });
    sceneAt('"Több" menu', (tester, size) async {
      await show(tester, const RootShell(), size: size);
      await tester.tap(find.text('Több'));
      await tester.pumpAndSettle();
    });
  });

  group('the Napló tab', () {
    sceneAt('the entries', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
    });
    sceneAt('food and fluids', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
    }, sizes: const [_phoneTall, _wide]);
    sceneAt('food and fluids, dark', (tester, size) async {
      await show(tester, const JournalTab(), size: size, dark: true);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
    }, sizes: const [_phoneTall]);
    sceneAt('a month of food and fluids', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('trend-30')));
      await tester.pumpAndSettle();
    }, sizes: const [_phoneTall]);
    sceneAt('the food form', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intake-add-food')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('food-macros-toggle')));
      await tester.pumpAndSettle();
    });
    sceneAt('the drink form', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
      // (the list builds what is near: scroll to the quick buttons)
      await tester.scrollUntilVisible(
        find.byKey(const Key('drink-other')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(IntakePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drink-other')));
      await tester.pumpAndSettle();
    });
    sceneAt('the goals form', (tester, size) async {
      await show(tester, const JournalTab(), size: size);
      await tester.tap(find.byKey(const Key('journal-tab-intake')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intake-goals')));
      await tester.pumpAndSettle();
    });
  });

  group('tasks and money', () {
    sceneAt('tasks', (tester, size) async {
      await show(tester, const TasksPage(), size: size);
    }, sizes: const [_phoneTall, _wide]);
    for (final tab in [
      'Áttekintés',
      'Tételek',
      'Keretek',
      'Ismétlődők',
      'Célok',
    ]) {
      sceneAt('money: $tab', (tester, size) async {
        await show(tester, const FinancePage(), size: size);
        await openTab(tester, tab);
      }, sizes: const [_phoneTall, _wide]);
    }
    // the editors the money pages open
    sceneAt('money: new transaction', (tester, size) async {
      await show(tester, const FinancePage(), size: size);
      await openTab(tester, 'Tételek');
      await tester.tap(find.byTooltip('Új tétel'));
      await tester.pumpAndSettle();
    });
    sceneAt('money: a budget', (tester, size) async {
      await show(tester, const FinancePage(), size: size);
      await openTab(tester, 'Keretek');
      await tester.tap(find.byTooltip('Keret beállítása').first);
      await tester.pumpAndSettle();
    });
    sceneAt('money: new recurring item', (tester, size) async {
      await show(tester, const FinancePage(), size: size);
      await openTab(tester, 'Ismétlődők');
      await tester.tap(find.byTooltip('Új ismétlődő tétel'));
      await tester.pumpAndSettle();
    });
    sceneAt('money: new goal', (tester, size) async {
      await show(tester, const FinancePage(), size: size);
      await openTab(tester, 'Célok');
      await tester.tap(find.byTooltip('Új cél'));
      await tester.pumpAndSettle();
    });
    sceneAt('money: a deposit', (tester, size) async {
      await show(tester, const FinancePage(), size: size);
      await openTab(tester, 'Célok');
      await tester.tap(find.text('Befizetés').first);
      await tester.pumpAndSettle();
    });
    sceneAt('tasks: new task', (tester, size) async {
      await show(tester, const TasksPage(), size: size);
      await tester.tap(find.text('Új feladat'));
      await tester.pumpAndSettle();
    });
    sceneAt('money, dark', (tester, size) async {
      await show(tester, const FinancePage(), size: size, dark: true);
    }, sizes: const [_phoneTall]);
  });

  group('settings and the rest', () {
    sceneAt('settings', (tester, size) async {
      await show(tester, const SettingsPage(), size: size);
    }, sizes: const [_phoneTall, _wideTall]);
    sceneAt('diagnostics', (tester, size) async {
      await show(tester, const DiagnosticsPage(), size: size);
    }, sizes: const [_phoneTall, _wideTall]);
    sceneAt('assistant, empty', (tester, size) async {
      await show(tester, const AssistantPage(), size: size, apiKey: 'k');
    });
    sceneAt('assistant, what we send', (tester, size) async {
      await show(tester, const AssistantPage(), size: size, apiKey: 'k');
      final panel = find.text('Mit küldünk a modellnek?');
      await tester.ensureVisible(panel);
      await tester.tap(panel);
      await tester.pumpAndSettle();
    }, sizes: const [_phoneTall, _wideTall]);
    sceneAt('assistant, with a plan', (tester, size) async {
      final llm = _Llm([
        (_) => calls([
          propose([
            item(
              'Reggeli futás a Duna-parton',
              '2026-11-13T07:00:00',
              '2026-11-13T08:00:00',
              hard: true,
            ),
            item(
              'Nyújtás és mobilitás otthon',
              '2026-11-14T18:00:00',
              '2026-11-14T18:30:00',
            ),
          ]),
        ]),
      ]);
      await show(
        tester,
        const AssistantPage(),
        size: size,
        apiKey: 'k',
        llm: llm,
      );
      await tester.enterText(
        find.byType(TextField),
        'Tervezz edzést a jövő hétre',
      );
      await tester.tap(find.byTooltip('Küldés'));
      await tester.pumpAndSettle();
    }, sizes: const [_phoneTall, _wideTall]);
  });

  group('dialogs and sheets', () {
    sceneAt('new event', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      await tester.tap(find.byType(FloatingActionButton).first);
      await tester.pumpAndSettle();
    });
    sceneAt('an event with everything', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      // (a weekly kayak training, on Sunday in the week)
      containerOf(
        tester,
        HomePage,
      ).read(viewModeProvider.notifier).set(CalView.week);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Kajak edzés').first);
      await tester.pumpAndSettle();
    });
    sceneAt('check-in', (tester, size) async {
      await show(
        tester,
        Consumer(
          builder: (c, ref, _) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => openCheckIn(c, ref),
                child: const Text('Megnyit'),
              ),
            ),
          ),
        ),
        size: size,
      );
      await tester.tap(find.text('Megnyit'));
      await tester.pumpAndSettle();
    });
    sceneAt('workout feedback', (tester, size) async {
      final o = Occurrence(
        eventId: 'e1',
        title: 'Reggeli edzés és nyújtás a Duna-parton',
        startUtc: DateTime.utc(2026, 11, 12, 6),
        endUtc: DateTime.utc(2026, 11, 12, 7, 30),
        originalStart: floating(2026, 11, 12, 7),
        allDay: false,
        tzid: bp,
      );
      await show(
        tester,
        Consumer(
          builder: (c, ref, _) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => openWorkoutFeedback(c, PendingWorkout(o)),
                child: const Text('Megnyit'),
              ),
            ),
          ),
        ),
        size: size,
      );
      await tester.tap(find.text('Megnyit'));
      await tester.pumpAndSettle();
    });
    sceneAt('the sync menu', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      await tester.tap(find.byType(SyncStatusButton));
      await tester.pumpAndSettle();
    });
    sceneAt('data consent', (tester, size) async {
      await show(
        tester,
        Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: c,
                  builder: (_) => ConsentDialog(
                    provider: providerById('groq'),
                    settings: const AiSettings(),
                  ),
                ),
                child: const Text('Megnyit'),
              ),
            ),
          ),
        ),
        size: size,
      );
      await tester.tap(find.text('Megnyit'));
      await tester.pumpAndSettle();
    });
    sceneAt('check-in history', (tester, size) async {
      await show(tester, const CheckInHistoryPage(), size: size);
    }, sizes: const [_phoneTall, _wide]);
    sceneAt('the handbook', (tester, size) async {
      await show(tester, const HandbookPage(), size: size);
    }, sizes: const [_phoneTall, _wide]);
    sceneAt('keyboard help (F1)', (tester, size) async {
      await show(tester, const HomePage(), size: size);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
    }, sizes: const [_wide]);
  });
}
