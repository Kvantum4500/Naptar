/// The three channels one sync run goes over. They run independently: a
/// problem with one never blocks the others.
const channelCalendar = 'calendar';
const channelDrive = 'drive';
const channelFinance = 'finance';
const syncChannels = [channelCalendar, channelDrive, channelFinance];

/// What the last run that looked at one channel found there.
class ChannelStatus {
  const ChannelStatus({
    this.lastTry,
    this.lastOk,
    this.code,
    this.text,
    this.pulled = 0,
    this.pushed = 0,
    this.failed = 0,
  });

  /// When a run last looked at this channel.
  final DateTime? lastTry;

  /// When a run last got through it without any problem.
  final DateTime? lastOk;

  /// What went wrong, as a short stable code (`transient`, `parked`, `gone`,
  /// `newer`, `unexpected` …); null when the last run was clean.
  final String? code;

  /// The Hungarian line for the user (null when clean).
  final String? text;

  /// What the last run moved: items taken over, items sent, items that did not
  /// go through.
  final int pulled, pushed, failed;

  bool get ok => code == null;
}
