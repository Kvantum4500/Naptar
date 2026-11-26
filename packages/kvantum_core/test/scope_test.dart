import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

/// What a request is about, read from its wording (2d): accents are optional,
/// a refused verb ("ne töröld") is no request, words that only look like money
/// are not money, a day named narrows the window, a question about the
/// calendar needs only the events, and "delete this and plan that" carries both.
void main() {
  // 2026-05-06 is a Wednesday
  final wed = floating(2026, 5, 6);

  /// The shape of a scope in one line: the kind, the window, the blocks.
  String shape(AskScope s) => [
    if (s.mixed)
      'mixed'
    else if (s.edit)
      'edit'
    else if (s.finance && !s.events)
      'money'
    else
      'plan',
    '${s.days}d',
    if (s.tasks) 'tasks',
    if (s.checkins) 'checkins',
    if (s.slots) 'slots',
    if (s.finance && s.events) 'finance',
    if (!s.events) 'no-events',
  ].join(' ');

  const all = 'tasks checkins slots';

  group('foldHu', () {
    test('lower case, no accents', () {
      expect(foldHu('Töröld a HOLNAPI edzést'), 'torold a holnapi edzest');
      expect(foldHu('ŐŰ őű áéíóöúü'), 'ou ou aeioouu');
      expect(foldHu('abc 123 – ft'), 'abc 123 – ft');
    });
  });

  group('deleting and moving', () {
    final table = <(String, String)>[
      ('Töröld a holnapi edzést', 'edit 3d'),
      ('torold a holnapi edzest', 'edit 3d'),
      ('TÖRÖLD A KÉZZEL FELVETT PROGRAMOKAT', 'edit 14d'),
      ('Töröld a kézzel felvett programokat holnapra', 'edit 3d'),
      ('Told át a keddi edzést csütörtökre', 'edit 14d'),
      ('Helyezd át a fogorvost', 'edit 14d'),
      ('Áthelyeznéd a megbeszélést?', 'edit 14d'),
      ('Módosítsd az ebédet', 'edit 14d'),
      ('Szüntesd meg a szerdai programot', 'edit 14d'),
      ('Vedd ki a péntek esti edzést', 'edit 14d'),
      ('Halaszd el az edzést holnapra', 'edit 3d'),
      ('Cseréld le a keddi edzést', 'edit 14d'),
      ('Töröld ma a délutáni programokat', 'edit 3d'),
      ('Töröld a jövő heti edzéseket', 'edit 12d'),
      // the first verb is a request, the second is refused
      ('Töröld a holnapit, de ne töröld a keddit', 'edit 3d'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }
  });

  group('a refused verb is no request', () {
    final table = <(String, String)>[
      ('Ne töröld a fogorvost', 'plan 7d'),
      ('Nem kell törölni semmit', 'plan 7d'),
      (
        'Ne told át az edzést, csak nézd meg mikor van szabad időm',
        'plan 7d $all',
      ),
      ('Tervezz edzést, de ne töröld a meglévőket', 'plan 7d $all'),
      ('Soha ne helyezd át a műszakot', 'plan 7d $all'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }
  });

  group('deleting and planning in one request', () {
    final table = <(String, String)>[
      (
        'Töröld a holnapi edzést és tervezz újat a jövő hétre',
        'mixed 12d $all',
      ),
      ('Told át az edzést és javasolj másik időpontot', 'mixed 14d $all'),
      (
        'Helyezd át a keddit, aztán ütemezd be a feladataimat',
        'mixed 14d $all',
      ),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }

    test('it is a deleting request that carries the planning too', () {
      final s = scopeFor('Told át az edzést és javasolj másik időpontot', wed);
      expect((s.edit, s.plan, s.mixed), (true, true, true));
      expect(s.kind, PromptKind.edit);
      expect(s.narrowed().mixed, isTrue);
    });
  });

  group('words that only look like something', () {
    final table = <(String, String)>[
      // moving house, payday, a towel, "mozgás" (movement) is not "mozgasd"
      ('Segítesz a költözésben szombaton?', 'plan 7d'),
      ('Mikor van fizetésnap?', 'plan 7d slots'),
      ('Vigyek törölközőt az edzésre?', 'plan 7d $all'),
      ('A mozgás mennyit számít?', 'plan 7d $all'),
      ('Fizetett szabadságot veszek ki jövő héten', 'plan 12d'),
      ('Milyen keretrendszert használjak?', 'plan 7d'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }
  });

  group('money', () {
    final table = <(String, String)>[
      ('Hogy állok a költségkerettel?', 'money 7d no-events'),
      ('Mennyit költöttem ebben a hónapban?', 'money 7d no-events'),
      ('Mennyi a megtakarításom?', 'money 7d no-events'),
      ('Mennyi a rezsi?', 'money 7d no-events'),
      ('Mennyi pénzem maradt?', 'money 7d no-events'),
      ('hogy allok a penzzel', 'money 7d no-events'),
      ('Mikor jön a következő számla?', 'money 7d no-events'),
      ('Tervezz edzést, és mennyit költhetek sportra?', 'plan 7d $all finance'),
      ('Tervezz edzést, de figyelj a pénzemre', 'plan 7d $all finance'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }
  });

  group('the window the wording names', () {
    final table = <(String, String)>[
      ('Tervezz edzést ma', 'plan 1d $all'),
      ('Tervezz edzést holnapra', 'plan 2d $all'),
      ('Mit tervezzek holnapután?', 'plan 3d $all'),
      ('Tervezz holnapra és holnaputánra', 'plan 3d $all'),
      ('Tervezz edzést a hétvégére', 'plan 5d $all'),
      ('Tervezz edzést a héten', 'plan 7d $all'),
      ('Tervezz két hétre', 'plan 14d $all'),
      ('Tervezz 2 hétre előre', 'plan 14d $all'),
      ('Tervezz egy hónapra', 'plan 21d $all'),
      ('Tervezz a jövő hétre', 'plan 12d $all'),
      ('Tervezz holnapra és a jövő hétre', 'plan 12d $all'),
      ('Tervezz edzést', 'plan 7d $all'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }

    test('"next week" ends on the Sunday after, whatever today is', () {
      expect(scopeFor('Tervezz a jövő hétre', floating(2026, 5, 4)).days, 14);
      expect(scopeFor('Tervezz a jövő hétre', floating(2026, 5, 10)).days, 8);
    });

    test('the weekend is what is left up to Sunday', () {
      expect(scopeFor('Tervezz a hétvégére', floating(2026, 5, 4)).days, 7);
      expect(scopeFor('Tervezz a hétvégére', floating(2026, 5, 9)).days, 2);
      expect(scopeFor('Tervezz a hétvégére', floating(2026, 5, 10)).days, 1);
    });
  });

  group('a question about the calendar needs only the events', () {
    final table = <(String, String)>[
      ('Mi van a naptáramban?', 'plan 7d $all'),
      ('Mikor van a következő műszakom?', 'plan 7d $all'),
      ('Mikor szabad a szerda este?', 'plan 7d slots'),
      ('Szia', 'plan 7d'),
      ('Mi a helyzet?', 'plan 7d'),
    ];
    for (final (q, want) in table) {
      test(q, () => expect(shape(scopeFor(q, wed)), want));
    }
  });

  test('the kind of request follows the wording', () {
    expect(scopeFor('Tervezz edzést', wed).kind, PromptKind.plan);
    expect(scopeFor('Töröld a holnapi edzést', wed).kind, PromptKind.edit);
    expect(
      scopeFor('Hogy állok a költségkerettel?', wed).kind,
      PromptKind.money,
    );
  });

  group('the system prompt of a mixed request', () {
    String prompt({bool mixed = false, PromptKind kind = PromptKind.edit}) =>
        buildSystemPrompt(
          handbook: '',
          rules: const PlanRules(),
          kind: kind,
          mixed: mixed,
        );

    test('a plain deleting request is as small as it was', () {
      final p = prompt();
      expect(p, contains('deletions'));
      expect(p.contains('KEMÉNY SZABÁLYOK'), isFalse);
      expect(p.contains('feladatok: t='), isFalse);
    });

    test(
      'a mixed one also carries the planning legends and the hard rules',
      () {
        final p = prompt(mixed: true);
        expect(p, contains('deletions'));
        expect(p, contains('r=hivatkozás'));
        expect(p, contains('feladatok: t='));
        expect(p, contains('check_in: d='));
        expect(p, contains('szabad_idosavok'));
        expect(p, contains('KEMÉNY SZABÁLYOK'));
        expect(p, contains('Új eseményt is javasolhatsz'));
      },
    );
  });
}
