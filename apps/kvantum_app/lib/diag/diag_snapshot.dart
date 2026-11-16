import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../data/record_repository.dart' show clockAhead;
import '../providers.dart';
import '../sync/channel_status.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_engine.dart' show maxUploadAttempts;
import '../update/update_dialog.dart' show currentBuildProvider;
import '../update/update_service.dart' show currentUpdatePlatform;
import 'diag_log.dart';
import 'newer_format.dart';
import 'request_stats.dart';

/// A queued upload that Google refused.
class DiagFailedItem {
  const DiagFailedItem({
    required this.seq,
    required this.op,
    required this.attempts,
    required this.parked,
    required this.reason,
    required this.title,
  });

  /// Its place in the queue (what [EventRepository.discardOutbox] takes).
  final int seq;

  /// `upsert` | `delete`
  final String op;
  final int attempts;

  /// Given up on: it waits for a manual retry or an edit.
  final bool parked;

  /// Why, in Hungarian ([outboxErrorText]).
  final String reason;

  /// The event's title. It is shown on the screen, never in a report.
  final String title;
}

/// Something the user should know about.
class DiagWarning {
  const DiagWarning(this.code, this.text);
  final String code, text;
}

/// Everything the Diagnostics page shows, taken at one moment. Only numbers,
/// codes and Hungarian sentences: [renderReport] turns it into a text that can
/// leave the device, so no title, amount, note or address is in here (the one
/// exception, [DiagFailedItem.title], is left out of the report).
class DiagSnapshot {
  const DiagSnapshot({
    required this.at,
    required this.build,
    required this.platform,
    required this.schema,
    required this.dbBytes,
    required this.counts,
    required this.signedIn,
    required this.pending,
    required this.parked,
    required this.nextAttempt,
    required this.needsDecision,
    required this.channels,
    required this.failed,
    required this.requests,
    required this.warnings,
    required this.log,
  });

  final DateTime at;
  final int? build;
  final String platform;
  final int schema;
  final int? dbBytes;

  /// What is stored, by kind (Hungarian labels): numbers only.
  final Map<String, int> counts;
  final bool signedIn;
  final int pending, parked;
  final DateTime? nextAttempt;

  /// Another Google account / calendar: the sync waits for a decision.
  final bool needsDecision;
  final Map<String, ChannelStatus> channels;
  final List<DiagFailedItem> failed;
  final RequestTable requests;
  final List<DiagWarning> warnings;

  /// The last log entries, oldest first.
  final List<DiagEntry> log;
}

/// Hungarian names of the sync channels.
const channelLabels = {
  channelCalendar: 'Naptár',
  channelDrive: 'Drive (feladatok, check-inek)',
  channelFinance: 'Pénzügy (levelek)',
};

const serviceLabels = {
  'calendar': 'Naptár',
  'drive': 'Drive',
  'other': 'Egyéb',
};

