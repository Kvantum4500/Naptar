import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/breakpoints.dart';

void main() {
  test('each limit applies from its own width, not a pixel earlier', () {
    expect(useRail(759.9), isFalse);
    expect(useRail(760), isTrue);
    expect(useFullControls(859.9), isFalse);
    expect(useFullControls(860), isTrue);
    expect(useSyncLabel(999.9), isFalse);
    expect(useSyncLabel(1000), isTrue);
    expect(useStepArrows(439.9), isFalse);
    expect(useStepArrows(440), isTrue);
    expect(useSidePanel(899.9), isFalse);
    expect(useSidePanel(900), isTrue);
    expect(useShortTitle(399.9), isTrue);
    expect(useShortTitle(400), isFalse);
  });

  test('they are in the order the layouts grow', () {
    expect(Breakpoints.shortTitle, lessThan(Breakpoints.stepArrows));
    expect(Breakpoints.stepArrows, lessThan(Breakpoints.rail));
    expect(Breakpoints.shortTitle, lessThan(Breakpoints.rail));
    expect(Breakpoints.rail, lessThan(Breakpoints.fullControls));
    expect(Breakpoints.fullControls, lessThan(Breakpoints.sidePanel));
    expect(Breakpoints.sidePanel, lessThan(Breakpoints.syncLabel));
  });

  test('a month cell needs about a phone-landscape width for text bars', () {
    expect(Breakpoints.dotCell, inInclusiveRange(48, 80));
  });
}
