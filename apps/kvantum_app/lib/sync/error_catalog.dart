import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DriftWrappedException;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart' show NewerFormatException;
import 'package:sqlite3/common.dart' show SqliteException;

import '../data/db_open.dart' show NewerDatabaseError;
import '../drive/drive_remote.dart' show DriveTransientError;
import '../google/google_auth_service.dart' show SignInException;
import 'api_errors.dart';
import 'remote.dart'
    show CalendarGoneError, ConflictException, TransientSyncError;

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
    'Diagnosztika oldalon vannak (Beállítások → A program, vagy a szinkron '
    'menüje).';

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

// ---------------------------------------------------------------- any error

/// What the screen offers next to an error.
enum ErrorAction { none, signIn, retry, diagnostics }

/// An error as the user sees it: what happened, what to do, and a short stable
/// [code] for the diagnostics log. Never the text of the exception: that may
/// be English, may quote what the user typed, and means nothing to them.
class ErrorInfo {
  const ErrorInfo(
    this.code,
    this.title, {
    this.advice,
    this.action = ErrorAction.none,
  });

  /// `net.offline`, `fs.full`, `db.sqlite.13` …
  final String code;

  /// What happened (Hungarian).
  final String title;

  /// What to do about it (Hungarian), if there is anything.
  final String? advice;
  final ErrorAction action;

  /// [title] and [advice] as one text.
  String get text => advice == null ? title : '$title $advice';
}

String _slug(String? s, {int max = 30}) {
  final t = (s ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9_]+'), '_');
  final cut = t.length > max ? t.substring(0, max) : t;
  return cut.isEmpty ? 'unknown' : cut;
}

const _seeDiagnostics =
    'A részletek a Diagnosztika oldalon vannak; a módosításaid nem vesznek el.';

/// Sorts any exception into a Hungarian [ErrorInfo]. This is the one place
/// that knows which exception means what; screens show [ErrorInfo.text] (or
/// the parts of it) and the log gets [ErrorInfo.code].
ErrorInfo errorInfoFor(Object e) {
  if (e is SignInException) {
    return ErrorInfo('auth.signin', e.message, action: ErrorAction.signIn);
  }
  if (e is TimeoutException) {
    return const ErrorInfo(
      'net.timeout',
      'A szolgáltatás nem válaszolt időben.',
      advice: 'Próbáld újra egy perc múlva.',
      action: ErrorAction.retry,
    );
  }
  if (e is SocketException ||
      e is http.ClientException ||
      e is HandshakeException ||
      e is TlsException ||
      e is HttpException) {
    return const ErrorInfo(
      'net.offline',
      'Nincs kapcsolat a szolgáltatással.',
      advice:
          'Ellenőrizd az internetet; a módosításaid megvannak, és később '
          'feltöltődnek.',
      action: ErrorAction.retry,
    );
  }
  if (e is TransientSyncError || e is DriveTransientError) {
    final h = e as RetryHint;
    if (h.dailyLimit) {
      return const ErrorInfo(
        'google.daily',
        'A Google mára kimerítette a kérések számát.',
        advice: 'A program később magától folytatja.',
      );
    }
    if (h.throttled) {
      return const ErrorInfo(
        'google.limit',
        'A Google ideiglenesen korlátozza a kéréseket.',
        advice: 'A program később magától folytatja.',
      );
    }
    return const ErrorInfo(
      'net.transient',
      'A szolgáltatás átmenetileg nem elérhető.',
      advice: 'A program magától újrapróbálja.',
      action: ErrorAction.retry,
    );
  }
  if (e is ItemRejectedError) {
    return ErrorInfo(
      'google.rejected.${e.status}',
      'A Google nem fogadta el a módosítást (kód: ${e.status}).',
      advice:
          'Szerkeszd újra az eseményt, vagy a Diagnosztika oldalon dobd el a '
          'feltöltését.',
      action: ErrorAction.diagnostics,
    );
  }
  if (e is ConflictException) {
    return const ErrorInfo(
      'google.conflict',
      'Az esemény közben megváltozott a Google-ban.',
      advice: 'A program a következő szinkronnál újrapróbálja.',
    );
  }
  if (e is CalendarGoneError) {
    return const ErrorInfo('google.calendar_gone', calendarGoneText);
  }
  if (e is FileSystemException) {
    final os = e.osError?.errorCode;
    if (os == 13 || os == 1 || os == 5) {
      return const ErrorInfo(
        'fs.denied',
        'A programnak nincs hozzáférése ehhez a fájlhoz vagy mappához.',
        advice: 'Válassz másik helyet.',
      );
    }
    if (os == 28 || os == 112 || os == 39) {
      return const ErrorInfo(
        'fs.full',
        'Elfogyott a hely az eszközön.',
        advice: 'Szabadíts fel tárhelyet, és próbáld újra.',
      );
    }
    if (os == 2 || os == 3) {
      return const ErrorInfo(
        'fs.missing',
        'A fájl vagy a mappa nem található.',
      );
    }
    return const ErrorInfo(
      'fs.error',
      'A fájlművelet nem sikerült.',
      advice: 'Próbáld újra, vagy válassz másik helyet.',
    );
  }
  if (e is SqliteException) {
    if (e.resultCode == 13) {
      return const ErrorInfo(
        'db.sqlite.13',
        'Elfogyott a hely az adatbázis írásához.',
        advice: 'Szabadíts fel tárhelyet, és indítsd újra a programot.',
      );
    }
    return ErrorInfo(
      'db.sqlite.${e.resultCode}',
      'Adatbázis-hiba történt.',
      advice:
          'Indítsd újra a programot; ha ismétlődik, nézd meg a Diagnosztika '
          'oldalt.',
      action: ErrorAction.diagnostics,
    );
  }
  if (e is DriftWrappedException) {
    final c = e.cause;
    return c is Object && c is! DriftWrappedException
        ? errorInfoFor(c)
        : const ErrorInfo(
            'db.error',
            'Adatbázis-hiba történt.',
            advice:
                'Indítsd újra a programot; ha ismétlődik, nézd meg a '
                'Diagnosztika oldalt.',
            action: ErrorAction.diagnostics,
          );
  }
  if (e is NewerFormatException || e is NewerDatabaseError) {
    return const ErrorInfo(
      'format.newer',
      'Ezt a programnak egy újabb verziója írta.',
      advice: 'Telepítsd a legújabb verziót; az adataid érintetlenek.',
    );
  }
  if (e is FormatException) {
    return const ErrorInfo(
      'data.format',
      'A fájl vagy a válasz formátuma nem megfelelő.',
      advice: 'Ha fájlt választottál, próbálj egy másikat.',
    );
  }
  if (e is MissingPluginException) {
    return const ErrorInfo(
      'platform.missing',
      'Ez a funkció ezen az eszközön nem érhető el.',
    );
  }
  if (e is PlatformException) {
    return ErrorInfo(
      'platform.${_slug(e.code)}',
      'A rendszer hibát jelzett.',
      advice: 'Próbáld újra; ha ismétlődik, nézd meg a Diagnosztika oldalt.',
      action: ErrorAction.diagnostics,
    );
  }
  if (e is Error) {
    return ErrorInfo(
      'app.bug.${_slug(e.runtimeType.toString())}',
      'Programhiba történt.',
      advice: _seeDiagnostics,
      action: ErrorAction.diagnostics,
    );
  }
  return ErrorInfo(
    'unknown.${_slug(e.runtimeType.toString())}',
    'Váratlan hiba történt.',
    advice: _seeDiagnostics,
    action: ErrorAction.diagnostics,
  );
}

