import 'recurrence_spec.dart';
import 'text_safety.dart';
import 'time.dart';

/// What a line of free text turned out to be.
enum QuickKind { event, task }

/// A line typed (or dictated) into the quick entry, taken apart: what it is,
/// when, how long, how often, and what is left as the title.
///
/// Nothing here is a guess the user cannot see: [assumptions] says in words
/// what was decided for them ("a 5-kort délutáninak vettem"), and the app
/// shows it next to the result before anything is saved.
class QuickEntry {
  const QuickEntry({
    required this.kind,
    required this.title,
    this.date,
    this.startMinute,
    this.durationMinutes,
    this.allDay = false,
    this.rrule,
    this.repeatText,
    this.assumptions = const [],
  });

  final QuickKind kind;

  /// What is left of the line when everything about time is taken out; empty
  /// when nothing is (then there is nothing to save).
  final String title;

  /// Floating date: the day of the event, or the due date of the task.
  final DateTime? date;

  /// Minutes after midnight; null for an all-day event and for a task.
  final int? startMinute;

  /// Length of an event with a time (60 when the line says nothing).
  final int? durationMinutes;
  final bool allDay;

  /// RFC 5545 rule body for the first occurrence, or null.
  final String? rrule;

  /// The words that said it repeats ("minden hétfőn").
  final String? repeatText;

  /// Hungarian sentences: what was taken for granted.
  final List<String> assumptions;

  bool get hasTitle => title.isNotEmpty;
  bool get repeats => rrule != null;

  /// Floating start of a timed event.
  DateTime? get start => date == null || startMinute == null
      ? null
      : date!.add(Duration(minutes: startMinute!));

  /// Floating end of a timed event.
  DateTime? get end => start?.add(Duration(minutes: durationMinutes ?? 60));

  QuickEntry withKind(QuickKind k) => k == kind
      ? this
      : QuickEntry(
          kind: k,
          title: title,
          date: date,
          startMinute: startMinute,
          durationMinutes: durationMinutes,
          allDay: allDay,
          rrule: rrule,
          repeatText: repeatText,
          assumptions: assumptions,
        );

  @override
  String toString() =>
      'QuickEntry($kind, "$title", $date, $startMinute, $durationMinutes, '
      'allDay: $allDay, $rrule)';
}

const _weekdayStems = [
  'hetfo',
  'kedd',
  'szerd',
  'csutortok',
  'pentek',
  'szombat',
  'vasarnap',
];
// The names of the days with the endings that mean "on / until / of that
// day" and no others: Szombathely is not a Saturday.
const _wd =
    '(?:hetfo(?:n|re|ig|tol|rol|i|k|kon|nek|vel)?'
    '|kedd(?:en|re|ig|tol|rol|i|ek|eken|nek|el)?'
    '|szerd(?:a|an|ara|aig|atol|arol|ai|ak|akon|anak|aval)?'
    '|csutortok(?:on|re|ig|tol|rol|i|ok|okon|nek|kel)?'
    '|pentek(?:en|re|ig|tol|rol|i|ek|eken|nek|kel)?'
    '|szombat(?:on|ra|ig|tol|rol|i|ok|okon|nak|tal)?'
    '|vasarnap(?:ra|ig|tol|rol|i|ok|okon|nak|pal)?)';
const _monthNames = [
  'januar',
  'februar',
  'marcius',
  'aprilis',
  'majus',
  'junius',
  'julius',
  'augusztus',
  'szeptember',
  'oktober',
  'november',
  'december',
];
const _monthAbbr = {
  'jan': 1,
  'febr': 2,
  'marc': 3,
  'apr': 4,
  'maj': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'szept': 9,
  'okt': 10,
  'nov': 11,
  'dec': 12,
};
const _numberWords = {
  'egy': 1,
  'ket': 2,
  'ketto': 2,
  'harom': 3,
  'negy': 4,
  'ot': 5,
  'hat': 6,
  'het': 7,
  'nyolc': 8,
  'kilenc': 9,
  'tiz': 10,
  'tizenegy': 11,
  'tizenketto': 12,
};
const _nw =
    '(?:egy|ketto|ket|harom|negy|ot|hat|het|nyolc|kilenc|tizenketto|tizenegy|tiz)';

int _wdOf(String foldedWord) {
  for (var i = 0; i < _weekdayStems.length; i++) {
    if (foldedWord.startsWith(_weekdayStems[i])) return i + 1;
  }
  throw ArgumentError('not a weekday: $foldedWord');
}

int _num(String s) => _numberWords[s] ?? int.parse(s);

