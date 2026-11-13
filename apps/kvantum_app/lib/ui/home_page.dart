import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import '../update/update_dialog.dart';
import 'agenda_view.dart';
import 'breakpoints.dart';
import 'checkin.dart';
import 'day_utils.dart';
import 'workout_feedback.dart';
import 'event_editor.dart';
import 'format.dart';
import 'month_view.dart';
import 'quick_entry_dialog.dart';
import 'search_page.dart';
import 'setup_card.dart';
import 'shortcuts.dart';
import '../notify/budget_alerts.dart';
import '../notify/reminders.dart';
import '../widget/widget_sync.dart';
import 'swipe_nav.dart';
import 'sync_status.dart';
import 'time_grid.dart';
import 'unreadable_events_banner.dart';

/// The calendar page. What it shows follows the room the PAGE has: beside the
/// rail of a wide window it is narrower than the window.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _Calendar(width: constraints.maxWidth),
  );
}

class _Calendar extends ConsumerWidget {
  const _Calendar({required this.width});

  /// The width the page has.
  final double width;

  void _goto(WidgetRef ref, DateTime day) {
    ref.read(selectedDayProvider.notifier).set(day);
    ref.read(visibleMonthProvider.notifier).set(day);
  }

  void _today(WidgetRef ref) => _goto(ref, ref.read(todayProvider));

  void _shift(WidgetRef ref, int dir) {
    final view = ref.read(viewModeProvider);
    final sel = ref.read(selectedDayProvider);
    switch (view) {
      case CalView.month:
        final m = ref.read(visibleMonthProvider);
        final next = DateTime.utc(m.year, m.month + dir, 1);
        ref.read(visibleMonthProvider.notifier).set(next);
        // The chosen day goes with the month: the day shown under or beside
        // the grid must belong to the month on the screen.
        ref.read(selectedDayProvider.notifier).set(sameDayIn(sel, next));
      case CalView.week:
        _goto(ref, sel.add(Duration(days: 7 * dir)));
      case CalView.day:
        _goto(ref, sel.add(Duration(days: dir)));
      case CalView.agenda:
        _goto(ref, sel.add(Duration(days: agendaDays * dir)));
    }
  }

  /// Loads the ranges next to the one on the screen in advance, so a step or a
  /// swipe finds its events ready and the page does not flash empty first.
  void _prefetch(WidgetRef ref, CalView view, DateTime month, DateTime sel) {
    DayRange around(DateTime first, int days, int dir) => DayRange(
      first.add(Duration(days: days * dir)),
      first.add(Duration(days: days * dir + days)),
    );
    final ranges = <DayRange>[];
    switch (view) {
      case CalView.month:
        for (final dir in const [-1, 1]) {
          ranges.add(monthRangeOf(DateTime.utc(month.year, month.month + dir)));
          ranges.add(around(sel, 1, dir)); // the day panel steps by a day
        }
      case CalView.week:
        for (final dir in const [-1, 1]) {
          ranges.add(around(startOfWeek(sel), 7, dir));
        }
      case CalView.day:
        for (final dir in const [-1, 1]) {
          ranges.add(around(sel, 1, dir));
        }
      case CalView.agenda:
        for (final dir in const [-1, 1]) {
          ranges.add(around(sel, agendaDays, dir));
        }
    }
    for (final r in ranges) {
      ref.listen(rangeOccurrencesProvider(r), (_, _) {});
    }
  }

  String _title(CalView v, DateTime month, DateTime sel, {bool short = false}) {
    switch (v) {
      case CalView.month:
        return DateFormat(short ? 'y. MMM' : 'y. MMMM', 'hu').format(month);
      case CalView.week:
        final a = startOfWeek(sel);
        return _range(a, a.add(const Duration(days: 6)));
      case CalView.day:
        return fmtDateLong(sel);
      case CalView.agenda:
        return _range(sel, sel.add(const Duration(days: agendaDays - 1)));
    }
  }