/// The line for a failed sign-in (or for restoring the saved login).
String signInFailedText(Object e, {bool restore = false}) {
  final info = errorInfoFor(e);
  if (e is SignInException) return info.title;
  final what = restore
      ? 'A mentett bejelentkezést nem sikerült visszaállítani'
      : 'A bejelentkezés nem sikerült';
  if (info.action == ErrorAction.diagnostics) {
    return '$what. Próbáld újra; ha ismétlődik, nézd meg a Diagnosztika '
        'oldalt.';
  }
  return '$what: ${info.title}'
      '${info.advice == null ? '' : ' ${info.advice}'}';
}

// ------------------------------------------------------ failed uploads

/// A short, text-free code for why an upload of an event failed. It is what
/// the database keeps (the free text of an error can quote the event);
/// [outboxErrorText] turns it into a Hungarian line.
String uploadErrorCode(Object e) => switch (e) {
  ConflictException() => 'conflict',
  ItemRejectedError(:final status, :final reason) =>
    'rejected:$status:${_slug(reason)}',
  TransientSyncError(:final throttled, :final dailyLimit) =>
    dailyLimit
        ? 'transient:daily'
        : throttled
        ? 'transient:limit'
        : 'transient',
  _ => 'unexpected:${_slug(e.runtimeType.toString(), max: 40)}',
};

/// Why an upload failed, in Hungarian, from a stored [code]. Codes written by
/// older versions (free text) read as "an earlier error".
String outboxErrorText(String? code) {
  if (code == null || code.isEmpty) return 'még nem sikerült feltölteni';
  final p = code.split(':');
  switch (p.first) {
    case 'conflict':
      return 'az esemény közben megváltozott a Google-ban';
    case 'transient':
      if (p.length > 1 && p[1] == 'daily') {
        return 'a Google mára kimerítette a kérések számát';
      }
      if (p.length > 1) return 'a Google ideiglenesen korlátozza a kéréseket';
      return 'átmeneti hálózati vagy szerverhiba';
    case 'rejected':
      final status = p.length > 1 ? p[1] : '?';
      final reason = p.length > 2 && p[2] != 'unknown' ? ', ${p[2]}' : '';
      return 'a Google nem fogadta el (kód: $status$reason)';
    case 'unexpected':
      return 'váratlan hiba (${p.length > 1 ? p[1] : '?'})';
    default:
      return 'korábbi hiba; újrapróbáláskor frissül';
  }
}
