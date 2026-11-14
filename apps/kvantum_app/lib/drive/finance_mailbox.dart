import 'dart:async';
import 'dart:convert';

import '../data/finance_repository.dart';
import '../diag/diag_log.dart';
import '../sync/api_errors.dart' show RetryHint;
import 'drive_remote.dart';

/// What one mail run did.
class MailReport {
  const MailReport({
    this.sentLetters = 0,
    this.receivedLetters = 0,
    this.applied = 0,
    this.corrupt = 0,
    this.expired = 0,
    this.peers = 0,
    this.stoppedEarly = false,
    this.newerLetters = 0,
    this.failed = 0,
    this.hint,
  });
  final int sentLetters;
  final int receivedLetters;

  /// Records that changed this device's data.
  final int applied;
  final int corrupt;

  /// Undelivered letters that were removed because they were too old.
  final int expired;
  final int peers;
  final bool stoppedEarly;

  /// Letters from a newer version of the app (or with records of kinds this
  /// version does not know): kept in Drive, not deleted.
  final int newerLetters;

  /// Letters, peers and notes this run could not handle because of an error
  /// that is not a passing one (a refused write, a letter that cannot be
  /// applied). Everything else was done: one failure does not stop the rest,
  /// and what failed stays where it was, to be tried again.
  final int failed;

  /// Why the run stopped early (when it did).
  final RetryHint? hint;

  @override
  String toString() =>
      'MailReport(sent:$sentLetters received:$receivedLetters applied:$applied corrupt:$corrupt expired:$expired peers:$peers failed:$failed early:$stoppedEarly)';
}

/// Finance sync "by post": each device keeps its data in its own database and
/// puts only CHANGES into addressed letters in Drive's hidden app folder. The
/// receiving device merges a letter and then deletes it ("it has arrived"), so
/// Drive holds nothing but undelivered mail.
///
///  * `fin-peer-<device>.json`  - "I exist" note (who to write to)
///  * `fin-letter-<from>-to-<to>-<ms>-<n>.json` - the changed records
///
/// A device that is new to a sender gets one letter with EVERYTHING (that is
/// how a second device receives the history). Merging is last-write-wins per
/// record, so letters can be applied twice or in any order.
class FinanceMailbox {
  FinanceMailbox(
    this.repo,
    this.drive, {
    required this.deviceId,
    int Function()? clock,
    this._log,
  }) : _clock = clock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final FinanceRepository repo;
  final DriveRemote drive;
  final String deviceId;
  final int Function() _clock;
  final DiagLog? _log;

  static const peerPrefix = 'fin-peer-';
  static const letterPrefix = 'fin-letter-';
  static const maxPerLetter = 400;

  /// A letter that fails this many runs (in this run of the app) is left alone
  /// until the app is started anew: it would only fill the log.
  static const maxLetterTries = 3;

  /// The letter format this build writes and reads.
  static const letterVersion = 1;
  static const announceEvery = Duration(hours: 12);
  static const peerGone = Duration(days: 180);
  static const letterTtl = Duration(days: 60);

  static const _knownKey = 'fin.known';
  static const _announcedKey = 'fin.announced';

  static final _letterName = RegExp(
    r'^fin-letter-([0-9a-zA-Z]+)-to-([0-9a-zA-Z]+)-(\d+)-(\d+)\.json$',
  );
  static final _peerName = RegExp(r'^fin-peer-([0-9a-zA-Z]+)\.json$');

  Future<MailReport>? _running;

  /// Letters (Drive file ids) left alone because a newer version wrote them:
  /// not read again until the app is started anew.
  final _leftAlone = <String>{};

  /// Letter id -> how many runs failed on it (see [maxLetterTries]).
  final _failedLetters = <String, int>{};

  Future<MailReport> sync() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  /// "Start the mail over": forget who has been greeted, so the next run
  /// sends every other device the whole snapshot (merging makes that safe)
  /// and announces this device again.
  Future<void> resetPeers() async {
    await repo.setMeta(_knownKey, null);
    await repo.setMeta(_announcedKey, null);
  }

