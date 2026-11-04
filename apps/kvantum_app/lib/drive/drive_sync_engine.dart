import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';
import 'drive_remote.dart';

const _tokenKey = 'drivePageToken';

/// Syncs tasks and check-ins with Drive's app folder: pull -> merge -> push.
///
/// Records merge field by field (see [SyncRecord]); nothing is ever lost to a
/// concurrent edit of another field, and a failed run leaves everything
/// queued for the next one.
class DriveSyncEngine {
  DriveSyncEngine(this.repo, this.remote);

  final RecordRepository repo;
  final DriveRemote remote;
  Future<void>? _running;

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

  Future<DriveReport> _run() async {
    var pulled = 0, pushed = 0, corrupt = 0, dups = 0, failed = 0;
    var full = false;
    try {
      // ---------------------------------------------------------- pull
      var token = await repo.meta(_tokenKey);
      DrivePull res;
      try {
        res = await remote.pull(token);
      } on DriveTokenExpired {
        await repo.setMeta(_tokenKey, null);
        token = null;
        res = await remote.pull(null);
      }
      full = res.full || token == null;

      // Group by name: two devices may have created the same file.
      final byName = <String, List<DriveRecordFile>>{};
      for (final f in res.files) {
        (byName[f.name] ??= []).add(f);
      }
      final seen = <String>{};
      for (final entry in byName.entries) {
        final files = entry.value..sort((a, b) => a.id.compareTo(b.id));
        final canonical = files.first;
        for (final f in files) {
          final rec = _parse(entry.key, f.content);
          if (rec == null) {
            if (_looksLikeRecordFile(entry.key)) corrupt++;
            continue;
          }
          await repo.applyRemote(rec);
          pulled++;
        }
        if (_parse(entry.key, canonical.content) != null || files.length == 1) {
          await repo.setFileId(entry.key, canonical.id);
          seen.add(canonical.id);
        }
        if (files.length > 1) {
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
      await repo.setMeta(_tokenKey, res.nextToken);

      // ---------------------------------------------------------- push
      for (final rec in await repo.dirty()) {
        try {
          if (await _push(rec)) pushed++;
        } on DriveTransientError {
          rethrow;
        } catch (_) {
          failed++; // keep it queued, try again next run
        }
      }
    } on DriveTransientError {
      return DriveReport(
        pulled: pulled,
        pushed: pushed,
        skippedCorrupt: corrupt,
        mergedDuplicates: dups,
        failed: failed,
        full: full,
        stoppedEarly: true,
      );
    }
    return DriveReport(
      pulled: pulled,
      pushed: pushed,
      skippedCorrupt: corrupt,
      mergedDuplicates: dups,
      failed: failed,
      full: full,
    );
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
      final content = await remote.read(fileId);
      if (content == null) {
        await repo.forgetFile(fileId);
        fileId = null;
      } else {
        remoteRec = _parse(name, content); // corrupt -> overwritten by ours
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
    final m = RegExp(r'^(task|checkin|handbook)-(.+)\.json$').firstMatch(name);
    if (m == null) return null;
    try {
      final r = SyncRecord.decode(content);
      // The name is the identity; a mismatching body is not ours to trust.
      if (r.kind != m[1] || r.id != m[2]) return null;
      return r;
    } on FormatException {
      return null;
    }
  }

  bool _looksLikeRecordFile(String name) =>
      RegExp(r'^(task|checkin|handbook)-.+\.json$').hasMatch(name);

  Future<SyncRecord?> _recordForName(String name) async {
    final m = RegExp(r'^(task|checkin|handbook)-(.+)\.json$').firstMatch(name);
    return m == null ? null : repo.get(m[1]!, m[2]!);
  }

  Future<void> _tryDelete(String id) async {
    try {
      await remote.delete(id);
    } on DriveTransientError {
      rethrow;
    } catch (_) {
      // leaving a harmless duplicate is better than failing the sync
    }
  }
}
