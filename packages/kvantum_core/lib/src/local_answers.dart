/// Questions the program answers itself, from the data on the device, without
/// asking a model: "Hogy állok a költségkerettel?" and "Mi lesz holnap?".
///
/// Only a whole sentence of a known shape is local. Anything with more in it
/// ("... és miből spórolhatnék?", "... a konferencián?") goes to the model, so
/// a local answer is never a guess at what the user meant.
library;

import 'assistant_context.dart';
import 'event.dart';
import 'finance.dart';
import 'models.dart';
import 'text_safety.dart';
import 'time.dart';
import 'weather.dart';

enum LocalKind {
  /// "Hogy állok a költségkerettel?"
  budget,

  /// "Mi lesz holnap?"
  agenda,

  /// The source the request needs is switched off: there is nothing to ask the
  /// model about, so the program says so itself.
  switchedOff,

  /// A workout plan the program made by itself ("Terv AI nélkül"): not the
  /// answer to a question, so there is nothing to ask the model about it.
  plan,
}

/// Which local question the wording is.
class LocalQuestion {
  const LocalQuestion.budget() : kind = LocalKind.budget, offset = 0, days = 1;
  const LocalQuestion.agenda({required this.offset, this.days = 1})
    : kind = LocalKind.agenda;
  final LocalKind kind;

  /// Agenda: the first day, counted from today.
  final int offset;

  /// Agenda: how many days.
  final int days;
}

/// What the program answered. [text] is for the user; [modelText] is what may
/// go to the model as context when the user asks a further question (the
/// titles of typed-in events hidden as planning hides them).
class LocalAnswer {
  const LocalAnswer(this.kind, this.text, {String? modelText})
    : modelText = modelText ?? text;
  final LocalKind kind;
  final String text;
  final String modelText;
}

// ------------------------------------------------------------ the wording