  Future<MailReport> _run() async {
    var sent = 0, received = 0, applied = 0, corrupt = 0, expired = 0;
    var peerCount = 0, newerLetters = 0, failed = 0;
    try {
      await _announce();

      // ------------------------------------------------------ receive
      final letters = await drive.listNames(letterPrefix);
      for (final l in letters) {
        final m = _letterName.firstMatch(l.name);
        if (m == null || m[2] != deviceId) continue;
        if (_leftAlone.contains(l.id)) {
          newerLetters++;
          continue;
        }
        if ((_failedLetters[l.id] ?? 0) >= maxLetterTries) {
          failed++; // still there and still unusable: not tried again now
          continue;
        }
        try {
          final text = await drive.read(l.id);
          if (text == null) continue; // already gone
          final letter = _letter(text);
          if (letter == null) {
            corrupt++;
            _log?.info('mail', 'letter.corrupt');
            await drive.delete(l.id);
            continue;
          }
          if (letter.newer) {
            // A newer version of the app wrote it: it stays in Drive until this
            // version is updated and can read it.
            _leftAlone.add(l.id);
            newerLetters++;
            _log?.infoOnce('letter.newer:${l.id}', 'mail', 'letter.newer');
            continue;
          }
          applied += await repo.applyIncomingAll([
            for (final r in letter.records)
              if (r is Map) ('${r['kind']}', r['data']),
          ]);
          final unknownKind = letter.records.any(
            (r) => r is Map && !repo.knowsKind('${r['kind']}'),
          );
          if (unknownKind) {
            // what is understood has been applied (applying it again later is
            // harmless); the letter stays for the version that knows the rest
            _leftAlone.add(l.id);
            newerLetters++;
            _log?.infoOnce(
              'letter.unknown:${l.id}',
              'mail',
              'letter.unknown_kind',
            );
            continue;
          }
          await drive.delete(l.id); // "it has arrived"
          received++;
        } on DriveTransientError {
          rethrow;
        } on DriveTokenExpired {
          rethrow;
        } catch (e, st) {
          // One letter that cannot be handled must not stop the other letters
          // nor the sending below: it stays in Drive and is tried again, a few
          // times (a letter is applied as a whole or not at all).
          failed++;
          final tries = _failedLetters[l.id] = (_failedLetters[l.id] ?? 0) + 1;
          _log?.error('mail', 'letter.failed', e, st, {'tries': tries});
        }
      }

      // --------------------------------------------------------- send
      final peers = await _activePeers();
      peerCount = peers.length;
      final known = await _known();
      // A device that has been silent long enough to count as gone missed
      // everything sent to the others meanwhile. Forget it, so that it is
      // greeted with the whole snapshot when it shows up again.
      known.removeWhere((id) => !peers.contains(id));
      final changed = await repo.mailRecords(onlyDirty: true);
      List<MailRecord>? everything;
      var allDelivered = false;
      var peersFailed = 0;
      try {
        for (final p in peers) {
          try {
            final List<MailRecord> payload;
            if (!known.contains(p)) {
              payload = everything ??= await repo.mailRecords(onlyDirty: false);
            } else if (changed.isNotEmpty) {
              payload = changed;
            } else {
              continue;
            }
            if (payload.isEmpty) {
              known.add(p);
              continue;
            }
            sent += await _post(p, payload);
            known.add(p);
          } on DriveTransientError {
            rethrow;
          } on DriveTokenExpired {
            rethrow;
          } catch (e, st) {
            // One peer that cannot be written to must not keep the others from
            // their mail. Its status stays as it was (a peer not greeted yet
            // is greeted with everything next time) and what is dirty stays
            // dirty, so the next run sends it again.
            peersFailed++;
            failed++;
            _log?.error('mail', 'peer.failed', e, st);
          }
        }
        allDelivered = peersFailed == 0;
      } finally {
        await _saveKnown(known);
        if (allDelivered && peers.isNotEmpty && changed.isNotEmpty) {
          await repo.markClean(changed);
        }
      }

      // ------------------------------------------------ housekeeping
      final old = await _expireOldLetters(letters, known);
      expired = old.expired;
      failed += old.failed;
      await _saveKnown(known);
    } on DriveTransientError catch (e) {
      return MailReport(
        sentLetters: sent,
        receivedLetters: received,
        applied: applied,
        corrupt: corrupt,
        expired: expired,
        peers: peerCount,
        stoppedEarly: true,
        newerLetters: newerLetters,
        failed: failed,
        hint: e,
      );
    }
    return MailReport(
      sentLetters: sent,
      receivedLetters: received,
      applied: applied,
      corrupt: corrupt,
      expired: expired,
      peers: peerCount,
      newerLetters: newerLetters,
      failed: failed,
    );
  }

