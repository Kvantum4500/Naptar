import 'models.dart';
import 'recurrence.dart';
import 'recurrence_spec.dart' show describeRrule;

/// The tasks that stand on their own: every task but the items of a checklist.
///
/// A task is an item of another task's checklist when its `parent` names a
/// task that exists (not deleted) and is not an item itself: a checklist is
/// one level deep. Whatever does not fit (a parent that was deleted on another
/// device, a loop, an item of an item) stands on its own, so that nothing ever
/// disappears from the list.
List<TaskView> topLevelTasks(Iterable<TaskView> all) {
  final items = _itemIds(all.toList());
  return [
    for (final t in all)
      if (!items.contains(t.id)) t,
  ];
}

/// The checklist of each task that has one: the id of the task, and its items
/// in the order they were added.
Map<String, List<TaskView>> checklists(Iterable<TaskView> all) {
  final list = all.toList();
  final items = _itemIds(list);
  final out = <String, List<TaskView>>{};
  for (final t in list) {
    if (items.contains(t.id)) (out[t.parentId!] ??= []).add(t);
  }
  for (final l in out.values) {
    l.sort((a, b) {
      final pa = a.pos, pb = b.pos;
      if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
      if ((pa == null) != (pb == null)) return pa == null ? 1 : -1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }
  return out;
}

Set<String> _itemIds(List<TaskView> all) {
  final live = {
    for (final t in all)
      if (!t.deleted) t.id: t,
  };
  bool hasParent(TaskView t) {
    final p = t.parentId;
    return p != null && live.containsKey(p);
  }

  // (a task that names itself, or two that name each other, have a parent
  // that has a parent: they stay on their own)
  return {
    for (final t in live.values)
      if (hasParent(t) && !hasParent(live[t.parentId]!)) t.id,
  };
}

/// What is left of a repeating task once the round in front of it is done.
class NextRound {
  const NextRound(this.due, this.rule);

  /// The next due date (floating).
  final DateTime due;

  /// The rule for what remains (with a count, one round fewer).
  final String rule;

  @override
  bool operator ==(Object other) =>
      other is NextRound && other.due == due && other.rule == rule;

  @override
  int get hashCode => Object.hash(due, rule);

  @override
  String toString() => 'NextRound($due, $rule)';
}

/// The round after the one due on [due], for a task that repeats by [rule]; null
/// when the series is over (or the rule is unreadable).
///
/// The next round is the first one after the later of [due] and [today]:
/// finishing early does not skip the one that is next, finishing late does
/// not leave the task overdue again at once (the rounds missed are dropped).
/// A rule with a count loses the rounds that passed.
NextRound? nextRound({
  required String rule,
  required DateTime due,
  required DateTime today,
}) {
  var body = rule.trim();
  if (body.startsWith('RRULE:')) body = body.substring('RRULE:'.length);
  final parsed = (() {
    try {
      return parseRule(body);
    } catch (_) {
      return null;
    }
  })();
  if (parsed == null) return null;
  final after = due.isAfter(today) ? due : today;
  var passed = 0;
  DateTime? next;
  for (final d in parsed.getInstances(start: due)) {
    if (d.isAfter(after)) {
      next = d;
      break;
    }
    if (++passed > 5000) return null; // a runaway rule
  }
  if (next == null) return null;
  final count = parsed.count;
  if (count != null) {
    // (the rounds that are left include [next], so there is at least one)
    final left = count - passed;
    body = body.replaceFirst(
      RegExp(r'COUNT=\d+', caseSensitive: false),
      'COUNT=$left',
    );
  }
  return NextRound(next, body);
}

/// "Hetente (hétfő)", for the line under a task.
String describeRepeat(String rule, DateTime due) => describeRrule(rule, due);
