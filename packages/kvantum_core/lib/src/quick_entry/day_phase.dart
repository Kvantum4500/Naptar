part of '../quick_entry.dart';

// The day: a date, a relative word ("holnap"), a weekday, "in so many days",
// "the 20th". Part of the library of [parseQuickEntry].

DateTime _addDays(DateTime d, int n) => d.add(Duration(days: n));

typedef _Day = ({DateTime? date, bool isToday, bool due});

/// The day the line says, taken out of [src]: the date (null when it says
/// none), whether it is today, and whether it was said as a deadline ("...ig").
_Day _takeDay(_Src src, DateTime today, List<String> notes) {
  DateTime? date;
  var dateIsToday = false;
  var dueWord = false;
  RegExpMatch? m;

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
      date = _addDays(today, n);
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
          date = _addDays(today, n);
        case 'het':
          date = _addDays(today, 7 * n);
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
      date = _addDays(
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
      date = _addDays(monday, 7 + wd - 1);
      if (m.group(1)!.endsWith('ig')) dueWord = true;
      src.takeMatch(m);
    }
  }
  if (date == null) {
    m = src.find('\\b(?:ezen\\s+a\\s+|e\\s+|a\\s+)?heten\\s+($_wd)\\b');
    if (m != null) {
      final wd = _wdOf(m.group(1)!);
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final d = _addDays(monday, wd - 1);
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

  return (date: date, isToday: dateIsToday, due: dueWord);
}
