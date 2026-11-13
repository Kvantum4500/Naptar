import 'finance_currency.dart';
import 'time.dart';

/// Personal finance model: transactions, categories, budgets, recurring
/// items and savings goals. Amounts are whole forints (HUF has no minor
/// unit in practice) and are always stored positive; [FinKind] gives the sign.
enum FinKind { income, expense }

enum FinSource { manual, wallet, recurring }

const kUncategorized = 'cat-uncategorized';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parseYmd(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v);
  if (m == null) return null;
  final mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return floating(int.parse(m[1]!), mo, d);
}

int? _amount(Object? v) {
  if (v is! num || !v.isFinite) return null;
  final n = v.round();
  return n > 0 && n <= 100000000000 ? n : null;
}

String _s(Object? v, int max) {
  final t = (v is String ? v : '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > max ? t.substring(0, max) : t;
}

int _int(Object? v) => v is num && v.isFinite ? v.round() : 0;

FinKind _kind(Object? v) => v == 'income' ? FinKind.income : FinKind.expense;

// -------------------------------------------------------------------- types

class FinTx {
  const FinTx({
    required this.id,
    required this.date,
    required this.amount,
    required this.kind,
    this.categoryId = kUncategorized,
    this.merchant = '',
    this.note = '',
    this.source = FinSource.manual,
    this.updatedAt = 0,
    this.deleted = false,
    this.foreign,
  });

  final String id;

  /// Floating date (y/m/d, UTC-flagged).
  final DateTime date;

  /// Whole forints. For a transaction paid in another currency it is what that
  /// was worth ([foreign] has the rest), so every sum goes on counting in
  /// forints.
  final int amount;
  final FinKind kind;
  final String categoryId;
  final String merchant;
  final String note;
  final FinSource source;
  final int updatedAt;
  final bool deleted;

  /// What it was paid in, when that was not forints.
  final FinForeign? foreign;

  /// Signed amount: income positive, expense negative.
  int get signed => kind == FinKind.income ? amount : -amount;

  FinTx copyWith({
    DateTime? date,
    int? amount,
    FinKind? kind,
    String? categoryId,
    String? merchant,
    String? note,
    int? updatedAt,
    bool? deleted,
    FinForeign? foreign,
    bool clearForeign = false,
  }) => FinTx(
    id: id,
    date: date ?? this.date,
    amount: amount ?? this.amount,
    kind: kind ?? this.kind,
    categoryId: categoryId ?? this.categoryId,
    merchant: merchant ?? this.merchant,
    note: note ?? this.note,
    source: source,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
    foreign: clearForeign ? null : foreign ?? this.foreign,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'date': _ymd(date),
    'amount': amount,
    'kind': kind.name,
    'cat': categoryId,
    'merchant': merchant,
    'note': note,
    'src': source.name,
    'upd': updatedAt,
    'del': deleted,
    if (foreign case final f?) 'fx': f.toJson(),
  };

  /// Null when the record is unusable (no id, date or a positive amount).
  static FinTx? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 100);
    final date = _parseYmd(j['date']);
    final amount = _amount(j['amount']);
    if (id.isEmpty || date == null || amount == null) return null;
    return FinTx(
      id: id,
      date: date,
      amount: amount,
      kind: _kind(j['kind']),
      categoryId: _s(j['cat'], 100).isEmpty
          ? kUncategorized
          : _s(j['cat'], 100),
      merchant: _s(j['merchant'], 80),
      note: _s(j['note'], 200),
      source: FinSource.values.firstWhere(
        (s) => s.name == j['src'],
        orElse: () => FinSource.manual,
      ),
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
      foreign: FinForeign.fromJson(j['fx']),
    );
  }
}

class FinCategory {
  const FinCategory({
    required this.id,
    required this.name,
    required this.kind,
    this.updatedAt = 0,
    this.deleted = false,
  });
  final String id;
  final String name;
  final FinKind kind;
  final int updatedAt;
  final bool deleted;

  FinCategory copyWith({String? name, int? updatedAt, bool? deleted}) =>
      FinCategory(
        id: id,
        name: name ?? this.name,
        kind: kind,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'upd': updatedAt,
    'del': deleted,
  };

  static FinCategory? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 100), name = _s(j['name'], 40);
    if (id.isEmpty || name.isEmpty) return null;
    return FinCategory(
      id: id,
      name: name,
      kind: _kind(j['kind']),
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
    );
  }
}

