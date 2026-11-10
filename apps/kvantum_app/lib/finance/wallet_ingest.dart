import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../data/finance_repository.dart';
import 'wallet_bridge.dart';

const _autoKey = 'fin.walletAuto';
const _logKey = 'fin.walletLog';
const _maxLog = 20;

class WalletImport {
  const WalletImport({this.booked = 0, this.ignored = 0, this.foreign = 0});
  final int booked;
  final int ignored;
  final int foreign;
  int get seen => booked + ignored + foreign;
}

/// One line of the diagnostic log (already masked).
class WalletLogEntry {
  const WalletLogEntry({
    required this.timeMs,
    required this.title,
    required this.text,
    required this.result,
    this.amount,
    this.merchant = '',
  });
  final int timeMs;
  final String title;
  final String text;

  /// booked | ignored | foreign | duplicate
  final String result;
  final int? amount;
  final String merchant;

  Map<String, Object?> toJson() => {
    't': timeMs,
    'title': title,
    'text': text,
    'r': result,
    'a': amount,
    'm': merchant,
  };

  static WalletLogEntry? fromJson(Object? j) {
    if (j is! Map || j['t'] is! num) return null;
    return WalletLogEntry(
      timeMs: (j['t'] as num).toInt(),
      title: '${j['title'] ?? ''}',
      text: '${j['text'] ?? ''}',
      result: '${j['r'] ?? ''}',
      amount: j['a'] is num ? (j['a'] as num).toInt() : null,
      merchant: '${j['m'] ?? ''}',
    );
  }
}

/// Turns captured Wallet notifications into transactions: automatically, with
/// the category the user gave the same merchant before. Nothing is booked for
/// notifications without a forint amount, and the same notification is never
/// booked twice (its id comes from its time and text).
class WalletIngest {
  WalletIngest(this.repo, this.bridge);
  final FinanceRepository repo;
  final WalletBridge bridge;

  Future<bool> get auto async => (await repo.meta(_autoKey)) != 'off';
  Future<void> setAuto(bool on) => repo.setMeta(_autoKey, on ? null : 'off');

  Future<List<WalletLogEntry>> log() async {
    final text = await repo.meta(_logKey);
    if (text == null) return const [];
    try {
      final j = jsonDecode(text);
      return [
        if (j is List)
          for (final e in j) ?WalletLogEntry.fromJson(e),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> _appendLog(List<WalletLogEntry> add) async {
    if (add.isEmpty) return;
    final all = [...await log(), ...add];
    final keep = all.length > _maxLog ? all.sublist(all.length - _maxLog) : all;
    await repo.setMeta(_logKey, jsonEncode([for (final e in keep) e.toJson()]));
  }

  static String idFor(WalletNotification n) {
    final h = sha1.convert(utf8.encode('${n.timeMs}|${n.title}|${n.text}'));
    return 'wal-${h.toString().substring(0, 16)}';
  }

  /// Collects what the listener queued and books it. Safe to call often.
  Future<WalletImport> run() async {
    if (!bridge.supported) return const WalletImport();
    if (!await auto) {
      // switched off: the raw notification text must not pile up on the phone
      await bridge.clear();
      return const WalletImport();
    }
    final items = await bridge.drain();
    if (items.isEmpty) return const WalletImport();
    var booked = 0, ignored = 0, foreign = 0;
    final log = <WalletLogEntry>[];
    for (final n in items) {
      final title = maskSensitive(n.title);
      final text = maskSensitive(n.text);
      final r = parseWalletNotification(title: n.title, text: n.text);
      switch (r.outcome) {
        case WalletOutcome.ignored:
          ignored++;
          log.add(
            WalletLogEntry(
              timeMs: n.timeMs,
              title: title,
              text: text,
              result: 'ignored',
            ),
          );
        case WalletOutcome.foreignCurrency:
          foreign++;
          log.add(
            WalletLogEntry(
              timeMs: n.timeMs,
              title: title,
              text: text,
              result: 'foreign',
            ),
          );
        case WalletOutcome.payment:
          final id = WalletIngest.idFor(n);
          if (await repo.hasTx(id)) {
            log.add(
              WalletLogEntry(
                timeMs: n.timeMs,
                title: title,
                text: text,
                result: 'duplicate',
              ),
            );
            continue;
          }
          final when = DateTime.fromMillisecondsSinceEpoch(n.timeMs);
          final cat = await repo.merchantCategory(r.merchant);
          await repo.saveTx(
            FinTx(
              id: id,
              date: DateTime.utc(when.year, when.month, when.day),
              amount: r.amount!,
              kind: r.kind ?? FinKind.expense,
              categoryId: cat ?? kUncategorized,
              merchant: r.merchant,
              source: FinSource.wallet,
            ),
          );
          booked++;
          log.add(
            WalletLogEntry(
              timeMs: n.timeMs,
              title: title,
              text: text,
              result: 'booked',
              amount: r.amount,
              merchant: r.merchant,
            ),
          );
      }
    }
    await _appendLog(log);
    // only now is the queue forgotten: a crash above leaves it for the next run
    await bridge.ack();
    return WalletImport(booked: booked, ignored: ignored, foreign: foreign);
  }
}
