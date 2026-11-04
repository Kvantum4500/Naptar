import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kvantum_core/kvantum_core.dart' show Occurrence, toWallClock;

import '../ui/day_utils.dart' show defaultTz;
import '../ui/event_editor.dart' show Scope;
import '../ui/format.dart';
import 'ai_providers.dart';
import 'settings_page.dart';

const _quickPrompts = [
  'Tervezz edzést a jövő hétre',
  'Mikor férne be 45 perc mozgás ma?',
  'Tervezz könnyű napot, kevés energiám van',
];

/// Ask for a plan; review the proposals; accept the ones you like.
class AssistantPage extends ConsumerStatefulWidget {
  const AssistantPage({super.key});
  @override
  ConsumerState<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends ConsumerState<AssistantPage> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    _input.text = t;
    ref.read(assistantControllerProvider.notifier).ask(t);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(assistantControllerProvider);
    final ctl = ref.read(assistantControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final o = st.outcome;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Asszisztens'),
        actions: [
          IconButton(
            tooltip: 'Beállítások',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _input,
                minLines: 2,
                maxLines: 5,
                enabled: !st.busy,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  labelText: 'Mit tervezzen az asszisztens?',
                  hintText: 'pl. Tervezz edzést a jövő hétre a feladataim és az energiaszintem alapján',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Küldés',
                    icon: st.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: st.busy ? null : _send,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final q in _quickPrompts)
                    ActionChip(
                      label: Text(q),
                      onPressed: st.busy ? null : () => _send(q),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (st.busy) _Working(status: st.status),
              if (st.error != null)
                Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          st.error!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                        if (st.errorDetail != null)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(
                              'Részletek',
                              style: TextStyle(color: scheme.onErrorContainer),
                            ),
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  st.errorDetail!,
                                  style: TextStyle(
                                    color: scheme.onErrorContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (st.errorNeedsSettings)
                              FilledButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const SettingsPage(),
                                  ),
                                ),
                                child: const Text('Beállítások'),
                              ),
                            TextButton(
                              onPressed: () => _send(st.prompt),
                              child: const Text('Újrapróbál'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (st.notice != null)
                Card(
                  color: scheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: Text(st.notice!),
                  ),
                ),
              if (st.acceptedCount != null)
                Card(
                  color: scheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(
                      '${st.acceptedCount} esemény bekerült a naptárba.',
                    ),
                    subtitle: const Text(
                      'Zöld színnel jelöltük őket, a Google „Naptar” naptárba is felmennek.',
                    ),
                    trailing: TextButton(
                      onPressed: ctl.dismiss,
                      child: const Text('Rendben'),
                    ),
                  ),
                ),
              if (st.movedCount != null)
                Card(
                  color: scheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.event_repeat),
                    title: Text('${st.movedCount} esemény áthelyezve.'),
                    trailing: TextButton(
                      onPressed: ctl.dismiss,
                      child: const Text('Rendben'),
                    ),
                  ),
                ),
              if (st.deletedCount != null)
                Card(
                  color: scheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text('${st.deletedCount} esemény törölve.'),
                    trailing: TextButton(
                      onPressed: ctl.dismiss,
                      child: const Text('Rendben'),
                    ),
                  ),
                ),
              if (o != null) ..._result(context, st, o),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moveCard(
    BuildContext context,
    AssistantState st,
    List<dynamic> moves,
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
            Row(
              children: [
                OutlinedButton(
                  onPressed: ctl.declineMoves,
                  child: const Text('Mégse'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: ctl.confirmMoves,
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
            const SizedBox(height: 8),
            for (var i = 0; i < dels.length; i++) ...[
              () {
                final occ = dels[i].occurrence as Occurrence;
                final reason = dels[i].reason as String;
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
                    if (reason.isNotEmpty) Text(reason),
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
                        onSelectionChanged: (v) =>
                            ctl.setDeleteScope(i, v.first),
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                );
              }(),
            ],
            Row(
              children: [
                OutlinedButton(
                  onPressed: ctl.declineDeletions,
                  child: const Text('Mégse'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: ctl.confirmDeletions,
                  child: const Text('Engedélyezem'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _result(BuildContext context, AssistantState st, dynamic o) {
    final ctl = ref.read(assistantControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    String when(dynamic it) {
      final s = it.startWall as DateTime, e = it.endWall as DateTime;
      return '${fmtDateLong(DateTime.utc(s.year, s.month, s.day))}, ${fmtTime(s)}–${fmtTime(e)}';
    }

    return [
      if (o.text.isNotEmpty)
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
        _moveCard(context, st, o.moves as List<dynamic>),
      if ((o.deletions as List).isNotEmpty)
        _deleteCard(context, st, o.deletions as List<dynamic>),
      if (o.items.isNotEmpty) ...[
        for (var i = 0; i < o.items.length; i++)
          Card(
            child: CheckboxListTile(
              value: st.selected.contains(i),
              onChanged: (_) => ctl.toggle(i),
              title: Text(o.items[i].title as String),
              subtitle: Text(
                '${when(o.items[i])}${(o.items[i].reason as String).isEmpty ? '' : '\n${o.items[i].reason}'}',
              ),
              isThreeLine: (o.items[i].reason as String).isNotEmpty,
              secondary: o.items[i].hard == true
                  ? const Tooltip(
                      message: 'Nehéz edzés',
                      child: Icon(Icons.fitness_center),
                    )
                  : null,
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: st.selected.isEmpty
                  ? null
                  : () => ctl.acceptSelected(),
              icon: const Icon(Icons.event_available),
              label: Text('Elfogadom a kijelölteket (${st.selected.length})'),
            ),
            const SizedBox(width: 10),
            TextButton(onPressed: ctl.dismiss, child: const Text('Elvetem')),
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
            style: TextStyle(color: scheme.outline),
          ),
          children: [
            for (final d in o.dropped as List<String>)
              ListTile(dense: true, title: Text(d)),
          ],
        ),
    ];
  }
}

class _Working extends StatelessWidget {
  const _Working({this.status});
  final String? status;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            status ??
                'Az asszisztens dolgozik: tervez, és ellenőrzi a szabályokat…',
          ),
        ),
      ],
    ),
  );
}
