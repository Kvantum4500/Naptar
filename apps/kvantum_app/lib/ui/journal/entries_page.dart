import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../journal/journal_providers.dart';
import '../../sync/error_catalog.dart';
import '../format.dart';
import 'entry_editor.dart';
import 'photo_widgets.dart';

/// How many pictures an entry shows in the list; the rest is told as "+N".
const entryThumbsShown = 4;

/// The diary entries (the first page of the "Napló" tab): a list by day, the
/// newest first; a tap opens the entry, the button writes a new one.
class JournalEntriesPage extends ConsumerWidget {
  const JournalEntriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(journalEntriesProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('journal-add'),
        onPressed: () => openEntryEditor(context),
        icon: const Icon(Icons.edit_note),
        label: const Text('Bejegyzés'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: entries.when(
            data: (list) => list.isEmpty
                ? const _Empty()
                : _EntryList(days: journalDays(list)),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'A napló nem olvasható. ${errorInfoFor(e).text}',
                key: const Key('journal-error'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
    children: [
      Card(
        key: const Key('journal-empty'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Még nincs bejegyzésed. A „Bejegyzés” gombbal leírhatod, mi '
            'történt veled, és képeket is tölthetsz hozzá. A szöveg és a '
            'képek a többi eszközödön is megjelennek (a képek szinkronja a '
            'Beállításokban kikapcsolható).',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    ],
  );
}

class _EntryList extends StatelessWidget {
  const _EntryList({required this.days});
  final List<JournalDay> days;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
    children: [
      for (final day in days) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Semantics(
            header: true,
            child: Text(
              fmtDateLong(day.day),
              key: Key('journal-day-${isoDay(day.day)}'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ),
        for (final e in day.entries) EntryTile(entry: e),
      ],
    ],
  );
}

/// What a screen reader says of an entry.
String spokenEntry(JournalEntry e) {
  final preview = journalPreview(e);
  return [
    'Bejegyzés, ${e.timeText}',
    e.heading,
    if (preview.isNotEmpty) preview.replaceAll('\n', ' '),
    if (e.photos.isNotEmpty) '${e.photos.length} kép',
  ].join('. ');
}

/// One entry in a list: the time, the head, the first lines, and a row of
/// small pictures (with "+N" for the rest). A tap opens the entry.
class EntryTile extends ConsumerWidget {
  const EntryTile({super.key, required this.entry, this.onOpen});

  final JournalEntry entry;

  /// What a tap does; by default the editor opens.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final e = entry;
    final preview = journalPreview(e);
    final shown = e.photos.take(entryThumbsShown).toList();
    final more = e.photos.length - shown.length;
    void open() =>
        onOpen != null ? onOpen!() : openEntryEditor(context, entry: e);
    return Card(
      key: Key('entry-${e.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        container: true,
        button: true,
        label: spokenEntry(e),
        excludeSemantics: true,
        onTap: open,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.timeText,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  e.heading,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    preview,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                if (shown.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final p in shown) PhotoThumb(photo: p, side: 56),
                      if (more > 0)
                        Text(
                          '+$more',
                          key: Key('entry-more-${e.id}'),
                          style: theme.textTheme.titleSmall,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
