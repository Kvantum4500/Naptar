import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'format.dart';

const _questions = [
  ('physical', 'Fizikai energia', 'fáradt', 'energikus'),
  ('mental', 'Mentális energia', 'kimerült', 'fókuszált'),
  ('mood', 'Hangulat', 'rossz', 'kiváló'),
  ('sleep', 'Alvás', 'rossz', 'kiváló'),
];

/// Banner at the top of the home page: today's check-in (answer or edit).
class CheckInBanner extends ConsumerWidget {
  const CheckInBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(checkInsProvider).value ?? const <CheckInView>[];
    final today = list
        .where((c) => c.date == ref.watch(todayProvider))
        .firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    String show(int? v) => v == null ? '–' : '$v';
    return Material(
      color: today == null
          ? scheme.tertiaryContainer.withValues(alpha: .6)
          : scheme.surfaceContainerHighest.withValues(alpha: .5),
      child: InkWell(
        onTap: () => openCheckIn(context, ref, existing: today),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                today == null ? Icons.favorite_border : Icons.favorite,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  today == null
                      ? 'Hogy vagy ma? Töltsd ki a napi check-int (10 másodperc).'
                      : 'Mai check-in: fizikai ${show(today.physical)} · mentális ${show(today.mental)} · hangulat ${show(today.mood)} · alvás ${show(today.sleep)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () => openCheckIn(context, ref, existing: today),
                child: Text(today == null ? 'Kitöltöm' : 'Módosít'),
              ),
              IconButton(
                tooltip: 'Előzmények',
                icon: const Icon(Icons.history),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CheckInHistoryPage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> openCheckIn(
  BuildContext context,
  WidgetRef ref, {
  CheckInView? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => CheckInDialog(existing: existing),
);

class CheckInDialog extends ConsumerStatefulWidget {
  const CheckInDialog({super.key, this.existing});
  final CheckInView? existing;
  @override
  ConsumerState<CheckInDialog> createState() => _CheckInDialogState();
}

class _CheckInDialogState extends ConsumerState<CheckInDialog> {
  late final Map<String, int?> _v;
  late final TextEditingController _note;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _v = {
      'physical': e?.physical,
      'mental': e?.mental,
      'mood': e?.mood,
      'sleep': e?.sleep,
    };
    _note = TextEditingController(text: e?.note ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_v.values.every((x) => x == null)) {
      setState(() => _error = 'Válaszolj legalább egy kérdésre.');
      return;
    }
    final fields = checkInFields(
      physical: _v['physical'],
      mental: _v['mental'],
      mood: _v['mood'],
      sleep: _v['sleep'],
      note: _note.text,
    );
    await ref
        .read(recordRepoProvider)
        .edit(kindCheckIn, checkInId(ref.read(todayProvider)), fields);
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Napi check-in'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (key, label, low, high) in _questions) ...[
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 1; i <= 5; i++)
                      ChoiceChip(
                        key: Key('$key-$i'),
                        label: Text('$i'),
                        selected: _v[key] == i,
                        onSelected: (on) {
                          // tapping the chosen value again keeps it (an
                          // answer is never silently dropped)
                          if (on) setState(() => _v[key] = i);
                        },
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 4),
                  // (each half may wrap: a large system font must not push the
                  // end of the scale off the dialog)
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '1 = $low',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '5 = $high',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Megjegyzés (nem kötelező)',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(onPressed: _save, child: const Text('Mentés')),
      ],
    );
  }
}

/// The last 30 days of check-ins as a simple list with colour-coded values.
class CheckInHistoryPage extends ConsumerWidget {
  const CheckInHistoryPage({super.key});

  Color _c(int? v, ColorScheme s) => switch (v) {
    null => s.outlineVariant,
    1 || 2 => s.error,
    3 => s.tertiary,
    _ => s.primary,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = (ref.watch(checkInsProvider).value ?? const <CheckInView>[])
        .take(30)
        .toList();
    final scheme = Theme.of(context).colorScheme;
    Widget dot(String label, int? v) => Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _c(v, scheme),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$label ${v ?? '–'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Check-in előzmények')),
      body: list.isEmpty
          ? const Center(child: Text('Még nincs check-in.'))
          : ListView(
              children: [
                for (final c in list)
                  ListTile(
                    title: Text(fmtDateLong(c.date!)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          children: [
                            dot('Fizikai', c.physical),
                            dot('Mentális', c.mental),
                            dot('Hangulat', c.mood),
                            dot('Alvás', c.sleep),
                          ],
                        ),
                        if (c.note.isNotEmpty) Text(c.note),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