  /// "2026. nov. 9. – 15." / "2026. nov. 30. – dec. 6." /
  /// "2026. dec. 28. – 2027. jan. 3." (the date format ends with its own dot).
  String _range(DateTime a, DateTime b) {
    final f = DateFormat('MMM d.', 'hu');
    if (a.year != b.year) {
      return '${a.year}. ${f.format(a)} – ${b.year}. ${f.format(b)}';
    }
    return '${a.year}. ${f.format(a)} – '
        '${a.month == b.month ? '${b.day}.' : f.format(b)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(reminderSyncProvider); // keeps the device reminders up to date
    ref.watch(budgetAlertsProvider); // tells when a budget is close or over
    ref.watch(widgetSyncProvider); // and the home-screen widget (Android)
    final view = ref.watch(viewModeProvider);
    final month = ref.watch(visibleMonthProvider);
    final sel = ref.watch(selectedDayProvider);
    final wide = useSidePanel(width);
    // Icon-only controls on a narrow window; the full labels need about 800 px.
    final compact = !useFullControls(width);
    final shortTitle = useShortTitle(width);
    // A phone held upright has no room for the arrows: a swipe steps instead.
    // A screen reader cannot swipe the calendar, so it keeps them.
    final arrows =
        useStepArrows(width) || MediaQuery.accessibleNavigationOf(context);
    _prefetch(ref, view, month, sel);

    Future<void> open(Occurrence o) => openEditor(context, ref, occurrence: o);
    void step(int dir) => _shift(ref, dir);

    final Widget body;
    switch (view) {
      case CalView.month:
        final grid = SwipeNav(
          onStep: step,
          child: MonthView(
            onOpen: open,
            onMore: (d) {
              _goto(ref, d);
              ref.read(viewModeProvider.notifier).set(CalView.day);
            },
          ),
        );
        final list = _DayPanel(
          onOpen: open,
          onCreateAt: (s) => openEditor(context, ref, initialStart: s),
          // under the month grid a swipe moves the day, not the month
          onStep: (dir) => _goto(ref, sel.add(Duration(days: dir))),
        );
        body = wide
            ? Row(
                children: [
                  Expanded(flex: 3, child: grid),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 2, child: list),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 3, child: grid),
                  const Divider(height: 1),
                  Expanded(flex: 2, child: list),
                ],
              );
      case CalView.week:
        final range = ref.watch(weekRangeProvider);
        final days = [
          for (var i = 0; i < 7; i++) range.first.add(Duration(days: i)),
        ];
        body = SwipeNav(
          onStep: step,
          child: TimeGrid(
            days: days,
            range: range,
            onOpen: open,
            onCreateAt: (s) => openEditor(context, ref, initialStart: s),
            onDayTap: (d) {
              _goto(ref, d);
              ref.read(viewModeProvider.notifier).set(CalView.day);
            },
          ),
        );
      case CalView.day:
        final range = ref.watch(dayRangeProvider);
        body = SwipeNav(
          onStep: step,
          child: TimeGrid(
            days: [range.first],
            range: range,
            onOpen: open,
            onCreateAt: (s) => openEditor(context, ref, initialStart: s),
          ),
        );
      case CalView.agenda:
        body = SwipeNav(
          onStep: step,
          child: AgendaView(onOpen: open),
        );
    }

    return CalendarKeys(
      actions: {
        NewEventIntent: PageAction<NewEventIntent>(
          (_) => openEditor(context, ref, initialDay: sel),
        ),
        QuickEntryIntent: PageAction<QuickEntryIntent>(
          (_) => showQuickEntry(context, ref),
        ),
        TodayIntent: PageAction<TodayIntent>((_) => _today(ref)),
        StepIntent: PageAction<StepIntent>((i) => _shift(ref, i.dir)),
        ViewIntent: PageAction<ViewIntent>(
          (i) => ref.read(viewModeProvider.notifier).set(i.view),
        ),
        SyncIntent: PageAction<SyncIntent>(
          (_) =>
              ref.read(syncControllerProvider.notifier).syncNow(manual: true),
        ),
        SearchIntent: PageAction<SearchIntent>((_) => openSearch(context)),
        HelpIntent: PageAction<HelpIntent>((_) => showShortcutHelp(context)),
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 12,
          // the title shrinks to what the buttons leave, it is never cut off
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(_title(view, month, sel, short: shortTitle)),
          ),
          actions: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SegmentedButton<CalView>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: CalView.month, label: Text('Hónap')),
                    ButtonSegment(value: CalView.week, label: Text('Hét')),
                    ButtonSegment(value: CalView.day, label: Text('Nap')),
                    ButtonSegment(
                      value: CalView.agenda,
                      label: Text('Napirend'),
                    ),
                  ],
                  selected: {view},
                  onSelectionChanged: (s) =>
                      ref.read(viewModeProvider.notifier).set(s.first),
                ),
              )
            else
              PopupMenuButton<CalView>(
                tooltip: 'Nézet',
                icon: const Icon(Icons.view_agenda_outlined),
                onSelected: (v) => ref.read(viewModeProvider.notifier).set(v),
                itemBuilder: (c) => const [
                  PopupMenuItem(value: CalView.month, child: Text('Hónap')),
                  PopupMenuItem(value: CalView.week, child: Text('Hét')),
                  PopupMenuItem(value: CalView.day, child: Text('Nap')),
                  PopupMenuItem(value: CalView.agenda, child: Text('Napirend')),
                ],
              ),
            IconButton(
              tooltip: 'Keresés',
              icon: const Icon(Icons.search),
              onPressed: () => openSearch(context),
            ),
            if (arrows)
              IconButton(
                tooltip: 'Előző',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(ref, -1),
              ),
            if (compact)
              IconButton(
                tooltip: 'Ma',
                icon: const Icon(Icons.today),
                onPressed: () => _today(ref),
              )
            else
              TextButton(onPressed: () => _today(ref), child: const Text('Ma')),
            if (arrows)
              IconButton(
                tooltip: 'Következő',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shift(ref, 1),
              ),
            SyncStatusButton(
              compact: compact || !useSyncLabel(width),
              onCheckUpdate: () => showUpdateDialog(context, ref),
            ),
            const SizedBox(width: 4),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Új esemény',
          onPressed: () => openEditor(context, ref, initialDay: sel),
          child: const Icon(Icons.add),
        ),
        body: Column(
          children: [
            const _Banners(),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// The banners above the calendar. Where space is short (a large text size, a
/// phone held sideways) they take a third of the height at most and scroll,
/// so that the calendar is never squeezed out by them.
class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    key: const Key('home-banners'),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height / 3,
    ),
    child: const SingleChildScrollView(
      child: Column(
        children: [
          SetupCard(),
          CheckInBanner(),
          WorkoutFeedbackBanner(),
          UnreadableEventsBanner(),
        ],
      ),
    ),
  );
}

