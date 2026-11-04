import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
              if (st.busy) const _Working(),
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
              if (o != null) ..._result(context, st, o),
            ],
          ),
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
      if (o.items.isEmpty && o.text.isEmpty && (o.questions as List).isEmpty)
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Most nem tudtam használható tervet adni.'),
        ),
      if ((o.dropped as List).isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            'Nem javasolt (${(o.dropped as List).length}), mert sértené a szabályokat',
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
  const _Working();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'Az asszisztens dolgozik: adatot kér le, szabad időt keres, ellenőrzi a szabályokat…',
          ),
        ),
      ],
    ),
  );
}
