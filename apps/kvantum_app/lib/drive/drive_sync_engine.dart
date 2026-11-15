import 'package:kvantum_core/kvantum_core.dart';

import '../data/housekeeping.dart' show tombstoneRetention;
import '../data/record_repository.dart';
import '../diag/diag_log.dart';
import 'drive_remote.dart';

/// Syncs tasks and check-ins with Drive's app folder: pull -> merge -> push.
///
/// Records merge field by field (see [SyncRecord]); nothing is ever lost to a
/// concurrent edit of another field, and a failed run leaves everything
/// queued for the next one.
class DriveSyncEngine {
  DriveSyncEngine(this.repo, this.remote, {this._log});

  final RecordRepository repo;
  final DriveRemote remote;
  final DiagLog? _log;
  Future<void>? _running;

  /// Names of record files a NEWER version of the app wrote (this run): they
  /// are neither read, nor overwritten, nor deleted.
  final _newerNames = <String>{};

  /// Serialised: a call during a running sync waits, then runs once more.
  Future<DriveReport> sync() async {
    while (_running != null) {
      await _running;
    }
    late DriveReport result;
    final done = () async {
      result = await _run();
    }();
    _running = done.catchError((_) {});
    try {
      await done;
    } finally {
      _running = null;
    }
    return result;
  }

  /// The day (UTC date) of the last look for old markers.
  static const purgeDayKey = 'tombstonePurgeDay';

  Future<DriveReport> _run() async {
    _newerNames.clear();
    var pulled = 0, pushed = 0, corrupt = 0, dups = 0, failed = 0, newer = 0;
    var purged = 0;
    var full = false;
    var fin = true; // unknown until a pull succeeded: assume there is mail
    try {
      // ---------------------------------------------------------- pull
      var token = await repo.meta(driveTokenKey);
      DrivePull res;
      try {
        res = await remote.pull(token);
      } on DriveTokenExpired {
        _log?.info('drive', 'token_expired');
        await repo.setMeta(driveTokenKey, null);
        token = null;
        res = await remote.pull(null);
      }
      full = res.full || token == null;
      fin = res.finChanged || full;

      // Group by name: two devices may have created the same file.
      final byName = <String, List<DriveRecordFile>>{};
      for (final f in res.files) {
        (byName[f.name] ??= []).add(f);
      }
      final seen = <String>{};
      for (final entry in byName.entries) {
        // finance mailbox files (peers, letters) are handled by FinanceMailbox
        if (entry.key.startsWith('fin-')) continue;
        final files = entry.value..sort((a, b) => a.id.compareTo(b.id));
        final canonical = files.first;
        for (final f in files) {
          final rec = _parse(entry.key, f.content);
          if (rec == null) {
            if (_newerNames.contains(entry.key)) {
              newer++;
            } else if (_looksLikeRecordFile(entry.key)) {
              corrupt++;
              _log?.info(
                'drive',
                'file.corrupt',
                data: {'kind': recordFileNamePattern.firstMatch(entry.key)![1]},
              );
            }
            continue;
          }
          await repo.applyRemote(rec);
          pulled++;
        }
        if (_parse(entry.key, canonical.content) != null || files.length == 1) {
          await repo.setFileId(entry.key, canonical.id);
          seen.add(canonical.id);
        }
        if (files.length > 1 && !_newerNames.contains(entry.key)) {
          // everything is merged locally; make sure the canonical file gets
          // the merged result, then drop the extra copies
          final rec = await _recordForName(entry.key);
          if (rec != null) {
            await repo.markDirty(rec.kind, rec.id);
          }
          for (final extra in files.skip(1)) {
            await _tryDelete(extra.id);
            dups++;
          }
        }
      }
      for (final id in res.removedIds) {
        final name = await repo.nameOfFile(id);
        if (name == null) continue;
        await repo.forgetFile(id);
        final rec = await _recordForName(name);
        if (rec != null) {
          await repo.markDirty(rec.kind, rec.id); // file vanished: upload again
        }
      }
      if (full) {
        // Files we knew about that the full listing no longer contains.
        for (final kind in syncedKinds) {
          for (final rec in await repo.all(kind)) {
            final name = recordFileName(kind, rec.id);
            final fid = await repo.fileId(name);
            if (fid != null &&
                !seen.contains(fid) &&
                !res.files.any((f) => f.id == fid)) {
              await repo.forgetFile(fid);
              await repo.markDirty(kind, rec.id);
            }
          }
        }
      }
      await repo.setMeta(driveTokenKey, res.nextToken);

      // ---------------------------------------------------------- push
      for (final rec in await repo.dirty()) {
        try {
          if (await _push(rec)) pushed++;
        } on DriveTransientError {
          rethrow;
        } catch (e, st) {
          failed++; // keep it queued, try again next run
          _log?.error('drive', 'push.failed', e, st, {'kind': rec.kind});
        }
      }
      // files a newer version wrote: those met while pulling, and those met
      // only now, when a local change wanted to overwrite them
      if (_newerNames.length > newer) newer = _newerNames.length;
      purged = await _purgeTombstones();
    } on DriveTransientError catch (e) {
      return DriveReport(
        pulled: pulled,
        pushed: pushed,
        skippedCorrupt: corrupt,
        mergedDuplicates: dups,
        failed: failed,
        full: full,
        stoppedEarly: true,
        finChanged: fin,
        newerFormat: newer,
        purged: purged,
        hint: e,
      );
    }
    return DriveReport(
      pulled: pulled,
      pushed: pushed,
      skippedCorrupt: corrupt,
      mergedDuplicates: dups,
      failed: failed,
      full: full,
      finChanged: fin,
      newerFormat: newer,
      purged: purged,
    );
  }