/// Lower case, no accents, no punctuation, no greeting or "please".
String _plain(String prompt) {
  var p = foldHu(prompt)
      .replaceAll(RegExp(r'[?!.,;:]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final lead = RegExp(
    r'^(?:szia|szervusz|hello|hali|na|kerlek|kerem|akkor|es|hat)\s+',
  );
  final tail = RegExp(r'\s+(?:kerlek|kerem|most|jelenleg)$');
  for (var i = 0; i < 3; i++) {
    final next = p.replaceFirst(lead, '').replaceFirst(tail, '');
    if (next == p) break;
    p = next;
  }
  return p;
}

final _budgetFrames = [
  RegExp(
    r'^(?:hogy|hogyan) (?:allok|allunk) (?:a |az )?(?:koltsegkerettel|kerettel|koltsegvetessel|budzsevel|penzzel|penzugyekkel|penzugyeimmel)(?: ebben a honapban| a honapban)?$',
  ),
  RegExp(
    r'^mennyi (?:penzem|keretem|koltsegkeretem) (?:maradt|van hatra|van meg)(?: ebben a honapban)?$',
  ),
  RegExp(
    r'^mennyi (?:maradt|van meg|van hatra) (?:a |az )?(?:koltsegkeretbol|kerebol|budzsebol|havi kerebol)(?: ebben a honapban)?$',
  ),
  RegExp(
    r'^mennyi(?:t| penzt) koltottem(?: ebben a honapban| a honapban| mar)?$',
  ),
  RegExp(
    r'^(?:a )?(?:koltsegkeret|havi keret|koltsegvetes|budzse)(?: allasa| statusza| helyzete| allapota)?$',
  ),
  RegExp(r'^penzugyi (?:allapot|osszefoglalo|statusz|helyzet)$'),
  RegExp(r'^tulleptem(?: a keretet| a koltsegkeretet)?$'),
];

final _dayToken = RegExp(r'\b(holnaputani|holnaputan|holnapi|holnap|mai|ma)\b');

final _agendaFrames = [
  RegExp(r'^mi (?:lesz|van) <d>(?: a (?:naptaramban|programban|tervben))?$'),
  RegExp(r'^mi (?:lesz|van) a <d> napon$'),
  RegExp(r'^mi (?:lesz|van) a (?:naptaramban|programomban|tervemben) <d>$'),
  RegExp(
    r'^mi a <d> (?:napirendem|programom|tervem|utemtervem|napirend|program|terv)$',
  ),
  RegExp(r'^mit csinalok <d>$'),
  RegExp(
    r'^milyen (?:programom|esemenyem|teendom|dolgom|feladatom) (?:van|lesz) <d>$',
  ),
  RegExp(
    r'^(?:a )?<d> (?:napirendem|napirend|program|programom|terv|tervem|esemenyek|esemenyeim)$',
  ),
  RegExp(
    r'^(?:mutasd|mondd|add) (?:meg )?(?:a )?<d> (?:napirendet|programot|tervet|esemenyeket)$',
  ),
];

final _weekFrames = [
  RegExp(r'^mi (?:lesz|van) (?:a |ezen a )?heten$'),
  RegExp(r'^mi a heti (?:napirend|program|terv)$'),
  RegExp(r'^(?:a )?heti (?:napirend|program|terv)$'),
];

/// Which local question [prompt] is, or null when it is for the model.
/// [today] is a floating date (the week runs up to the Sunday).
LocalQuestion? localQuestionFor(String prompt, DateTime today) {
  if (prompt.length > 90) return null;
  final p = _plain(prompt);
  if (p.isEmpty) return null;
  if (_budgetFrames.any((r) => r.hasMatch(p))) {
    return const LocalQuestion.budget();
  }
  if (_weekFrames.any((r) => r.hasMatch(p))) {
    return LocalQuestion.agenda(offset: 0, days: 8 - today.weekday);
  }
  final words = {for (final m in _dayToken.allMatches(p)) m[1]!};
  if (words.length != 1) return null;
  final offset = switch (words.single) {
    'ma' || 'mai' => 0,
    'holnap' || 'holnapi' => 1,
    _ => 2,
  };
  final framed = p.replaceAll(_dayToken, '<d>');
  return _agendaFrames.any((r) => r.hasMatch(framed))
      ? LocalQuestion.agenda(offset: offset)
      : null;
}

// ----------------------------------------------------------------- budget

const _months = [
  'január',
  'február',
  'március',
  'április',
  'május',
  'június',
  'július',
  'augusztus',
  'szeptember',
  'október',
  'november',
  'december',
];
const _weekdays = [
  'hétfő',
  'kedd',
  'szerda',
  'csütörtök',
  'péntek',
  'szombat',
  'vasárnap',
];

String _two(int n) => n.toString().padLeft(2, '0');
String _md(DateTime d) => '${_two(d.month)}-${_two(d.day)}';
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// The month of [today] in money: the totals, every budget with its state, the
/// spending without a budget, what is due soon and the goals. The numbers are
/// those of [financeForTool] (the block the model would get), so the answer
/// and the model cannot disagree.
LocalAnswer budgetAnswer({
  required DateTime today,
  required Iterable<FinTx> txs,
  required Iterable<FinCategory> categories,
  required Iterable<FinBudget> budgets,
  required Iterable<FinRecurring> recurring,
  required Iterable<FinGoal> goals,
  required Iterable<FinDeposit> deposits,
}) {
  final data = financeForTool(
    today: today,
    txs: txs,
    categories: categories,
    budgets: budgets,
    recurring: recurring,
    goals: goals,
    deposits: deposits,
  );
  final month = (data['honapok'] as List).first as Map<String, Object?>;
  final cats = (month['kategoriak'] as List).cast<Map<String, Object?>>();
  final expense = month['kiadas'] as int;
  final income = month['bevetel'] as int;
  final b = StringBuffer(
    'Költségkeret – ${today.year}. ${_months[today.month - 1]}',
  );

  final budgeted = [
    for (final c in cats)
      if (c.containsKey('keret')) c,
  ];
  double ratioOf(Map<String, Object?> c) {
    final limit = c['keret'] as int;
    return limit <= 0 ? 0 : (c['kiadas'] as int) / limit;
  }

  budgeted.sort((x, y) => ratioOf(y).compareTo(ratioOf(x)));

  if (expense == 0 && income == 0 && budgeted.isEmpty) {
    b.write('\nEbben a hónapban még nincs rögzített tétel.');
  } else {
    b.write(
      '\nKiadás eddig: ${formatHuf(expense)} · bevétel: ${formatHuf(income)} · egyenleg: ${formatHuf(month['egyenleg'] as int)}',
    );
  }

  if (budgeted.isEmpty) {
    if (expense > 0 || income > 0) {
      b.write('\nNincs beállított keret (a Pénzügyek oldalon adhatsz meg).');
    }
  } else {
    var over = 0, warn = 0;
    final lines = <String>[];
    for (final c in budgeted) {
      final spent = c['kiadas'] as int, limit = c['keret'] as int;
      final left = c['maradt'] as int;
      final pct = (ratioOf(c) * 100).round();
      final String state;
      if (spent > limit) {
        over++;
        state = 'túllépve ${formatHuf(-left)}-tal';
      } else if (ratioOf(c) >= 0.8) {
        warn++;
        state = 'közel a kerethez (még ${formatHuf(left)})';
      } else {
        state = 'rendben (még ${formatHuf(left)})';
      }
      lines.add(
        '• ${c['nev']}: ${formatHuf(spent)} / ${formatHuf(limit)} ($pct%) – $state',
      );
    }
    b.write(
      over == 0 && warn == 0
          ? '\nMinden keret rendben.'
          : '\nFigyelem: ${[if (over > 0) '$over keret túllépve', if (warn > 0) '$warn közel a kerethez'].join(', ')}.',
    );
    b.write('\nKeretek:\n${lines.join('\n')}');
  }

  final free = [
    for (final c in cats)
      if (!c.containsKey('keret') && (c['kiadas'] as int) > 0) c,
  ];
  if (free.isNotEmpty) {
    final shown = free
        .take(4)
        .map((c) => '${c['nev']} ${formatHuf(c['kiadas'] as int)}')
        .join(', ');
    b.write(
      '\nKeret nélkül: $shown${free.length > 4 ? ' és még ${free.length - 4}' : ''}',
    );
  }

  final due = (data['esedekes_ismetlodok'] as List)
      .cast<Map<String, Object?>>();
  if (due.isNotEmpty) {
    b.write('\nEsedékes a következő 14 napban:');
    for (final d in due.take(8)) {
      final nap = '${d['nap']}'.substring(5);
      final sign = d['tipus'] == 'bevetel' ? '+' : '-';
      b.write('\n• $nap ${d['nev']} $sign${formatHuf(d['osszeg'] as int)}');
    }
    if (due.length > 8) b.write('\n• … és még ${due.length - 8}');
  }

  final goalRows = (data['celok'] as List).cast<Map<String, Object?>>();
  if (goalRows.isNotEmpty) {
    b.write('\nCélok:');
    for (final g in goalRows.take(6)) {
      final saved = g['megtakaritva'] as int, target = g['cel'] as int;
      final monthly = g['havi_szukseges'];
      b.write(
        '\n• ${g['nev']}: ${formatHuf(saved)} / ${formatHuf(target)} (${g['szazalek']}%)'
        '${saved >= target ? ' – elérve' : ''}'
        '${monthly is int ? ' – havi ${formatHuf(monthly)} kellene a határidőig' : ''}',
      );
    }
  }

  final loose = data['besorolatlan_db'];
  if (loose is int && loose > 0) {
    b.write(
      '\nBesorolatlan tétel: $loose db (a Pénzügyek oldalon besorolhatod).',
    );
  }
  return LocalAnswer(LocalKind.budget, b.toString());
}

// ----------------------------------------------------------------- agenda

/// The agenda of [days] days from [first] (a floating date): per day the
/// events in order of time (all-day ones first), what carries over from the
/// night before, the tasks due, and the weather when it is known. [today] is
/// the floating date of today (the overdue tasks are told on today's page).
///
/// The text for the model is the same with the titles of typed-in short events
/// hidden as planning hides them ([titleHiddenWhenPlanning]).
LocalAnswer agendaAnswer({
  required DateTime today,
  required DateTime first,
  required int days,
  required String tz,
  required List<Occurrence> occurrences,
  required List<TaskView> tasks,
  List<DayWeather>? forecast,
}) {
  String render({required bool forModel}) {
    String titleOf(Occurrence o) => forModel && titleHiddenWhenPlanning(o)
        ? busyTitle
        : sanitizeText(o.title, max: 100);
    final open = [
      for (final t in tasks)
        if (!t.done && !t.deleted) t,
    ];
    final out = <String>[];
    for (var i = 0; i < days; i++) {
      final day = first.add(Duration(days: i));
      final since = day.difference(today).inDays;
      final name = _weekdays[day.weekday - 1];
      final head = switch (since) {
        0 => 'Ma – $name (${_md(day)})',
        1 => 'Holnap – $name (${_md(day)})',
        2 => 'Holnapután – $name (${_md(day)})',
        _ => '${name[0].toUpperCase()}${name.substring(1)} (${_md(day)})',
      };
      final next = day.add(const Duration(days: 1));
      final rows = <({DateTime at, String text})>[];
      for (final o in occurrences) {
        if (o.allDay) {
          // an all-day event covers the dates from its start up to its end
          final s = floating(o.startUtc.year, o.startUtc.month, o.startUtc.day);
          final e = floating(o.endUtc.year, o.endUtc.month, o.endUtc.day);
          if (!day.isBefore(s) &&
              day.isBefore(e.isAfter(s) ? e : s.add(const Duration(days: 1)))) {
            rows.add((
              at: DateTime.utc(1970),
              text: '• egész napos: ${titleOf(o)}',
            ));
          }
          continue;
        }
        final s = toWallClock(o.tzid ?? tz, o.startUtc);
        final e = toWallClock(o.tzid ?? tz, o.endUtc);
        final sDay = floating(s.year, s.month, s.day);
        final onThatDay = !sDay.isBefore(day) && sDay.isBefore(next);
        final carried = sDay.isBefore(day) && e.isAfter(day);
        if (onThatDay) {
          final eDay = floating(e.year, e.month, e.day);
          rows.add((
            at: s,
            text:
                '• ${_hm(s)}–${_hm(e)}${eDay.isAfter(sDay) ? ' (másnap)' : ''} ${titleOf(o)}',
          ));
        } else if (carried) {
          rows.add((
            at: day,
            text: '• ${_hm(day)}–${_hm(e)} ${titleOf(o)} (előző napról)',
          ));
        }
      }
      rows.sort((a, b) => a.at.compareTo(b.at));
      final lines = <String>[head];
      if (rows.isEmpty) {
        lines.add('Nincs esemény.');
      } else {
        for (final r in rows.take(12)) {
          lines.add(r.text);
        }
        if (rows.length > 12) lines.add('• … és még ${rows.length - 12}');
      }
      final due = [
        for (final t in open)
          if (t.due != null && !t.due!.isBefore(day) && t.due!.isBefore(next))
            t,
      ];
      final late = since == 0
          ? [
              for (final t in open)
                if (t.isOverdue(today)) t,
            ]
          : <TaskView>[];
      for (final t in due.take(5)) {
        lines.add('• Határidős feladat: ${sanitizeText(t.title, max: 100)}');
      }
      if (due.length > 5) lines.add('• … és még ${due.length - 5} feladat');
      for (final t in late.take(5)) {
        lines.add(
          '• Késésben: ${sanitizeText(t.title, max: 100)} (határidő: ${_md(t.due!)})',
        );
      }
      if (late.length > 5) lines.add('• … és még ${late.length - 5} késésben');
      DayWeather? w;
      for (final f in forecast ?? const <DayWeather>[]) {
        if (f.day == day) w = f;
      }
      if (w != null) {
        final line = weatherLine(w);
        if (line.isNotEmpty) lines.add('Időjárás: $line');
      }
      out.add(lines.join('\n'));
    }
    return out.join('\n\n');
  }

  return LocalAnswer(
    LocalKind.agenda,
    render(forModel: false),
    modelText: render(forModel: true),
  );
}
