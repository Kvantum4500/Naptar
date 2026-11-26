import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/backup_io.dart';
import 'package:kvantum_core/kvantum_core.dart';

void main() {
  setUpAll(ensureTimeZones);

  // a calendar whose title has an "ő" (C5 91) with a fold between its bytes
  List<int> calendarWithACutLetter() => [
    ...utf8.encode(
      'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n'
      'DTSTART;TZID=Europe/Budapest:20260504T090000\r\n'
      'DTEND;TZID=Europe/Budapest:20260504T100000\r\nSUMMARY:F',
    ),
    0xC5,
    0x0D,
    0x0A,
    0x20,
    0x91,
    ...utf8.encode('rt\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'),
  ];

  group('the file the user picks', () {
    test('a letter that a fold cut in two is one letter again', () async {
      final io = FilePickerBackupIo(read: () async => calendarWithACutLetter());
      final text = (await io.pick())!;
      expect(text, isNot(contains('�')));
      expect(parseIcs(text, calendarId: 'c').events.single.title, 'Főrt');
    });

    test('nothing picked is null', () async {
      final io = FilePickerBackupIo(read: () async => null);
      expect(await io.pick(), isNull);
    });

    test('a file that is not a calendar is read as it is', () async {
      final json = utf8.encode('{"a":\r\n "bő"}');
      final io = FilePickerBackupIo(read: () async => json);
      expect(await io.pick(), '{"a":\r\n "bő"}');
    });

    test(
      'the default reads through the file dialog (not a thing to run here)',
      () {
        // the constant constructor of the provider keeps working
        expect(const FilePickerBackupIo(), isA<BackupIo>());
      },
    );
  });
}
