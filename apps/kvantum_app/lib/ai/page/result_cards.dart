part of '../assistant_page.dart';

// The cards of what was proposed: the moves, the deletions and the new events
// with their buttons and the notes about what was left out. Part of the
// library of the page: they read the controller and the theme, and change
// nothing in the state of the page itself.
extension _ResultCards on _AssistantPageState {
  Widget _moveCard(
    BuildContext context,
    AssistantState st,
    List<dynamic> moves,
    bool applying,
  ) {
    final ctl = ref.read(assistantControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    String span(DateTime s, DateTime e) =>
        '${fmtDateLong(DateTime.utc(s.year, s.month, s.day))}, ${fmtTime(s)}–${fmtTime(e)}';
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Áthelyezésre javasolt események (${moves.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text('Semmi nem módosul, amíg nem engedélyezed.'),
            const SizedBox(height: 8),
            for (final m in moves) ...[
              () {
                final occ = m.occurrence as Occurrence;
                final tz = occ.tzid ?? defaultTz;
                final from = span(
                  toWallClock(tz, occ.startUtc),
                  toWallClock(tz, occ.endUtc),
                );
                final to = span(m.newStart as DateTime, m.newEnd as DateTime);
                final reason = m.reason as String;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        occ.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('Most: $from'),
                      Text('Új időpont: $to'),
                      if (occ.recurring)
                        const Text('Ismétlődő esemény: csak ez a nap mozdul.'),
                      if (reason.isNotEmpty) Text(reason),
                    ],
                  ),
                );
              }(),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: applying ? null : ctl.declineMoves,
                  child: const Text('Mégse'),
                ),
                FilledButton(
                  // (the bar for "Visszavonás" is shown from here: the site is
                  // taken now, while this page is surely there)
                  onPressed: applying
                      ? null
                      : () => ctl.confirmMoves(UndoSite.of(context)),
                  child: const Text('Engedélyezem'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _deleteCard(
    BuildContext context,
    AssistantState st,
    List<dynamic> dels,
    bool applying,
  ) {
    final ctl = ref.read(assistantControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Törlésre javasolt események (${dels.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text('Semmi nem törlődik, amíg nem engedélyezed.'),
            // What the user asked for, in their own words. (The model's own
            // reason used to stand under each event: often English, and not the
            // user's to vouch for.)
            if (st.prompt.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'A kérésed: „${st.prompt.trim()}”',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: 8),
            for (var i = 0; i < dels.length; i++) ...[
              () {
                final occ = dels[i].occurrence as Occurrence;
                final tz = occ.tzid ?? defaultTz;
                final s = occ.allDay
                    ? occ.startUtc
                    : toWallClock(tz, occ.startUtc);
                final e = occ.allDay ? occ.endUtc : toWallClock(tz, occ.endUtc);
                final day = fmtDateLong(DateTime.utc(s.year, s.month, s.day));
                final label = occ.allDay
                    ? '$day (egész napos)'
                    : '$day, ${fmtTime(s)}–${fmtTime(e)}';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      occ.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(label),
                    if (occ.recurring) ...[
                      const SizedBox(height: 4),
                      const Text('Ismétlődő esemény, mit töröljek?'),
                      SegmentedButton<Scope>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: Scope.only,
                            label: Text('Csak ezt'),
                          ),
                          ButtonSegment(
                            value: Scope.following,
                            label: Text('Ezt és a következőket'),
                          ),
                          ButtonSegment(
                            value: Scope.all,
                            label: Text('Az összeset'),
                          ),
                        ],
                        selected: {st.deleteScopes[i] ?? Scope.only},
                        onSelectionChanged: applying
                            ? null
                            : (v) => ctl.setDeleteScope(i, v.first),
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                );
              }(),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: applying ? null : ctl.declineDeletions,
                  child: const Text('Mégse'),
                ),
                FilledButton(
                  onPressed: applying
                      ? null
                      : () => ctl.confirmDeletions(UndoSite.of(context)),
                  child: const Text('Engedélyezem'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _result(
    BuildContext context,
    AssistantState st,
    dynamic o,
    bool applying,
  ) {
    final ctl = ref.read(assistantControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    String when(dynamic it) {
      final s = it.startWall as DateTime, e = it.endWall as DateTime;
      return '${fmtDateLong(DateTime.utc(s.year, s.month, s.day))}, ${fmtTime(s)}–${fmtTime(e)}';
    }

    return [
      if (o.localAnswer != null)
        _LocalCard(
          answer: o.localAnswer as LocalAnswer,
          onAsk: (q) => ctl.askMore(q),
        )
      else if (o.text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SelectableText(o.text),
        ),
      if (o.summary.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            o.summary,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      for (final q in o.questions as List<String>)
        ListTile(
          dense: true,
          leading: const Icon(Icons.help_outline),
          title: Text(q),
        ),
      if ((o.moves as List).isNotEmpty)
        _moveCard(context, st, o.moves as List<dynamic>, applying),
      if ((o.deletions as List).isNotEmpty)
        _deleteCard(context, st, o.deletions as List<dynamic>, applying),
      if (o.items.isNotEmpty) ...[
        for (var i = 0; i < o.items.length; i++)
          Card(
            child: CheckboxListTile(
              value: st.selected.contains(i),
              onChanged: applying ? null : (_) => ctl.toggle(i),
              title: Text(o.items[i].title as String),
              subtitle: Text(
                '${o.items[i].taskTitle == null ? '' : 'Feladat: ${o.items[i].taskTitle}\n'}'
                '${when(o.items[i])}${(o.items[i].reason as String).isEmpty ? '' : '\n${o.items[i].reason}'}',
              ),
              isThreeLine:
                  (o.items[i].reason as String).isNotEmpty ||
                  o.items[i].taskTitle != null,
              // (the service has set it to the code's verdict: 60 minutes or
              // more by default, the user's own limits once learned)
              secondary: o.items[i].hard == true
                  ? const Tooltip(
                      message: 'Nehéz edzés',
                      child: Icon(Icons.fitness_center),
                    )
                  : null,
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: (st.selected.isEmpty || applying)
                  ? null
                  : () => ctl.acceptSelected(UndoSite.of(context)),
              icon: const Icon(Icons.event_available),
              label: Text('Elfogadom a kijelölteket (${st.selected.length})'),
            ),
            TextButton(
              onPressed: applying ? null : ctl.discardPlan,
              child: const Text('Elvetem'),
            ),
          ],
        ),
      ],
      if (o.items.isEmpty &&
          o.text.isEmpty &&
          (o.questions as List).isEmpty &&
          (o.deletions as List).isEmpty &&
          (o.moves as List).isEmpty &&
          o.summary.isEmpty &&
          st.movedCount == null &&
          st.deletedCount == null)
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Most nem tudtam használható tervet adni.'),
        ),
      if ((o.dropped as List).isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            'Nem javasolt (${(o.dropped as List).length}): szabálysértés vagy nem található',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          children: [
            for (final d in o.dropped as List<String>)
              ListTile(dense: true, title: Text(d)),
          ],
        ),
    ];
  }
}