/// Monthly limit for one expense category (the record id is the category id).
class FinBudget {
  const FinBudget({
    required this.categoryId,
    required this.limit,
    this.updatedAt = 0,
    this.deleted = false,
  });
  final String categoryId;
  final int limit;
  final int updatedAt;
  final bool deleted;

  String get id => categoryId;

  FinBudget copyWith({int? limit, int? updatedAt, bool? deleted}) => FinBudget(
    categoryId: categoryId,
    limit: limit ?? this.limit,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toJson() => {
    'cat': categoryId,
    'limit': limit,
    'upd': updatedAt,
    'del': deleted,
  };

  static FinBudget? fromJson(Object? j) {
    if (j is! Map) return null;
    final cat = _s(j['cat'], 100);
    final limit = _amount(j['limit']);
    if (cat.isEmpty || limit == null) return null;
    return FinBudget(
      categoryId: cat,
      limit: limit,
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
    );
  }
}

/// A monthly repeating income or expense (salary, rent, subscriptions).
class FinRecurring {
  const FinRecurring({
    required this.id,
    required this.title,
    required this.amount,
    required this.kind,
    required this.categoryId,
    required this.dayOfMonth,
    required this.fromMonth,
    this.toMonth,
    this.active = true,
    this.updatedAt = 0,
    this.deleted = false,
  });
  final String id;
  final String title;
  final int amount;
  final FinKind kind;
  final String categoryId;

  /// 1..31; months shorter than that use their last day.
  final int dayOfMonth;

  /// First month the rule applies to, as the 1st of that month (floating).
  final DateTime fromMonth;
  final DateTime? toMonth;
  final bool active;
  final int updatedAt;
  final bool deleted;

  FinRecurring copyWith({
    String? title,
    int? amount,
    FinKind? kind,
    String? categoryId,
    int? dayOfMonth,
    DateTime? fromMonth,
    DateTime? toMonth,
    bool clearToMonth = false,
    bool? active,
    int? updatedAt,
    bool? deleted,
  }) => FinRecurring(
    id: id,
    title: title ?? this.title,
    amount: amount ?? this.amount,
    kind: kind ?? this.kind,
    categoryId: categoryId ?? this.categoryId,
    dayOfMonth: dayOfMonth ?? this.dayOfMonth,
    fromMonth: fromMonth ?? this.fromMonth,
    toMonth: clearToMonth ? null : (toMonth ?? this.toMonth),
    active: active ?? this.active,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'amount': amount,
    'kind': kind.name,
    'cat': categoryId,
    'day': dayOfMonth,
    'from': _ymd(fromMonth),
    'to': toMonth == null ? null : _ymd(toMonth!),
    'active': active,
    'upd': updatedAt,
    'del': deleted,
  };

  static FinRecurring? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 100), title = _s(j['title'], 60);
    final amount = _amount(j['amount']);
    final from = _parseYmd(j['from']);
    final day = _int(j['day']);
    if (id.isEmpty ||
        title.isEmpty ||
        amount == null ||
        from == null ||
        day < 1 ||
        day > 31) {
      return null;
    }
    return FinRecurring(
      id: id,
      title: title,
      amount: amount,
      kind: _kind(j['kind']),
      categoryId: _s(j['cat'], 100).isEmpty
          ? kUncategorized
          : _s(j['cat'], 100),
      dayOfMonth: day,
      fromMonth: floating(from.year, from.month, 1),
      toMonth: () {
        final t = _parseYmd(j['to']);
        return t == null ? null : floating(t.year, t.month, 1);
      }(),
      active: j['active'] != false,
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
    );
  }
}

class FinGoal {
  const FinGoal({
    required this.id,
    required this.name,
    required this.target,
    this.deadline,
    this.updatedAt = 0,
    this.deleted = false,
  });
  final String id;
  final String name;
  final int target;
  final DateTime? deadline;
  final int updatedAt;
  final bool deleted;

  FinGoal copyWith({
    String? name,
    int? target,
    DateTime? deadline,
    bool clearDeadline = false,
    int? updatedAt,
    bool? deleted,
  }) => FinGoal(
    id: id,
    name: name ?? this.name,
    target: target ?? this.target,
    deadline: clearDeadline ? null : (deadline ?? this.deadline),
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'target': target,
    'deadline': deadline == null ? null : _ymd(deadline!),
    'upd': updatedAt,
    'del': deleted,
  };

