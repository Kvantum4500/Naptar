import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kvantum_core/kvantum_core.dart';

import '../data/record_repository.dart';
import '../diag/diag_log.dart';
import '../journal/photo_files.dart';
import '../sync/api_errors.dart' show ItemRejectedError, RetryHint;
import 'drive_remote.dart';

/// The pictures of the diary between the devices of the user, through the
/// hidden folder of Drive (9th round).
///
/// A picture is one file there, named by [PhotoRef.driveName]. The record of an
/// entry says which pictures belong to it (the records are synced by
/// [DriveSyncEngine], which this class does not touch); this class carries the
/// FILES: what the entries refer to and this device has is sent up, what they
/// refer to and this device lacks is fetched, and once a day what no entry
/// refers to any more is taken out of Drive.
///
/// It is built to be harmless: every run does a few transfers, one after the
/// other (never at once), a picture that cannot go does not stop the others,
/// and nothing but a code goes to the log (no name, no path).
class PhotoSyncEngine {
  PhotoSyncEngine({
    required this.records,
    required this.remote,
    required this.files,
    required this.now,
    this.log,
    this.shouldStop,
    this.perRun = photoSyncPerRun,
    this.maxBytes = photoSyncMaxBytes,
    this.remoteGrace = photoRemoteGrace,
  });

  final RecordRepository records;
  final DriveRemote remote;
  final PhotoFiles files;

  /// The clock (replaced by tests).
  final DateTime Function() now;
  final DiagLog? log;

  /// Asked before every transfer: true ends the run (the app went to the
  /// background, the account was left).
  final bool Function()? shouldStop;

  /// How many pictures one run sends up, and how many it fetches.
  final int perRun;

  /// The most bytes one picture may have to travel.
  final int maxBytes;

  /// How old a picture in Drive that no entry refers to must be to be removed.
  final Duration remoteGrace;

  /// The `meta` keys: whether a picture ever went through this device (the
  /// daily tidying of Drive is only for a device that took part), and the day
  /// of the last tidying (UTC date).
  static const usedKey = 'photoSyncUsed';
  static const tidyDayKey = 'photoTidyDay';

  /// The first wait after a picture was not in Drive yet (the other device has
  /// not sent it, most often it is only a moment behind), or after its transfer
  /// went wrong: it doubles each time, up to [longestMissingWait].
  static const firstMissingWait = Duration(minutes: 1);
  static const longestMissingWait = Duration(hours: 6);

  Future<void>? _running;

  /// Pictures given up on in this run of the program: too big, not a JPEG, or
  /// refused by Drive. (Tried again after a restart.)
  final _given = <String>{};

  /// Pictures to try again later (they were not in Drive yet, or their transfer
  /// went wrong): when, and how often it was tried.
  final _later = <String, ({DateTime until, int tries})>{};

