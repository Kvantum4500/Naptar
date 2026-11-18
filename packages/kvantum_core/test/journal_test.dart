import 'dart:convert';

import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// The diary (8th round): the entries and how they are checked, how a record
/// holds one, what two devices make of the same entry, the list by day, the
/// search and the draft.
void main() {
  final nov16 = DateTime.utc(2026, 11, 16, 8, 15);

  SyncRecord rec(
    String id,
    Map<String, Object?> fields, {
    int ts = 1000,
    String dev = 'aaaa',
    SyncRecord? base,
  }) => (base ?? SyncRecord(id: id, kind: kindJournal)).edit(
    fields,
    ts: ts,
    dev: dev,
  );

  JournalEntry entry(
    String id, {
    DateTime? at,
    String title = 'Kirándulás',
    String text = 'Szép idő volt.',
    List<PhotoRef> photos = const [],
  }) => JournalEntry.checked(
    id: id,
    at: at ?? nov16,
    title: title,
    text: text,
    photos: photos,
  );

  PhotoRef photo(String id, {int w = 1600, int h = 1200, int b = 400000}) =>
      PhotoRef(id: id, width: w, height: h, bytes: b);

  group('the kind', () {
    test('journal is a synced kind and its files have names Drive knows', () {
      expect(kindJournal, 'journal');
      expect(syncedKinds, contains(kindJournal));
      expect(syncedKinds.toSet(), hasLength(syncedKinds.length));
      final name = recordFileName(
        kindJournal,
        '3f2a9c1e-8b1d-4c1e-9a77-0e5f2d6b7a10',
      );
      expect(name, 'journal-3f2a9c1e-8b1d-4c1e-9a77-0e5f2d6b7a10.json');
      for (final pattern in [
        recordFileNamePattern,
        safeRecordFileNamePattern,
      ]) {
        final m = pattern.firstMatch(name);
        expect(m, isNotNull);
        expect(m![1], kindJournal);
      }
    });
  });

  group('a picture', () {
    test('is told by its id, its ending and its size', () {
      final p = PhotoRef.tryParse({
        'id': 'abc-123',
        'w': 1600,
        'h': 1200,
        'b': 345678,
      })!;
      expect(p.fileName, 'abc-123.jpg');
      expect((p.width, p.height, p.bytes), (1600, 1200, 345678));
      expect(PhotoRef.tryParse(p.toJson()), p);
    });

    test('equal pictures hash alike, and say what they are', () {
      const a = PhotoRef(id: 'p1', width: 3, height: 2, bytes: 9);
      const b = PhotoRef(id: 'p1', width: 3, height: 2, bytes: 9);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<PhotoRef>{a}..add(b), hasLength(1));
      expect(
        a,
        isNot(const PhotoRef(id: 'p1', width: 3, height: 2, bytes: 10)),
      );
      expect(a.toString(), 'PhotoRef(p1.jpg, 3x2, 9 B)');
    });

    test('keeps another ending, and leaves the usual one unsaid', () {
      const heic = PhotoRef(id: 'x1', ext: 'heic', bytes: 5);
      expect(heic.fileName, 'x1.heic');
      expect(heic.toJson()['x'], 'heic');
      expect(PhotoRef.tryParse(heic.toJson()), heic);
      expect(const PhotoRef(id: 'x1').toJson().containsKey('x'), isFalse);
    });

    test('with an id that could carry a path is not a picture', () {
      for (final id in [
        '../x',
        'a/b',
        r'a\b',
        '',
        'a b',
        'x' * 41,
        'ö',
        null,
        5,
      ]) {
        expect(PhotoRef.tryParse({'id': id}), isNull, reason: '$id');
      }
    });

    test('with an ending that is no picture is not a picture', () {
      for (final x in ['exe', 'jpg/x', '', '.jpg', 'JPG', 5]) {
        expect(PhotoRef.tryParse({'id': 'a', 'x': x}), isNull, reason: '$x');
      }
    });

    test('with a size that cannot be is not a picture', () {
      for (final bad in [
        {'id': 'a', 'w': -1},
        {'id': 'a', 'h': maxPhotoSide + 1},
        {'id': 'a', 'b': maxPhotoBytes + 1},
        {'id': 'a', 'w': 'sok'},
        {'id': 'a', 'b': -5},
      ]) {
        expect(PhotoRef.tryParse(bad), isNull, reason: '$bad');
      }
      // (an unknown size is 0, and says nothing else)
      expect(PhotoRef.tryParse({'id': 'a'})!.width, 0);
    });

    test('a list of them: only the usable ones, each id once, at most 12', () {
      final text = encodePhotos([for (var i = 0; i < 12; i++) photo('p$i')]);
      expect(decodePhotos(text), hasLength(12));
      final many = jsonEncode([
        for (var i = 0; i < 20; i++) photo('p$i').toJson(),
      ]);
      expect(decodePhotos(many), hasLength(maxJournalPhotos));
      final mixed = jsonEncode([
        photo('a').toJson(),
        {'id': '../x'},
        'nem kép',
        null,
        photo('a', w: 5).toJson(), // the same id again
        photo('b').toJson(),
      ]);
      expect([for (final p in decodePhotos(mixed)) p.id], ['a', 'b']);
      for (final v in <Object?>[null, '', 'nem json', '{"a":1}', 5, '"x"']) {
        expect(decodePhotos(v), isEmpty, reason: '$v');
      }
    });
  });

  group('an entry made of what the user typed', () {
    test('holds what was given, and says when it is about', () {
      final e = entry('e1', photos: [photo('p1')]);
      expect(e.title, 'Kirándulás');
      expect(e.text, 'Szép idő volt.');
      expect(e.photos.single.id, 'p1');
      expect(e.at, nov16);
      expect(e.day, DateTime.utc(2026, 11, 16));
      expect(e.timeText, '08:15');
    });

    test('equal entries hash alike, different pictures make them differ', () {
      final a = entry('e1', photos: [photo('p1')]);
      final b = entry('e1', photos: [photo('p1')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
      expect(a, isNot(entry('e1', photos: [photo('p2')])));
      expect(a, isNot(entry('e2', photos: [photo('p1')])));
    });

    test('drops the seconds and makes the time a floating one', () {
      final e = JournalEntry.checked(
        id: 'e1',
        at: DateTime(2026, 11, 16, 8, 15, 42, 7),
        title: 'x',
      );
      expect(e.at, DateTime.utc(2026, 11, 16, 8, 15));
      expect(e.at.isUtc, isTrue);
    });

    test('has to hold something: a title, a text or a picture', () {
      expect(
        () => JournalEntry.checked(id: 'e', at: nov16),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => JournalEntry.checked(id: 'e', at: nov16, title: '  ', text: '\n'),
        throwsA(isA<ArgumentError>()),
      );
      JournalEntry.checked(id: 'e', at: nov16, text: 'x');
      JournalEntry.checked(id: 'e', at: nov16, photos: [photo('p')]);
      JournalEntry.checked(id: 'e', at: nov16, title: 'x');
    });

    test('says in words what is wrong', () {
      String why(void Function() f) {
        try {
          f();
        } on ArgumentError catch (e) {
          return '${e.message}';
        }
        return 'nothing';
      }

      expect(
        why(() => JournalEntry.checked(id: 'e', at: nov16)),
        'Írj valamit, vagy tölts fel egy képet.',
      );
      expect(
        why(
          () => JournalEntry.checked(
            id: 'e',
            at: nov16,
            title: 'x' * (maxJournalTitle + 1),
          ),
        ),
        'A cím legföljebb 80 karakter lehet.',
      );
      expect(
        why(
          () => JournalEntry.checked(
            id: 'e',
            at: nov16,
            text: 'x' * (maxJournalText + 1),
          ),
        ),
        'A szöveg legföljebb 20000 karakter lehet.',
      );
      expect(
        why(
          () => JournalEntry.checked(
            id: 'e',
            at: nov16,
            photos: [for (var i = 0; i < 13; i++) photo('p$i')],
          ),
        ),
        'Egy bejegyzéshez legföljebb 12 kép tartozhat.',
      );
      expect(
        why(
          () => JournalEntry.checked(
            id: 'e',
            at: nov16,
            photos: [photo('p'), photo('p')],
          ),
        ),
        'Ugyanaz a kép kétszer szerepel.',
      );
      expect(
        why(() => JournalEntry.checked(id: '../e', at: nov16, title: 'x')),
        'Az azonosító nem megfelelő.',
      );
    });

    test('takes the largest sizes, no more', () {
      JournalEntry.checked(
        id: 'e',
        at: nov16,
        title: 'x' * maxJournalTitle,
        text: 'y' * maxJournalText,
        photos: [for (var i = 0; i < maxJournalPhotos; i++) photo('p$i')],
      );
    });

    test('keeps the line breaks of the text, not of the title', () {
      final e = JournalEntry.checked(
        id: 'e',
        at: nov16,
        title: 'Első\nmásodik\tharmadik',
        text: 'Egy\r\nkettő\rhárom\n\n  négy  ',
      );
      expect(e.title, 'Első második harmadik');
      expect(e.text, 'Egy\nkettő\nhárom\n\n  négy');
    });

    test('takes the control and invisible characters out of the words', () {
      // (written as code points: the characters themselves are invisible)
      String c(int code) => String.fromCharCode(code);
      final e = JournalEntry.checked(
        id: 'e',
        at: nov16,
        title: 'a${c(0)}b${c(0x200B)}c${c(0x202E)}d',
        text: 'x${c(7)}y${c(0x200F)}z${c(0x2060)}',
      );
      // (a control character in a title is a gap, an invisible one is nothing)
      expect(e.title, 'a bcd');
      expect(e.text, 'xyz');
    });

    test('counts characters, not bytes: the accents are one each', () {
      final e = JournalEntry.checked(
        id: 'e',
        at: nov16,
        title: 'ő' * maxJournalTitle,
      );
      expect(e.title.length, maxJournalTitle);
    });
  });

  group('the head of an entry', () {
    test(
      'is the title, else the first line of the text, else what it holds',
      () {
        expect(entry('e').heading, 'Kirándulás');
        expect(
          JournalEntry.checked(
            id: 'e',
            at: nov16,
            text: '\n\n  Első sor\nmásik',
          ).heading,
          'Első sor',
        );
        expect(
          JournalEntry.checked(
            id: 'e',
            at: nov16,
            text: 'x' * 100,
          ).heading.length,
          lessThanOrEqualTo(61),
        );
        expect(
          JournalEntry.checked(
            id: 'e',
            at: nov16,
            photos: [photo('p')],
          ).heading,
          '1 kép',
        );
        expect(
          JournalEntry.checked(
            id: 'e',
            at: nov16,
            photos: [photo('p'), photo('q'), photo('r')],
          ).heading,
          '3 kép',
        );
      },
    );
  });

  group('a record', () {
    test('holds an entry and gives it back', () {
      final e = entry('e1', photos: [photo('p1'), photo('p2')]);
      final back = JournalEntry.fromRecord(rec('e1', e.fields))!;
      expect(back, e);
      expect(back.photos, e.photos);
    });

    test('has a field for each part, the pictures in one', () {
      final f = entry('e1', photos: [photo('p1')]).fields;
      expect(f.keys.toSet(), {'at', 'title', 'text', 'photos'});
      expect(f['at'], '2026-11-16T08:15');
      expect(f['photos'], isA<String>());
    });

    test('of another kind, or with an id that is no id, is no entry', () {
      final e = entry('e1');
      expect(
        JournalEntry.fromRecord(
          SyncRecord(id: 'e1', kind: kindTask).edit(e.fields, ts: 1, dev: 'a'),
        ),
        isNull,
      );
      expect(JournalEntry.fromRecord(rec('../e', e.fields)), isNull);
    });

    test(
      'without a real time is no entry (a corrupt file hides itself only)',
      () {
        for (final at in <Object?>[
          null,
          '',
          'tegnap',
          '2026-02-30T08:15',
          '2026-11-16T25:00',
          '2026-11-16 08:15',
          '2026-11-16T08:15:00',
          5,
        ]) {
          expect(
            JournalEntry.fromRecord(rec('e', {'at': at, 'title': 'x'})),
            isNull,
            reason: '$at',
          );
        }
      },
    );

    test('with words that are too long is cut, with pictures that are bad has the rest', () {
      final r = rec('e', {
        'at': '2026-11-16T08:15',
        'title': 'c' * 200,
        'text': 't' * 30000,
        'photos': jsonEncode([
          photo('p').toJson(),
          {'id': '../x'},
        ]),
      });
      final e = JournalEntry.fromRecord(r)!;
      expect(e.title.length, maxJournalTitle);
      expect(e.text.length, maxJournalText);
      expect([for (final p in e.photos) p.id], ['p']);
    });

    test('with fields of the wrong kind is read as empty words', () {
      final e = JournalEntry.fromRecord(
        rec('e', {
          'at': '2026-11-16T08:15',
          'title': 5,
          'text': [1],
          'photos': 7,
        }),
      )!;
      expect(e.title, '');
      expect(e.text, '');
      expect(e.photos, isEmpty);
      expect(e.heading, 'Üres bejegyzés');
    });
  });

  group('two devices', () {
    test('a title changed on one and a text on the other both stay', () {
      final base = rec('e1', entry('e1').fields, ts: 100);
      final a = rec(
        'e1',
        entry('e1', title: 'Új cím').fields,
        ts: 200,
        dev: 'aaaa',
        base: base,
      );
      final b = rec(
        'e1',
        entry('e1', text: 'Új szöveg').fields,
        ts: 210,
        dev: 'bbbb',
        base: base,
      );
      for (final merged in [a.merge(b), b.merge(a)]) {
        final e = JournalEntry.fromRecord(merged)!;
        expect(e.title, 'Új cím');
        expect(e.text, 'Új szöveg');
      }
    });

    test('the list of pictures is one wish: the later one wins whole', () {
      final base = rec(
        'e1',
        entry('e1', photos: [photo('p1')]).fields,
        ts: 100,
      );
      final a = rec(
        'e1',
        entry('e1', photos: [photo('p1'), photo('pa')]).fields,
        ts: 200,
        dev: 'aaaa',
        base: base,
      );
      final b = rec(
        'e1',
        entry('e1', photos: [photo('pb')]).fields,
        ts: 300,
        dev: 'bbbb',
        base: base,
      );
      for (final merged in [a.merge(b), b.merge(a)]) {
        expect(
          [for (final p in JournalEntry.fromRecord(merged)!.photos) p.id],
          ['pb'],
        );
      }
    });

    test(
      'a deletion is the usual marker; taking it back brings the entry again',
      () {
        final r = rec('e1', entry('e1').fields, ts: 100);
        final gone = r.edit({'deleted': true}, ts: 200, dev: 'aaaa');
        expect(journalEntries([gone]), isEmpty);
        expect(
          JournalEntry.fromRecord(gone),
          isNotNull,
          reason: 'still readable',
        );
        final back = gone.edit({'deleted': false}, ts: 300, dev: 'aaaa');
        expect(journalEntries([back]).single.id, 'e1');
      },
    );
  });

  group('the list', () {
    test('has the newest first, by time and then by id', () {
      final records = [
        rec('a', entry('a', at: DateTime.utc(2026, 11, 14, 9)).fields),
        rec('b', entry('b', at: DateTime.utc(2026, 11, 16, 7)).fields),
        rec('c', entry('c', at: DateTime.utc(2026, 11, 16, 18)).fields),
        rec('d', entry('d', at: DateTime.utc(2026, 11, 16, 18)).fields),
      ];
      expect(
        [for (final e in journalEntries(records)) e.id],
        ['d', 'c', 'b', 'a'],
      );
      expect(
        [for (final e in journalEntries(records.reversed)) e.id],
        ['d', 'c', 'b', 'a'],
        reason: 'the same on every device',
      );
    });

    test('leaves out what was deleted and what is not an entry', () {
      final records = [
        rec('a', entry('a').fields),
        rec('b', entry('b').fields).edit({'deleted': true}, ts: 2000, dev: 'a'),
        rec('c', {'at': 'x', 'title': 'y'}),
        rec('../d', entry('d').fields),
      ];
      expect([for (final e in journalEntries(records)) e.id], ['a']);
    });

    test('is grouped by day, the latest day first', () {
      final list = journalEntries([
        rec('a', entry('a', at: DateTime.utc(2026, 11, 14, 9)).fields),
        rec('b', entry('b', at: DateTime.utc(2026, 11, 16, 7)).fields),
        rec('c', entry('c', at: DateTime.utc(2026, 11, 16, 18)).fields),
        rec('d', entry('d', at: DateTime.utc(2026, 10, 31, 23, 59)).fields),
      ]);
      final days = journalDays(list);
      expect(
        [for (final d in days) d.day],
        [
          DateTime.utc(2026, 11, 16),
          DateTime.utc(2026, 11, 14),
          DateTime.utc(2026, 10, 31),
        ],
      );
      expect([for (final e in days.first.entries) e.id], ['c', 'b']);
      expect(journalDays(const []), isEmpty);
    });
  });

  group('the first lines', () {
    test('are at most three, without the empty ones', () {
      expect(
        journalExcerpt('Egy\n\n  \nKettő\nHáromnégy\nNégy\nÖt'),
        'Egy\nKettő\nHáromnégy…',
      );
      expect(journalExcerpt('Egy\nKettő'), 'Egy\nKettő');
      expect(journalExcerpt(''), '');
      expect(journalExcerpt('  \n \n'), '');
    });

    test('are cut at a length, with a mark', () {
      final out = journalExcerpt('x' * 500, maxChars: 100);
      expect(out.length, 101);
      expect(out.endsWith('…'), isTrue);
      expect(journalExcerpt('x' * 100, maxChars: 100), 'x' * 100);
    });
  });

  group('what a list shows under the head', () {
    JournalEntry make(String title, String text) =>
        JournalEntry.checked(id: 'e', at: nov16, title: title, text: text);

    test('is the first lines of the text, when there is a title', () {
      expect(
        journalPreview(make('Cím', 'Egy\nKettő\nHárom\nNégy')),
        'Egy\nKettő\nHárom…',
      );
      expect(journalPreview(make('Cím', '')), '');
    });

    test('leaves out the first line when that is the head already', () {
      expect(
        journalPreview(make('', 'Fejléc\nMásodik\nHarmadik')),
        'Második\nHarmadik',
      );
      expect(journalPreview(make('', 'Csak egy sor')), '');
      expect(journalPreview(make('', '\n\nFejléc\nRest')), 'Rest');
    });

    test('shows a long first line whole: the head cut it short', () {
      final long = 'szó ' * 30; // 119 characters
      final e = make('', '${long.trim()}\nMásik');
      expect(e.heading.endsWith('…'), isTrue);
      expect(journalPreview(e).startsWith('szó szó'), isTrue);
      expect(journalPreview(e).contains('Másik'), isTrue);
    });

    test('is nothing for an entry of pictures only', () {
      final e = JournalEntry.checked(id: 'e', at: nov16, photos: [photo('p')]);
      expect(journalPreview(e), '');
    });
  });

  group('the search', () {
    final list = journalEntries([
      rec(
        'a',
        entry(
          'a',
          title: 'Fogorvos',
          text: 'Nem fájt.',
          at: DateTime.utc(2026, 11, 14),
        ).fields,
      ),
      rec(
        'b',
        entry(
          'b',
          title: 'Kirándulás',
          text: 'A Börzsönyben túráztunk, szép idő volt.',
          at: DateTime.utc(2026, 11, 15),
        ).fields,
      ),
      rec(
        'c',
        entry(
          'c',
          title: '',
          text: 'Esti futás a Duna-parton',
          at: DateTime.utc(2026, 11, 16),
        ).fields,
      ),
    ]);

    test('looks at the title and the text, without accents and case', () {
      expect(
        [for (final e in searchJournal(list, 'fogorvos').hits) e.id],
        ['a'],
      );
      expect(
        [for (final e in searchJournal(list, 'BORZSONY').hits) e.id],
        ['b'],
      );
      expect(
        [for (final e in searchJournal(list, 'szep ido').hits) e.id],
        ['b'],
      );
      expect(
        [for (final e in searchJournal(list, 'duna futas').hits) e.id],
        ['c'],
      );
    });

    test('wants every word, in any order', () {
      expect(searchJournal(list, 'idő szép').hits, hasLength(1));
      expect(searchJournal(list, 'idő fogorvos').hits, isEmpty);
    });

    test('wants at least a word of two letters', () {
      expect(searchJournal(list, '').hits, isEmpty);
      expect(searchJournal(list, 'a').hits, isEmpty);
      expect(searchJournal(list, '  ').hits, isEmpty);
    });

    test('keeps the order it was given and says how many more there were', () {
      final many = journalEntries([
        for (var i = 0; i < 40; i++)
          rec(
            'e$i',
            entry(
              'e$i',
              title: 'Séta $i',
              text: 'x',
              at: DateTime.utc(2026, 11, 1, 0, i),
            ).fields,
          ),
      ]);
      final r = searchJournal(many, 'séta');
      expect(r.hits, hasLength(30));
      expect(r.more, 10);
      expect(r.hits.first.id, many.first.id);
      expect(searchJournal(many, 'séta', limit: 100).more, 0);
    });
  });

  group('the draft', () {
    final draft = JournalDraft(
      id: 'new-1',
      at: nov16,
      title: 'Cím',
      text: 'Szöveg\nsorral',
      photos: [photo('p1')],
    );

    test('is written and read back', () {
      final back = JournalDraft.decode(draft.encode())!;
      expect(back.id, 'new-1');
      expect(back.at, nov16);
      expect(back.title, 'Cím');
      expect(back.text, 'Szöveg\nsorral');
      expect(back.photos, [photo('p1')]);
    });

    test('with nothing in it is not worth offering', () {
      expect(JournalDraft(id: 'n', at: nov16).isEmpty, isTrue);
      expect(
        JournalDraft.decode(JournalDraft(id: 'n', at: nov16).encode()),
        isNull,
      );
      expect(
        JournalDraft.decode(
          JournalDraft(id: 'n', at: nov16, title: ' \n ').encode(),
        ),
        isNull,
      );
      expect(
        JournalDraft.decode(
          JournalDraft(id: 'n', at: nov16, photos: [photo('p')]).encode(),
        ),
        isNotNull,
      );
    });

    test('damaged is not offered, and never throws', () {
      for (final t in <String?>[
        null,
        '',
        'nem json',
        '[1,2]',
        '{}',
        '{"id":"../x","at":"2026-11-16T08:15","title":"x"}',
        '{"id":"n","at":"tegnap","title":"x"}',
        '{"id":5,"at":"2026-11-16T08:15","title":"x"}',
      ]) {
        expect(JournalDraft.decode(t), isNull, reason: '$t');
      }
    });

    test('cuts words that are too long and drops pictures that are bad', () {
      final d = JournalDraft.decode(
        jsonEncode({
          'id': 'n',
          'at': '2026-11-16T08:15',
          'title': 'c' * 300,
          'text': 't' * 30000,
          'photos': jsonEncode([
            photo('p').toJson(),
            {'id': '../x'},
          ]),
        }),
      )!;
      expect(d.title.length, maxJournalTitle);
      expect(d.text.length, maxJournalText);
      expect(d.photos.single.id, 'p');
    });
  });
}