  static FinGoal? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 100), name = _s(j['name'], 60);
    final target = _amount(j['target']);
    if (id.isEmpty || name.isEmpty || target == null) return null;
    return FinGoal(
      id: id,
      name: name,
      target: target,
      deadline: _parseYmd(j['deadline']),
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
    );
  }
}

/// Money put aside for a goal.
class FinDeposit {
  const FinDeposit({
    required this.id,
    required this.goalId,
    required this.date,
    required this.amount,
    this.updatedAt = 0,
    this.deleted = false,
  });
  final String id;
  final String goalId;
  final DateTime date;
  final int amount;
  final int updatedAt;
  final bool deleted;

  FinDeposit copyWith({int? updatedAt, bool? deleted}) => FinDeposit(
    id: id,
    goalId: goalId,
    date: date,
    amount: amount,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'goal': goalId,
    'date': _ymd(date),
    'amount': amount,
    'upd': updatedAt,
    'del': deleted,
  };

  static FinDeposit? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 100), goal = _s(j['goal'], 100);
    final date = _parseYmd(j['date']);
    final amount = _amount(j['amount']);
    if (id.isEmpty || goal.isEmpty || date == null || amount == null) {
      return null;
    }
    return FinDeposit(
      id: id,
      goalId: goal,
      date: date,
      amount: amount,
      updatedAt: _int(j['upd']),
      deleted: j['del'] == true,
    );
  }
}

// ----------------------------------------------------------------- defaults

List<FinCategory> defaultCategories() => const [
  FinCategory(id: 'cat-food', name: 'Élelmiszer', kind: FinKind.expense),
  FinCategory(id: 'cat-utilities', name: 'Rezsi', kind: FinKind.expense),
  FinCategory(id: 'cat-housing', name: 'Lakás', kind: FinKind.expense),
  FinCategory(id: 'cat-transport', name: 'Közlekedés', kind: FinKind.expense),
  FinCategory(id: 'cat-health', name: 'Egészség', kind: FinKind.expense),
  FinCategory(id: 'cat-fun', name: 'Szórakozás', kind: FinKind.expense),
  FinCategory(id: 'cat-sport', name: 'Sport', kind: FinKind.expense),
  FinCategory(id: 'cat-clothes', name: 'Ruházat', kind: FinKind.expense),
  FinCategory(id: 'cat-subs', name: 'Előfizetések', kind: FinKind.expense),
  FinCategory(id: 'cat-other-exp', name: 'Egyéb kiadás', kind: FinKind.expense),
  FinCategory(id: 'cat-salary', name: 'Fizetés', kind: FinKind.income),
  FinCategory(id: 'cat-other-inc', name: 'Egyéb bevétel', kind: FinKind.income),
];

// --------------------------------------------------------------- summaries

class MonthSummary {
  const MonthSummary({
    required this.year,
    required this.month,
    required this.income,
    required this.expense,
    required this.expenseByCategory,
    required this.incomeByCategory,
  });
  final int year;
  final int month;
  final int income;
  final int expense;
  final Map<String, int> expenseByCategory;
  final Map<String, int> incomeByCategory;

  int get balance => income - expense;
}

/// Totals of one calendar month. Deleted transactions are ignored.
MonthSummary monthSummary(Iterable<FinTx> txs, int year, int month) {
  var income = 0, expense = 0;
  final eCat = <String, int>{}, iCat = <String, int>{};
  for (final t in txs) {
    if (t.deleted || t.date.year != year || t.date.month != month) continue;
    if (t.kind == FinKind.income) {
      income += t.amount;
      iCat[t.categoryId] = (iCat[t.categoryId] ?? 0) + t.amount;
    } else {
      expense += t.amount;
      eCat[t.categoryId] = (eCat[t.categoryId] ?? 0) + t.amount;
    }
  }
  return MonthSummary(
    year: year,
    month: month,
    income: income,
    expense: expense,
    expenseByCategory: eCat,
    incomeByCategory: iCat,
  );
}

enum BudgetLevel { ok, warn, over }

class BudgetStatus {
  const BudgetStatus({
    required this.categoryId,
    required this.limit,
    required this.spent,
  });
  final String categoryId;
  final int limit;
  final int spent;

