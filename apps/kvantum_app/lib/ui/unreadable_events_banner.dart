import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';

/// Events the app cannot expand (an unreadable repeat rule, an unknown time
/// zone). They stay stored but are not shown, so the user is told instead of
/// wondering where they went.
final unreadableEventsProvider = FutureProvider.autoDispose<List<CalEvent>>((
  ref,
) async {
  ref.watch(eventsTickProvider); // look again whenever any event changes
  return ref.watch(repoProvider).unreadableEvents();
});

/// Slim warning under the check-in banner; empty when everything is readable.
class UnreadableEventsBanner extends ConsumerWidget {
  const UnreadableEventsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list =
        ref.watch(unreadableEventsProvider).value ?? const <CalEvent>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer.withValues(alpha: .7),
      child: InkWell(
        onTap: () => _details(context, ref, list),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  list.length == 1
                      ? '1 esemény ismétlődési szabályát nem tudom olvasni, ezért nem látszik a naptárban.'
                      : '${list.length} esemény ismétlődési szabályát nem tudom olvasni, ezért nem látszanak a naptárban.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () => _details(context, ref, list),
                child: const Text('Részletek'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _details(
    BuildContext context,
    WidgetRef ref,
    List<CalEvent> list,
  ) async {
    final convert = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nem olvasható ismétlődés'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ezeket az eseményeket nem tudom megjeleníteni, mert az ismétlődési szabályuk ismeretlen formájú. '
                'Nem vesztek el: a Google Naptárban kijavíthatod őket, vagy itt egyszeri eseménnyé alakíthatod '
                '(az első alkalom marad meg, az ismétlődés megszűnik).',
              ),
              const SizedBox(height: 12),
              for (final e in list.take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '• ${e.title.isEmpty ? '(cím nélkül)' : e.title}'
                    '${e.rrule == null ? '' : '\n   ${e.rrule}'}',
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                ),
              if (list.length > 10) Text('… és még ${list.length - 10}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Bezár'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Egyszeri eseménnyé alakít'),
          ),
        ],
      ),
    );
    if (convert != true) return;
    final repo = ref.read(repoProvider);
    for (final e in list) {
      if (e.isRecurring) await repo.saveLocal(e.copyWith(clearRrule: true));
    }
  }
}