  /// null: not a letter at all. A letter of a newer format is reported as such
  /// without looking at its records (their shape may have changed).
  ({List<Object?> records, bool newer})? _letter(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      final v = j['v'];
      if (v is num && v > letterVersion) {
        return (records: const [], newer: true);
      }
      final r = j['records'];
      return r is List ? (records: r, newer: false) : null;
    } on FormatException {
      return null;
    }
  }

  // ------------------------------------------------------------ peers

  Future<void> _announce() async {
    final now = _clock();
    final last = int.tryParse(await repo.meta(_announcedKey) ?? '');
    if (last != null && now - last < announceEvery.inMilliseconds) return;
    final name = '$peerPrefix$deviceId.json';
    final existing = await drive.findByName(name);
    await drive.write(
      fileId: existing.isEmpty ? null : existing.first,
      name: name,
      content: jsonEncode({'v': 1, 'device': deviceId, 'seen': now}),
    );
    await repo.setMeta(_announcedKey, '$now');
  }

  /// Other devices that have shown a sign of life recently.
  Future<List<String>> _activePeers() async {
    final now = _clock();
    final out = <String>[];
    for (final f in await drive.listNames(peerPrefix)) {
      final m = _peerName.firstMatch(f.name);
      if (m == null || m[1] == deviceId) continue;
      String? text;
      try {
        text = await drive.read(f.id);
      } on DriveTransientError {
        rethrow;
      } on DriveTokenExpired {
        rethrow;
      } catch (e, st) {
        // a note that cannot be read is taken like one that cannot be parsed
        _log?.error('mail', 'peer.note_failed', e, st);
      }
      var seen = now; // unreadable note: assume alive
      try {
        final j = text == null ? null : jsonDecode(text);
        final s = j is Map ? j['seen'] : null;
        if (s is num) seen = s.toInt();
      } on FormatException {
        // keep the assumption
      }
      if (now - seen < peerGone.inMilliseconds) out.add(m[1]!);
    }
    return out;
  }

  Future<Set<String>> _known() async => {
    for (final s in (await repo.meta(_knownKey) ?? '').split(','))
      if (s.isNotEmpty) s,
  };

  Future<void> _saveKnown(Set<String> known) => repo.setMeta(
    _knownKey,
    known.isEmpty ? null : (known.toList()..sort()).join(','),
  );

  // ---------------------------------------------------------- sending

  /// Writes the records to [peer] in letters of at most [maxPerLetter];
  /// returns how many letters were written.
  Future<int> _post(String peer, List<MailRecord> records) async {
    var letters = 0;
    final ts = _clock();
    for (var i = 0; i < records.length; i += maxPerLetter) {
      final chunk = records.sublist(
        i,
        i + maxPerLetter > records.length ? records.length : i + maxPerLetter,
      );
      await drive.write(
        name: '$letterPrefix$deviceId-to-$peer-$ts-${i ~/ maxPerLetter}.json',
        content: jsonEncode({
          'v': letterVersion,
          'from': deviceId,
          'to': peer,
          'sent': ts,
          'records': [for (final r in chunk) r.toJson()],
        }),
      );
      letters++;
    }
    return letters;
  }

  /// Own letters nobody collected for [letterTtl] are removed; that peer then
  /// counts as new again and gets a full letter when it comes back.
  Future<({int expired, int failed})> _expireOldLetters(
    List<DriveName> listed,
    Set<String> known,
  ) async {
    final now = _clock();
    var n = 0, failed = 0;
    for (final l in listed) {
      final m = _letterName.firstMatch(l.name);
      if (m == null || m[1] != deviceId) continue;
      final sent = int.tryParse(m[3]!) ?? now;
      if (now - sent < letterTtl.inMilliseconds) continue;
      try {
        await drive.delete(l.id);
      } on DriveTransientError {
        rethrow;
      } on DriveTokenExpired {
        rethrow;
      } catch (e, st) {
        // it stays (and so does its peer's status); the next run tries again
        failed++;
        _log?.error('mail', 'expire.failed', e, st);
        continue;
      }
      known.remove(m[2]);
      n++;
    }
    return (expired: n, failed: failed);
  }
}