  int get remaining => limit - spent;
  double get ratio => limit <= 0 ? 0 : spent / limit;
  BudgetLevel get level => spent > limit
      ? BudgetLevel.over
      : ratio >= 0.8
      ? BudgetLevel.warn
      : BudgetLevel.ok;
}

/// One status per active budget, in the order of [budgets].
List<BudgetStatus> budgetStatus(
  Iterable<FinBudget> budgets,
  MonthSummary summary,
) => [
  for (final b in budgets)
    if (!b.deleted)
      BudgetStatus(
        categoryId: b.categoryId,
        limit: b.limit,
        spent: summary.expenseByCategory[b.categoryId] ?? 0,
      ),
];

// -------------------------------------------------------------- recurring

String recurringTxId(String ruleId, int year, int month) =>
    'rec-$ruleId-$year${month.toString().padLeft(2, '0')}';

/// The transactions [rules] expect in the given month. Ids are derived from
/// the rule and the month, so generating twice - or on two devices - gives the
/// same records instead of duplicates.
List<FinTx> dueRecurring(Iterable<FinRecurring> rules, int year, int month) {
  final first = floating(year, month, 1);
  final days = DateTime.utc(year, month + 1, 0).day;
  final out = <FinTx>[];
  for (final r in rules) {
    if (r.deleted || !r.active) continue;
    if (first.isBefore(floating(r.fromMonth.year, r.fromMonth.month, 1))) {
      continue;
    }
    final to = r.toMonth;
    if (to != null && first.isAfter(floating(to.year, to.month, 1))) continue;
    out.add(
      FinTx(
        id: recurringTxId(r.id, year, month),
        date: floating(year, month, r.dayOfMonth > days ? days : r.dayOfMonth),
        amount: r.amount,
        kind: r.kind,
        categoryId: r.categoryId,
        merchant: r.title,
        source: FinSource.recurring,
        updatedAt: first.millisecondsSinceEpoch,
      ),
    );
  }
  return out;
}

// ------------------------------------------------------------------ goals

class GoalProgress {
  const GoalProgress({
    required this.saved,
    required this.target,
    required this.monthlyNeeded,
  });
  final int saved;
  final int target;

  /// What must be put aside per month to reach the goal by its deadline;
  /// null without a deadline or when the goal is reached.
  final int? monthlyNeeded;

  int get remaining => target > saved ? target - saved : 0;
  double get ratio => target <= 0 ? 0 : saved / target;
  bool get reached => saved >= target;
}

GoalProgress goalProgress(
  FinGoal goal,
  Iterable<FinDeposit> deposits,
  DateTime today,
) {
  var saved = 0;
  for (final d in deposits) {
    if (!d.deleted && d.goalId == goal.id) saved += d.amount;
  }
  final remaining = goal.target > saved ? goal.target - saved : 0;
  int? monthly;
  final dl = goal.deadline;
  if (dl != null && remaining > 0) {
    final months = ((dl.year - today.year) * 12 + dl.month - today.month).clamp(
      1,
      1200,
    );
    monthly = (remaining / months).ceil();
  }
  return GoalProgress(
    saved: saved,
    target: goal.target,
    monthlyNeeded: monthly,
  );
}

// ---------------------------------------------------------------- format

/// 3490 -> "3 490 Ft" (non-breaking spaces), negative with a minus sign.
String formatHuf(int amount) {
  final neg = amount < 0;
  final digits = amount.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(' ');
    b.write(digits[i]);
  }
  return '${neg ? '-' : ''}$b Ft';
}

/// A short amount for the side of a chart: 500 -> "500 Ft", 20000 -> "20 e Ft",
/// 1500000 -> "1,5 M Ft" (at most one decimal), negative with a minus sign.
String compactHuf(int amount) {
  final sign = amount < 0 ? '-' : '';
  final a = amount.abs();
  if (a < 1000) return '$sign$a Ft';
  // (tenths of a thousand; 999 950 and more is a million, not "1000 e")
  if (a < 999950) return '$sign${_tenths((a / 100).round())} e Ft';
  return '$sign${_tenths((a / 100000).round())} M Ft';
}

String _tenths(int t) => t % 10 == 0 ? '${t ~/ 10}' : '${t ~/ 10},${t % 10}';
