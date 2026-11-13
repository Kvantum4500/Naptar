import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:kvantum_core/kvantum_core.dart';

import '../data/backup_ops.dart';
import '../data/event_repository.dart';
import '../data/finance_repository.dart';
import '../data/record_repository.dart';
import 'backup_bundle.dart';

/// Runs [job] somewhere else (by default on a new isolate): packing and
/// unpacking a backup is the slow part, and the screen must not freeze.
typedef BackupRunner = Future<T> Function<T>(T Function() job);

Future<T> onIsolate<T>(T Function() job) => Isolate.run(job);
Future<T> inline<T>(T Function() job) async => job();

// (the jobs are made here, not inside the service: a job that is sent to
// another isolate must not carry the repositories along)
Future<Uint8List> _pack(
  BackupRunner run,
  BackupData data,
  BackupMeta meta,
  String? password,
) => run(() => packBackup(data, meta, password: password));

Future<BackupFile> _unpack(
  BackupRunner run,
  Uint8List bytes,
  String? password,
) => run(() => unpackBackup(bytes, password: password));

/// What restoring a backup would do on this device (nothing is written).
class BackupPreview {
  const BackupPreview({
    required this.meta,
    required this.events,
    required this.finance,
    required this.records,
    this.problems = const [],
  });
  final BackupMeta meta;

  /// The calendar: new events, changed ones (a restore may overwrite them) and
  /// the ones that are the same.
  final ImportPlan events;
  final ({int added, int updated}) finance;

  /// The tasks, check-ins, handbook files and workout logs.
  final ({int added, int updated, int same}) records;
  final List<String> problems;

  /// Nothing in the backup would change anything.
  bool get changesNothing =>
      events.fresh.isEmpty &&
      events.changes.isEmpty &&
      finance.added + finance.updated == 0 &&
      records.added + records.updated == 0;
}

/// What a restore did.
class RestoreResult {
  const RestoreResult({
    required this.events,
    required this.finance,
    required this.records,
    this.problems = const [],
  });
  final ImportResult events;
  final ({int added, int updated}) finance;
  final ({int added, int updated, int same}) records;
  final List<String> problems;
}

/// Makes backups of everything the app keeps, and puts them back. A restore
/// never deletes: it adds what the device lacks and, field by field or record
/// by record, takes what is newer.
class BackupService {
  BackupService({
    required this.events,
    required this.records,
    required this.finance,
    required this.now,
    this.build,
    this.runner = onIsolate,
  });

  final EventRepository events;
  final RecordRepository records;
  final FinanceRepository finance;

  /// The clock (replaced by tests).
  final DateTime Function() now;

  /// The build of this app (written into each backup).
  final Future<int?> Function()? build;
  final BackupRunner runner;

  /// A backup of everything now, as a zip. With a [password] it is locked
  /// (AES-256).
  Future<Uint8List> create({String? password}) async {
    final evs = await events.all();
    final fin = await finance.exportJson();
    final counts = <String, int>{'events': evs.length};
    final finRecords = (jsonDecode(fin) as Map)['records'];
    counts['finance'] = finRecords is List ? finRecords.length : 0;
    final encoded = <String>[];
    for (final kind in syncedKinds) {
      final all = await records.all(kind);
      counts[kind] = all.where((r) => !r.deleted).length;
      encoded.addAll(all.map((r) => r.encode()));
    }
    final data = BackupData(
      calendarIcs: exportIcs(evs),
      financeJson: fin,
      records: encoded,
    );
    int? b;
    try {
      b = await build?.call();
    } catch (_) {
      b = null; // (the build number is a nicety)
    }
    final meta = BackupMeta(createdAt: now().toUtc(), build: b, counts: counts);
    return _pack(runner, data, meta, password);
  }

  /// Opens a backup file. Throws a [BackupException] saying what is wrong.
  Future<BackupFile> open(Uint8List bytes, {String? password}) =>
      _unpack(runner, bytes, password);

  List<SyncRecord> _decodeRecords(BackupFile file, List<String> problems) {
    final out = <SyncRecord>[];
    var bad = 0;
    for (final text in file.data.records) {
      try {
        final r = SyncRecord.decode(text);
        if (syncedKinds.contains(r.kind)) {
          out.add(r);
        } else {
          bad++;
        }
      } on FormatException {
        bad++; // (also a record of a newer format: it is not read)
      }
    }
    if (bad > 0) problems.add('$bad rekord nem olvasható, kihagyom.');
    return out;
  }

  /// What restoring [file] would do here. Writes nothing.
  Future<BackupPreview> preview(BackupFile file) async {
    final problems = <String>[];
    final plan = file.data.calendarIcs.isEmpty
        ? const ImportPlan()
        : await previewBackup(
            events,
            file.data.calendarIcs,
            calendarId: kNaptarCalendar,
            runner: (job) => runner<IcsImport>(job),
          );
    problems.addAll(plan.problems);

    var fin = (added: 0, updated: 0);
    if (file.data.financeJson.isNotEmpty) {
      final r = await finance.importJson(file.data.financeJson, dryRun: true);
      if (r.newer) {
        problems.add('A pénzügyi rész újabb formátumú, nem állítom vissza.');
      } else if (!r.recognized) {
        problems.add('A pénzügyi rész nem olvasható, kihagyom.');
      } else {
        fin = (added: r.added, updated: r.updated);
      }
    }

    final recs = await records.restoreRecords(
      _decodeRecords(file, problems),
      dryRun: true,
    );
    return BackupPreview(
      meta: file.meta,
      events: plan,
      finance: fin,
      records: recs,
      problems: problems,
    );
  }

  /// Puts [file] back. [overwrite] says whether events that were changed since
  /// the backup may be replaced by their backed-up form (no default: the caller
  /// must say).
  Future<RestoreResult> restore(
    BackupFile file, {
    required bool overwrite,
  }) async {
    final problems = <String>[];
    final plan = file.data.calendarIcs.isEmpty
        ? const ImportPlan()
        : await previewBackup(
            events,
            file.data.calendarIcs,
            calendarId: kNaptarCalendar,
            runner: (job) => runner<IcsImport>(job),
          );
    final ev = await applyBackup(events, plan, overwrite: overwrite);
    problems.addAll(plan.problems);

    var fin = (added: 0, updated: 0);
    if (file.data.financeJson.isNotEmpty) {
      final r = await finance.importJson(file.data.financeJson);
      if (r.newer) {
        problems.add('A pénzügyi rész újabb formátumú, nem állítottam vissza.');
      } else if (!r.recognized) {
        problems.add('A pénzügyi rész nem olvasható, kihagytam.');
      } else {
        fin = (added: r.added, updated: r.updated);
      }
    }

    final recs = await records.restoreRecords(_decodeRecords(file, problems));
    return RestoreResult(
      events: ev,
      finance: fin,
      records: recs,
      problems: problems,
    );
  }
}
