import 'package:flutter/material.dart';

import '../data/backup_ops.dart';

/// What to do with events that changed on this device since the backup file
/// was written.
enum ImportChoice { all, onlyNew }

/// Asks before a restore overwrites events of this device. Returns null when
/// the user cancels (nothing is written then).
Future<ImportChoice?> askImportChoice(BuildContext context, ImportPlan plan) {
  final fresh = plan.fresh.length;
  final changed = plan.changes.length;
  final names = <String>{for (final c in plan.changes) c.current.title}
      .take(5)
      .toList();
  final more = changed - names.length;
  final lead = fresh == 0
      ? 'A fájlban nincs új esemény, de $changed olyan van, amely az '
            'eszközön azóta másképp néz ki.'
      : 'A fájlban $fresh új esemény van, és $changed olyan, amely az '
            'eszközön azóta másképp néz ki.';
  return showDialog<ImportChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('import-choice'),
      title: const Text('Felülírjam a módosult eseményeket?'),
      content: Text(
        '$lead\n\nHa felülírod őket, a fájl szerinti állapotra állnak '
        'vissza, és a mostani módosításaid elvesznek.\n\n'
        'Érintett: ${names.join(', ')}${more > 0 ? ' és még $more' : ''}.',
      ),
      actions: [
        TextButton(
          key: const Key('import-cancel'),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Mégse'),
        ),
        if (fresh > 0)
          OutlinedButton(
            key: const Key('import-new'),
            onPressed: () => Navigator.pop(ctx, ImportChoice.onlyNew),
            child: const Text('Csak az újak'),
          ),
        FilledButton(
          key: const Key('import-all'),
          onPressed: () => Navigator.pop(ctx, ImportChoice.all),
          child: Text(fresh > 0 ? 'Mind' : 'Felülírás'),
        ),
      ],
    ),
  );
}
