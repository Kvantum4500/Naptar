import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/data/db.dart';
import 'package:kvantum_app/data/event_repository.dart';
import 'package:kvantum_app/providers.dart';
import 'package:kvantum_app/sync/sync_controller.dart';
import 'package:kvantum_core/kvantum_core.dart';

const bp = 'Europe/Budapest';

CalEvent evt(
  String id,
  String title,
  DateTime start, {
  Duration len = const Duration(hours: 1),
  String? rrule,
  String? colorId,
  bool allDay = false,
}) => CalEvent(
  id: id,
  calendarId: kNaptarCalendar,
  title: title,
  tzid: allDay ? null : bp,
  allDay: allDay,
  start: start,
  end: allDay ? start.add(len) : start.add(len),
  rrule: rrule,
  colorId: colorId,
);

/// Wide test window so the dialog editor and side-by-side layout are used.
void useSize(WidgetTester tester, {Size size = const Size(1280, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<AppDatabase> newDb() async => AppDatabase(NativeDatabase.memory());

List<Override> baseOverrides(AppDatabase db) => [
  dbProvider.overrideWithValue(db),
  googleConfiguredProvider.overrideWithValue(false),
];

/// [textScale] enlarges all text the way the system's font size does;
/// [theme], [darkTheme] and [themeMode] put the app in a theme (by default the
/// framework's own light theme).
Widget app(
  Widget home,
  AppDatabase db, {
  List<Override> extra = const [],
  double? textScale,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.light,
}) => ProviderScope(
  overrides: [...baseOverrides(db), ...extra],
  child: MaterialApp(
    locale: const Locale('hu'),
    supportedLocales: const [Locale('hu')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: theme,
    darkTheme: darkTheme,
    themeMode: themeMode,
    builder: textScale == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
    home: home,
  ),
);

/// Unmount first so drift's stream-cleanup timers run, then close the db in
/// real time (closing inside fake async would never complete).
Future<void> shutdown(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(db.close);
}
