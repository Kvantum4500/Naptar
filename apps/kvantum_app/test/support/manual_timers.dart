import 'dart:async';

/// Timers that fire only when the test says so, and remember how long they
/// were asked to wait.
class ManualTimers {
  final made =
      <({Duration wait, void Function() fire, bool Function() live})>[];

  Timer make(Duration wait, void Function() fire) {
    final t = _ManualTimer();
    made.add((
      wait: wait,
      fire: () {
        if (t.isActive) {
          t._active = false;
          fire();
        }
      },
      live: () => t.isActive,
    ));
    return t;
  }

  /// How many are still waiting.
  int get live => made.where((m) => m.live()).length;

  /// The one still waiting (there must be exactly one).
  ({Duration wait, void Function() fire, bool Function() live}) get current =>
      made.singleWhere((m) => m.live());
}

class _ManualTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}
