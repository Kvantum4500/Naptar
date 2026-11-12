/// The window widths the layouts change at. One place, so the pages agree on
/// what a phone, a tablet and a desktop window are (they used to carry their
/// own numbers).
abstract final class Breakpoints {
  /// From this window width the destinations sit in a rail at the side instead
  /// of a bar at the bottom, and the event editor is a dialog instead of a page.
  static const double rail = 760;

  /// Below this the calendar bar uses icons only: the full labels need about
  /// 800 px.
  static const double fullControls = 820;

  /// From this width the month view shows the day panel beside the grid.
  static const double sidePanel = 900;

  /// Below this the month title is the short form ("2026. nov.").
  static const double shortTitle = 400;

  /// A month cell narrower than this shows coloured dots instead of text
  /// chips (the text would only be a few letters).
  static const double dotCell = 64;
}

bool useRail(double windowWidth) => windowWidth >= Breakpoints.rail;
bool useFullControls(double windowWidth) =>
    windowWidth >= Breakpoints.fullControls;
bool useSidePanel(double windowWidth) => windowWidth >= Breakpoints.sidePanel;
bool useShortTitle(double windowWidth) => windowWidth < Breakpoints.shortTitle;
