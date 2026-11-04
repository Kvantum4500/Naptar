import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import '../update/update_dialog.dart';
import '../ai/assistant_page.dart';
import '../ai/settings_page.dart';
import 'checkin.dart';
import 'event_editor.dart';
import 'tasks_page.dart';
import 'format.dart';
import 'month_view.dart';
import 'sync_status.dart';
import 'time_grid.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  void _goto(WidgetRef ref, DateTime day) {
    ref.read(selectedDayProvider.notifier).set(day);
    ref.read(visibleMonthProvider.notifier).set(day);
  }

  void _today(WidgetRef ref) {
    final n = DateTime.now();
    _goto(ref, DateTime.utc(n.year, n.month, n.day));
  }

  void _shift(WidgetRef ref, int dir) {
    final view = ref.read(viewModeProvider);
    final sel = ref.read(selectedDayProvider);
    switch (view) {
      case CalView.month:
        final m = ref.read(visibleMonthProvider);
        ref
            .read(visibleMonthProvider.notifier)
            .set(DateTime.utc(m.year, m.month + dir, 1));
      case CalView.week:
        _goto(ref, sel.add(Duration(days: 7 * dir)));
      case CalView.day:
        _goto(ref, sel.add(Duration(days: dir)));
    }
  }

  String _title(CalView v, DateTime month, DateTime sel) {
    switch (v) {
      case CalView.month:
        return DateFormat('y. MMMM', 'hu').format(month);
      case CalView.week:
        final a = startOfWeek(sel), b = a.add(const Duration(days: 6));
        final f = DateFormat('MMM d.', 'hu');
        return '${a.year}. ${f.format(a)} – ${a.month == b.month ? b.day.toString() : f.format(b)}.';
      case CalView.day:
        return fmtDateLong(sel);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(viewModeProvider);
    final month = ref.watch(visibleMonthProvider);
    final sel = ref.watch(selectedDayProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    // Icon-only controls below this width; the full labels need about 800 px.
    final compact = width < 820;
    // Below this width the page shortcuts fold into one menu so the bar never overflows.
    final menuMode = width < 1000;

    Future<void> open(Occurrence o) => openEditor(context, ref, occurrence: o);

    final Widget body;
    switch (view) {
      case CalView.month:
        final grid = MonthView(
          onOpen: open,
          onMore: (d) {
            _goto(ref, d);
            ref.read(viewModeProvider.notifier).set(CalView.day);
          },
        );
        final list = _DayPanel(
          onOpen: open,
          onCreateAt: (s) => openEditor(context, ref, initialStart: s),
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
        body = TimeGrid(
          days: days,
          range: range,
          onOpen: open,
          onCreateAt: (s) => openEditor(context, ref, initialStart: s),
          onDayTap: (d) {
            _goto(ref, d);
            ref.read(viewModeProvider.notifier).set(CalView.day);
          },
        );
      case CalView.day:
        final range = ref.watch(dayRangeProvider);
        body = TimeGrid(
          days: [range.first],
          range: range,
          onOpen: open,
          onCreateAt: (s) => openEditor(context, ref, initialStart: s),
        );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Text(_title(view, month, sel), overflow: TextOverflow.ellipsis),
        actions: [
          if (!compact)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<CalView>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: CalView.month, label: Text('Hónap')),
                  ButtonSegment(value: CalView.week, label: Text('Hét')),
                  ButtonSegment(value: CalView.day, label: Text('Nap')),
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
              ],
            ),
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
          IconButton(
            tooltip: 'Következő',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _shift(ref, 1),
          ),
          if (menuMode)
            PopupMenuButton<String>(
              tooltip: 'Menü',
              onSelected: (v) {
                final page = switch (v) {
                  'tasks' => const TasksPage(),
                  'assistant' => const AssistantPage(),
                  _ => const SettingsPage(),
                };
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page));
              },
              itemBuilder: (c) => const [
                PopupMenuItem(value: 'tasks', child: Text('Feladatok')),
                PopupMenuItem(value: 'assistant', child: Text('Asszisztens')),
                PopupMenuItem(value: 'settings', child: Text('Beállítások')),
              ],
            )
          else ...[
            IconButton(
              tooltip: 'Feladatok',
              icon: const Icon(Icons.checklist),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TasksPage()),
              ),
            ),
            IconButton(
              tooltip: 'Asszisztens',
              icon: const Icon(Icons.auto_awesome),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AssistantPage()),
              ),
            ),
            IconButton(
              tooltip: 'Beállítások',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              ),
            ),
          ],
          SyncStatusButton(
            compact: compact,
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
          const CheckInBanner(),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Side panel of the month view: the selected day as an hour-scale timeline,
/// so a day can be read and extended without switching to the day view.
class _DayPanel extends ConsumerWidget {
  const _DayPanel({required this.onOpen, required this.onCreateAt});
  final OpenOccurrence onOpen;
  final void Function(DateTime wallStart) onCreateAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(selectedDayProvider);
    final range = ref.watch(dayRangeProvider);
    final count = ref.watch(monthOccurrencesProvider).value?[day]?.length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fmtDateLong(day),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                count == 0 ? 'Nincs esemény erre a napra.' : '$count esemény',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: TimeGrid(
            days: [range.first],
            range: range,
            showDayHeader: false,
            onOpen: onOpen,
            onCreateAt: onCreateAt,
          ),
        ),
      ],
    );
  }
}
