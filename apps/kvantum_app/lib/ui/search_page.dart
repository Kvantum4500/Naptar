import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'day_utils.dart';
import 'event_editor.dart';
import 'finance/finance_editors.dart';
import 'format.dart';
import 'palette.dart';
import 'quick_entry_dialog.dart';
import 'quick_entry_ops.dart' show quickWhen;
import 'shell_tab.dart';
import 'tasks_page.dart';
import 'theme.dart';

/// What is typed into the search box. It lives as long as the page is open,
/// so a new search starts empty.
class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q;
}

final searchQueryProvider = NotifierProvider.autoDispose<SearchQuery, String>(
  SearchQuery.new,
);

/// Every event, kept in memory while the search is open: a keystroke filters
/// this list, it does not read the database again.
final _searchEventsProvider = StreamProvider.autoDispose<List<CalEvent>>(
  (ref) => ref.watch(repoProvider).watchAll(),
);

/// What a search found, in the three places it looks.
class SearchResults {
  const SearchResults(this.events, this.tasks, this.tx);
  const SearchResults.none()
    : events = const EventSearch.none(),
      tasks = const TaskSearch.none(),
      tx = const TxSearch.none();

  final EventSearch events;
  final TaskSearch tasks;
  final TxSearch tx;

  bool get isEmpty =>
      events.hits.isEmpty && tasks.hits.isEmpty && tx.hits.isEmpty;
}

final searchResultsProvider = Provider.autoDispose<SearchResults>((ref) {
  final q = ref.watch(searchQueryProvider);
  if (searchTerms(q).isEmpty) return const SearchResults.none();
  final now = ref.watch(appClockProvider)();
  final events = ref.watch(_searchEventsProvider).value ?? const <CalEvent>[];
  final tasks = ref.watch(tasksProvider).value ?? const <TaskView>[];
  final txs = ref.watch(finTxProvider).value ?? const <FinTx>[];
  final cats = ref.watch(finCategoriesProvider).value ?? const <FinCategory>[];
  return SearchResults(
    searchEvents(events, q, now: now),
    searchTasks(tasks, q),
    searchTx(txs, q, categoryName: (id) => categoryName(cats, id)),
  );
});

/// Opens the search page.
Future<void> openSearch(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));

/// The calendar day an occurrence starts on.
DateTime occurrenceDay(Occurrence o) => o.allDay
    ? dateOnly(o.startUtc)
    : dateOnly(toWallClock(o.tzid ?? defaultTz, o.startUtc));

