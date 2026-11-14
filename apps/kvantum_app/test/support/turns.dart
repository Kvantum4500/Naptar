import 'package:flutter_test/flutter_test.dart';

/// Turns the event loop until [done] is true. What futures, zero-length timers
/// and database streams do happens in turns of the event loop, not in time, so
/// a test that waits for it waits for TURNS: no clock decides whether it
/// passes, and a slow machine only makes it take longer. Fails the test (with
/// [what]) if the condition does not come about within [turns] turns.
Future<void> turnUntil(
  bool Function() done, {
  int turns = 5000,
  String what = 'what the test waits for',
}) async {
  for (var i = 0; i < turns; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  if (!done()) {
    fail('$what did not come about in $turns turns of the event loop');
  }
}

/// Lets everything that is ready to run, run: a fixed number of turns of the
/// event loop. For "nothing more happens" and for letting a chain of futures
/// finish when there is nothing to look at to know it has. (Waiting for
/// something that is known to come: [turnUntil].)
Future<void> turns([int count = 100]) => pumpEventQueue(times: count);
