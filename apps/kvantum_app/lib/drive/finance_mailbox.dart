import 'dart:async';
import 'dart:convert';

import '../data/finance_repository.dart';
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

  @override
  String toString() =>
      'MailReport(sent:$sentLetters received:$receivedLetters applied:$applied corrupt:$corrupt expired:$expired peers:$peers early:$stoppedEarly)';
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
  }) : _clock = clock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final FinanceRepository repo;
  final DriveRemote drive;
  final String deviceId;
  final int Function() _clock;

  static const peerPrefix = 'fin-peer-';
  static const letterPrefix = 'fin-letter-';
  static const maxPerLetter = 400;
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

  Future<MailReport> sync() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  Future<MailReport> _run() async {
    var sent = 0, received = 0, applied = 0, corrupt = 0, expired = 0;
    var peerCount = 0;
    try {
      await _announce();

      // ------------------------------------------------------ receive
      final letters = await drive.listNames(letterPrefix);
      for (final l in letters) {
        final m = _letterName.firstMatch(l.name);
        if (m == null || m[2] != deviceId) continue;
        final text = await drive.read(l.id);
        if (text == null) continue; // already gone
        final records = _records(text);
        if (records == null) {
          corrupt++;
          await drive.delete(l.id);
          continue;
        }
        for (final r in records) {
          if (r is Map && await repo.applyIncoming('${r['kind']}', r['data'])) {
            applied++;
          }
        }
        await drive.delete(l.id); // "it has arrived"
        received++;
      }

      // --------------------------------------------------------- send
      final peers = await _activePeers();
      peerCount = peers.length;
      final known = await _known();
      final changed = await repo.mailRecords(onlyDirty: true);
      List<MailRecord>? everything;
      var allDelivered = false;
      try {
        for (final p in peers) {
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
        }
        allDelivered = true;
      } finally {
        await _saveKnown(known);
        if (allDelivered && peers.isNotEmpty && changed.isNotEmpty) {
          await repo.markClean(changed);
        }
      }

      // ------------------------------------------------ housekeeping
      expired = await _expireOldLetters(letters, known);
      await _saveKnown(known);
    } on DriveTransientError {
      return MailReport(
        sentLetters: sent,
        receivedLetters: received,
        applied: applied,
        corrupt: corrupt,
        expired: expired,
        peers: peerCount,
        stoppedEarly: true,
      );
    }
    return MailReport(
      sentLetters: sent,
      receivedLetters: received,
      applied: applied,
      corrupt: corrupt,
      expired: expired,
      peers: peerCount,
    );
  }

  List<Object?>? _records(String text) {
    try {
      final j = jsonDecode(text);
      final r = j is Map ? j['records'] : null;
      return r is List ? r : null;
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
      final text = await drive.read(f.id);
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
          'v': 1,
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
  Future<int> _expireOldLetters(
    List<DriveName> listed,
    Set<String> known,
  ) async {
    final now = _clock();
    var n = 0;
    for (final l in listed) {
      final m = _letterName.firstMatch(l.name);
      if (m == null || m[1] != deviceId) continue;
      final sent = int.tryParse(m[3]!) ?? now;
      if (now - sent < letterTtl.inMilliseconds) continue;
      await drive.delete(l.id);
      known.remove(m[2]);
      n++;
    }
    return n;
  }
}
