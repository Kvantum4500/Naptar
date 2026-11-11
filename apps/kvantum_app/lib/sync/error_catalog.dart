import 'api_errors.dart';

/// Hungarian texts for what can go wrong with the sync, one place, so the
/// screen never shows a class name or an English exception.

String _wait(Duration d) {
  if (d.inSeconds < 90) return 'egy perc múlva';
  if (d.inMinutes < 60) return '${(d.inSeconds / 60).round()} perc múlva';
  final h = (d.inMinutes / 60).round();
  return '$h óra múlva';
}

/// A run that stopped because of the moment (network, server, a limit).
/// [next] is when the next try is planned.
String transientText(String channel, RetryHint? hint, {Duration? next}) {
  final when = next == null ? '' : ' Újrapróbálom ${_wait(next)}.';
  if (hint != null && hint.dailyLimit) {
    return '$channel: a Google mára kimerítette a kérések számát, később '
        'folytatom.$when';
  }
  if (hint != null && hint.throttled) {
    return '$channel: a Google ideiglenesen korlátozza a kéréseket.$when';
  }
  return '$channel: nincs kapcsolat vagy a Google nem válaszol; a '
      'módosítások megvannak, és feltöltődnek.$when';
}

String parkedText(String channel, int n) =>
    '$channel: $n módosítást a Google nem fogadott el, ezeket nem erőltetem. '
    'A „Szinkron most” újra megpróbálja, vagy módosítsd az eseményt.';

String refusedText(String channel, int n) =>
    '$channel: $n módosítást nem sikerült elküldeni, újrapróbálom.';

String skippedText(String channel, int n) =>
    '$channel: $n Google-esemény nem olvasható be, kihagytam.';

String newerFormatText(String channel, int n) =>
    '$channel: $n elemet az alkalmazás egy újabb verziója írt; ezeket nem '
    'bántom, és nem is írom felül. Telepítsd az újabb verziót.';

const calendarGoneText =
    'A Google-naptár eltűnt (törölték vagy átnevezték). Megkeresem, és ha '
    'másik naptár van a helyén, megkérdezlek, mit tegyek.';

/// An error nobody planned for: a short Hungarian line, never the raw
/// exception text (that goes to the diagnostics log).
String unexpectedText(String channel) =>
    '$channel: váratlan hiba történt; a módosítások megvannak. A részletek a '
    'Szinkron → Részletek alatt vannak.';

const bindingTitleAccount = 'Másik Google-fiók';
const bindingTitleCalendar = 'A Google-naptár megváltozott';

String bindingBody({
  required bool accountChanged,
  required String stored,
  required String current,
}) {
  final what = accountChanged
      ? 'Ez az eszköz eddig a(z) $stored fiók „Naptar” naptárával '
            'szinkronizált, most a(z) $current fiókba léptél be.'
      : 'Ez az eszköz eddig egy másik „Naptar” naptárral szinkronizált '
            '($stored), de ez a naptár már nem ugyanaz (törölték vagy újra '
            'létrehozták).';
  return '$what A naptár-szinkron megállt, hogy a két naptár eseményei ne '
      'keveredjenek össze. Mit tegyek?';
}

const bindingKeepTitle = 'Helyi események megtartása és feltöltése';
const bindingKeepBody =
    'Az eszközön lévő összes esemény feltöltődik az új naptárba. Semmi nem '
    'törlődik.';
const bindingFreshTitle = 'Üres indulás';
const bindingFreshBody =
    'Az eszközön lévő naptáresemények törlődnek, és az új naptár eseményei '
    'töltődnek le. A Google-ban semmi nem törlődik.';

String bindingFreshConfirm(int n) =>
    '$n esemény törlődik erről az eszközről. A Google-ban semmi nem törlődik. '
    'Biztos?';

const resetTitle = 'Szinkron alaphelyzetbe?';
const resetBody =
    'Minden helyi esemény újra összekapcsolódik a Google-naptárral, a '
    'feladatok, a check-inek és a pénzügyi levelek szinkronja pedig a '
    'nulláról indul. Helyben semmi nem törlődik, a Google-ban sem. Ha '
    'valamit közben a Google-ban töröltél, azt a program visszateszi. Sok '
    'eseménynél eltarthat egy ideig.';