  /// Serialised: a call during a running sync waits, then runs once more.
  Future<PhotoSyncReport> sync() async {
    while (_running != null) {
      await _running;
    }
    late PhotoSyncReport result;
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

  Future<PhotoSyncReport> _run() async {
    var uploaded = 0, downloaded = 0, skipped = 0, failed = 0;
    var waiting = 0, cleaned = 0;
    var more = false, quotaFull = false, diskFull = false;
    final arrived = <String>[];
    try {
      final journal = await records.all(kindJournal);
      final wanted = <PhotoRef>[
        for (final e in journalEntries(journal))
          for (final p in e.photos)
            if (p.syncable) p,
      ];
      final here = {for (final f in await files.list()) f.name};
      final at = now();

      // ------------------------------------------------------------ up
      final up = <PhotoRef>[];
      for (final p in wanted) {
        if (!here.contains(p.fileName) || _given.contains(p.fileName)) continue;
        if (await records.fileId(p.driveName!) != null) continue;
        up.add(p);
      }
      var sent = 0, handledUp = 0;
      for (final p in up) {
        if (_early(p.fileName, at)) continue; // (it went wrong a moment ago)
        if (sent >= perRun) {
          more = true;
          break;
        }
        if (_stop() || quotaFull) break;
        try {
          final went = await _upload(p);
          // (it went well: a failure later starts anew)
          _later.remove(p.fileName);
          switch (went) {
            case _Went.sent:
              uploaded++;
              sent++;
              handledUp++;
            case _Went.already:
              handledUp++; // (in Drive already: nothing to do, no transfer)
            case _Went.given:
              skipped++;
              handledUp++;
          }
        } on DriveTransientError catch (e) {
          // (Google files a full Drive under the limits of usage, so it
          // comes as a wait; a full Drive is no wait: it is told as it is)
          if (!_isQuotaMessage(e.message)) rethrow;
          quotaFull = true;
          log?.infoOnce('photo.quota_full', 'drive', 'photo.quota_full');
        } on ItemRejectedError catch (e) {
          if (_isQuotaMessage(e.reason ?? '')) {
            quotaFull = true;
            log?.infoOnce('photo.quota_full', 'drive', 'photo.quota_full');
          } else {
            _given.add(p.fileName);
            failed++;
            log?.error('drive', 'photo.upload_rejected', _Failed('rejected'));
          }
        } catch (e, st) {
          failed++;
          _tryLater(p.fileName);
          log?.error('drive', 'photo.upload_failed', _Failed('upload'), st);
        }
      }
      waiting += up.length - handledUp;

      // ---------------------------------------------------------- down
      final down = <PhotoRef>[];
      for (final p in wanted) {
        if (here.contains(p.fileName) || _given.contains(p.fileName)) continue;
        down.add(p);
      }
      var fetched = 0, handledDown = 0;
      for (final p in down) {
        if (_early(p.fileName, at)) continue;
        if (fetched >= perRun) {
          more = true;
          break;
        }
        if (_stop() || diskFull) break;
        try {
          switch (await _download(p)) {
            case _Got.arrived:
              downloaded++;
              fetched++;
              handledDown++;
              arrived.add(p.fileName);
            case _Got.notThere:
              break; // (the other device has not sent it yet: still waiting)
            case _Got.given:
              skipped++;
              handledDown++;
          }
        } on DriveTransientError {
          rethrow;
        } on _DiskFull {
          diskFull = true;
          log?.infoOnce('photo.disk_full', 'drive', 'photo.disk_full');
        } catch (e, st) {
          failed++;
          _tryLater(p.fileName);
          log?.error('drive', 'photo.download_failed', _Failed('download'), st);
        }
      }
      waiting += down.length - handledDown;
      if (downloaded + uploaded > 0) await _markUsed();

      // ---------------------------------------------------------- tidy
      if (!_stop()) cleaned = await _tidy(wanted, journal);
    } on DriveTransientError catch (e) {
      return PhotoSyncReport(
        uploaded: uploaded,
        downloaded: downloaded,
        skipped: skipped,
        failed: failed,
        waiting: waiting,
        cleaned: cleaned,
        arrived: arrived,
        stoppedEarly: true,
        hint: e,
      );
    }
    return PhotoSyncReport(
      uploaded: uploaded,
      downloaded: downloaded,
      skipped: skipped,
      failed: failed,
      waiting: waiting,
      cleaned: cleaned,
      more: more,
      quotaFull: quotaFull,
      diskFull: diskFull,
      arrived: arrived,
    );
  }

  bool _stop() => shouldStop?.call() ?? false;

  Future<void> _markUsed() async {
    if (await records.meta(usedKey) == null) {
      await records.setMeta(usedKey, '1');
    }
  }

  // --------------------------------------------------------------- one up

  Future<_Went> _upload(PhotoRef p) async {
    final name = p.driveName!;
    final bytes = await files.read(p.fileName);
    if (bytes == null) return _Went.already; // (gone from here meanwhile)
    if (bytes.length > maxBytes) {
      _given.add(p.fileName);
      log?.infoOnce('photo.too_big_to_sync', 'drive', 'photo.too_big_to_sync');
      return _Went.given;
    }
    if (!_isJpeg(bytes)) {
      _given.add(p.fileName);
      log?.infoOnce('photo.not_a_jpeg', 'drive', 'photo.not_a_jpeg');
      return _Went.given;
    }
    // (another run, or another device, may have sent it already: Drive is
    // asked before a second file of the same name is made)
    final existing = await remote.findByName(name);
    if (existing.isNotEmpty) {
      await records.setFileId(name, existing.first);
      await _markUsed();
      return _Went.already;
    }
    final id = await remote.writeBytes(
      name: name,
      bytes: bytes,
      contentType: 'image/jpeg',
    );
    await records.setFileId(name, id);
    return _Went.sent;
  }

  // ------------------------------------------------------------ one down

  Future<_Got> _download(PhotoRef p) async {
    final name = p.driveName!;
    final ids = await remote.findByName(name);
    if (ids.isEmpty) return _notThereYet(p);
    final Uint8List? bytes;
    try {
      bytes = await remote.readBytes(ids.first, maxBytes: maxBytes);
    } on DriveFileTooBig {
      _given.add(p.fileName);
      log?.infoOnce('photo.too_big_to_sync', 'drive', 'photo.too_big_to_sync');
      return _Got.given;
    }
    if (bytes == null) return _notThereYet(p);
    if (!_isJpeg(bytes)) {
      // (what is in Drive under the name of a picture is none: left alone)
      _given.add(p.fileName);
      log?.infoOnce('photo.bad_download', 'drive', 'photo.bad_download');
      return _Got.given;
    }
    try {
      await files.write(p.fileName, bytes);
    } catch (e) {
      if (isDiskFull(e)) throw _DiskFull();
      rethrow;
    }
    _later.remove(p.fileName);
    await records.setFileId(name, ids.first);
    await _markUsed();
    return _Got.arrived;
  }

  /// The picture is not in Drive (yet): the other device has not sent it. It
  /// is looked for again after a while, longer each time.
  _Got _notThereYet(PhotoRef p) {
    _tryLater(p.fileName);
    return _Got.notThere;
  }

  /// Whether the picture is to be left alone at [at]: it was put off, and the
  /// time has not come.
  bool _early(String fileName, DateTime at) {
    final wait = _later[fileName];
    return wait != null && at.isBefore(wait.until);
  }

  /// Puts the picture off: [firstMissingWait], doubled with each try, at most
  /// [longestMissingWait]. A picture that keeps failing is thus tried less and
  /// less often, and never in every run.
  void _tryLater(String fileName) {
    final tries = (_later[fileName]?.tries ?? 0) + 1;
    // (the doubling is held down: a picture that never comes must not run it
    // over)
    final seconds = firstMissingWait.inSeconds << math.min(tries - 1, 12);
    final wait = Duration(
      seconds: math.min(seconds, longestMissingWait.inSeconds),
    );
    _later[fileName] = (until: now().add(wait), tries: tries);
  }

  // ------------------------------------------------------------- the tidy

  /// Once a day: what Drive holds of the pictures is looked through. A picture
  /// this device thinks it sent that is no longer there is forgotten (and sent
  /// again), and a picture in Drive that no record refers to, and that was made
  /// more than [remoteGrace] ago, is removed. Only a device that took part in
  /// the pictures does it, and only when its records are those of Drive.
  /// Returns how many pictures were removed.
  ///
  /// Removing a file is what cannot be taken back, so it is the careful part: a
  /// picture is "referred to" by any record of the diary that is not deleted,
  /// also one this version cannot show as an entry (a damaged one, a newer
  /// one). Only what no such record names at all can go.
  Future<int> _tidy(List<PhotoRef> wanted, Iterable<SyncRecord> journal) async {
    if (await records.meta(usedKey) == null) return 0;
    if (await records.meta(driveTokenKey) == null) return 0;
    final at = now();
    final day = at.toUtc().toIso8601String().substring(0, 10);
    if (await records.meta(tidyDayKey) == day) return 0;

    final listed = <String, DriveName>{
      for (final n in await remote.listNames(photoDrivePrefix))
        if (photoDriveNamePattern.hasMatch(n.name)) n.name: n,
    };

    // what this device believes is in Drive, against what is
    for (final p in wanted) {
      final known = await records.fileId(p.driveName!);
      if (known != null && listed[p.driveName]?.id != known) {
        await records.forgetFile(known); // (sent again by the next run)
      }
    }

    // what nobody refers to any more, and is old
    final referred = <String>{
      for (final r in journal)
        if (!r.deleted)
          for (final p in decodePhotos(r['photos']))
            if (p.syncable) p.driveName!,
    };
    final old = [
      for (final n in listed.values)
        if (!referred.contains(n.name) &&
            n.created != null &&
            at.difference(n.created!) >= remoteGrace)
          n,
    ];
    var cleaned = 0;
    if (old.length > 10 && old.length * 2 > listed.length) {
      // (more than half of Drive, gone at once: the records of this device are
      // not to be believed. Nothing is touched)
      log?.infoOnce('photo.tidy_skipped', 'drive', 'photo.tidy_skipped');
    } else {
      for (final n in old) {
        if (_stop()) return cleaned;
        try {
          await remote.delete(n.id);
        } on DriveTransientError {
          rethrow;
        } catch (e, st) {
          log?.error('drive', 'photo.tidy_failed', _Failed('delete'), st);
          continue; // (the next day tries again)
        }
        await records.forgetFile(n.id);
        cleaned++;
      }
    }
    await records.setMeta(tidyDayKey, day);
    return cleaned;
  }
}

/// Whether what Google said (the reason, or the text the Drive adapter made of
/// it) is that the Drive of the user is full.
bool _isQuotaMessage(String text) =>
    text.toLowerCase().contains('storagequotaexceeded');

/// A JPEG begins with these bytes. (What the other devices send is a picture of
/// ours; a file of Drive that is not one is no picture of the diary.)
bool _isJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

enum _Went { sent, already, given }

enum _Got { arrived, notThere, given }

/// The device has no room for the picture.
class _DiskFull implements Exception {}

/// What the log is told of a failure: a code, and nothing the system said (the
/// text of a file error carries the name and the folder of the file).
class _Failed implements Exception {
  _Failed(this.code);
  final String code;

