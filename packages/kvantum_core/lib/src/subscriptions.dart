/// Subscriptions found in the money log: the same merchant, about the same
/// amount, about every month (or every year).
///
/// This is a reading of what happened, not a promise: a charge that stopped
/// is not listed any more, a merchant whose amount jumps around (a utility
/// bill) or whose visits are not regular (a shop) is not a subscription.
library;

import 'finance.dart';
import 'text_safety.dart';
import 'time.dart';

enum SubscriptionCadence { monthly, yearly }

/// The key two spellings of one merchant share: lower case, no accents, only
/// letters and digits, and without the words that look like a number (a
/// reference or a card id on the statement line changes with every charge).
/// Empty when nothing is left.
String subscriptionKey(String merchant) {
  final words = foldHu(merchant)
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .split(' ')
      .where((w) => w.length > 1 && !RegExp(r'\d').hasMatch(w));
  return words.join(' ');
}

/// One subscription.
class Subscription {
  const Subscription({
    required this.key,
    required this.name,
    required this.amount,
    required this.cadence,
    required this.lastDate,
    required this.nextDate,
    required this.count,
    required this.categoryId,
  });

  /// [subscriptionKey] of the merchant.
  final String key;

  /// The merchant as the latest charge names it.
  final String name;

  /// The latest charge.
  final int amount;
  final SubscriptionCadence cadence;
  final DateTime lastDate;

  /// When the next charge is due, if it goes on.
  final DateTime nextDate;

  /// How many charges it is read from.
  final int count;
  final String categoryId;

  /// What it costs in a month.
  int get perMonth =>
      cadence == SubscriptionCadence.yearly ? (amount / 12).round() : amount;

  /// What it costs in a year.
  int get perYear =>
      cadence == SubscriptionCadence.yearly ? amount : amount * 12;
}

// The gap between two monthly charges, in days: a month is 28 - 31 days and
// a charge can slide a few days over a weekend or a holiday.
const _monthlyGap = (24, 38);
const _yearlyGap = (350, 380);

// The dearest charge may be this much more than the cheapest (a price rise is
// a subscription, a bill that doubles is not).
const _amountSpread = 1.25;

// A charge is overdue after this many days; a subscription that has not been
// charged for so long has stopped.
const _monthlyAlive = 45;
const _yearlyAlive = 400;

DateTime _plusMonths(DateTime d, int months) {
  final m = d.year * 12 + d.month - 1 + months;
  final y = m ~/ 12, mo = m % 12 + 1;
  final days = DateTime.utc(y, mo + 1, 0).day;
  return floating(y, mo, d.day > days ? days : d.day);
}

/// The subscriptions in [txs] that are still going on at [today], dearest per
/// month first. Transactions made by a recurring rule are not read (they are
/// known already), and neither are merchants whose key is in [known] (for
/// instance the titles of the rules that exist).
///
/// A monthly subscription needs three charges, each 24 - 38 days after the
/// one before; a yearly one two charges 350 - 380 days apart; the amounts of
/// the charges may differ by a quarter at most.
List<Subscription> detectSubscriptions(
  Iterable<FinTx> txs, {
  required DateTime today,
  Set<String> known = const {},
}) {
  final byKey = <String, List<FinTx>>{};
  for (final t in txs) {
    if (t.deleted ||
        t.kind != FinKind.expense ||
        t.source == FinSource.recurring) {
      continue;
    }
    final key = subscriptionKey(t.merchant);
    if (key.isEmpty || known.contains(key)) continue;
    byKey.putIfAbsent(key, () => []).add(t);
  }

  final day = DateTime.utc(today.year, today.month, today.day);
  final out = <Subscription>[];
  for (final e in byKey.entries) {
    // (two charges of one day have a gap of 0: such a merchant is no
    // subscription, whichever of them comes first)
    final list = e.value..sort((a, b) => a.date.compareTo(b.date));
    if (list.length < 2) continue;
    var low = list.first.amount, high = list.first.amount;
    final gaps = <int>[];
    for (var i = 0; i < list.length; i++) {
      final a = list[i].amount;
      if (a < low) low = a;
      if (a > high) high = a;
      if (i > 0) gaps.add(list[i].date.difference(list[i - 1].date).inDays);
    }
    if (high > low * _amountSpread) continue;

    bool within((int, int) range) =>
        gaps.every((g) => g >= range.$1 && g <= range.$2);
    final SubscriptionCadence cadence;
    if (list.length >= 3 && within(_monthlyGap)) {
      cadence = SubscriptionCadence.monthly;
    } else if (within(_yearlyGap)) {
      cadence = SubscriptionCadence.yearly;
    } else {
      continue;
    }
    final last = list.last;
    final age = day.difference(last.date).inDays;
    final alive = cadence == SubscriptionCadence.monthly
        ? _monthlyAlive
        : _yearlyAlive;
    if (age > alive) continue;
    out.add(
      Subscription(
        key: e.key,
        name: last.merchant,
        amount: last.amount,
        cadence: cadence,
        lastDate: last.date,
        nextDate: _plusMonths(
          last.date,
          cadence == SubscriptionCadence.monthly ? 1 : 12,
        ),
        count: list.length,
        categoryId: last.categoryId,
      ),
    );
  }
  out.sort((a, b) {
    final c = b.perMonth.compareTo(a.perMonth);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out;
}
