import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kvantum_core/kvantum_core.dart'
    show LocalAnswer, LocalKind, Occurrence, toWallClock;

import '../ui/day_utils.dart' show defaultTz;
import '../ui/event_editor.dart' show Scope;
import '../ui/format.dart';
import '../ui/undo_service.dart' show UndoSite;
import 'ai_providers.dart';
import 'approval.dart' show assistantApplyingProvider;
import 'assistant_service.dart'
    show AssistantOutcome, PreparedRequest, maxPromptLength;
import 'llm_provider.dart' show LlmUsage;
import 'settings_page.dart';

part 'page/panels.dart';
part 'page/result_cards.dart';

const _quickPrompts = [
  'Tervezz edzést a jövő hétre',
  'Mikor férne be 45 perc mozgás ma?',
  'Tervezz könnyű napot, kevés energiám van',
  'Ütemezd a nyitott feladataimat a következő napokra',
  'Hogy állok a költségkerettel?',
  'Mi lesz holnap?',
];

/// Ask for a plan; review the proposals; accept the ones you like.
class AssistantPage extends ConsumerStatefulWidget {
  const AssistantPage({super.key});
  @override
  ConsumerState<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends ConsumerState<AssistantPage> {
  final _input = TextEditingController();
  late final AssistantController _ctl;

  // "Mit küldünk a modellnek?": built when the panel is opened or refreshed
  // (no timers: it does not follow the typing by itself).
  Future<PreparedRequest>? _preview;

  @override
  void initState() {
    super.initState();
    _ctl = ref.read(assistantControllerProvider.notifier);
  }

  @override
  void dispose() {
    // Leaving the page ends the running request (nobody is waiting for it, and
    // it would only spend tokens). Later, because the tree is locked now.
    final ctl = _ctl;
    Future.microtask(ctl.cancel);
    _input.dispose();
    super.dispose();
  }

  void _showPreview() {
    final text = _input.text.trim().isEmpty ? '…' : _input.text;
    final future = ref.read(assistantControllerProvider.notifier).preview(text);
    setState(() {
      _preview = future;
    });
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
    // an approval is being carried out: its buttons (and the question box)
    // wait, so a second tap cannot do it twice
    final applying = ref.watch(assistantApplyingProvider);
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
                maxLength: maxPromptLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
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
                    onPressed: (st.busy || applying) ? null : _send,
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
                      // (a chip is one line unless told otherwise: at a large
                      // text size a suggestion would be cut off)
                      label: Text(q, softWrap: true, maxLines: 3),
                      onPressed: (st.busy || applying) ? null : () => _send(q),
                    ),
                  // the program plans by itself: no key, no model, no tokens
                  ActionChip(
                    key: const Key('plan-local-chip'),
                    avatar: const Icon(Icons.offline_bolt_outlined, size: 18),
                    label: const Text(
                      'Terv AI nélkül',
                      softWrap: true,
                      maxLines: 3,
                    ),
                    tooltip: 'A program tervez a naptáradból, modell és kulcs nélkül (a következő 7 napra)',
                    onPressed: (st.busy || applying) ? null : ctl.planLocally,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _PreviewPanel(
                future: _preview,
                onOpen: _showPreview,
                onClose: () => setState(() {
                  _preview = null;
                }),
              ),
              const SizedBox(height: 8),
              if (st.busy) _Working(status: st.status, onCancel: ctl.cancel),
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
                            if (st.errorOffersLocalPlan)
                              FilledButton.tonalIcon(
                                key: const Key('plan-local-error'),
                                onPressed: (st.busy || applying)
                                    ? null
                                    : ctl.planLocally,
                                icon: const Icon(Icons.offline_bolt_outlined),
                                label: const Text('Helyi terv'),
                              ),
                            TextButton(
                              // (a plan the program made itself is made again,
                              // not asked of the model)
                              onPressed: st.prompt == localPlanPrompt
                                  ? ctl.planLocally
                                  : () => _send(st.prompt),
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
                      onPressed: ctl.dismissAccepted,
                      child: const Text('Rendben'),
                    ),
                  ),
                ),
              if (st.askWhy) const _WhyCard(),
              if (st.habitSaved)
                Card(
                  color: scheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.psychology_outlined),
                    title: const Text(
                      'Rögzítve a Tanult szokások közé (Beállítások → Kézikönyv).',
                    ),
                    trailing: TextButton(
                      onPressed: ctl.dismissHabit,
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
                      onPressed: ctl.dismissMoved,
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
                      onPressed: ctl.dismissDeleted,
                      child: const Text('Rendben'),
                    ),
                  ),
                ),
              if (o != null) _CostLine(outcome: o),
              if (o != null) ..._result(context, st, o, applying),
            ],
          ),
        ),
      ),
    );
  }
}
