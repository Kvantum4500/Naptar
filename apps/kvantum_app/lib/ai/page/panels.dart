part of '../assistant_page.dart';

// The small widgets of the page: the "working" row, the "why" card, the cost
// line, the "what is sent" panel and the card of an answer the program gave by
// itself. Part of the library of the page.

class _Working extends StatelessWidget {
  const _Working({this.status, required this.onCancel});
  final String? status;
  final VoidCallback onCancel;
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
        TextButton(onPressed: onCancel, child: const Text('Mégse')),
      ],
    ),
  );
}

const _whyChips = [
  'Ne tervezz edzést reggel 8 előtt.',
  'Ne tervezz edzést este 8 után.',
  'Ne tervezz két nehéz edzést egymás után.',
  'Rossz napon inkább csak könnyű edzés legyen.',
];

/// After "Elvetem": the user may tell why; only their own sentence is saved,
/// and only when they press "Megjegyzem".
class _WhyCard extends ConsumerStatefulWidget {
  const _WhyCard();

  @override
  ConsumerState<_WhyCard> createState() => _WhyCardState();
}

class _WhyCardState extends ConsumerState<_WhyCard> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = ref.read(assistantControllerProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Szeretnéd, hogy megjegyezzem, miért?',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'A mondatod bekerül a „Tanult szokások” közé, és a következő tervezéskor figyelembe veszi. Csak ezt mentem el, és csak ha megnyomod a gombot.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in _whyChips)
                  ActionChip(
                    label: Text(c, softWrap: true, maxLines: 3),
                    onPressed: () => setState(() => _text.text = c),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: 'pl. Ne tervezz edzést reggel 8 előtt.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _text.text.trim().isEmpty
                      ? null
                      : () => ctl.rememberHabit(_text.text),
                  child: const Text('Megjegyzem'),
                ),
                TextButton(
                  onPressed: ctl.skipHabit,
                  child: const Text('Nem most'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the last request cost: the provider's own numbers, or the program's
/// estimate of the first request when the provider said nothing.
class _CostLine extends StatelessWidget {
  const _CostLine({required this.outcome});
  final AssistantOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final LlmUsage? u = outcome.usage;
    final int? est = outcome.estimatedTokens;
    final int calls = outcome.calls;
    final String text;
    if (u != null) {
      text =
          'Utolsó kérés: ${spaced(u.total)} token (be ${spaced(u.prompt)} · ki ${spaced(u.output)}'
          '${u.thinking > 0 ? ' · gondolkodás ${spaced(u.thinking)}' : ''}'
          '${u.cached > 0 ? ' · ebből gyorsítótárból ${spaced(u.cached)}' : ''}'
          ')${calls > 1 ? ' · $calls hívás' : ''}';
    } else if (est != null) {
      text =
          'Utolsó kérés: ≈ ${spaced(est)} token (becslés; a szolgáltató nem közölt adatot)';
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// A collapsible look at exactly what is sent to the model.
class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.future,
    required this.onOpen,
    required this.onClose,
  });
  final Future<PreparedRequest>? future;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 11.5);
    return ExpansionTile(
      key: const Key('preview-panel'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Mit küldünk a modellnek?'),
      onExpansionChanged: (open) => open ? onOpen() : onClose(),
      children: [
        if (future != null)
          FutureBuilder<PreparedRequest>(
            future: future,
            builder: (context, snap) {
              if (snap.hasError) {
                return const Text('Az előnézet most nem készíthető el.');
              }
              final r = snap.data;
              if (r == null) {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Az előnézet készül',
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Becsült méret: ≈ ${spaced(r.estimatedTokens)} token '
                    '(utasítás ${spaced(r.systemTokens)} · eszközök ${spaced(r.toolsTokens)} · adat és kérés ${spaced(r.messageTokens)})',
                    style: small,
                  ),
                  for (final b in r.blocks)
                    Text(
                      '  • ${b.name}: ≈ ${spaced(b.tokens)} token',
                      style: small,
                    ),
                  if (r.reductions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'A méretkorlát miatt kimarad: ${r.reductions.join('; ')}.',
                        style: small,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Frissítés a beírt kéréssel'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('A kérés szövege (adatok, idő, kérésed)'),
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxHeight: 260),
                        width: double.infinity,
                        child: SingleChildScrollView(
                          child: SelectableText(r.firstMessage, style: mono),
                        ),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Utasítások a modellnek'),
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxHeight: 260),
                        width: double.infinity,
                        child: SingleChildScrollView(
                          child: SelectableText(r.system, style: mono),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// An answer the program gave by itself, from the data on the device, with no
/// model: marked as such, and open to a further question that DOES go to the
/// model (with the answer as context, where the sharing switches allow it).
class _LocalCard extends StatefulWidget {
  const _LocalCard({required this.answer, required this.onAsk});
  final LocalAnswer answer;
  final void Function(String question) onAsk;

  @override
  State<_LocalCard> createState() => _LocalCardState();
}

class _LocalCardState extends State<_LocalCard> {
  final _more = TextEditingController();

  @override
  void dispose() {
    _more.dispose();
    super.dispose();
  }

  void _ask() {
    final q = _more.text.trim();
    if (q.isNotEmpty) widget.onAsk(q);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final isPlan = widget.answer.kind == LocalKind.plan;
    final canAsk = widget.answer.kind != LocalKind.switchedOff && !isPlan;
    return Card(
      key: const Key('local-answer'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.offline_bolt_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    isPlan
                        ? 'Helyi terv, modell nélkül'
                        : 'Helyi válasz, modell nélkül',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: scheme.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(widget.answer.text),
            if (canAsk) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('local-more'),
                controller: _more,
                maxLength: maxPromptLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _ask(),
                decoration: InputDecoration(
                  labelText: 'További kérdés',
                  hintText: widget.answer.kind == LocalKind.budget
                      ? 'pl. Miből spórolhatnék a legtöbbet?'
                      : 'pl. Mikor férne be egy edzés?',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const Key('local-more-send'),
                  onPressed: _ask,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Kérdezd a modellt is'),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'A kérdés a modellhez megy. Ennek a válasznak a szövege csak akkor megy vele, ha a Beállításokban az érintett adat megosztása be van kapcsolva.',
                style: small,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
