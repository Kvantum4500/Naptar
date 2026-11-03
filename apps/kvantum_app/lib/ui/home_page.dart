import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart';
import 'event_editor.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref, {
    CalEvent? event,
  }) => Navigator.of(context).push(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) =>
          EventEditor(event: event, initialDay: ref.read(selectedDayProvider)),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(visibleMonthProvider);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final grid = _MonthGrid(onEdit: (e) => _openEditor(context, ref, event: e));
    final day = _DayList(onEdit: (e) => _openEditor(context, ref, event: e));
    return Scaffold(
      appBar: AppBar(
        title: Text(DateFormat.yMMMM('hu').format(month)),
        actions: [
          const _SyncButton(),
          IconButton(
            tooltip: 'Előző hónap',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => ref
                .read(visibleMonthProvider.notifier)
                .set(DateTime.utc(month.year, month.month - 1, 1)),
          ),
          TextButton(
            onPressed: () {
              final n = DateTime.now();
              ref
                  .read(visibleMonthProvider.notifier)
                  .set(DateTime.utc(n.year, n.month, 1));
              ref
                  .read(selectedDayProvider.notifier)
                  .set(DateTime.utc(n.year, n.month, n.day));
            },
            child: const Text('Ma'),
          ),
          IconButton(
            tooltip: 'Következő hónap',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => ref
                .read(visibleMonthProvider.notifier)
                .set(DateTime.utc(month.year, month.month + 1, 1)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Új esemény',
        onPressed: () => _openEditor(context, ref),
        child: const Icon(Icons.add),
      ),
      body: wide
          ? Row(
              children: [
                Expanded(flex: 3, child: grid),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: day),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 3, child: grid),
                const Divider(height: 1),
                Expanded(flex: 2, child: day),
              ],
            ),
    );
  }
}

class _MonthGrid extends ConsumerWidget {
  const _MonthGrid({required this.onEdit});
  final void Function(CalEvent) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(visibleMonthProvider);
    final selected = ref.watch(selectedDayProvider);
    final occ = ref.watch(monthOccurrencesProvider).value ?? const {};
    final cells = monthGrid(month);
    final today = DateTime.now();
    final scheme = Theme.of(context).colorScheme;
    final names = [
      for (var i = 0; i < 7; i++)
        DateFormat.E('hu').format(DateTime(2024, 1, 1 + i)),
    ];
    return Column(
      children: [
        Row(
          children: [
            for (final n in names)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      n,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              for (var w = 0; w < 6; w++)
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < 7; i++)
                        Expanded(
                          child: _cell(
                            context,
                            ref,
                            cells[w * 7 + i],
                            month,
                            selected,
                            today,
                            occ,
                            scheme,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    WidgetRef ref,
    DateTime d,
    DateTime month,
    DateTime selected,
    DateTime today,
    Map<DateTime, List<Occurrence>> occ,
    ColorScheme scheme,
  ) {
    final inMonth = d.month == month.month;
    final isSel = d == selected;
    final isToday =
        d.year == today.year && d.month == today.month && d.day == today.day;
    final items = occ[d] ?? const [];
    return Semantics(
      label: '${d.year}. ${d.month}. ${d.day}., ${items.length} esemény',
      button: true,
      child: InkWell(
        onTap: () => ref.read(selectedDayProvider.notifier).set(d),
        child: Container(
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: isSel ? scheme.primaryContainer : null,
            border: isToday
                ? Border.all(color: scheme.primary, width: 1.5)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${d.day}',
                style: TextStyle(color: inMonth ? null : scheme.outline),
              ),
              const SizedBox(height: 2),
              for (final o in items.take(2))
                Flexible(
                  child: Text(
                    o.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: scheme.primary),
                  ),
                ),
              if (items.length > 2)
                Text(
                  '+${items.length - 2}',
                  style: const TextStyle(fontSize: 10),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayList extends ConsumerWidget {
  const _DayList({required this.onEdit});
  final void Function(CalEvent) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(selectedDayProvider);
    final occ = ref.watch(monthOccurrencesProvider).value ?? const {};
    final items = occ[day] ?? const <Occurrence>[];
    final tf = DateFormat.Hm('hu');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            DateFormat.yMMMMEEEEd('hu').format(day),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Nincs esemény erre a napra.'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final o = items[i];
                    final time = o.allDay
                        ? 'Egész nap'
                        : '${tf.format(toWallClock(o.tzid ?? defaultTz, o.startUtc))}–${tf.format(toWallClock(o.tzid ?? defaultTz, o.endUtc))}';
                    return ListTile(
                      title: Text(o.title),
                      subtitle: Text(time),
                      onTap: () async {
                        final e = await ref.read(repoProvider).byId(o.eventId);
                        if (e != null) onEdit(e);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SyncButton extends ConsumerWidget {
  const _SyncButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);
    final ctl = ref.read(syncControllerProvider.notifier);
    if (!s.configured) {
      return IconButton(
        tooltip: 'Google nincs beállítva',
        icon: const Icon(Icons.cloud_off_outlined),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Google nincs beállítva'),
            content: const Text(
              'Add meg a GOOGLE_CLIENT_ID és GOOGLE_CLIENT_SECRET értéket '
              'a secrets.json fájlban, és indítsd így:\n'
              'flutter run --dart-define-from-file=secrets.json',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Rendben'),
              ),
            ],
          ),
        ),
      );
    }
    if (!s.signedIn) {
      return TextButton.icon(
        onPressed: ctl.signIn,
        icon: const Icon(Icons.login),
        label: const Text('Belépés Google-lal'),
      );
    }
    if (s.syncing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final last = s.lastSync == null
        ? 'még nem szinkronizált'
        : 'utoljára ${DateFormat.Hm('hu').format(s.lastSync!)}';
    return PopupMenuButton<String>(
      tooltip:
          s.error ??
          'Szinkron: $last${s.pending > 0 ? ', ${s.pending} függőben' : ''}',
      icon: Icon(s.error == null ? Icons.sync : Icons.sync_problem),
      onSelected: (v) => v == 'sync' ? ctl.syncNow() : ctl.signOut(),
      itemBuilder: (c) => [
        PopupMenuItem(value: 'sync', child: Text('Szinkron most ($last)')),
        const PopupMenuItem(value: 'out', child: Text('Kilépés')),
      ],
    );
  }
}
