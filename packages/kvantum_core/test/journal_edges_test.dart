import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The edges of the diary that nothing held until the deliberate breakage
/// round of the 8th round: every limit to the last unit, what a stored record
/// is cleaned of (a record may come from another device), how a head is cut,
/// what two entries have to share to be the same, and what a list shows of an
/// entry.
void main() {
  final at = DateTime.utc(2026, 11, 16, 8, 15);

  JournalEntry entry(
    String id, {
    DateTime? when,
    String title = '',
    String text = 'x',
    List<PhotoRef> photos = const [],
  }) => JournalEntry.checked(
    id: id,
    at: when ?? at,
    title: title,
    text: text,
    photos: photos,
  );

  SyncRecord record(Map<String, Object?> fields, {String id = 'a'}) =>
      SyncRecord(
        id: id,
        kind: kindJournal,
      ).edit({'at': '2026-11-16T08:15', ...fields}, ts: 1, dev: 'A');

  PhotoRef? parse(Map<String, Object?> json) => PhotoRef.tryParse(json);

  group('what a picture may say', () {
    test('a size or a weight is taken up to the limit, not beyond it', () {
      expect(parse({'id': 'a', 'b': 5 * 1024 * 1024})?.bytes, 5 * 1024 * 1024);
      expect(parse({'id': 'a', 'b': maxPhotoBytes})?.bytes, maxPhotoBytes);
      expect(parse({'id': 'a', 'b': maxPhotoBytes + 1}), isNull);
      expect(parse({'id': 'a', 'w': 4000})?.width, 4000);
      expect(parse({'id': 'a', 'w': maxPhotoSide})?.width, maxPhotoSide);
      expect(parse({'id': 'a', 'w': maxPhotoSide + 1}), isNull);
      expect(parse({'id': 'a', 'h': maxPhotoSide})?.height, maxPhotoSide);
      expect(parse({'id': 'a', 'h': maxPhotoSide + 1}), isNull);
      expect(parse({'id': 'a', 'w': -1}), isNull);
    });

    test('what is not said is not known: nothing, not one pixel', () {
      final p = parse({'id': 'a'})!;
      expect((p.width, p.height, p.bytes), (0, 0, 0));
      expect(parse({'id': 'a', 'w': 100})!.height, 0);
      expect(parse({'id': 'a', 'h': 100})!.width, 0);
    });

    test('the endings of a picture are those eight and no others', () {
      const endings = [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'bmp',
        'heic',
        'heif',
      ];
      expect(photoExtensions, endings.toSet());
      for (final x in endings) {
        expect(parse({'id': 'a', 'x': x})?.ext, x, reason: x);
      }
      for (final x in ['tiff', 'JPG', 'exe', '', '.jpg']) {
        expect(parse({'id': 'a', 'x': x}), isNull, reason: x);
      }
      expect(parse({'id': 'a', 'x': 7}), isNull);
    });

    test('an id is up to 40 letters, digits, dashes and underscores', () {
      expect(parse({'id': 'a' * 40}), isNotNull);
      expect(parse({'id': 'a' * 41}), isNull);
      expect(parse({'id': 'a_b-C9'}), isNotNull);
      for (final bad in ['', 'a b', 'a/b', 'a.b', '../a', 'á']) {
        expect(parse({'id': bad}), isNull, reason: bad);
      }
      expect(parse({'id': 3}), isNull);
    });

    test('is written as its id, its ending when it is not jpg, and its size '
        'only', () {
      expect(const PhotoRef(id: 'a', width: 4, height: 3, bytes: 99).toJson(), {
        'id': 'a',
        'w': 4,
        'h': 3,
        'b': 99,
      });
      expect(const PhotoRef(id: 'a', ext: 'png').toJson(), {
        'id': 'a',
        'x': 'png',
        'w': 0,
        'h': 0,
        'b': 0,
      });
    });

    test('two pictures are the same only if every part is the same', () {
      const base = PhotoRef(id: 'a', width: 4, height: 3, bytes: 9);
      expect(base, const PhotoRef(id: 'a', width: 4, height: 3, bytes: 9));
      for (final other in const [
        PhotoRef(id: 'b', width: 4, height: 3, bytes: 9),
        PhotoRef(id: 'a', ext: 'png', width: 4, height: 3, bytes: 9),
        PhotoRef(id: 'a', width: 5, height: 3, bytes: 9),
        PhotoRef(id: 'a', width: 4, height: 4, bytes: 9),
        PhotoRef(id: 'a', width: 4, height: 3, bytes: 10),
      ]) {
        expect(base == other, isFalse, reason: '$other');
      }
    });
  });

  group('how words are cleaned', () {
    test('a title is one line: blanks run together, control characters go', () {
      expect(entry('a', title: '  a    b  ').title, 'a b');
      expect(entry('a', title: 'a\t\n\r b').title, 'a b');
      // (a control character of the second block, where a line break would
      // not be found by a blank)
      expect(entry('a', title: 'a\u0085b').title, 'a b');
      expect(entry('a', title: 'a\u0080b\u009Fc').title, 'a b c');
      expect(entry('a', title: 'a\u007Fb').title, 'a b');
      expect(entry('a', title: 'a​b').title, 'ab');
    });

    test('a text keeps its lines, and loses control characters', () {
      expect(entry('a', text: 'a\u007Fb').text, 'ab');
      expect(entry('a', text: 'a\u0000b\u0008c').text, 'abc');
      expect(entry('a', text: 'a\r\nb\rc').text, 'a\nb\nc');
      expect(entry('a', text: '  a\n\n b  ').text, 'a\n\n b');
      expect(entry('a', text: 'a\tb').text, 'a\tb');
    });

    test('a length is the length of what is kept, not of what was typed', () {
      // many blanks in a title, many invisible characters in a text
      expect(entry('a', title: 'a${' ' * 100}b').title, 'a b');
      expect(entry('a', text: 'a${'​' * 25000}b').text, 'ab');
    });

    test('a limit holds to the last unit', () {
      expect(entry('a', title: 'c' * maxJournalTitle).title.length, 80);
      expect(
        () => entry('a', title: 'c' * (maxJournalTitle + 1)),
        throwsArgumentError,
      );
      expect(entry('a', text: 't' * maxJournalText).text.length, 20000);
      expect(
        () => entry('a', text: 't' * (maxJournalText + 1)),
        throwsArgumentError,
      );
    });

    test('the pictures of an entry are at most twelve, each once', () {
      final twelve = [for (var i = 0; i < 12; i++) PhotoRef(id: 'p$i')];
      expect(entry('a', photos: twelve).photos, hasLength(12));
      expect(
        () => entry(
          'a',
          photos: [
            ...twelve,
            const PhotoRef(id: 'p12'),
          ],
        ),
        throwsArgumentError,
      );
      // (the same picture twice is told by its id, whatever else differs)
      expect(
        () => entry(
          'a',
          photos: const [
            PhotoRef(id: 'p', width: 1),
            PhotoRef(id: 'p', width: 2),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('an entry keeps its own list of pictures', () {
      final given = [const PhotoRef(id: 'p1')];
      final e = entry('a', photos: given);
      given.add(const PhotoRef(id: 'p2'));
      expect(e.photos, hasLength(1));
      expect(
        () => e.photos.add(const PhotoRef(id: 'p3')),
        throwsUnsupportedError,
      );
    });

    test('an id is up to 40 letters, digits, dashes and underscores', () {
      expect(entry('a' * 40).id, 'a' * 40);
      expect(() => entry('a' * 41), throwsArgumentError);
      expect(entry('a_b-C9').id, 'a_b-C9');
      expect(() => entry('a b'), throwsArgumentError);
    });
  });

  group('a cut', () {
    JournalEntry viaRecord(String title) =>
        JournalEntry.fromRecord(record({'title': title}))!;

    test('does not split a pair of surrogates', () {
      // 79 letters and one character that takes two code units: 81 in all
      final cut = viaRecord('${'a' * 79}😀').title;
      expect(cut, 'a' * 79);
      expect(cut.codeUnits.last, 'a'.codeUnitAt(0));
    });

    test('does not leave the blank it ends on', () {
      expect(viaRecord('${'a' * 79} bcd').title, 'a' * 79);
    });

    test('leaves a title of exactly the limit whole', () {
      expect(viaRecord('c' * 80).title, 'c' * 80);
      expect(viaRecord('c' * 81).title, 'c' * 80);
    });
  });

  group('what a record is read as', () {
    test('a time with something around it is no time', () {
      expect(parseJournalAt('2026-11-16T08:15'), at);
      expect(parseJournalAt('x2026-11-16T08:15'), isNull);
      expect(parseJournalAt('2026-11-16T08:15x'), isNull);
      expect(parseJournalAt(' 2026-11-16T08:15'), isNull);
    });

    test('a minute is 00 to 59, an hour 00 to 23', () {
      expect(parseJournalAt('2026-11-16T08:59'), isNotNull);
      expect(parseJournalAt('2026-11-16T08:60'), isNull);
      expect(parseJournalAt('2026-11-16T08:99'), isNull);
      expect(parseJournalAt('2026-11-16T23:59'), isNotNull);
      expect(parseJournalAt('2026-11-16T24:00'), isNull);
    });

    test('its title is one line and its text is cleaned', () {
      final e = JournalEntry.fromRecord(
        record({'title': 'a\nb\t c', 'text': '  a\u0000b\r\nc  '}),
      )!;
      expect(e.title, 'a b c');
      expect(e.text, 'ab\nc');
    });

    test('a record is an entry only if it is one of the diary and its id is '
        'safe', () {
      final other = SyncRecord(
        id: 'a',
        kind: kindTask,
      ).edit({'at': '2026-11-16T08:15', 'text': 'x'}, ts: 1, dev: 'A');
      expect(JournalEntry.fromRecord(other), isNull);
      expect(JournalEntry.fromRecord(record({'text': 'x'}, id: 'a b')), isNull);
      expect(JournalEntry.fromRecord(record({'text': 'x'}))!.text, 'x');
    });
  });

  group('the head of an entry without a title', () {
    JournalEntry untitled(String text) => entry('a', text: text);

    test('is its first line, cut after 60 characters with a mark', () {
      expect(untitled('a' * 60).heading, 'a' * 60);
      expect(untitled('a' * 61).heading, '${'a' * 60}…');
      expect(untitled('a' * 100).heading, '${'a' * 60}…');
      expect(untitled('${'a' * 59}😀b').heading, '${'a' * 59}…');
    });

    test('is the first line that says something, whatever comes before', () {
      // (a line of one control character of the second block is blank when
      // it is read as one line; the text is only cleaned of the first block)
      final e = JournalEntry.fromRecord(record({'text': '\u0080\nMásodik'}))!;
      expect(e.heading, 'Második');
    });
  });

  group('two entries are the same', () {
    final p1 = const PhotoRef(id: 'p1');
    final p2 = const PhotoRef(id: 'p2');

    test('only when every part is the same', () {
      final base = entry('a', title: 't', text: 'x', photos: [p1]);
      expect(base, entry('a', title: 't', text: 'x', photos: [p1]));
      expect(
        base.hashCode,
        entry('a', title: 't', text: 'x', photos: [p1]).hashCode,
      );
      for (final other in [
        entry('b', title: 't', text: 'x', photos: [p1]),
        entry(
          'a',
          when: at.add(const Duration(minutes: 1)),
          title: 't',
          text: 'x',
          photos: [p1],
        ),
        entry('a', title: 'u', text: 'x', photos: [p1]),
        entry('a', title: 't', text: 'y', photos: [p1]),
        entry('a', title: 't', text: 'x', photos: [p2]),
        entry('a', title: 't', text: 'x', photos: [p1, p2]),
        entry('a', title: 't', text: 'x'),
      ]) {
        expect(base == other, isFalse);
        expect(other == base, isFalse);
      }
    });

    test('a list of pictures that only starts alike is another list', () {
      final one = entry('a', photos: [p1]);
      final two = entry('a', photos: [p1, p2]);
      expect(one == two, isFalse);
      expect(two == one, isFalse);
    });
  });

  group('what a list shows of an entry', () {
    JournalEntry make(String title, String text) =>
        entry('a', title: title, text: text);

    test('the first lines are at most as many as asked, and say when there '
        'are more', () {
      expect(journalExcerpt('1\n2\n3'), '1\n2\n3');
      expect(journalExcerpt('1\n2\n3\n4'), '1\n2\n3…');
      expect(journalExcerpt('1\n2', maxLines: 2), '1\n2');
      expect(journalExcerpt('1\n2\n3', maxLines: 2), '1\n2…');
    });

    test('a line has no blank around it, and an empty line is not a line', () {
      expect(journalExcerpt('  a  \n\n  b  '), 'a\nb');
    });

    test('the length is 240 characters unless another is asked', () {
      expect(journalExcerpt('x' * 100), 'x' * 100);
      expect(journalExcerpt('x' * 240), 'x' * 240);
      expect(journalExcerpt('x' * 241), '${'x' * 240}…');
      expect(journalExcerpt('x' * 50, maxChars: 10), '${'x' * 10}…');
    });

    test('a preview of an entry with a title holds as many lines as asked', () {
      final e = make('Cím', '1\n2\n3\n4\n5');
      expect(journalPreview(e), '1\n2\n3…');
      expect(journalPreview(e, maxLines: 2), '1\n2…');
      expect(journalPreview(e, maxLines: 5), '1\n2\n3\n4\n5');
      expect(
        journalPreview(make('Cím', 'x' * 50), maxChars: 10),
        '${'x' * 10}…',
      );
    });

    test('a preview of an entry without a title leaves its head out, as long '
        'as the head showed it whole', () {
      expect(journalPreview(make('', 'Fej\nA\nB')), 'A\nB');
      // (a first line of 60 characters is shown whole as the head)
      expect(journalPreview(make('', '${'a' * 60}\nmásik')), 'másik');
      // (one of 61 is cut short in the head: the preview shows all of it)
      expect(
        journalPreview(make('', '${'a' * 61}\nmásik')),
        '${'a' * 61}\nmásik',
      );
    });

    test('a preview of an entry without a title holds the lines and the '
        'length that were asked for', () {
      final e = make('', 'Fej\n${'x' * 50}\nb\nc\nd');
      expect(journalPreview(e, maxLines: 2), '${'x' * 50}\nb…');
      expect(journalPreview(e, maxChars: 10), '${'x' * 10}…');
    });

    test('a preview has nothing in it when the text has nothing', () {
      expect(journalPreview(entry('a', title: 'Csak cím', text: '')), '');
    });
  });

  group('the search of the diary', () {
    test('a word is not found across the end of the title', () {
      final e = entry('a', title: 'xa', text: 'bx');
      expect(searchJournal([e], 'ab').hits, isEmpty);
      expect(searchJournal([e], 'xa bx').hits, [e]);
      expect(searchJournal([e], 'xa').hits, [e]);
      expect(searchJournal([e], 'bx').hits, [e]);
    });
  });

  group('a draft', () {
    test('with only blanks in its title is empty', () {
      expect(JournalDraft(id: 'a', at: at, title: '   ').isEmpty, isTrue);
      expect(JournalDraft(id: 'a', at: at, text: ' \n ').isEmpty, isTrue);
      expect(JournalDraft(id: 'a', at: at, title: 'x').isEmpty, isFalse);
      expect(
        JournalDraft(
          id: 'a',
          at: at,
          photos: const [PhotoRef(id: 'p')],
        ).isEmpty,
        isFalse,
      );
    });

    test('is read with its title as one line and its text cleaned', () {
      final d = JournalDraft.decode(
        '{"id":"a","at":"2026-11-16T08:15","title":"a\\nb\\t c",'
        '"text":"x\\u0000y\\r\\nz"}',
      )!;
      expect(d.title, 'a b c');
      expect(d.text, 'xy\nz');
    });

    test('is read with its title cut at the limit, and its text too', () {
      final d = JournalDraft.decode(
        '{"id":"a","at":"2026-11-16T08:15","title":"${'c' * 90}",'
        '"text":"${'t' * 20010}"}',
      )!;
      expect(d.title.length, maxJournalTitle);
      expect(d.text.length, maxJournalText);
    });

    test('with nothing in it is not offered', () {
      expect(
        JournalDraft.decode('{"id":"a","at":"2026-11-16T08:15","title":" "}'),
        isNull,
      );
    });
  });

  group('the name of a picture in Drive (9th round)', () {
    test('is the prefix, the id and .jpg, and nothing else', () {
      expect(photoDrivePrefix, 'photo-');
      expect(const PhotoRef(id: 'abc-123_X').driveName, 'photo-abc-123_X.jpg');
      for (final id in ['a', 'a' * 40, 'A-b_9', '0123456789']) {
        final p = PhotoRef(id: id, width: 4, height: 3, bytes: 7);
        expect(p.driveName, 'photo-$id.jpg', reason: id);
        expect(p.driveName, 'photo-${p.fileName}', reason: id);
        expect(photoDriveNamePattern.firstMatch(p.driveName!)![1], id);
      }
    });

    test('only a JPEG travels: any other kind has no name there', () {
      expect(const PhotoRef(id: 'a').syncable, isTrue);
      expect(const PhotoRef(id: 'a', ext: 'jpg').syncable, isTrue);
      for (final ext in photoExtensions.where((e) => e != 'jpg')) {
        final p = PhotoRef(id: 'a', ext: ext);
        expect(p.syncable, isFalse, reason: ext);
        expect(p.driveName, isNull, reason: ext);
      }
    });

    test('the pattern takes a name this makes, and no other', () {
      for (final good in [
        'photo-a.jpg',
        'photo-${'x' * 40}.jpg',
        'photo-a_B-9.jpg',
      ]) {
        expect(photoDriveNamePattern.hasMatch(good), isTrue, reason: good);
      }
      for (final bad in [
        'photo-.jpg',
        'photo-${'x' * 41}.jpg',
        'photo-a.png',
        'photo-a.jpeg',
        'photo-a.JPG',
        'photo-a.jpg.tmp',
        'photo-a.jpg ',
        ' photo-a.jpg',
        'photo-a/b.jpg',
        'photo-a b.jpg',
        'photo-a.b.jpg',
        'Photo-a.jpg',
        'a.jpg',
        'photo_a.jpg',
        'xphoto-a.jpg',
        'photo-a.jpg\n',
        'photo-a1xjpg', // (the dot before "jpg" is a dot, not any character)
        'photo-a_jpg',
      ]) {
        expect(photoDriveNamePattern.hasMatch(bad), isFalse, reason: bad);
      }
    });

    test('is never taken for a record, nor a record for a picture', () {
      // (the sync of the records reads every file whose name is a record's:
      // a picture must never be one, and the mail of the finances is "fin-")
      for (final kind in syncedKinds) {
        expect(
          recordFileNamePattern.hasMatch('photo-a.jpg'),
          isFalse,
          reason: kind,
        );
        expect(
          safeRecordFileNamePattern.hasMatch('photo-a.jpg'),
          isFalse,
          reason: kind,
        );
        expect(
          photoDriveNamePattern.hasMatch(recordFileName(kind, 'a')),
          isFalse,
          reason: kind,
        );
        expect(kind.startsWith(photoDrivePrefix), isFalse, reason: kind);
      }
      expect('fin-peer-x.json'.startsWith(photoDrivePrefix), isFalse);
      expect(photoDrivePrefix.startsWith('fin-'), isFalse);
    });

    test('a reference read from a record has a name that fits the pattern', () {
      final p = PhotoRef.tryParse({'id': 'a1', 'w': 1, 'h': 1, 'b': 1})!;
      expect(photoDriveNamePattern.hasMatch(p.driveName!), isTrue);
      final other = PhotoRef.tryParse({'id': 'a1', 'x': 'heic'})!;
      expect(other.driveName, isNull);
    });
  });
}