  @override
  String toString() => code;
}

/// The `meta` key of the switch "Képek szinkronja" of this device: it holds
/// "off" when the pictures are not to travel; anything else (nothing, as it is
/// on from the start) is on.
const photoSyncKey = 'photoSync';

/// Whether the pictures travel from and to this device.
Future<bool> photoSyncEnabled(RecordRepository records) async =>
    await records.meta(photoSyncKey) != 'off';

/// How many pictures one run sends up, and how many it fetches: a handful, so
/// that a phone on mobile data is not kept busy for long and the other
/// channels are not kept waiting.
const photoSyncPerRun = 6;

/// The most bytes one picture may have to be sent or fetched (a picture of the
/// diary is a few hundred kilobytes: this is far above, and below what a single
/// upload of Drive takes).
const photoSyncMaxBytes = 3 * 1024 * 1024;

/// How old a picture in Drive that no entry refers to must be to be removed:
/// the entry that refers to it may not have reached this device yet.
const photoRemoteGrace = Duration(days: 7);

/// What one run of the picture sync did.
class PhotoSyncReport {
  const PhotoSyncReport({
    this.uploaded = 0,
    this.downloaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.waiting = 0,
    this.cleaned = 0,
    this.more = false,
    this.quotaFull = false,
    this.diskFull = false,
    this.arrived = const [],
    this.stoppedEarly = false,
    this.hint,
  });

  /// Pictures sent up, and fetched, in this run.
  final int uploaded, downloaded;

  /// Pictures given up on (too big, not a JPEG).
  final int skipped;

  /// Pictures that went wrong in this run (each is tried again later).
  final int failed;

  /// Pictures still to send or fetch (also those that wait for the other
  /// device to send them).
  final int waiting;

  /// Pictures taken out of Drive by the daily tidying.
  final int cleaned;

  /// There is more to do than one run does: the next should come soon.
  final bool more;

  /// Drive has no room: nothing is sent until it has.
  final bool quotaFull;

  /// This device has no room: nothing is fetched until it has.
  final bool diskFull;

  /// The files that came in (`<id>.jpg`): the screens that show them are told.
  final List<String> arrived;

  /// The run was cut short by a failure of the moment (network, a limit).
  final bool stoppedEarly;
  final RetryHint? hint;

  /// Whether the run moved a picture.
  bool get busy => uploaded > 0 || downloaded > 0;

  @override
  String toString() =>
      'PhotoSyncReport(up:$uploaded down:$downloaded skipped:$skipped '
      'failed:$failed waiting:$waiting cleaned:$cleaned more:$more '
      'quota:$quotaFull disk:$diskFull early:$stoppedEarly)';
}
