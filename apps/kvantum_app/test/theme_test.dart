import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kvantum_app/ai/ai_providers.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/settings_page.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/main.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/ui/palette.dart';
import 'package:kvantum_app/ui/theme.dart';
import 'package:kvantum_app/update/update_dialog.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    ensureTimeZones();
    await initializeDateFormatting('hu');
  });

  group('contrastRatio', () {
    test('black on white is 21, the same colour is 1', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
      expect(contrastRatio(Colors.white, Colors.black), closeTo(21, 0.01));
      expect(contrastRatio(Colors.red, Colors.red), closeTo(1, 0.001));
    });

    test('a translucent colour counts as it looks over the background', () {
      // black at 87 % over white is nearly black: well above 4.5
      final looks = contrastRatio(Colors.black87, Colors.white);
      expect(looks, lessThan(21));
      expect(looks, greaterThan(14));
      // white at 10 % over white is white: no contrast at all
      expect(
        contrastRatio(Colors.white.withValues(alpha: .1), Colors.white),
        closeTo(1, 0.001),
      );
    });

    test('mid grey on white is the known 4.0', () {
      expect(
        contrastRatio(const Color(0xFF808080), Colors.white),
        closeTo(3.95, 0.05),
      );
    });
  });

  group('the status colours can be read', () {
    for (final b in Brightness.values) {
      final theme = appTheme(b);
      final scheme = theme.colorScheme;
      final colors = theme.extension<StatusColors>()!;
      final surfaces = {
        'surface': scheme.surface,
        'container low': scheme.surfaceContainerLow,
        'container': scheme.surfaceContainer,
        'highest': scheme.surfaceContainerHighest,
      };
      surfaces.forEach((name, bg) {
        test('${b.name}: "fine" on $name', () {
          expect(contrastRatio(colors.ok, bg), greaterThanOrEqualTo(4.5));
        });
        test('${b.name}: "watch out" on $name', () {
          expect(contrastRatio(colors.warn, bg), greaterThanOrEqualTo(4.5));
        });
        test('${b.name}: "over" (the error colour) on $name', () {
          expect(contrastRatio(scheme.error, bg), greaterThanOrEqualTo(4.5));
        });
        test('${b.name}: the muted text on $name', () {
          expect(
            contrastRatio(scheme.onSurfaceVariant, bg),
            greaterThanOrEqualTo(4.5),
          );
        });
      });
    }

    test('the old plain green and orange could not be read (why)', () {
      final light = appTheme(Brightness.light).colorScheme.surface;
      expect(contrastRatio(Colors.green, light), lessThan(3));
      expect(contrastRatio(Colors.orange, light), lessThan(3));
    });

    test('the three states are three different colours', () {
      for (final c in [StatusColors.light, StatusColors.dark]) {
        expect(c.ok, isNot(c.warn));
      }
      expect(StatusColors.light.ok, isNot(StatusColors.dark.ok));
    });

    testWidgets('a theme without them still gets the right pair', (
      tester,
    ) async {
      late StatusColors got;
      Widget probe(Brightness b) => MaterialApp(
        theme: ThemeData(brightness: b),
        home: Builder(
          builder: (c) {
            got = statusColorsOf(c);
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(probe(Brightness.light));
      expect(got.ok, StatusColors.light.ok);
      await tester.pumpWidget(probe(Brightness.dark));
      await tester.pumpAndSettle(); // (the theme change is animated)
      expect(got.ok, StatusColors.dark.ok);
    });

    test('lerp and copyWith keep the pair together', () {
      final mid = StatusColors.light.lerp(StatusColors.dark, 1);
      expect(mid.ok, StatusColors.dark.ok);
      expect(mid.warn, StatusColors.dark.warn);
      expect(StatusColors.light.lerp(null, .5), StatusColors.light);
      final c = StatusColors.light.copyWith(ok: Colors.black);
      expect(c.ok, Colors.black);
      expect(c.warn, StatusColors.light.warn);
    });
  });

  group('the text on an event colour', () {
    final colors = <String, Color>{
      for (final e in eventColorChoices) e.key: e.value,
      'default': defaultEventColor,
    };
    colors.forEach((id, bg) {
      test('colour $id is readable (4.5 : 1)', () {
        expect(contrastRatio(onEventColor(bg), bg), greaterThanOrEqualTo(4.5));
      });
    });

    test('it picks the better of the two, not the one a guess says', () {
      // flamingo (4), lavender (1), tangerine (6), peacock (7): black reads
      // better, white was chosen before
      for (final id in ['1', '4', '6', '7']) {
        expect(onEventColor(eventColor(id)), Colors.black87, reason: id);
      }
      // grape (3), graphite (8), blueberry (9), tomato (11): white
      for (final id in ['3', '8', '9', '11']) {
        expect(onEventColor(eventColor(id)), Colors.white, reason: id);
      }
    });
  });

  group('the theme choice', () {
    late AppDatabase db;
    late ProviderContainer c;

    Future<void> boot(WidgetTester tester) async {
      useSize(tester);
      db = await newDb();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...baseOverrides(db),
            apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null)),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
          child: const KvantumApp(),
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    }

    MaterialApp appWidget(WidgetTester tester) =>
        tester.widget<MaterialApp>(find.byType(MaterialApp));

    testWidgets('it follows the system until told otherwise', (tester) async {
      await boot(tester);
      expect(c.read(themeModeProvider), ThemeMode.system);
      expect(appWidget(tester).themeMode, ThemeMode.system);
      await shutdown(tester, db);
    });

    testWidgets('light and dark are the same app theme in two brightnesses', (
      tester,
    ) async {
      await boot(tester);
      final light = appWidget(tester).theme!;
      final dark = appWidget(tester).darkTheme!;
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.extension<StatusColors>(), StatusColors.light);
      expect(dark.extension<StatusColors>(), StatusColors.dark);
      await shutdown(tester, db);
    });

    testWidgets('a choice changes the app at once', (tester) async {
      await boot(tester);
      c.read(themeModeProvider.notifier).set(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(appWidget(tester).themeMode, ThemeMode.dark);
      final ctx = tester.element(find.byType(Scaffold).first);
      expect(Theme.of(ctx).brightness, Brightness.dark);
      c.read(themeModeProvider.notifier).set(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(Theme.of(ctx).brightness, Brightness.light);
      await shutdown(tester, db);
    });

    testWidgets('the choice is remembered', (tester) async {
      await boot(tester);
      c.read(themeModeProvider.notifier).set(ThemeMode.dark);
      final saved = await tester.runAsync(
        () => c.read(repoProvider).meta('themeMode'),
      );
      expect(saved, 'dark');
      await shutdown(tester, db);
    });

    testWidgets('a new start reads the remembered choice', (tester) async {
      useSize(tester);
      db = await newDb();
      await tester.runAsync(
        () => AppDatabaseMeta.seed(db, 'themeMode', 'dark'),
      );
      await tester.pumpWidget(
        ProviderScope(overrides: baseOverrides(db), child: const KvantumApp()),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await shutdown(tester, db);
    });

    testWidgets('an unknown remembered value means the system', (tester) async {
      useSize(tester);
      db = await newDb();
      await tester.runAsync(
        () => AppDatabaseMeta.seed(db, 'themeMode', 'neon'),
      );
      await tester.pumpWidget(
        ProviderScope(overrides: baseOverrides(db), child: const KvantumApp()),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
      await shutdown(tester, db);
    });

    testWidgets('Settings has the selector, and it works', (tester) async {
      useSize(tester, size: const Size(900, 6400));
      db = await newDb();
      await tester.pumpWidget(
        app(
          const SettingsPage(),
          db,
          extra: [
            apiKeyStoreProvider.overrideWithValue(MemoryApiKeyStore(null)),
            currentBuildProvider.overrideWith((ref) async => 7),
          ],
        ),
      );
      await tester.pumpAndSettle();
      c = ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));
      expect(find.text('Rendszer szerint'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sötét').last);
      await tester.pumpAndSettle();
      expect(c.read(themeModeProvider), ThemeMode.dark);
      expect(find.text('Sötét'), findsOneWidget);
      await shutdown(tester, db);
    });
  });
}

/// Writes a meta row straight into the database (as an earlier run left it).
class AppDatabaseMeta {
  static Future<void> seed(AppDatabase db, String key, String value) => db
      .into(db.metaRows)
      .insertOnConflictUpdate(MetaRowsCompanion.insert(key: key, value: value));
}
