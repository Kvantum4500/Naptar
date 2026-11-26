import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/day_utils.dart' show defaultTz;
import 'package:kvantum_app/ui/theme.dart' show contrastRatio;
import 'package:kvantum_app/widget/widget_bridge.dart';
import 'package:kvantum_app/widget/widget_data.dart';
import 'package:kvantum_core/kvantum_core.dart';

// The home-screen widget is Android code and Android resources that these
// tests (and a Windows build) cannot run. What they can do is keep the two
// sides honest: the files that have to agree with each other are read as
// text and compared. (The Kotlin itself is compiled, and its logic run on a
// JVM, by the checks described in the changelog.)

String read(String path) =>
    File('android/app/src/main/$path').readAsStringSync();

String kotlin(String name) => read('kotlin/dev/kvantum/kvantum_app/$name.kt');

/// Kotlin without its comments (a remark may name what the code must not do).
String code(String kt) => kt
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//.*'), '');

/// The text without its comments.
String bare(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

Map<String, Color> colors(String path) => {
  for (final m in RegExp(
    r'<color name="(\w+)">#([0-9A-Fa-f]{6})</color>',
  ).allMatches(read(path)))
    m.group(1)!: Color(0xFF000000 | int.parse(m.group(2)!, radix: 16)),
};

Set<String> allMatches(String text, RegExp re, [int group = 1]) => {
  for (final m in re.allMatches(text)) m.group(group)!,
};

void main() {
  setUpAll(ensureTimeZones);

  final layout = bare(read('res/layout/widget_today.xml'));
  final info = bare(read('res/xml/today_widget_info.xml'));
  final manifest = bare(read('AndroidManifest.xml'));
  final provider = code(kotlin('TodayWidgetProvider'));
  final content = code(kotlin('TodayWidgetContent'));
  final activity = code(kotlin('MainActivity'));

  group('the colours', () {
    final light = colors('res/values/colors.xml');
    final dark = colors('res/values-night/colors.xml');

    test('light and dark define the same names', () {
      expect(light.keys.toSet(), dark.keys.toSet());
      expect(
        light.keys.toSet(),
        containsAll([
          'widget_background',
          'widget_text',
          'widget_text_dim',
          'widget_accent',
        ]),
      );
    });

    for (final (name, set) in [('light', light), ('dark', dark)]) {
      for (final text in ['widget_text', 'widget_text_dim', 'widget_accent']) {
        test('$text is readable on the $name background (4.5 : 1)', () {
          final ratio = contrastRatio(set[text]!, set['widget_background']!);
          expect(ratio, greaterThanOrEqualTo(4.5), reason: '$text $ratio');
        });
      }
    }

    test('the background of the light and the dark widget differ', () {
      expect(light['widget_background'], isNot(dark['widget_background']));
    });

    test(
      'they come from the layout, not from code (so night mode follows)',
      () {
        expect(provider, isNot(contains('setTextColor')));
        expect(provider, isNot(contains('getColor')));
        expect(layout, contains('@color/widget_text'));
        expect(layout, contains('@drawable/widget_background'));
      },
    );
  });

  group('the layout', () {
    final ids = allMatches(layout, RegExp(r'@\+id/(\w+)'));

    test('has every view the provider sets, and the provider none else', () {
      final used = allMatches(provider, RegExp(r'R\.id\.(\w+)'));
      expect(used, isNotEmpty);
      expect(ids, containsAll(used));
      // (every view of the layout is set, or it would show its preview text)
      expect(used, containsAll(ids.difference({'widget_root'})));
      expect(used, contains('widget_root'), reason: 'the tap');
    });

    test('has as many lines as the content may have', () {
      final max = int.parse(
        RegExp(r'MAX_LINES = (\d+)').firstMatch(content)!.group(1)!,
      );
      final lines = ids.where((i) => i.startsWith('widget_line_')).toList();
      expect(lines, hasLength(max));
      expect({for (var i = 0; i < max; i++) 'widget_line_$i'}, lines.toSet());
      expect(
        allMatches(provider, RegExp(r'R\.id\.(widget_line_\d+)')),
        lines.toSet(),
      );
    });

    test('uses only views a RemoteViews can show', () {
      final tags = allMatches(layout, RegExp(r'<([A-Za-z][\w.]*)'));
      expect(tags, {'LinearLayout', 'TextView', 'FrameLayout'});
    });

    test('is the layout the provider and the info file name', () {
      expect(provider, contains('R.layout.widget_today'));
      expect(info, contains('android:initialLayout="@layout/widget_today"'));
    });
  });

  group('the resources', () {
    test('everything the widget files refer to exists', () {
      final defined = <String, Set<String>>{
        'string': allMatches(
          read('res/values/strings.xml'),
          RegExp(r'<string name="(\w+)"'),
        ),
        'color': colors('res/values/colors.xml').keys.toSet(),
        'drawable': {
          for (final f in Directory(
            'android/app/src/main/res/drawable',
          ).listSync().whereType<File>())
            f.uri.pathSegments.last.split('.').first,
        },
        'layout': {'widget_today'},
        'xml': {'today_widget_info', 'data_extraction_rules'},
      };
      final files = {
        'layout': layout,
        'info': info,
        'background': bare(read('res/drawable/widget_background.xml')),
        'manifest-receiver': manifest,
      };
      for (final MapEntry(key: file, value: text) in files.entries) {
        for (final m in RegExp(
          r'@(string|color|drawable|layout|xml)/(\w+)',
        ).allMatches(text)) {
          final kind = m.group(1)!;
          final name = m.group(2)!;
          if (file == 'manifest-receiver' && kind != 'xml') continue;
          expect(defined[kind], contains(name), reason: '$file: @$kind/$name');
        }
      }
    });

    test('the platform updates it at least every half hour, no more often', () {
      final ms = int.parse(
        RegExp(r'updatePeriodMillis="(\d+)"').firstMatch(info)!.group(1)!,
      );
      expect(ms, greaterThanOrEqualTo(30 * 60 * 1000));
    });

    test('the widget can be resized and lives on the home screen', () {
      expect(info, contains('android:resizeMode="horizontal|vertical"'));
      expect(info, contains('android:widgetCategory="home_screen"'));
      expect(
        info,
        contains('android:description="@string/widget_description"'),
      );
    });
  });

  group('the manifest', () {
    test('declares the receiver, not exported, with its provider info', () {
      final receiver = RegExp(
        r'<receiver\s+[^>]*android:name="\.TodayWidgetProvider"[^>]*>(.*?)</receiver>',
        dotAll: true,
      ).firstMatch(manifest);
      expect(receiver, isNotNull);
      expect(receiver!.group(0), contains('android:exported="false"'));
      expect(
        receiver.group(1),
        contains('android.appwidget.action.APPWIDGET_UPDATE'),
      );
      expect(
        receiver.group(1),
        contains('android:resource="@xml/today_widget_info"'),
      );
      expect(receiver.group(1), contains('android.appwidget.provider'));
    });

    test('the class the manifest names is the one the Kotlin declares', () {
      expect(
        provider,
        contains('class TodayWidgetProvider : AppWidgetProvider()'),
      );
      expect(provider, contains('package dev.kvantum.kvantum_app'));
    });

    test('the alarm is inexact and does not wake the device', () {
      expect(provider, contains('AlarmManager.RTC,'));
      expect(provider, isNot(contains('RTC_WAKEUP')));
      expect(provider, isNot(contains('setExact')));
      expect(provider, isNot(contains('SCHEDULE_EXACT_ALARM')));
      expect(manifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
    });

    test('every pending intent is immutable', () {
      final flags = allMatches(
        provider,
        RegExp(r'PendingIntent\.FLAG_UPDATE_CURRENT or ([\w.]+)'),
      );
      expect(flags, {'PendingIntent.FLAG_IMMUTABLE'});
      expect(
        RegExp(r'PendingIntent\.get(Activity|Broadcast)\(')
            .allMatches(provider),
        hasLength(2),
      );
    });

    test('when the last widget goes, the text and the alarm go with it', () {
      final disabled = RegExp(
        r'override fun onDisabled\(context: Context\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(provider);
      expect(disabled, isNotNull);
      expect(disabled!.group(1), contains('TodayWidgetStore.clear(context)'));
      expect(disabled.group(1), contains('cancelTick(context)'));
    });

    test('what the widget keeps stays out of backups (it holds titles)', () {
      expect(read('res/xml/data_extraction_rules.xml'), contains('sharedpref'));
      expect(manifest, contains('android:allowBackup="false"'));
    });
  });

  group('the two sides agree', () {
    test('the keys the Kotlin reads are the ones the app writes', () {
      final j = jsonDecode(
        widgetSnapshot(
          nowUtc: DateTime.utc(2026, 11, 16, 5),
          occurrences: [
            Occurrence(
              eventId: 's',
              title: 'Műszak',
              startUtc: DateTime.utc(2026, 11, 17, 17),
              endUtc: DateTime.utc(2026, 11, 18, 5),
              originalStart: floating(2026, 11, 17, 18),
              allDay: false,
              isShift: true,
            ),
          ],
          tasks: const [],
        ),
      ) as Map<String, Object?>;
      final written = <String>{
        ...j.keys,
        ...((j['days'] as List).first as Map).keys.cast<String>(),
        ...((j['shifts'] as List).first as Map).keys.cast<String>(),
      };
      final read = allMatches(
        content,
        RegExp(
          r'(?:opt(?:Int|Long|String|JSONArray|JSONObject)|isNull)\("(\w+)"',
        ),
      );
      expect(read, written);
    });

    test('the version the Kotlin accepts is the one the app writes', () {
      final j = jsonDecode(
        widgetSnapshot(
          nowUtc: DateTime.utc(2026, 11, 16, 5),
          occurrences: const [],
          tasks: const [],
        ),
      ) as Map<String, Object?>;
      expect(content, contains('root.optInt("v", 0) != ${j['v']}'));
    });

    test('the default zone is the app\'s display zone', () {
      expect(content, contains('DEFAULT_ZONE = "$defaultTz"'));
    });

    test('the channel and its methods have the same names on both sides', () {
      expect(activity, contains('"${MethodChannelWidgetBridge.channelName}"'));
      expect(activity, contains('"isPlaced" ->'));
      expect(activity, contains('"update" ->'));
      expect(
        activity,
        contains('TodayWidgetProvider.hasWidgets(applicationContext)'),
      );
    });

    test('the platform takes more than the app ever sends', () {
      final cap = RegExp(r'MAX_SNAPSHOT = (\d+) \* 1024')
          .firstMatch(kotlin('TodayWidgetStore'))!;
      expect(int.parse(cap.group(1)!) * 1024, greaterThanOrEqualTo(32 * 1024));
    });
  });
}
