import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const bp = 'Europe/Budapest';

/// The questions the program answers itself (2d): a whole sentence of a known
/// shape, never a guess; the numbers are those of the money block.
void main() {
  // 2026-05-06 is a Wednesday
  final wed = floating(2026, 5, 6);

  group('which questions are answered locally', () {
    test('the budget, with or without accents, with a greeting', () {
      for (final q in [
        'Hogy állok a költségkerettel?',
        'hogy allok a koltsegkerettel',
        'Hogyan állok a pénzzel?',
        'Szia! Hogy állok a költségkerettel, kérlek?',
        'Mennyi pénzem maradt?',
        'Mennyi maradt a költségkeretből?',
        'Mennyit költöttem?',
        'Mennyit költöttem ebben a hónapban?',
        'Mennyi pénzt költöttem már?',
        'Költségkeret',
        'A költségkeret állása',
        'Pénzügyi állapot',
        'Túlléptem a keretet?',
      ]) {
        expect(localQuestionFor(q, wed)?.kind, LocalKind.budget, reason: q);
      }
    });

    test('the agenda of a day', () {
      for (final (q, offset) in [
        ('Mi lesz ma?', 0),
        ('mi van holnap', 1),
        ('Mi lesz holnapután?', 2),
        ('Mi a mai napirendem?', 0),
        ('Mi a holnapi program?', 1),
        ('Mit csinálok holnap?', 1),
        ('Milyen programom van ma?', 0),
        ('Mi lesz a holnapi napon?', 1),
        ('Mi van a naptáramban holnap?', 1),
        ('Mai napirend', 0),
        ('A holnapi program', 1),
        ('Mutasd meg a holnapi napirendet', 1),
        ('Szia, mi lesz holnap, kérlek?', 1),
        ('mi lesz holnaputan', 2),
      ]) {
        final r = localQuestionFor(q, wed);
        expect(
          (r?.kind, r?.offset, r?.days),
          (LocalKind.agenda, offset, 1),
          reason: q,
        );
      }
    });

    test('the agenda of the week runs up to the Sunday', () {
      for (final q in [
        'Mi lesz a héten?',
        'Mi van ezen a héten?',
        'Mi a heti program?',
        'Heti napirend',
      ]) {
        final r = localQuestionFor(q, wed);
        expect(
          (r?.kind, r?.offset, r?.days),
          (LocalKind.agenda, 0, 5),
          reason: q,
        );
      }
      // on a Sunday it is that one day
      expect(localQuestionFor('Heti napirend', floating(2026, 5, 10))?.days, 1);
    });

    test('anything with more in it goes to the model', () {
      for (final q in [
        'Hogy állok a költségkerettel és miből spórolhatnék?',
        'Hogy állok a költségkerettel az elmúlt három hónapban?',
        'Mennyit költöttem ruhára?',
        'Mennyit költhetek még sportra?',
        'Hogyan spórolhatnék?',
        'Mennyi a rezsi?',
        'Mi lesz holnap és tervezz edzést',
        'Mi lesz holnap a konferencián?',
        'Mi lesz ma és holnap?',
        'Mi lesz?',
        'Mi lesz a jövő héten?',
        'Mi van holnap este 7-kor?',
        'Tervezz edzést holnapra',
        'Töröld a holnapi programot',
        'Mi a holnapi program, és mikor tudok edzeni?',
        '',
        '   ',
        'x' * 200,
      ]) {
        expect(localQuestionFor(q, wed), isNull, reason: q);
      }
    });
  });

  group('the budget', () {
    final today = floating(2026, 11, 10);
    FinTx tx(
      String id,
      DateTime d,
      int amount, {
      FinKind kind = FinKind.expense,
      String cat = 'cat-food',
      bool deleted = false,
    }) => FinTx(
      id: id,
      date: d,
      amount: amount,
      kind: kind,
      categoryId: cat,
      deleted: deleted,
    );

    LocalAnswer answer({
      List<FinTx>? txs,
      List<FinBudget> budgets = const [],
      List<FinRecurring> rec = const [],
      List<FinGoal> goals = const [],
      List<FinDeposit> deps = const [],
    }) => budgetAnswer(
      today: today,
      txs: txs ?? const [],
      categories: defaultCategories(),
      budgets: budgets,
      recurring: rec,
      goals: goals,
      deposits: deps,
    );

    final txs = [
      tx('a', floating(2026, 11, 3), 20000),
      tx('b', floating(2026, 11, 5), 5000, cat: 'cat-fun'),
      tx(
        'c',
        floating(2026, 11, 1),
        400000,
        kind: FinKind.income,
        cat: 'cat-salary',
      ),
      tx('d', floating(2026, 10, 20), 7000), // last month
      tx('e', floating(2026, 11, 8), 99999, deleted: true),
      tx('f', floating(2026, 11, 9), 1500, cat: kUncategorized),
      tx('g', floating(2026, 11, 9), 3000, cat: 'cat-clothes'),
    ];
    final budgets = const [
      FinBudget(categoryId: 'cat-food', limit: 24000), // 20 000: 83 %
      FinBudget(categoryId: 'cat-fun', limit: 4000), // 5 000: over
      FinBudget(categoryId: 'cat-sport', limit: 10000), // nothing spent
    ];

    test('the totals are those of the month summary', () {
      final a = answer(txs: txs, budgets: budgets);
      final s = monthSummary(txs, 2026, 11);
      expect(a.kind, LocalKind.budget);
      expect(a.text, startsWith('Költségkeret – 2026. november'));
      expect(
        a.text,
        contains(
          'Kiadás eddig: ${formatHuf(s.expense)} · bevétel: ${formatHuf(s.income)} · egyenleg: ${formatHuf(s.balance)}',
        ),
      );
      expect(s.expense, 29500); // 20 000 + 5 000 + 1 500 + 3 000
    });

    test('every budget has its state, the worst first', () {
      final a = answer(txs: txs, budgets: budgets).text;
      final over = a.indexOf(
        '• Szórakozás: ${formatHuf(5000)} / ${formatHuf(4000)} (125%) – túllépve ${formatHuf(1000)}-tal',
      );
      final near = a.indexOf(
        '• Élelmiszer: ${formatHuf(20000)} / ${formatHuf(24000)} (83%) – közel a kerethez (még ${formatHuf(4000)})',
      );
      final fine = a.indexOf(
        '• Sport: ${formatHuf(0)} / ${formatHuf(10000)} (0%) – rendben (még ${formatHuf(10000)})',
      );
      expect(over, greaterThan(-1));
      expect(near, greaterThan(over));
      expect(fine, greaterThan(near));
      expect(a, contains('Figyelem: 1 keret túllépve, 1 közel a kerethez.'));
    });

    test('the state agrees with the budget status the app shows', () {
      final s = monthSummary(txs, 2026, 11);
      final st = {for (final b in budgetStatus(budgets, s)) b.categoryId: b};
      expect(st['cat-fun']!.level, BudgetLevel.over);
      expect(st['cat-food']!.level, BudgetLevel.warn);
      expect(st['cat-sport']!.level, BudgetLevel.ok);
    });

    test('spending without a budget, and the uncategorised ones', () {
      final a = answer(txs: txs, budgets: budgets).text;
      expect(a, contains('Keret nélkül: Ruházat ${formatHuf(3000)}'));
      expect(a, contains('Besorolatlan tétel: 1 db'));
    });

    test('all budgets fine, and no budget at all', () {
      final calm = answer(
        txs: [tx('a', floating(2026, 11, 3), 1000)],
        budgets: const [FinBudget(categoryId: 'cat-food', limit: 50000)],
      ).text;
      expect(calm, contains('Minden keret rendben.'));
      expect(calm.contains('Figyelem'), isFalse);

      final none = answer(txs: [tx('a', floating(2026, 11, 3), 1000)]).text;
      expect(none, contains('Nincs beállított keret'));
    });

    test('an empty month says so', () {
      expect(
        answer().text,
        'Költségkeret – 2026. november\nEbben a hónapban még nincs rögzített tétel.',
      );
    });

    test('what is due in the next two weeks, and the goals', () {
      final a = answer(
        rec: [
          FinRecurring(
            id: 'r',
            title: 'Netflix',
            amount: 5000,
            kind: FinKind.expense,
            categoryId: 'cat-subs',
            dayOfMonth: 20,
            fromMonth: floating(2026, 1, 1),
          ),
          FinRecurring(
            id: 'p',
            title: 'Fizetés',
            amount: 400000,
            kind: FinKind.income,
            categoryId: 'cat-salary',
            dayOfMonth: 12,
            fromMonth: floating(2026, 1, 1),
          ),
        ],
        goals: [
          FinGoal(
            id: 'g',
            name: 'Nyaralás',
            target: 600000,
            deadline: floating(2027, 3, 31),
          ),
        ],
        deps: [
          FinDeposit(
            id: 'd',
            goalId: 'g',
            date: floating(2026, 11, 1),
            amount: 100000,
          ),
        ],
      ).text;
      expect(a, contains('Esedékes a következő 14 napban:'));
      expect(a, contains('• 11-12 Fizetés +${formatHuf(400000)}'));
      expect(a, contains('• 11-20 Netflix -${formatHuf(5000)}'));
      expect(a.indexOf('11-12'), lessThan(a.indexOf('11-20')));
      expect(
        a,
        contains(
          '• Nyaralás: ${formatHuf(100000)} / ${formatHuf(600000)} (17%) – havi ${formatHuf(125000)} kellene a határidőig',
        ),
      );
    });

    test('what the model could get is what the answer says', () {
      // the numbers of the answer are those of the money block
      final data = financeForTool(
        today: today,
        txs: txs,
        categories: defaultCategories(),
        budgets: budgets,
        recurring: const [],
        goals: const [],
        deposits: const [],
      );
      final month = (data['honapok'] as List).first as Map<String, Object?>;
      final a = answer(txs: txs, budgets: budgets);
      expect(a.text, contains(formatHuf(month['kiadas'] as int)));
      expect(a.modelText, a.text);
    });
  });

  group('the agenda', () {
    final today = floating(2026, 5, 4); // a Monday

    Occurrence ev(
      String title,
      DateTime s,
      DateTime e, {
      bool allDay = false,
      bool shift = false,
      bool ai = false,
    }) => Occurrence(
      eventId: title,
      title: title,
      allDay: allDay,
      tzid: allDay ? null : bp,
      startUtc: allDay ? s : resolveWallClock(bp, s),
      endUtc: allDay ? e : resolveWallClock(bp, e),
      originalStart: s,
      isShift: shift,
      aiGenerated: ai,
    );

    TaskView task(
      String id,
      String title, {
      DateTime? due,
      bool done = false,
    }) => TaskView(
      SyncRecord(id: id, kind: kindTask).edit(
        taskFields(title: title, due: due, done: done),
        ts: 1,
        dev: 'A',
      ),
    );

    LocalAnswer day(
      int offset,
      List<Occurrence> events, {
      List<TaskView> tasks = const [],
      List<DayWeather>? forecast,
      int days = 1,
    }) => agendaAnswer(
      today: today,
      first: today.add(Duration(days: offset)),
      days: days,
      tz: bp,
      occurrences: events,
      tasks: tasks,
      forecast: forecast,
    );

    test('the events of the day in order of time, the all-day ones first', () {
      final a = day(1, [
        ev('Gym', floating(2026, 5, 5, 18), floating(2026, 5, 5, 19)),
        ev('Névnap', floating(2026, 5, 5), floating(2026, 5, 6), allDay: true),
        ev('Fogorvos', floating(2026, 5, 5, 9), floating(2026, 5, 5, 9, 30)),
        ev('Máskor', floating(2026, 5, 7, 9), floating(2026, 5, 7, 10)),
      ]);
      expect(a.kind, LocalKind.agenda);
      expect(
        a.text,
        'Holnap – kedd (05-05)\n'
        '• egész napos: Névnap\n'
        '• 09:00–09:30 Fogorvos\n'
        '• 18:00–19:00 Gym',
      );
    });

    test('a night shift: its start tonight, its end tomorrow morning', () {
      final shift = ev(
        'Éjszakai műszak',
        floating(2026, 5, 4, 18),
        floating(2026, 5, 5, 6),
        shift: true,
      );
      expect(
        day(0, [shift]).text,
        'Ma – hétfő (05-04)\n• 18:00–06:00 (másnap) Éjszakai műszak',
      );
      expect(
        day(1, [shift]).text,
        'Holnap – kedd (05-05)\n• 00:00–06:00 Éjszakai műszak (előző napról)',
      );
    });

    test('an empty day', () {
      expect(day(2, []).text, 'Holnapután – szerda (05-06)\nNincs esemény.');
    });

    test('a multi-day all-day event covers every one of its days', () {
      final trip = ev(
        'Nyaralás',
        floating(2026, 5, 4),
        floating(2026, 5, 7),
        allDay: true,
      );
      for (var i = 0; i < 3; i++) {
        expect(day(i, [trip]).text, contains('• egész napos: Nyaralás'));
      }
      expect(day(3, [trip]).text, contains('Nincs esemény.'));
    });

    test('tasks due that day, and the overdue ones on today\'s page only', () {
      final tasks = [
        task('1', 'Beadandó', due: floating(2026, 5, 5)),
        task('2', 'Számla', due: floating(2026, 5, 1)), // overdue
        task('3', 'Kész dolog', due: floating(2026, 5, 5), done: true),
        task('4', 'Később', due: floating(2026, 5, 9)),
      ];
      final tomorrow = day(1, [], tasks: tasks).text;
      expect(tomorrow, contains('• Határidős feladat: Beadandó'));
      expect(tomorrow.contains('Számla'), isFalse);
      expect(tomorrow.contains('Kész dolog'), isFalse);
      expect(tomorrow.contains('Később'), isFalse);
      final now = day(0, [], tasks: tasks).text;
      expect(now, contains('• Késésben: Számla (határidő: 05-01)'));
      expect(now.contains('Beadandó'), isFalse);
    });

    test('the weather of the day, when it is known', () {
      final text = day(
        1,
        [],
        forecast: [
          DayWeather(
            day: floating(2026, 5, 5),
            tMin: 8,
            tMax: 17,
            precipProb: 60,
            code: 3,
          ),
        ],
      ).text;
      expect(text, contains('Időjárás: felhős, 8–17 °C, csapadék 60%'));
      expect(day(0, [], forecast: const []).text.contains('Időjárás'), isFalse);
    });

    test('a week: a page per day, today first', () {
      final a = day(0, [], days: 3).text;
      expect(a.split('\n\n'), [
        'Ma – hétfő (05-04)\nNincs esemény.',
        'Holnap – kedd (05-05)\nNincs esemény.',
        'Holnapután – szerda (05-06)\nNincs esemény.',
      ]);
      expect(
        day(0, [], days: 5).text,
        contains('\n\nCsütörtök (05-07)\nNincs esemény.'),
      );
    });

    test('a long day is cut and says how many are left', () {
      final many = [
        for (var i = 0; i < 15; i++)
          ev('E$i', floating(2026, 5, 5, 8, i), floating(2026, 5, 5, 8, i + 1)),
      ];
      final text = day(1, many).text;
      expect(text, contains('• … és még 3'));
      expect(text.split('\n').length, 1 + 12 + 1);
    });

    test(
      'for the model, typed-in short events are "foglalt", the rest is not',
      () {
        final a = day(1, [
          ev('Fogorvos', floating(2026, 5, 5, 9), floating(2026, 5, 5, 10)),
          ev('Konferencia', floating(2026, 5, 5, 8), floating(2026, 5, 5, 17)),
          ev(
            'Nappali műszak',
            floating(2026, 5, 5, 6),
            floating(2026, 5, 5, 8),
            shift: true,
          ),
          ev(
            'Korábbi terv',
            floating(2026, 5, 5, 18),
            floating(2026, 5, 5, 19),
            ai: true,
          ),
        ]);
        expect(a.text, contains('Fogorvos'));
        expect(a.modelText.contains('Fogorvos'), isFalse);
        expect(a.modelText, contains('• 09:00–10:00 foglalt'));
        expect(a.modelText, contains('Konferencia'));
        expect(a.modelText, contains('Nappali műszak'));
        expect(a.modelText, contains('Korábbi terv'));
      },
    );
  });
}