/// Collects the snapshot. It reads the sync state, so the page updates when a
/// run ends; nothing here changes anything.
final diagSnapshotProvider = FutureProvider.autoDispose<DiagSnapshot>((
  ref,
) async {
  final sync = ref.watch(syncControllerProvider);
  final log = ref.watch(diagLogProvider);
  final events = ref.read(repoProvider);
  final records = ref.read(recordRepoProvider);
  final finance = ref.read(financeRepoProvider);
  final db = ref.read(dbProvider);
  final now = ref.read(appClockProvider)();

  int? build;
  try {
    build = await ref.watch(currentBuildProvider.future);
  } on Object {
    build = null;
  }

  var schema = AppDatabase.currentSchemaVersion;
  try {
    final r = await db.customSelect('PRAGMA user_version').getSingle();
    schema = r.read<int>('user_version');
  } on Object {
    // the number this build knows is the best answer
  }

  int? dbBytes;
  final path = ref.read(dbPathProvider);
  if (path != null) {
    try {
      dbBytes = File(path).lengthSync();
    } on Object {
      dbBytes = null;
    }
  }

  final counts = <String, int>{};
  Future<int> one(String sql) async {
    final r = await db.customSelect(sql).getSingle();
    return r.read<int>('n');
  }

  counts['esemény'] = await one(
    'SELECT COUNT(*) AS n FROM event_rows WHERE deleted = 0',
  );
  final byKind = await db
      .customSelect('SELECT kind, COUNT(*) AS n FROM record_rows GROUP BY kind')
      .get();
  for (final row in byKind) {
    final label = switch (row.read<String>('kind')) {
      'task' => 'feladat',
      'checkin' => 'check-in',
      'workoutlog' => 'edzésnapló',
      'handbook' => 'kézikönyv-fájl',
      'intake' => 'étkezési hónap',
      'journal' => 'napló-bejegyzés',
      'settings' => 'beállítás-csoport',
      final other => other,
    };
    counts[label] = row.read<int>('n');
  }
  counts['pénzügyi elem'] = await one(
    'SELECT COUNT(*) AS n FROM fin_rows WHERE deleted = 0',
  );

  final failed = [
    for (final i in await events.failedOutbox())
      DiagFailedItem(
        seq: i.seq,
        op: i.op,
        attempts: i.attempts,
        parked: i.attempts >= maxUploadAttempts,
        reason: outboxErrorText(i.lastError),
        title: i.event.title,
      ),
  ];

  final requests = await ref.read(requestStatsProvider).read(events.meta);
  final entries = await log.tail(100);

  // ------------------------------------------------------------ warnings
  final warnings = <DiagWarning>[];
  if (sync.mismatch != null) {
    warnings.add(
      const DiagWarning(
        'binding',
        'Másik Google-fiók vagy naptár: a naptár-szinkron megállt, és a '
            'szinkron menüjében kell dönteni.',
      ),
    );
  }
  final stamps = [
    await records.newestStamp(),
    await finance.newestStamp(),
  ].whereType<int>();
  final ahead = clockAhead(
    stamps.isEmpty ? null : stamps.reduce(math.max),
    now.toUtc().millisecondsSinceEpoch,
  );
  if (ahead != null) {
    warnings.add(
      DiagWarning(
        'clock',
        'Egy módosítás ${ahead.inDays} nappal a jövőben van bélyegezve: '
            'ennek vagy egy másik eszköznek az órája előrejár. Állítsd be az '
            'órát. Addig a program az újabb szerkesztéseket a jövőbeli bélyeg '
            'után bélyegzi, hogy ne vesszenek el.',
      ),
    );
  }
  final newer = decodeNewerFormat(await events.meta(newerFormatKey));
  if (newer.isNotEmpty) {
    final n = newer.values.fold<int>(0, (a, b) => a + b.count);
    warnings.add(
      DiagWarning(
        'newer',
        '$n elemet a program egy újabb verziója írt (${newer.keys.map((k) => k == 'drive' ? 'Drive' : 'pénzügy').join(', ')}). '
            'Nem olvasom és nem írom felül; telepítsd az újabb verziót.',
      ),
    );
  }
  final unreadable = (await events.unreadableEvents()).length;
  if (unreadable > 0) {
    warnings.add(
      DiagWarning(
        'unreadable',
        '$unreadable esemény ismétlődési szabályát nem tudom olvasni, ezek '
            'nem jelennek meg a naptárban.',
      ),
    );
  }
  if (entries.any((e) => e.code == 'expand.capped')) {
    warnings.add(
      const DiagWarning(
        'capped',
        'Egy ismétlődő esemény több mint 20 000 előfordulást adna; a távoli '
            'jövőjét nem mutatom.',
      ),
    );
  }
  final today = requests[dayKeyOf(now)];
  final limited = today == null
      ? 0
      : today.values.fold<int>(0, (a, c) => a + c.throttled);
  if (limited > 0) {
    warnings.add(
      DiagWarning(
        'quota',
        'A Google ma $limited alkalommal korlátozta a kéréseket. A program '
            'lassabban folytatja.',
      ),
    );
  }
  final parked = failed.where((f) => f.parked).length;
  if (parked > 0) {
    warnings.add(
      DiagWarning(
        'parked',
        '$parked módosítást a Google többszöri próba után sem fogadott el; '
            'ezek feladva várnak (lent a lista).',
      ),
    );
  }

  return DiagSnapshot(
    at: now,
    build: build,
    platform: currentUpdatePlatform().name,
    schema: schema,
    dbBytes: dbBytes,
    counts: counts,
    signedIn: sync.signedIn,
    pending: sync.pending,
    parked: sync.parked,
    nextAttempt: sync.nextAttempt,
    needsDecision: sync.mismatch != null,
    channels: sync.channels,
    failed: failed,
    requests: requests,
    warnings: warnings,
    log: entries,
  );
});

// ------------------------------------------------------------------ report

String _two(int n) => n.toString().padLeft(2, '0');

