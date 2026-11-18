import 'package:flutter_test/flutter_test.dart';

/// How many semantic nodes sit directly under the node of [finder]. A tile that
/// is read out as one sentence (the pieces of it left out of the tree) has
/// none: a screen reader goes over it once, not piece by piece as well.
int semanticChildCount(WidgetTester tester, Finder finder) {
  var count = 0;
  tester.getSemantics(finder).visitChildren((_) {
    count++;
    return true;
  });
  return count;
}