/// Side panel of the month view: the selected day as an hour-scale timeline,
/// so a day can be read and extended without switching to the day view.
class _DayPanel extends ConsumerWidget {
  const _DayPanel({
    required this.onOpen,
    required this.onCreateAt,
    required this.onStep,
  });
  final OpenOccurrence onOpen;
  final void Function(DateTime wallStart) onCreateAt;

  /// A swipe over the day: the previous (-1) or the next (+1) day.
  final void Function(int dir) onStep;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(selectedDayProvider);
    final range = ref.watch(dayRangeProvider);
    final count = ref.watch(monthOccurrencesProvider).value?[day]?.length ?? 0;
    final special = huDayInfo(day);
    return LayoutBuilder(
      builder: (context, c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The title takes at most half of the panel and scrolls beyond that
          // (a large text size on a small phone), so the hours are never
          // squeezed out and nothing overflows.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: c.maxHeight / 2),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fmtDateLong(day),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (special != null)
                      Text(
                        special.label,
                        key: const Key('day-special'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: special.isDayOff
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    Text(
                      count == 0
                          ? 'Nincs esemény erre a napra.'
                          : '$count esemény',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: SwipeNav(
              onStep: onStep,
              child: TimeGrid(
                days: [range.first],
                range: range,
                showDayHeader: false,
                onOpen: onOpen,
                onCreateAt: onCreateAt,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