String diagTime(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:'
      '${_two(l.minute)}';
}

/// "3,2 MB" / "480 KB".
String sizeText(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
  return '${(bytes / 1024).round()} KB';
}

/// The log entries as the report and the page show them: time, area/code and
/// what is known, on one line.
String entryLine(DiagEntry e) {
  final t = e.time.toUtc();
  final d = [for (final x in e.data.entries) '${x.key}=${x.value}'].join(' ');
  return '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:'
      '${_two(t.second)}Z ${e.area}/${e.code}'
      '${d.isEmpty ? '' : ' $d'}${e.error == null ? '' : ' · ${e.error}'}';
}

/// The report the user can copy or save and show to whoever helps. Numbers,
/// codes and Hungarian sentences only: no event title, no amount, no note, no
/// address, no key (see the tests).
String renderReport(DiagSnapshot s) {
  final b = StringBuffer()
    ..writeln('Kvantum Naptár – diagnosztikai jelentés')
    ..writeln('Készült: ${diagTime(s.at)}')
    ..writeln()
    ..writeln('== Alkalmazás ==')
    ..writeln('Verzió: ${s.build == null ? 'ismeretlen' : 'build ${s.build}'}')
    ..writeln('Platform: ${s.platform}')
    ..writeln(
      'Adatbázis: séma ${s.schema}'
      '${s.dbBytes == null ? '' : ', ${sizeText(s.dbBytes!)}'}',
    )
    ..writeln(
      'Elemek: ${s.counts.entries.map((e) => '${e.key} ${e.value}').join(' · ')}',
    )
    ..writeln()
    ..writeln('== Szinkron ==')
    ..writeln('Bejelentkezve: ${s.signedIn ? 'igen' : 'nem'}')
    ..writeln(
      'Függő módosítás: ${s.pending}'
      '${s.parked > 0 ? ' (feladva: ${s.parked})' : ''}',
    );
  if (s.needsDecision) b.writeln('Másik fiók vagy naptár: döntés kell');
  if (s.nextAttempt != null) {
    b.writeln('Következő próba: ${diagTime(s.nextAttempt!)}');
  }
  for (final ch in syncChannels) {
    final st = s.channels[ch];
    final name = channelLabels[ch]!;
    if (st == null) {
      b.writeln('$name: még nem volt futás');
      continue;
    }
    b.writeln(
      '$name: ${st.ok ? 'rendben' : 'hiba (kód: ${st.code})'}'
      ' · utolsó próba ${st.lastTry == null ? '–' : diagTime(st.lastTry!)}'
      ' · utolsó siker ${st.lastOk == null ? '–' : diagTime(st.lastOk!)}'
      ' · ${st.pulled} le, ${st.pushed} fel, ${st.failed} nem ment át',
    );
  }
  b
    ..writeln()
    ..writeln('== Feltöltésre váró, elutasított módosítások ==');
  if (s.failed.isEmpty) {
    b.writeln('nincs');
  } else {
    var i = 0;
    for (final f in s.failed) {
      i++;
      b.writeln(
        '$i. ${f.op == 'delete' ? 'törlés' : 'módosítás'}, ${f.attempts}. '
        'próba, ${f.reason}${f.parked ? ' [feladva]' : ''}',
      );
    }
  }
  b
    ..writeln()
    ..writeln('== Google-kérések (naponta) ==');
  if (s.requests.isEmpty) {
    b.writeln('még nincs adat');
  } else {
    final days = s.requests.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final day in days) {
      for (final svc in requestServices) {
        final c = s.requests[day]?[svc];
        if (c == null || c.calls == 0) continue;
        b.writeln(
          '$day ${serviceLabels[svc]}: ${c.calls} hívás · ${c.ok} rendben · '
          '${c.client} elutasítva · ${c.throttled} korlátozva · '
          '${c.server} szerverhiba · ${c.failed} nem ért célba',
        );
      }
    }
  }
  b
    ..writeln()
    ..writeln('== Figyelmeztetések ==');
  if (s.warnings.isEmpty) {
    b.writeln('nincs');
  } else {
    for (final w in s.warnings) {
      b.writeln('- ${w.text}');
    }
  }
  b
    ..writeln()
    ..writeln('== Hibanapló (utolsó ${s.log.length} bejegyzés, UTC) ==');
  if (s.log.isEmpty) {
    b.writeln('üres');
  } else {
    for (final e in s.log) {
      b.writeln(entryLine(e));
    }
  }
  return b.toString();
}