/// Lower case and without accents, one character for one: positions in the
/// result are positions in [s].
String _fold(String s) {
  const from = 'áéíóöőúüűÁÉÍÓÖŐÚÜŰ';
  const to = 'aeiooouuuaeiooouuu';
  final out = <int>[];
  for (final c in s.codeUnits) {
    final i = from.indexOf(String.fromCharCode(c));
    if (i >= 0) {
      out.add(to.codeUnitAt(i));
    } else if (c >= 65 && c <= 90) {
      out.add(c + 32);
    } else {
      out.add(c);
    }
  }
  return String.fromCharCodes(out);
}

/// The line, with the parts already understood blanked out.
class _Src {
  _Src(this.original)
    : _f = _fold(original).codeUnits.toList(),
      _used = List.filled(original.length, false);

  final String original;
  final List<int> _f;
  final List<bool> _used;

  String get text => String.fromCharCodes(_f);

  RegExpMatch? find(String pattern) => RegExp(pattern).firstMatch(text);

  /// Blanks [m] (or a part of the line) so that nothing matches it again.
  void take(int start, int end) {
    for (var i = start; i < end; i++) {
      _f[i] = 32;
      _used[i] = true;
    }
  }

  void takeMatch(RegExpMatch m) => take(m.start, m.end);

  /// What is left of the original, the gaps as single spaces.
  String get rest {
    final b = StringBuffer();
    for (var i = 0; i < original.length; i++) {
      b.write(_used[i] ? ' ' : original[i]);
    }
    return b.toString();
  }

  /// The word (folded) that ends right before [index], or ''.
  String wordBefore(int index) {
    var e = index;
    while (e > 0 && _f[e - 1] == 32) {
      e--;
    }
    var s = e;
    while (s > 0 && _f[s - 1] != 32) {
      s--;
    }
    return String.fromCharCodes(_f.sublist(s, e));
  }

  int wordBeforeStart(int index) {
    var e = index;
    while (e > 0 && _f[e - 1] == 32) {
      e--;
    }
    var s = e;
    while (s > 0 && _f[s - 1] != 32) {
      s--;
    }
    return s;
  }

  /// The word (folded) that starts right after [index], or ''.
  String wordAfter(int index) {
    var s = index;
    while (s < _f.length && _f[s] == 32) {
      s++;
    }
    var e = s;
    while (e < _f.length && _f[e] != 32) {
      e++;
    }
    return String.fromCharCodes(_f.sublist(s, e));
  }

  int wordAfterEnd(int index) {
    var s = index;
    while (s < _f.length && _f[s] == 32) {
      s++;
    }
    var e = s;
    while (e < _f.length && _f[e] != 32) {
      e++;
    }
    return e;
  }
}

const _dayParts = {
  'reggel': 'am',
  'delelott': 'am',
  'hajnal': 'am',
  'hajnali': 'am',
  'de.': 'am',
  'du.': 'pm',
  'delutan': 'pm',
  'du': 'pm',
  'este': 'pm',
  'ejjel': 'night',
  'ejszaka': 'night',
};