/// Search over the events, the tasks and the money log. A tap opens the thing
/// itself; the small calendar button beside an event goes to its day.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(String v) => ref.read(searchQueryProvider.notifier).set(v);

  void _jump(DateTime day) {
    ref.read(selectedDayProvider.notifier).set(day);
    ref.read(visibleMonthProvider.notifier).set(day);
    ref.read(shellTabProvider.notifier).select(ShellTab.calendar);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final q = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider);
    final searching = searchTerms(q).isNotEmpty;
    // A line that says when ("holnap 18:00 edzés") can be made right here.
    final made = searching ? parseQuickEntry(q, now: wallNow(ref)) : null;
    final offer = made != null && looksLikeQuickEntry(made) ? made : null;

    final Widget body;
    if (!searching) {
      body = const _Note(
        'Írj be legalább két betűt. Az eseményekben, a feladatokban és a '
        'pénzügyi tételekben keres, kis- és nagybetűre, ékezetre nem kényes.',
      );
    } else if (results.isEmpty) {
      body = _Note('Nincs találat: „${q.trim()}”.');
    } else {
      body = ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (results.events.hits.isNotEmpty) ...[
            _Header('Események', results.events.hits.length),
            for (final h in results.events.hits)
              _EventTile(hit: h, onJump: _jump),
            _More(results.events.more),
          ],
          if (results.tasks.hits.isNotEmpty) ...[
            _Header('Feladatok', results.tasks.hits.length),
            for (final t in results.tasks.hits) _TaskTile(task: t),
            _More(results.tasks.more),
          ],
          if (results.tx.hits.isNotEmpty) ...[
            _Header('Pénzügyek', results.tx.hits.length),
            for (final t in results.tx.hits) _TxTile(tx: t),
            _More(results.tx.more),
          ],
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: TextField(
            key: const Key('search-field'),
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Keresés',
              border: InputBorder.none,
            ),
            onChanged: _set,
          ),
          actions: [
            if (q.isNotEmpty)
              IconButton(
                tooltip: 'Mező törlése',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _text.clear();
                  _set('');
                },
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                if (offer != null)
                  _QuickOffer(
                    entry: offer,
                    today: ref.watch(todayProvider),
                    onTap: () =>
                        showQuickEntry(context, ref, initialText: q.trim()),
                  ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "＋ Felvétel: …": what the typed line would make, one tap away.
class _QuickOffer extends StatelessWidget {
  const _QuickOffer({
    required this.entry,
    required this.today,
    required this.onTap,
  });
  final QuickEntry entry;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('search-quick-offer'),
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: ListTile(
      leading: const Icon(Icons.bolt),
      title: Text('Felvétel: ${entry.title}'),
      subtitle: Text(quickWhen(entry, today)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.count);
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Semantics(
      header: true,
      child: Text(
        '$title ($count)',
        style: Theme.of(context).textTheme.titleSmall,
      ),
    ),
  );
}

/// "… and N more": the list is cut, a more exact word narrows it.
class _More extends StatelessWidget {
  const _More(this.more);
  final int more;

  @override
  Widget build(BuildContext context) => more <= 0
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'és még $more találat – pontosítsd a keresést',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
}

class _EventTile extends ConsumerWidget {
  const _EventTile({required this.hit, required this.onJump});
  final EventHit hit;
  final void Function(DateTime day) onJump;

  String _when() {
    final o = hit.occurrence;
    final day = occurrenceDay(o);
    final String time;
    if (o.allDay) {
      time = 'egész nap';
    } else {
      final tz = o.tzid ?? defaultTz;
      time =
          '${fmtTime(toWallClock(tz, o.startUtc))}–${fmtTime(toWallClock(tz, o.endUtc))}';
    }
    return [
      fmtDateLong(day),
      time,
      if (o.recurring) 'ismétlődő',
      if (hit.location.isNotEmpty) hit.location,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = hit.occurrence;
    return ListTile(
      key: ValueKey('hit-event-${o.eventId}-${o.originalStart}'),
      leading: ExcludeSemantics(
        child: SizedBox(
          width: 24,
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: eventColor(o.colorId),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
      title: Text(o.title.isEmpty ? '(nincs cím)' : o.title),
      subtitle: Text(_when()),
      trailing: IconButton(
        tooltip: 'Ugrás a naptárban',
        icon: const Icon(Icons.event_outlined),
        onPressed: () => onJump(occurrenceDay(o)),
      ),
      onTap: () => openEditor(context, ref, occurrence: o),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});
  final TaskView task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('hit-task-${task.id}'),
      leading: Icon(
        task.done ? Icons.check_box_outlined : Icons.check_box_outline_blank,
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
          color: task.done ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text(
        [
          if (task.due != null) 'Határidő: ${fmtDate(task.due!)}',
          if (task.done) 'kész',
        ].join(' · '),
      ),
      onTap: () => openTaskEditor(context, ref, task: task),
    );
  }
}

class _TxTile extends ConsumerWidget {
  const _TxTile({required this.tx});
  final FinTx tx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cats = ref.watch(finCategoriesProvider).value ?? const [];
    final income = tx.kind == FinKind.income;
    final cat = categoryName(cats, tx.categoryId);
    return ListTile(
      key: ValueKey('hit-tx-${tx.id}'),
      leading: Icon(
        income ? Icons.south_west : Icons.north_east,
        color: income ? statusColorsOf(context).ok : scheme.error,
        semanticLabel: income ? 'Bevétel' : 'Kiadás',
      ),
      title: Text(tx.merchant.isEmpty ? cat : tx.merchant),
      subtitle: Text(
        [
          fmtDate(tx.date),
          if (tx.merchant.isNotEmpty) cat,
          if (tx.note.isNotEmpty) tx.note,
        ].join(' · '),
      ),
      trailing: Text(
        '${income ? '+' : '-'}${formatHuf(tx.amount)}',
        style: TextStyle(
          color: income ? statusColorsOf(context).ok : scheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: () => editTx(context, existing: tx),
    );
  }
}
