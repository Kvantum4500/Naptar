part of '../quick_entry.dart';

// How often: "minden hétfőn", "hetente", "2 naponta", "havonta 5-én"... Part of
// the library of [parseQuickEntry].

typedef _Repeat = ({
  RecurrenceSpec? spec,
  String? text,
  Set<int> days,
  int? monthDay,
});

/// The repeat the line says, taken out of [src] (nothing, when it says none).
_Repeat _takeRepeat(_Src src) {
  RecurrenceSpec? repeat;
  String? repeatText;
  Set<int> repeatDays = {};
  int? monthDay;
  RegExpMatch? m;

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

  return (spec: repeat, text: repeatText, days: repeatDays, monthDay: monthDay);
}