  /// Once a day: forgets the records deleted more than [tombstoneRetention]
  /// ago, on this device and in Drive. The Drive file goes first: without it
  /// the next pull would hand the marker back. Only what has already been
  /// uploaded is touched.
  Future<int> _purgeTombstones() async {
    final now = repo.now();
    final day = DateTime.fromMillisecondsSinceEpoch(
      now,
      isUtc: true,
    ).toIso8601String().substring(0, 10);
    if (await repo.meta(purgeDayKey) == day) return 0;
    var purged = 0;
    for (final rec in await repo.oldTombstones(
      now - tombstoneRetention.inMilliseconds,
    )) {
      final name = recordFileName(rec.kind, rec.id);
      if (_newerNames.contains(name)) continue;
      try {
        final known = await repo.fileId(name);
        for (final id
            in known != null ? [known] : await remote.findByName(name)) {
          await remote.delete(id);
        }
        if (known != null) await repo.forgetFile(known);
      } on DriveTransientError {
        rethrow;
      } catch (e, st) {
        // the marker stays; the next day tries again
        _log?.error('drive', 'purge.failed', e, st, {'kind': rec.kind});
        continue;
      }
      await repo.purge(rec.kind, rec.id);
      purged++;
    }
    await repo.setMeta(purgeDayKey, day);
    return purged;
  }

  /// Uploads one dirty record. Returns true when a write happened.
  Future<bool> _push(SyncRecord rec) async {
    final name = recordFileName(rec.kind, rec.id);
    var fileId = await repo.fileId(name);
    var merged = rec;
    SyncRecord? remoteRec;

    if (fileId == null) {
      // Maybe another device already created it: adopt instead of duplicating.
      final existing = await remote.findByName(name);
      if (existing.isNotEmpty) fileId = existing.first;
    }
    if (fileId != null) {
      String? content;
      try {
        content = await remote.read(fileId);
      } on DriveFileTooBig {
        // not a record of ours (nothing the app writes is that big): treated
        // like a corrupt one, and overwritten by ours
        content = '';
      }
      if (content == null) {
        await repo.forgetFile(fileId);
        fileId = null;
      } else {
        remoteRec = _parse(name, content); // corrupt -> overwritten by ours
        if (remoteRec == null && _newerNames.contains(name)) {
          // A newer version of the app owns this file: leave it exactly as it
          // is. Ours stays queued, and is uploaded once this version is updated.
          return false;
        }
        if (remoteRec != null) {
          merged = rec.merge(remoteRec);
          if (!merged.sameAs(rec)) {
            await repo.applyRemote(merged); // keep local in step
          }
        }
      }
    }
    if (remoteRec != null && remoteRec.sameAs(merged)) {
      // Drive already has everything we have.
      if (fileId != null) {
        await repo.setFileId(name, fileId);
      }
      await repo.markClean(merged);
      return false;
    }
    final id = await remote.write(
      fileId: fileId,
      name: name,
      content: merged.encode(),
    );
    await repo.setFileId(name, id);
    await repo.markClean(merged);
    return true;
  }

  SyncRecord? _parse(String name, String content) {
    final m = recordFileNamePattern.firstMatch(name);
    if (m == null) return null;
    try {
      final r = SyncRecord.decode(content);
      // The name is the identity; a mismatching body is not ours to trust.
      if (r.kind != m[1] || r.id != m[2]) return null;
      // A stamp years ahead is no clock error but a forged or broken record
      // (see maxStampAhead): taken like a corrupt file - not applied, and
      // overwritten by ours when we have the record.
      if (stampIsAbsurd(r.updatedAt, repo.now())) return null;
      return r;
    } on NewerFormatException {
      _newerNames.add(name);
      return null;
    } on FormatException {
      return null;
    }
  }

  bool _looksLikeRecordFile(String name) =>
      recordFileNamePattern.hasMatch(name);

  Future<SyncRecord?> _recordForName(String name) async {
    final m = recordFileNamePattern.firstMatch(name);
    return m == null ? null : repo.get(m[1]!, m[2]!);
  }

  Future<void> _tryDelete(String id) async {
    try {
      await remote.delete(id);
    } on DriveTransientError {
      rethrow;
    } catch (e, st) {
      // leaving a harmless duplicate is better than failing the sync
      _log?.error('drive', 'duplicate.delete_failed', e, st);
    }
  }
}
