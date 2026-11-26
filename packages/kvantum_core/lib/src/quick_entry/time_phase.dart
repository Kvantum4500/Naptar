part of '../quick_entry.dart';

// The time: "in so many minutes", how long, the hour (and the end of a range),
// and a length said after the hour. Part of the library of [parseQuickEntry].

/// "20 perc múlva", "másfél óra múlva": the start is that many minutes from
/// now, and the day is today (or tomorrow, past midnight) unless [known].
({int? startMin, DateTime? date}) _takeMinutesFromNow(
  _Src src,
  DateTime today,
  int nowMinute,
  DateTime? known,
) {
  var date = known;
  int? startMin;
  RegExpMatch? m;

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
      date ??= _addDays(today, 1);
    }
    src.takeMatch(m);
  }

  return (startMin: startMin, date: date);
}

/// A length that says it is a length, not an hour ("másfél óra", "90 perc").
int? _takeDuration(_Src src) {
  int? duration;
  RegExpMatch? m;

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

  return duration;
}

/// The hour: a range, "-tól -ig", "fél 7", "18:30", "5-kor", "este 6", noon.
/// [fromNow] is a start that "in so many minutes" already found. The end is
/// only known for a range.
({int? startMin, int? endMin}) _takeHour(
  _Src src,
  List<String> notes,
  DateTime? date,
  int? fromNow,
) {
  var startMin = fromNow;
  int? endMin;
  RegExpMatch? m;
  String two(int n) => n.toString().padLeft(2, '0');

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

  return (startMin: startMin, endMin: endMin);
}

/// A length said after the start: "18:00 2 órára".
int? _takeLengthAfterStart(_Src src, int? known, int? startMin) {
  var duration = known;
  RegExpMatch? m;

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

  return duration;
}
