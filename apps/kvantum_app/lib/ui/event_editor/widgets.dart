part of '../event_editor.dart';

// The colour choice and the "where does this event come from" badge of the
// editor. Part of the library of the editor.

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget dot(String? id, Color c, String tip) => Tooltip(
      message: tip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onChanged(id),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: value == id
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: value == id
              ? Icon(Icons.check, size: 16, color: onEventColor(c))
              : null,
        ),
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        dot(null, defaultEventColor, 'Alapértelmezett'),
        for (final e in eventColorChoices)
          dot(e.key, e.value, eventColorNames[e.key] ?? e.key),
      ],
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.event});
  final CalEvent? event;
  @override
  Widget build(BuildContext context) {
    if (event == null) {
      return const Text(
        'Mentés után a Google „Naptar” naptárába szinkronizálódik.',
        style: TextStyle(fontSize: 12),
      );
    }
    final synced = event!.googleId != null;
    return Row(
      children: [
        Icon(
          synced ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
          size: 16,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            [
              synced
                  ? 'Szinkronban a Google-lel'
                  : 'Még nincs elküldve a Google-nek',
              if (event!.aiGenerated) 'AI-javaslatból jött',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
