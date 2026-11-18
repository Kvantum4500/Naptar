import 'dart:collection' show ListBase;
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/backup/backup_bundle.dart';

void main() {
  final when = DateTime.utc(2026, 11, 13, 9, 15, 30);
  final data = BackupData(
    calendarIcs: 'BEGIN:VCALENDAR\nSUMMARY:Fogorvos – áéíóöőúüű\nEND:VCALENDAR',
    financeJson: '{"format":"kvantum-finance","version":1,"records":[]}',
    records: const ['{"v":1,"id":"a","kind":"task","f":{}}', '{"id":"b"}'],
  );
  final meta = BackupMeta(
    createdAt: when,
    build: 73,
    counts: const {'events': 1, 'task': 2},
  );

  BackupException problemOf(void Function() body) {
    try {
      body();
    } on BackupException catch (e) {
      return e;
    }
    fail('no BackupException');
  }

  /// A zip with the given files, locked or not.
  Uint8List zip(Map<String, String> files, {String? password}) {
    final a = Archive();
    files.forEach((n, t) => a.add(ArchiveFile.string(n, t)));
    return Uint8List.fromList(ZipEncoder(password: password).encodeBytes(a));
  }

  String metaText({Object? format = backupFormat, Object? version = 1}) =>
      jsonEncode({
        'format': format,
        'version': version,
        'createdAt': when.toIso8601String(),
        'counts': <String, int>{},
      });

  group('a backup file', () {
    test('keeps what was put in, accents and all', () {
      final back = unpackBackup(packBackup(data, meta));
      expect(back.data.calendarIcs, data.calendarIcs);
      expect(back.data.financeJson, data.financeJson);
      expect(back.data.records, data.records);
      expect(back.meta.createdAt, when);
      expect(back.meta.build, 73);
      expect(back.meta.counts, {'events': 1, 'task': 2});
    });

    test('an empty backup is a backup', () {
      final back = unpackBackup(
        packBackup(const BackupData(), BackupMeta(createdAt: when)),
      );
      expect(back.data.calendarIcs, '');
      expect(back.data.records, isEmpty);
      expect(back.meta.build, isNull);
    });

    test('is a zip that any archive program opens', () {
      final names = ZipDecoder()
          .decodeBytes(packBackup(data, meta))
          .map((f) => f.name)
          .toSet();
      expect(names, {
        'meta.json',
        'calendar.ics',
        'finance.json',
        'records.json',
      });
    });

    test('with a password it opens only with that password', () {
      final locked = packBackup(data, meta, password: 'titok-jelszo');
      expect(
        unpackBackup(locked, password: 'titok-jelszo').data.calendarIcs,
        data.calendarIcs,
      );
      expect(
        problemOf(() => unpackBackup(locked)).problem,
        BackupProblem.passwordNeeded,
      );
      expect(
        problemOf(() => unpackBackup(locked, password: 'másik')).problem,
        BackupProblem.wrongPassword,
      );
    });

    test('with a password the text is not in the file', () {
      final locked = packBackup(
        BackupData(calendarIcs: 'SUMMARY:Fogorvosi időpont ${'x' * 50}'),
        meta,
        password: 'jelszo',
      );
      expect(
        latin1.decode(locked, allowInvalid: true),
        isNot(contains('Fogorvosi')),
      );
    });

    test('an empty password means no password', () {
      final plain = packBackup(data, meta, password: '');
      expect(unpackBackup(plain).data.records, data.records);
      expect(unpackBackup(plain, password: '').data.records, data.records);
    });

    test('a file that is not a zip is not a backup', () {
      expect(
        problemOf(() => unpackBackup(utf8.encode('BEGIN:VCALENDAR'))).problem,
        BackupProblem.notABackup,
      );
      expect(
        problemOf(() => unpackBackup(const [])).problem,
        BackupProblem.notABackup,
      );
    });

    test('a zip of something else is not a backup', () {
      expect(
        problemOf(() => unpackBackup(zip({'a.txt': 'hello'}))).problem,
        BackupProblem.notABackup,
      );
      expect(
        problemOf(
          () => unpackBackup(zip({'meta.json': metaText(format: 'other')})),
        ).problem,
        BackupProblem.notABackup,
      );
      expect(
        problemOf(() => unpackBackup(zip({'meta.json': 'not json'}))).problem,
        BackupProblem.notABackup,
      );
    });

    test('a newer format is refused, not half read', () {
      expect(
        problemOf(() => unpackBackup(zip({'meta.json': metaText(version: 2)})))
            .problem,
        BackupProblem.newerVersion,
      );
    });

    test('a damaged part is said to be damaged', () {
      expect(
        problemOf(
          () => unpackBackup(
            zip({'meta.json': metaText(), 'records.json': '{not a list'}),
          ),
        ).problem,
        BackupProblem.damaged,
      );
      expect(
        problemOf(
          () => unpackBackup(
            zip({'meta.json': metaText(), 'records.json': '{"a":1}'}),
          ),
        ).problem,
        BackupProblem.damaged,
      );
      expect(
        problemOf(
          () => unpackBackup(zip({'meta.json': metaText(version: 'x')})),
        ).problem,
        BackupProblem.damaged,
      );
    });

    test('a part that is not text is damaged, not half read', () {
      // the calendar holds bytes that are not UTF-8 (a cut-off accent)
      final a = Archive()
        ..add(ArchiveFile.string('meta.json', metaText()))
        ..add(ArchiveFile('calendar.ics', 3, [0x53, 0xC3, 0x28]));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(a));
      expect(
        problemOf(() => unpackBackup(bytes)).problem,
        BackupProblem.damaged,
      );
    });

    test('a missing part reads as empty (the rest is still usable)', () {
      final back = unpackBackup(zip({'meta.json': metaText()}));
      expect(back.data.calendarIcs, '');
      expect(back.data.financeJson, '');
      expect(back.data.records, isEmpty);
    });

    test('every problem has words for the user', () {
      for (final p in BackupProblem.values) {
        expect(BackupException(p).message, isNotEmpty);
      }
      expect(
        const BackupException(BackupProblem.wrongPassword).message,
        'Hibás jelszó.',
      );
    });
  });

  group('zipIsLocked: is the zip locked with a password?', () {
    test('a plain zip is not, a locked one is', () {
      final files = {'a.txt': 'tartalom', 'b.txt': 'másik'};
      expect(zipIsLocked(zip(files)), isFalse);
      expect(zipIsLocked(zip(files, password: 'Titok-2026')), isTrue);
    });

    test('a real backup, locked: yes; the same without the lock: no', () {
      expect(
        zipIsLocked(packBackup(data, meta, password: 'Titok-2026')),
        isTrue,
      );
      expect(zipIsLocked(packBackup(data, meta)), isFalse);
    });

    test('an entry with no content is never locked, and does not count', () {
      // (the zip format leaves an empty file unlocked, password or not)
      final bytes = packBackup(
        const BackupData(),
        meta,
        password: 'Titok-2026',
      );
      expect(zipIsLocked(bytes), isTrue);
    });

    test('a zip with nothing in it but empty entries is not locked', () {
      expect(
        zipIsLocked(zip({'a.txt': '', 'b.txt': ''}, password: 'x')),
        isFalse,
      );
      expect(zipIsLocked(zip({}, password: 'x')), isFalse);
    });

    test('one entry with content that is not locked spoils it', () {
      final bytes = Uint8List.fromList(
        packBackup(data, meta, password: 'Titok-2026'),
      );
      expect(zipIsLocked(bytes), isTrue);
      // clear the "encrypted" flag of the second entry in the central
      // directory (the signature PK 01 02, the flags 8 bytes after it)
      final signatures = <int>[
        for (var i = 0; i + 4 < bytes.length; i++)
          if (bytes[i] == 0x50 &&
              bytes[i + 1] == 0x4b &&
              bytes[i + 2] == 0x01 &&
              bytes[i + 3] == 0x02)
            i,
      ];
      expect(signatures.length, greaterThanOrEqualTo(3));
      for (final entry in [0, 1, 2]) {
        final patched = Uint8List.fromList(bytes);
        patched[signatures[entry] + 8] &= 0xFE;
        expect(zipIsLocked(patched), isFalse, reason: 'entry $entry');
      }
    });

    test('what is not a zip at all is not locked', () {
      expect(zipIsLocked(<int>[]), isFalse);
      expect(zipIsLocked(utf8.encode('nem zip, csak szöveg')), isFalse);
      expect(zipIsLocked(List<int>.filled(100, 0x50)), isFalse);
    });

    test('bytes that cannot be read at all are not locked either', () {
      // (the reader of the zip is not trusted to be quiet about damaged
      // bytes: whatever it throws, the answer is "not locked")
      expect(zipIsLocked(_Unreadable()), isFalse);
    });

    test('the message says what happened', () {
      const e = BackupException(BackupProblem.notLocked);
      expect(e.message, contains('nincs jelszóval lezárva'));
      expect(e.message, contains('Nem állítom vissza'));
    });
  });
}

/// Bytes whose every access fails.
class _Unreadable extends ListBase<int> {
  @override
  int get length => throw StateError('unreadable');

  @override
  set length(int newLength) => throw StateError('unreadable');

  @override
  int operator [](int index) => throw StateError('unreadable');

  @override
  void operator []=(int index, int value) => throw StateError('unreadable');
}
