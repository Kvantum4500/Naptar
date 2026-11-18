import 'package:kvantum_core/kvantum_core.dart';

import 'record_repository.dart';

/// What came of ticking a task off.
class TaskCompleted {
  const TaskCompleted({this.comesBack, required this.undo});

  /// The due date the task came back with (it repeats), or null when it is
  /// done for good.
  final DateTime? comesBack;

  /// Puts everything the tick changed back.
  final Future<void> Function() undo;
}

/// The things done to tasks: ticking off (a task that repeats comes back),
/// the checklist, deleting a task together with its checklist.
class TaskOps {
  TaskOps(this.records);
  final RecordRepository records;

  /// Ticks [t] off. A task that repeats is not done: it comes back with the
  /// next due date, and its checklist ([items]) starts over. When the series
  /// has run out (a count, an end date) the task is done like any other.
  Future<TaskCompleted> complete(
    TaskView t, {
    required DateTime today,
    List<TaskView> items = const [],
  }) async {
    final rule = t.repeatRule;
    final due = t.due;
    if (rule != null && due != null) {
      final next = nextRound(rule: rule, due: due, today: today);
      if (next != null) {
        final before = {
          'due': t.record['due'],
          'repeat': t.record['repeat'],
          'done': t.record['done'] ?? false,
        };
        await records.edit(kindTask, t.id, {
          'due': isoDay(next.due),
          'repeat': next.rule,
          'done': false,
        });
        final ticked = [
          for (final i in items)
            if (i.done) i,
        ];
        for (final i in ticked) {
          await records.edit(kindTask, i.id, {'done': false});
        }
        return TaskCompleted(
          comesBack: next.due,
          undo: () async {
            await records.edit(kindTask, t.id, before);
            for (final i in ticked) {
              await records.edit(kindTask, i.id, {'done': true});
            }
          },
        );
      }
    }
    await records.edit(kindTask, t.id, {'done': true});
    return TaskCompleted(
      undo: () async {
        await records.edit(kindTask, t.id, {'done': false});
      },
    );
  }

  /// Takes a tick back (an ordinary task, or an item of a checklist).
  Future<void> setDone(TaskView t, bool done) =>
      records.edit(kindTask, t.id, {'done': done});

  /// Adds an item to the checklist of [parentId]. [pos] orders the items.
  Future<String> addItem(
    String parentId,
    String title, {
    required int pos,
    required String id,
    bool done = false,
  }) async {
    await records.edit(
      kindTask,
      id,
      taskFields(title: title, parent: parentId, pos: pos, done: done),
    );
    return id;
  }

  Future<void> renameItem(TaskView item, String title) =>
      records.edit(kindTask, item.id, {'title': title.trim()});

  /// Deletes [t] and its checklist ([items]); the ids tell what to bring back.
  Future<List<String>> delete(
    TaskView t, {
    List<TaskView> items = const [],
  }) async {
    final ids = [t.id, for (final i in items) i.id];
    for (final id in ids) {
      await records.delete(kindTask, id);
    }
    return ids;
  }

  /// Brings back what [delete] deleted.
  Future<bool> undelete(List<String> ids) async {
    var any = false;
    for (final id in ids) {
      if (await records.undelete(kindTask, id)) any = true;
    }
    return any;
  }
}