/// Takes a Hungarian line apart.
///
/// [now] is the wall clock of the display zone (a floating date and time):
/// "kedden" is the Tuesday after today, an hour that has already gone by
/// today means tomorrow.
QuickEntry parseQuickEntry(String input, {required DateTime now}) {
  final today = floating(now.year, now.month, now.day);
  final nowMinute = now.hour * 60 + now.minute;
  final src = _Src(input);
  final notes = <String>[];

  QuickKind? explicit;
  var dueWord = false;
  var allDay = false;
  DateTime? date;
  var dateIsToday = false;
  int? startMin;
  int? endMin;
  int? duration;
  String? repeatText;
  RecurrenceSpec? repeat;
  Set<int> repeatDays = {};
  int? monthDay;

  String two(int n) => n.toString().padLeft(2, '0');

  // ---- 0. a word that says what it is
  var m = src.find(r'^\s*(feladat|teendo|todo|to-do)\s*[:\-–]?\s');
  if (m != null) {
    explicit = QuickKind.task;
    src.takeMatch(m);
  } else {
    m = src.find(r'^\s*(esemeny|talalkozo)\s*:\s*');
    if (m != null) {
      explicit = QuickKind.event;
      src.takeMatch(m);
    }
  }

  // ---- 1. all day
  m = src.find(r'\b(egesz\s+nap(?:ra|os|ig)?|egesznapos)\b');
  if (m != null) {
    allDay = true;
    src.takeMatch(m);
  }

  // ---- 2. how often
  void setRepeat(RecurrenceSpec spec, RegExpMatch at) {
    repeat = spec;
    repeatText = src.original.substring(at.start, at.end).trim();
    src.takeMatch(at);
  }

  m = src.find(
    '\\bminden\\s+($_wd(?:\\s*(?:,|&|\\+)\\s*$_wd|\\s+es\\s+$_wd)*)',
  );
  if (m != null) {
    final days = {
      for (final d in RegExp(_wd).allMatches(m.group(1)!)) _wdOf(d.group(0)!),
    };
    repeatDays = days;
    setRepeat(RecurrenceSpec(freq: RepeatFreq.weekly, weekdays: days), m);
  }
  if (repeat == null) {
    m = src.find(
      '\\b(hetfo|kedd|szerd|csutortok|pentek|szombat|vasarnap)(?:en|on|an|n)?kent\\b',
    );
    if (m != null) {
      repeatDays = {_wdOf(m.group(1)!)};
      setRepeat(
        RecurrenceSpec(freq: RepeatFreq.weekly, weekdays: repeatDays),
        m,
      );
    }
  }
  if (repeat == null) {
    m = src.find(r'\b(?:minden\s+)?(hetkoznapokon|munkanapokon|hetkoznap)\b');
    if (m != null &&
        (m.group(1) != 'hetkoznap' || m.group(0)!.startsWith('minden'))) {
      repeatDays = {1, 2, 3, 4, 5};
      setRepeat(
        RecurrenceSpec(freq: RepeatFreq.weekly, weekdays: repeatDays),
        m,
      );
    }
  }
  if (repeat == null) {
    m = src.find(r'\b(hetvegenkent|minden\s+hetvegen)\b');
    if (m != null) {
      repeatDays = {6, 7};
      setRepeat(
        RecurrenceSpec(freq: RepeatFreq.weekly, weekdays: repeatDays),
        m,
      );
    }
  }
  if (repeat == null) {
    // (a number glued to an hour is the minutes of the hour: "18:00 naponta";
    // a count of zero is no count: the plain "naponta" below takes it)
    m = src.find(
      '\\b(?:(?<![\\d:.])(\\d{1,2}|$_nw)\\s*-?\\s*naponta|minden\\s+(masodik|harmadik)'
      '\\s+nap(?:on)?)\\b',
    );
    if (m != null) {
      final n = m.group(1) != null
          ? _num(m.group(1)!)
          : (m.group(2) == 'masodik' ? 2 : 3);
      if (n >= 1) {
        setRepeat(RecurrenceSpec(freq: RepeatFreq.daily, interval: n), m);
      }
    }
  }
  if (repeat == null) {
    m = src.find(r'\b(naponta|mindennap|minden\s+nap(?:on)?)\b');
    if (m != null) setRepeat(const RecurrenceSpec(freq: RepeatFreq.daily), m);
  }
  if (repeat == null) {
    m = src.find(
      '\\b(?:(?<![\\d:.])(\\d{1,2}|$_nw)\\s*-?\\s*hetente|minden\\s+masodik\\s+'
      'heten)\\b',
    );
    if (m != null) {
      final n = m.group(1) != null ? _num(m.group(1)!) : 2;
      if (n >= 1) {
        setRepeat(RecurrenceSpec(freq: RepeatFreq.weekly, interval: n), m);
      }
    }
  }
  if (repeat == null) {
    m = src.find(r'\b(hetente|minden\s+heten|minden\s+het)\b');
    if (m != null) setRepeat(const RecurrenceSpec(freq: RepeatFreq.weekly), m);
  }
  if (repeat == null) {
    // "minden hónap 5-én", "havonta 5-én"
    m = src.find(
      r'\b(?:minden\s+honap|havonta)\s+(\d{1,2})\.?(?:\s*-\s*(?:an|en|jan|jen))?(?!\d)',
    );
    if (m != null) {
      final day = int.parse(m.group(1)!);
      if (day >= 1 && day <= 31) {
        monthDay = day;
        setRepeat(const RecurrenceSpec(freq: RepeatFreq.monthly), m);
      }
    }
  }
  if (repeat == null) {
    m = src.find(r'\b(havonta|minden\s+honapban|minden\s+honap)\b');
    if (m != null) setRepeat(const RecurrenceSpec(freq: RepeatFreq.monthly), m);
  }
  if (repeat == null) {
    m = src.find(r'\b(evente|minden\s+evben|minden\s+ev)\b');
    if (m != null) setRepeat(const RecurrenceSpec(freq: RepeatFreq.yearly), m);
  }

  // ---- 3. a deadline
  m = src.find(r'\bhatarid(?:o|ovel|oig)\s*[:\-]?\s*');
  if (m != null) {
    dueWord = true;
    src.takeMatch(m);
  }

  // ---- 4. the day
  DateTime addDays(DateTime d, int n) => d.add(Duration(days: n));
  DateTime nextWeekday(int wd) {
    var n = (wd - today.weekday) % 7;
    if (n == 0) n = 7;
    return today.add(Duration(days: n));
  }

  DateTime? validDate(int y, int mo, int d) {
    if (mo < 1 || mo > 12 || d < 1) return null;
    final dt = floating(y, mo, d);
    return dt.month == mo && dt.day == d ? dt : null;
  }

  /// A month and day without a year: this year, or next when it is behind us.
  DateTime? yearless(int mo, int d, String said) {
    final here = validDate(today.year, mo, d);
    if (here == null) return null;
    if (!here.isBefore(today)) return here;
    final next = validDate(today.year + 1, mo, d);
    if (next != null) {
      notes.add('A(z) „$said” már elmúlt idén, ezért a jövő évit vettem.');
    }
    return next;
  }

  void dueSuffix(String? suffix) {
    if (suffix != null && suffix.startsWith('ig')) dueWord = true;
  }

  // 4a. 2026.11.20. / 2026-11-20
  m = src.find(
    r'(?<![\d.:])(\d{4})[.\-/]\s?(\d{1,2})[.\-/]\s?(\d{1,2})(?![\d:])\.?(?:-([a-z]+))?',
  );
  if (m != null) {
    final d = validDate(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
    if (d != null) {
      date = d;
      dueSuffix(m.group(4));
      src.takeMatch(m);
    }
  }
  // 4b. november 20. / nov. 20-án / 2026. november 20.
  if (date == null) {
    final names = _monthNames.join('|');
    final abbr = _monthAbbr.keys.join('|');
    m = src.find(
      '(?:(\\d{4})\\.?\\s+)?\\b(?:($names)(?:ban|ben|ig|re|tol|rol|i)?|($abbr)\\.)'
      '\\s*(\\d{1,2})(?![\\d:])\\.?(?:-((?:an|en|ara|ere|ig|ra|re|tol|rol|i)\\b))?',
    );
    if (m != null) {
      final mo = m.group(2) != null
          ? _monthNames.indexOf(m.group(2)!) + 1
          : _monthAbbr[m.group(3)!]!;
      final day = int.parse(m.group(4)!);
      DateTime? d;
      if (m.group(1) != null) {
        d = validDate(int.parse(m.group(1)!), mo, day);
      } else {
        d = yearless(mo, day, src.original.substring(m.start, m.end).trim());
      }
      if (d != null) {
        date = d;
        dueSuffix(m.group(5));
        src.takeMatch(m);
      }
    }
  }
  // 4c. 11.20.
  if (date == null) {
    m = src.find(
      r'(?<![\d.:])(\d{1,2})\.\s?(\d{1,2})\.(?![\d:])(?:-([a-z]+))?',
    );
    if (m != null) {
      final mo = int.parse(m.group(1)!);
      final day = int.parse(m.group(2)!);
      if (mo >= 1 && mo <= 12 && day >= 1 && day <= 31) {
        final d = yearless(
          mo,
          day,
          src.original.substring(m.start, m.end).trim(),
        );
        if (d != null) {
          date = d;
          dueSuffix(m.group(3));
          src.takeMatch(m);
        }
      }
    }
  }
  // 4d. a relative word
  if (date == null) {
    m = src.find(
      r'\b(mara|maig|ma|holnaputanra|holnaputanig|holnaputan|holnapra|holnapig|holnap)\b',
    );
    if (m != null) {
      final w = m.group(1)!;
      final n = w.startsWith('holnaputan')
          ? 2
          : w.startsWith('holnap')
          ? 1
          : 0;
      date = addDays(today, n);
      dateIsToday = n == 0;
      if (w.endsWith('ig')) dueWord = true;
      src.takeMatch(m);
    }
  }
  // 4e. in so many days / weeks / months
  if (date == null) {
    m = src.find(
      '\\b(\\d{1,3}|$_nw)\\s+(nap|het|honap|ev)\\s+(?:mulva|mulvara)\\b',
    );
    if (m != null) {
      final n = _num(m.group(1)!);
      switch (m.group(2)) {
        case 'nap':
          date = addDays(today, n);
        case 'het':
          date = addDays(today, 7 * n);
        case 'honap':
          var mo = today.month - 1 + n;
          final y = today.year + mo ~/ 12;
          mo = mo % 12 + 1;
          final lastDay = floating(y, mo + 1, 0).day;
          date = floating(y, mo, today.day > lastDay ? lastDay : today.day);
        default:
          date = floating(today.year + n, today.month, today.day);
      }
      src.takeMatch(m);
    }
  }
  if (date == null) {
    m = src.find('\\b(\\d{1,3}|$_nw)\\s+(napon|heten|honapon)\\s+belul\\b');
    if (m != null) {
      final n = _num(m.group(1)!);
      date = addDays(
        today,
        m.group(2) == 'napon'
            ? n
            : m.group(2) == 'heten'
            ? 7 * n
            : 30 * n,
      );
      dueWord = true;
      src.takeMatch(m);
    }
  }
  // 4f. next week's, this week's, the next such day
  if (date == null) {
    m = src.find('\\bjovo\\s+(?:het(?:en)?\\s+)?($_wd)\\b');
    if (m != null) {
      final wd = _wdOf(m.group(1)!);
      final monday = today.subtract(Duration(days: today.weekday - 1));
      date = addDays(monday, 7 + wd - 1);
      if (m.group(1)!.endsWith('ig')) dueWord = true;
      src.takeMatch(m);
    }
  }
  if (date == null) {
    m = src.find('\\b(?:ezen\\s+a\\s+|e\\s+|a\\s+)?heten\\s+($_wd)\\b');
    if (m != null) {
      final wd = _wdOf(m.group(1)!);
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final d = addDays(monday, wd - 1);
      date = d;
      if (d.isBefore(today)) {
        notes.add('Ez a nap már elmúlt a héten.');
      }
      if (m.group(1)!.endsWith('ig')) dueWord = true;
      src.takeMatch(m);
    }
  }
  if (date == null) {
    m = src.find('\\b(?:kovetkezo\\s+)?($_wd)\\b');
    if (m != null) {
      final word = m.group(1)!;
      final wd = _wdOf(word);
      date = nextWeekday(wd);
      if (wd == today.weekday) {
        notes.add(
          'A mai nap helyett a következő ${_weekdayAccusative[wd - 1]} vettem.',
        );
      }
      if (word.endsWith('ig')) dueWord = true;
      src.takeMatch(m);
    }
  }
  if (date == null) {
    m = src.find(r'\bhetvege(?:n|re|ig)?\b');
    if (m != null) {
      date = nextWeekday(6);
      notes.add('A hétvégét a következő szombatnak vettem.');
      src.takeMatch(m);
    }
  }
  // 4g. the 20th (of this month, or the next)
  if (date == null) {
    m = src.find(r'(?<![\d.:])(\d{1,2})\.?\s*-\s*(an|en|ara|ere)\b');
    if (m != null) {
      final day = int.parse(m.group(1)!);
      if (day >= 1 && day <= 31) {
        DateTime? d = validDate(today.year, today.month, day);
        if (d == null || d.isBefore(today)) {
          var y = today.year, mo = today.month + 1;
          if (mo > 12) {
            mo = 1;
            y++;
          }
          d = validDate(y, mo, day);
          if (d != null) {
            notes.add(
              'A(z) $day. napot a következő hónapra vettem (ebben már elmúlt).',
            );
          }
        }
        if (d != null) {
          date = d;
          if (m.group(2) == 'ara' || m.group(2) == 'ere') dueWord = true;
          src.takeMatch(m);
        }
      }
    }
  }

  if (date != null) {
    // "péntek, nov. 20.": the weekday that agrees with the date is said twice
    for (final w in RegExp('\\b($_wd)\\b').allMatches(src.text).toList()) {
      if (_wdOf(w.group(1)!) == date.weekday) {
        src.takeMatch(w);
        break;
      }
    }
  }

  // ---- 4b. in so many minutes
  m = src.find(
    '\\b(?:(\\d+(?:[.,]\\d+)?|$_nw)|(fel|negyed|masfel|haromnegyed))\\s*'
    '(perc|ora)\\s+mulva\\b',
  );
  if (m != null) {
    final unit = m.group(3) == 'perc' ? 1 : 60;
    final v = m.group(1) != null
        ? (_numberWords.containsKey(m.group(1)!)
              ? _numberWords[m.group(1)!]!.toDouble()
              : double.parse(m.group(1)!.replaceAll(',', '.')))
        : switch (m.group(2)) {
            'fel' => 0.5,
            'negyed' => 0.25,
            'masfel' => 1.5,
            _ => 0.75,
          };
    final at = nowMinute + (v * unit).round();
    if (at < 24 * 60) {
      startMin = at;
      date ??= today;
    } else {
      startMin = at - 24 * 60;
      date ??= addDays(today, 1);
    }
    src.takeMatch(m);
  }

  // ---- 5. how long (what says it is a length, not an hour)
  m = src.find(r'\bmasfel\s+ora\w*');
  if (m != null) {
    duration = 90;
    src.takeMatch(m);
  }
  if (duration == null) {
    m = src.find(r'\bharomnegyed\s+ora\w*');
    if (m != null) {
      duration = 45;
      src.takeMatch(m);
    }
  }
  if (duration == null) {
    m = src.find(r'\bnegyed\s+ora\w*');
    if (m != null) {
      duration = 15;
      src.takeMatch(m);
    }
  }
  if (duration == null) {
    m = src.find(r'\bfel\s+ora(?:s|t|n|ra)?\b');
    if (m != null) {
      duration = 30;
      src.takeMatch(m);
    }
  }
  if (duration == null) {
    // 2 órás, 2 órát, 2 órán át, 90 perc, 90 percre, 1,5 óra hosszú
    m = src.find(
      '(?<![\\d:.])\\b(\\d+(?:[.,]\\d+)?|$_nw)\\s*-?\\s*'
      '(?:(ora)(?:s|t|n)\\b|(perc)(?:es|et|re|ig|en|\\b))(?:\\s+(?:at|keresztul)\\b)?',
    );
    if (m != null) {
      final raw = m.group(1)!;
      final v = _numberWords.containsKey(raw)
          ? _numberWords[raw]!.toDouble()
          : double.parse(raw.replaceAll(',', '.'));
      final minutes = (m.group(2) != null ? v * 60 : v).round();
      if (minutes >= 1 && minutes <= 24 * 60) {
        duration = minutes;
        src.takeMatch(m);
      }
    }
  }

  // ---- 6. the hour
  /// Words for the part of the day right before or after [at].
  String? dayPartAround(int start, int end, {bool consume = true}) {
    final before = src.wordBefore(start);
    final b = before.replaceAll(RegExp(r'[,;:]+$'), '');
    if (_dayParts.containsKey(b)) {
      if (consume) src.take(src.wordBeforeStart(start), start);
      return _dayParts[b];
    }
    final after = src.wordAfter(end).replaceAll(RegExp(r'[,;:.]+$'), '');
    if (_dayParts.containsKey(after) && after != 'de') {
      if (consume) src.take(end, src.wordAfterEnd(end));
      return _dayParts[after];
    }
    return null;
  }

  int withPart(
    int h,
    String? part, {
    required bool bare,
    required String said,
    int minute = 0,
  }) {
    if (part == 'am') return h == 12 && said.contains('hajnal') ? 0 : h;
    if (part == 'pm') return h < 12 ? h + 12 : h;
    if (part == 'night') {
      if (h == 12) return 0;
      return h >= 6 && h <= 11 ? h + 12 : h;
    }
    if (bare && h >= 1 && h <= 6) {
      notes.add(
        'A(z) „$said” időpontot délutáninak vettem (${two(h + 12)}:${two(minute)}).',
      );
      return h + 12;
    }
    return h;
  }

  int? hourOf(String s) {
    final n = _numberWords.containsKey(s) ? _numberWords[s]! : int.tryParse(s);
    return n != null && n >= 0 && n <= 23 ? n : null;
  }

  // 6a. 18:00-19:30
  m = src.find(
    r'(?<![\d:.])(\d{1,2})[:.](\d{2})\s*[-–—]\s*(\d{1,2})[:.](\d{2})(?![\d:.])',
  );
  if (m != null) {
    final h1 = int.parse(m.group(1)!), n1 = int.parse(m.group(2)!);
    final h2 = int.parse(m.group(3)!), n2 = int.parse(m.group(4)!);
    if (h1 <= 23 && h2 <= 24 && n1 <= 59 && n2 <= 59) {
      final part = dayPartAround(m.start, m.end);
      final said = src.original.substring(m.start, m.end);
      startMin = withPart(h1, part, bare: false, said: said) * 60 + n1;
      endMin = withPart(h2, part, bare: false, said: said) * 60 + n2;
      src.takeMatch(m);
    }
  }
  // 6b. 18-tól 20-ig, 18:00-tól 20:00-ig
  if (startMin == null) {
    m = src.find(
      r'(?<![\d:.])(\d{1,2})(?:[:.](\d{2}))?\s*(?:ora)?\s*-?\s*tol\s+(\d{1,2})(?:[:.](\d{2}))?\s*(?:ora)?\s*-?\s*ig\b',
    );
    if (m != null) {
      final h1 = int.parse(m.group(1)!), n1 = int.parse(m.group(2) ?? '0');
      final h2 = int.parse(m.group(3)!), n2 = int.parse(m.group(4) ?? '0');
      if (h1 <= 23 && h2 <= 24 && n1 <= 59 && n2 <= 59) {
        final part = dayPartAround(m.start, m.end);
        final said = src.original.substring(m.start, m.end);
        final colon = m.group(2) != null;
        startMin = withPart(h1, part, bare: !colon, said: said) * 60 + n1;
        endMin = withPart(h2, part, bare: !colon, said: said) * 60 + n2;
        if (!colon && part == null && h1 >= 1 && h1 <= 6) {
          // the same part of the day for both ends
          final alt = endMin + 12 * 60;
          if (endMin < startMin && alt > startMin) endMin = alt;
        }
        src.takeMatch(m);
      }
    }
  }
  // 6c. 18-20 (a bare range is only believed next to a day or an hour word)
  if (startMin == null) {
    m = src.find(
      r'(?<![\d:.])(\d{1,2})\s*[-–—]\s*(\d{1,2})(?![\d:.])(?:\s*(?:ora|orakor|kozott))?',
    );
    if (m != null) {
      final h1 = int.parse(m.group(1)!), h2 = int.parse(m.group(2)!);
      final said = src.original.substring(m.start, m.end).trim();
      final next = m.group(0)!;
      final hasWord = RegExp(r'ora|kozott').hasMatch(next);
      final part = dayPartAround(m.start, m.end, consume: false);
      if (h1 <= 23 &&
          h2 <= 24 &&
          h1 != h2 &&
          (date != null || hasWord || part != null)) {
        dayPartAround(m.start, m.end);
        startMin = withPart(h1, part, bare: true, said: said) * 60;
        endMin = withPart(h2, part, bare: false, said: said) * 60;
        final alt = endMin + 12 * 60;
        if (endMin <= startMin && alt > startMin) endMin = alt;
        src.takeMatch(m);
      }
    }
  }
  // 6d. fél 7, negyed 8, háromnegyed 8
  if (startMin == null) {
    m = src.find(
      '\\b(fel|negyed|haromnegyed)\\s+(\\d{1,2}|$_nw)\\b(?!\\s*ora)(?:\\s*-\\s*(?:kor|re|ra|tol|ig))?',
    );
    if (m != null) {
      final h = hourOf(m.group(2)!);
      if (h != null && h >= 1) {
        final minute = switch (m.group(1)) {
          'fel' => 30,
          'negyed' => 15,
          _ => 45,
        };
        final base = (h - 1) % 24;
        final part = dayPartAround(m.start, m.end);
        final said = src.original.substring(m.start, m.end).trim();
        startMin =
            withPart(base, part, bare: true, said: said, minute: minute) * 60 +
            minute;
        src.takeMatch(m);
      }
    }
  }
  // 6e. 18:30, 18.30, 18:30-kor
  if (startMin == null) {
    m = src.find(
      r'(?<![\d:.])(\d{1,2})[:.](\d{2})(?![\d:.]\d)(?:\s*-\s*(?:kor|tol|re|ra))?(?:\s*ora)?',
    );
    if (m != null) {
      final h = int.parse(m.group(1)!), n = int.parse(m.group(2)!);
      if (h <= 23 && n <= 59) {
        final part = dayPartAround(m.start, m.end);
        final said = src.original.substring(m.start, m.end).trim();
        startMin = withPart(h, part, bare: false, said: said) * 60 + n;
        src.takeMatch(m);
      }
    }
  }
  // 6f. 5-kor, 18-kor, 6 órakor, 18 óra, 6 órára, 7 h
  if (startMin == null) {
    m = src.find(
      '(?<![\\d:.])\\b(\\d{1,2}|$_nw)\\s*(?:-\\s*kor\\b|ora(?:kor|ra|tol)?\\b|h\\b)',
    );
    if (m != null) {
      final h = hourOf(m.group(1)!);
      if (h != null && h <= 23) {
        final part = dayPartAround(m.start, m.end);
        final said = src.original.substring(m.start, m.end).trim();
        startMin = withPart(h, part, bare: true, said: said) * 60;
        src.takeMatch(m);
      }
    }
  }
  // 6g. a part of the day and an hour: este 6, délután 3
  if (startMin == null) {
    m = src.find(
      '\\b(reggel|reggeli|delelott|delutan|du|este|esti|ejjel|ejszaka|hajnal|hajnali)\\.?\\s+(\\d{1,2})(?![\\d:.])\\b',
    );
    if (m != null) {
      final h = int.parse(m.group(2)!);
      if (h <= 12) {
        final part = _dayParts[m.group(1)!];
        startMin = withPart(h, part, bare: false, said: m.group(0)!) * 60;
        src.takeMatch(m);
      }
    }
  }
  // 6h. noon
  if (startMin == null) {
    m = src.find(r'\bdel(?:ben|re|tol)\b');
    if (m != null) {
      startMin = 12 * 60;
      src.takeMatch(m);
    }
  }
  // a length after a start: "18:00 2 órára"
  if (duration == null && startMin != null) {
    m = src.find(
      '(?<![\\d:.])\\b(\\d+(?:[.,]\\d+)?|$_nw)\\s*(?:orara|percre?)\\b',
    );
    if (m != null) {
      final raw = m.group(1)!;
      final v = _numberWords.containsKey(raw)
          ? _numberWords[raw]!.toDouble()
          : double.parse(raw.replaceAll(',', '.'));
      final minutes = (m.group(0)!.contains('perc') ? v : v * 60).round();
      if (minutes >= 1 && minutes <= 24 * 60) {
        duration = minutes;
        src.takeMatch(m);
      }
    }
  }
  if (endMin != null && startMin != null) {
    final span = endMin > startMin
        ? endMin - startMin
        : endMin + 24 * 60 - startMin;
    duration = span;
  }

  // ---- the day, when the line does not say
  final timed = startMin != null && !allDay;
  if (repeat != null && date == null) {
    date = _firstOccurrence(
      repeat!,
      repeatDays,
      monthDay,
      today,
      timed ? startMin : null,
      nowMinute,
    );
  }
  if (date == null && timed) {
    if (startMin <= nowMinute) {
      date = addDays(today, 1);
      notes.add('Az időpont ma már elmúlt, ezért holnapra vettem.');
    } else {
      date = today;
    }
  } else if (date != null && dateIsToday && timed && startMin <= nowMinute) {
    notes.add('Az időpont ma már elmúlt.');
  }

  // ---- what it is
  var kind = explicit;
  if (kind == null) {
    if (dueWord) {
      kind = QuickKind.task;
    } else if (timed || allDay) {
      kind = QuickKind.event;
    } else if (repeat != null && repeat!.freq != RepeatFreq.yearly) {
      kind = QuickKind.task;
      notes.add('Időpont nélkül ismétlődő feladatot vettem fel.');
    } else if (date != null) {
      kind = _looksLikeTodo(src.rest) ? QuickKind.task : QuickKind.event;
      if (kind == QuickKind.event) {
        notes.add('Nincs időpont, ezért egész napos eseményt vettem fel.');
      }
    } else {
      kind = QuickKind.task;
    }
  }
  if (kind == QuickKind.task && timed) {
    notes.add('A feladatnak nincs időpontja, csak határideje.');
  }
  if (kind == QuickKind.event && date == null) {
    date = today;
    notes.add('Nincs dátum, ezért a mai napra vettem.');
  }
  final isEvent = kind == QuickKind.event;

  // ---- the rest is the title
  var title = src.rest
      .replaceAll(RegExp(r'(^|\s)-[^\s]{1,5}(?=\s|$)'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  title = title.replaceAll(RegExp(r'^[\s,;:.\-–—/]+|[\s,;:\-–—/]+$'), '');
  title = sanitizeText(title, max: 80);
  if (title.isNotEmpty) {
    title = title[0].toUpperCase() + title.substring(1);
  }

  final anchor = date;
  return QuickEntry(
    kind: kind,
    title: title,
    date: anchor,
    startMinute: isEvent && timed ? startMin : null,
    durationMinutes: isEvent && timed ? (duration ?? 60) : null,
    allDay: isEvent && !timed,
    rrule: repeat == null || anchor == null
        ? null
        : repeat!.toRrule(
            repeat!.freq == RepeatFreq.monthly && monthDay != null
                ? floating(anchor.year, anchor.month, monthDay)
                : anchor,
          ),
    repeatText: repeat == null ? null : repeatText,
    assumptions: notes,
  );
}

/// The days with the ending that makes them the object of a sentence ("a
/// következő keddet vettem").
const _weekdayAccusative = [
  'hétfőt',
  'keddet',
  'szerdát',
  'csütörtököt',
  'pénteket',
  'szombatot',
  'vasárnapot',
];

/// A line without an hour but with a verb in it ("tejet venni") is a thing to
/// do, not a happening.
bool _looksLikeTodo(String text) {
  for (final w in text.split(RegExp(r'\s+'))) {
    final f = _fold(w).replaceAll(RegExp(r'[^a-z]'), '');
    if (f.length >= 5 && f.endsWith('ni')) return true;
  }
  return false;
}

/// The first day on which a rule given without a date happens: today (when
/// the hour is still ahead), or the first matching day after.
DateTime _firstOccurrence(
  RecurrenceSpec spec,
  Set<int> days,
  int? monthDay,
  DateTime today,
  int? startMinute,
  int nowMinute,
) {
  bool todayStillOpen() => startMinute == null || startMinute > nowMinute;
  switch (spec.freq) {
    case RepeatFreq.daily:
      return todayStillOpen() ? today : today.add(const Duration(days: 1));
    case RepeatFreq.weekly:
      final set = days.isEmpty ? {today.weekday} : days;
      for (var i = 0; i < 8; i++) {
        final d = today.add(Duration(days: i));
        if (set.contains(d.weekday) && (i > 0 || todayStillOpen())) return d;
      }
      return today;
    case RepeatFreq.monthly:
      final day = monthDay ?? today.day;
      for (var i = 0; i < 14; i++) {
        final y = today.year + (today.month - 1 + i) ~/ 12;
        final mo = (today.month - 1 + i) % 12 + 1;
        final d = floating(y, mo, day);
        if (d.month != mo) continue;
        if (d.isAfter(today) || (d == today && todayStillOpen())) return d;
      }
      return today;
    case RepeatFreq.yearly:
      return todayStillOpen() ? today : today.add(const Duration(days: 1));
  }
}
