import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const bp = 'Europe/Budapest';
DateTime at(int day, int hour, [int min = 0]) =>
    resolveWallClock(bp, floating(2026, 5, day, hour, min));

void main() {
  setUpAll(ensureTimeZones);

  group('compactHandbook', () {
    test('drops blank lines, the file title and the "(üres …)" marker', () {
      const text = '''
# Tanult szokások (az AI javasol)

(üres – az elfogadott javaslatok alapján bővül)

- Ne legyen edzés kedden este
''';
      expect(compactHandbook(text), '- Ne legyen edzés kedden este');
    });

    test('drops template fields without a value, keeps the ones with one', () {
      const text = '''
# Profil (a Kézikönyvben szerkesztheted)
- Fő edzéstípusok: Calisthenics, Gym
- Célok: (pl. állóképesség, izomtömeg, erő)
- Edzettségi szint: (kezdő / haladó)
- Sérülések, korlátok:
- Elérhető eszközök / helyszínek:
- Tipikus munkarend: váltóműszak (lásd a műszak-eseményeket)
- Időzóna: Europe/Budapest
''';
      expect(
        compactHandbook(text),
        '- Fő edzéstípusok: Calisthenics, Gym\n'
        '- Tipikus munkarend: váltóműszak (lásd a műszak-eseményeket)\n'
        '- Időzóna: Europe/Budapest',
      );
    });

    test('a label with indented values under it is real content', () {
      const text = '- Sérülések:\n  - bal bokám\n  - jobb vállam\n- Cél:\n';
      expect(
        compactHandbook(text),
        '- Sérülések:\n  - bal bokám\n  - jobb vállam',
      );
    });

    test('rules, tables and sentences are never touched', () {
      const text = '''
# Szabályok
- Edzés: Calisthenics, Gym és Street Workout.
| Helyzet | Következmény |
|---|---|
| Alvás ≤ 2 | könnyű mozgás |
Ütközésnél a magas súly dönt: indokolj.
''';
      expect(
        compactHandbook(text),
        '- Edzés: Calisthenics, Gym és Street Workout.\n'
        '| Helyzet | Következmény |\n'
        '|---|---|\n'
        '| Alvás ≤ 2 | könnyű mozgás |\n'
        'Ütközésnél a magas súly dönt: indokolj.',
      );
    });

    test('Windows line endings are fine; an empty file stays empty', () {
      expect(compactHandbook('# C\r\n\r\n- a: b\r\n'), '- a: b');
      expect(compactHandbook('# Tanult szokások\n(üres – semmi)\n'), '');
      expect(compactHandbook(''), '');
    });
  });

  group('the first message helpers', () {
    test('nowLine says when now is, in the user zone', () {
      expect(
        nowLine(DateTime.utc(2026, 5, 4, 8, 30), bp),
        'MOST: 2026-05-04 10:30 (Europe/Budapest).',
      );
    });

    test('free slots are one short text per day; an end on another day carries its date', () {
      final slots = [
        TimeSlot(at(5, 7), at(5, 11, 45)),
        TimeSlot(at(5, 15), at(6, 7)),
        TimeSlot(at(7, 9), at(7, 12)),
      ];
      final r = freeSlotsForTool(slots, tz: bp);
      expect(r['idosavok'], {
        '2026-05-05': '07:00-11:45 15:00-05-06 07:00',
        '2026-05-07': '09:00-12:00',
      });
      expect(r.containsKey('levagva'), isFalse);

      final capped = freeSlotsForTool(
        slots,
        tz: bp,
        max: 1,
        note: 'megjegyzés',
      );
      expect((capped['idosavok'] as Map).length, 1);
      expect(capped['levagva'], isTrue);
      expect(capped['osszes'], 3);
      expect(capped['megjegyzes'], 'megjegyzés');
      expect(freeSlotsForTool(const [], tz: bp)['idosavok'], isEmpty);
    });

    test('tasks leave out the default priority and energy', () {
      Map<String, Object?> only(TaskView t) =>
          ((tasksForTool([t], today: floating(2026, 5, 4))['feladatok'] as List)
                  .single
              as Map<String, Object?>);
      TaskView task({int priority = 2, int energy = 3}) => TaskView(
        SyncRecord(id: 'x', kind: kindTask).edit(
          taskFields(title: 'Valami', priority: priority, energyNeed: energy),
          ts: 1,
          dev: 'A',
        ),
      );
      expect(only(task()).containsKey('pr'), isFalse);
      expect(only(task()).containsKey('e'), isFalse);
      expect(only(task(priority: 3, energy: 5))['pr'], 3);
      expect(only(task(priority: 3, energy: 5))['e'], 5);
    });

    group('planning only needs to know WHEN the user is busy', () {
      Occurrence ev(
        String title,
        int fromH,
        int toH, {
        bool shift = false,
        bool ai = false,
        bool allDay = false,
        int toMin = 0,
      }) => Occurrence(
        eventId: 'id-${title.length}', // (a real id never contains the title)
        title: title,
        allDay: allDay,
        tzid: allDay ? null : bp,
        startUtc: allDay ? at(5, 0) : at(5, fromH),
        endUtc: allDay ? at(6, 0) : at(5, toH, toMin),
        originalStart: floating(2026, 5, 5, fromH),
        isShift: shift,
        aiGenerated: ai,
      );

      List<String> titles(List<Occurrence> list, {required bool hide}) => [
        for (final day
            in (eventsForTool(list, tz: bp, hideTitles: hide)['esemenyek']
                    as Map)
                .values)
          for (final row in day as List) (row as Map)['c'] as String,
      ];

      test('a short typed-in event is just "foglalt"', () {
        final list = [ev('Fogorvos Kiss Péter', 9, 10)];
        expect(titles(list, hide: true), [busyTitle]);
        expect(titles(list, hide: false), ['Fogorvos Kiss Péter']);
        expect(
          dataBlock(
            'esemenyek',
            eventsForTool(list, tz: bp, hideTitles: true),
          ).contains('Fogorvos'),
          isFalse,
        );
      });

      test('a long one keeps its title: travel days matter to the rules', () {
        // 4 hours: kept; one minute less: hidden
        expect(titles([ev('Repülőút Berlin', 8, 12)], hide: true), [
          'Repülőút Berlin',
        ]);
        expect(titles([ev('Konferencia', 8, 11, toMin: 59)], hide: true), [
          busyTitle,
        ]);
        expect(longEvent, const Duration(hours: 4));
      });

      test(
        'shifts, the assistant\'s own events and all-day events keep theirs',
        () {
          final list = [
            ev('Éjszakás műszak', 9, 10, shift: true),
            ev('Calisthenics 45 perc', 11, 12, ai: true),
            ev('Munkaszüneti nap', 0, 0, allDay: true),
          ];
          expect(titles(list, hide: true), [
            'Munkaszüneti nap',
            'Éjszakás műszak',
            'Calisthenics 45 perc',
          ]);
        },
      );

      test('the times are untouched', () {
        final r = eventsForTool(
          [ev('Titok', 9, 10)],
          tz: bp,
          hideTitles: true,
          withRefs: false,
        );
        final row =
            ((r['esemenyek'] as Map).values.single as List).single as Map;
        expect(row, {'k': '09:00', 'v': '10:00', 'c': busyTitle});
      });
    });

    test(
      'tasks: the most urgent come first, and a cut drops the least urgent',
      () {
        TaskView task(String id, {DateTime? due, int priority = 2}) => TaskView(
          SyncRecord(id: id, kind: kindTask).edit(
            taskFields(title: 'F $id', due: due, priority: priority),
            ts: 1,
            dev: 'A',
          ),
        );
        final today = floating(2026, 5, 4);
        final list = [
          task('nodue'),
          task('late-week', due: floating(2026, 5, 12)),
          task('overdue', due: floating(2026, 5, 1)),
          task('soon-low', due: floating(2026, 5, 6), priority: 1),
          task('soon-high', due: floating(2026, 5, 6), priority: 3),
          task('nodue-high', priority: 3),
        ];
        List<String> order(Map<String, Object?> r) => [
          for (final t in r['feladatok'] as List) (t as Map)['c'] as String,
        ];
        expect(order(tasksForTool(list, today: today)), [
          'F overdue',
          'F soon-high',
          'F soon-low',
          'F late-week',
          'F nodue-high',
          'F nodue',
        ]);
        final cut = tasksForTool(list, today: today, max: 3);
        expect(order(cut), ['F overdue', 'F soon-high', 'F soon-low']);
        expect(cut['levagva'], isTrue);
        expect(cut['osszes'], 6);
      },
    );

    test('weather lines are keyed by month-day', () {
      final days = weatherForTool([
        DayWeather(
          day: floating(2026, 5, 5),
          tMax: 18,
          tMin: 8,
          precipProb: 20,
          precipMm: 0,
          windMax: 12,
          code: 1,
        ),
      ])['napok'];
      expect((days as Map).keys, ['05-05']);
    });
  });

  group('the narrowed scope (one more try after "too big")', () {
    final today = floating(2026, 5, 4);

    test('a plan shrinks to a few days of events', () {
      final wide = scopeFor('Tervezz edzést a jövő hétre', today);
      expect(wide.days, 14);
      expect(wide.canNarrow, isTrue);
      final n = wide.narrowed();
      expect(n.days, AskScope.narrowDays);
      expect(n.events, isTrue);
      expect([n.tasks, n.checkins, n.slots], [false, false, false]);
      // already as small as it gets
      expect(n.canNarrow, isFalse);
      expect(n.narrowed().days, n.days);
    });

    test('the kind of request stays', () {
      for (final q in [
        'Tervezz edzést a jövő hétre',
        'Töröld a holnapi edzést',
        'Hogy állok a költségkerettel?',
      ]) {
        final wide = scopeFor(q, today);
        expect(wide.narrowed().kind, wide.kind, reason: q);
      }
    });

    test('a short request has nothing to shrink in its window', () {
      const s = AskScope(
        edit: true,
        days: 2,
        tasks: false,
        checkins: false,
        slots: false,
      );
      expect(s.canNarrow, isFalse);
      expect(s.narrowed().days, 2);
    });

    test('a money question has nothing to shrink', () {
      final money = scopeFor('Hogy állok a költségkerettel?', today);
      expect(money.kind, PromptKind.money);
      expect(money.canNarrow, isFalse);
    });
  });

  group('the system prompt by kind of request', () {
    String prompt(PromptKind k, {String hb = 'H'}) =>
        buildSystemPrompt(handbook: hb, rules: const PlanRules(), kind: k);

    test('the scope tells what kind of request it is', () {
      final today = floating(2026, 5, 4);
      expect(scopeFor('Tervezz edzést', today).kind, PromptKind.plan);
      expect(scopeFor('Töröld a holnapi edzést', today).kind, PromptKind.edit);
      expect(
        scopeFor('Hogy állok a költségkerettel?', today).kind,
        PromptKind.money,
      );
      // money AND planning in one request is a plan with the money tool
      expect(
        scopeFor('Tervezz edzést, de figyelj a pénzemre', today).kind,
        PromptKind.plan,
      );
    });

    test('planning gets every section, with the live numbers', () {
      final p = prompt(PromptKind.plan);
      for (final must in [
        'MŰKÖDÉS',
        'ADATJELÖLÉSEK',
        'BIZALMI SZABÁLY',
        'KEMÉNY SZABÁLYOK',
        'KÉZIKÖNYV',
        'taskId',
        'idojaras',
        'penzugy',
        'Alvási sáv: 23:00–07:00',
      ]) {
        expect(p, contains(must), reason: must);
      }
      // a plan cannot delete or move anything: no references, no such tools
      expect(p.contains('deletions'), isFalse);
      expect(p.contains('moves'), isFalse);
      expect(p.contains('r=hivatkozás'), isFalse);
    });

    test(
      'deleting / moving needs only the event rules and no training rules',
      () {
        final p = prompt(PromptKind.edit, hb: '## Naptár-jelentések\nX');
        expect(p, contains('deletions'));
        expect(p, contains('moves'));
        expect(p, contains('esemenyek'));
        expect(p, contains('Műszak nem törölhető'));
        expect(p, contains('BIZALMI SZABÁLY'));
        expect(p, contains('Naptár-jelentések'));
        for (final not in [
          'KEMÉNY SZABÁLYOK',
          'Alvási sáv',
          'taskId',
          'idojaras',
          'penzugy',
          'feladatok:',
          'check_in',
        ]) {
          expect(p.contains(not), isFalse, reason: not);
        }
      },
    );

    test('a money question needs only the money rules and no handbook', () {
      final p = prompt(PromptKind.money, hb: '');
      expect(p, contains('penzugy'));
      expect(p, contains('pénzügyi tételt nem veszel fel'));
      expect(p, contains('get_finance'));
      expect(p, contains('BIZALMI SZABÁLY'));
      for (final not in [
        'KÉZIKÖNYV',
        'KEMÉNY SZABÁLYOK',
        'deletions',
        'propose_events',
        'esemenyek',
      ]) {
        expect(p.contains(not), isFalse, reason: not);
      }
    });

    test('a plan without money data is not told about money', () {
      final withMoney = buildSystemPrompt(
        handbook: 'H',
        rules: const PlanRules(),
      );
      final without = buildSystemPrompt(
        handbook: 'H',
        rules: const PlanRules(),
        finance: false,
      );
      expect(withMoney, contains('get_finance'));
      expect(without.contains('get_finance'), isFalse);
      expect(without.contains('penzugy'), isFalse);
      expect(without.length, lessThan(withMoney.length));
      // the rest is the same
      expect(without, contains('KEMÉNY SZABÁLYOK'));
      expect(without, contains('taskId'));
    });

    test('a move can ask for a free time', () {
      expect(prompt(PromptKind.edit), contains('find_free_slots'));
    });

    test('each kind is smaller than the one with more to say', () {
      final plan = prompt(PromptKind.plan, hb: '').length;
      final edit = prompt(PromptKind.edit, hb: '').length;
      final money = prompt(PromptKind.money, hb: '').length;
      expect(money, lessThan(edit));
      expect(edit, lessThan(plan));
    });

    test('an empty handbook leaves the handbook section out', () {
      expect(prompt(PromptKind.plan, hb: '  \n'), isNot(contains('KÉZIKÖNYV')));
      expect(prompt(PromptKind.plan, hb: 'X'), endsWith('X'));
    });

    test('the same kind gives the same text every time', () {
      for (final k in PromptKind.values) {
        expect(prompt(k), prompt(k));
      }
    });
  });

  group('the system prompt is stable', () {
    test('no clock, the same text every time, the legend is in it', () {
      final a = buildSystemPrompt(handbook: 'H', rules: const PlanRules());
      final b = buildSystemPrompt(handbook: 'H', rules: const PlanRules());
      expect(a, b);
      expect(
        RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}').hasMatch(a),
        isFalse,
        reason: 'a minute-precise clock would defeat prefix caching',
      );
      expect(a, contains('ADATJELÖLÉSEK'));
      expect(a, contains('k/v=kezdés/vég'));
      expect(a, contains('t=azonosító'));
      expect(a, contains('d=nap'));
      // the reference key is only explained where references are sent
      final edit = buildSystemPrompt(
        handbook: 'H',
        rules: const PlanRules(),
        kind: PromptKind.edit,
      );
      expect(edit, contains('r=hivatkozás'));
    });

    test('the user rules and the handbook change it, nothing else does', () {
      final base = buildSystemPrompt(handbook: 'H', rules: const PlanRules());
      final other = buildSystemPrompt(
        handbook: 'H2',
        rules: const PlanRules(sleepStartHour: 22),
      );
      expect(other, isNot(base));
      expect(other, contains('Alvási sáv: 22:00'));
    });
  });
}
