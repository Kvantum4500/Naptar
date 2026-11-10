import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_controller.dart';
import '../update/update_dialog.dart' show currentBuildProvider;
import 'format.dart';

/// Always-visible sync indicator in the app bar, with a details menu.
class SyncStatusButton extends ConsumerWidget {
  const SyncStatusButton({
    super.key,
    required this.onCheckUpdate,
    this.compact = false,
  });
  final VoidCallback onCheckUpdate;

  /// Icon-only variant for narrow windows (the label moves into the tooltip).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);
    final ctl = ref.read(syncControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    if (!s.configured) {
      void help() => _info(
        context,
        'Google nincs beállítva',
        'Add meg a GOOGLE_CLIENT_ID és GOOGLE_CLIENT_SECRET értéket a secrets.json fájlban, '
            'és indítsd így:\nflutter run --dart-define-from-file=secrets.json',
      );
      return compact
          ? IconButton(
              tooltip: 'Google nincs beállítva',
              onPressed: help,
              icon: const Icon(Icons.cloud_off_outlined),
            )
          : TextButton.icon(
              onPressed: help,
              icon: const Icon(Icons.cloud_off_outlined, size: 18),
              label: const Text('Nincs Google'),
            );
    }
    if (!s.signedIn && s.error != null) {
      // the login expired: say so, one tap signs in again
      return compact
          ? IconButton(
              tooltip: s.error,
              onPressed: ctl.signIn,
              icon: Icon(Icons.error_outline, color: scheme.error),
            )
          : TextButton.icon(
              onPressed: ctl.signIn,
              icon: Icon(Icons.error_outline, size: 18, color: scheme.error),
              label: Text(
                'Belépés szükséges',
                style: TextStyle(color: scheme.error),
              ),
            );
    }
    if (!s.signedIn) {
      return compact
          ? IconButton(
              tooltip: 'Belépés Google-lal',
              onPressed: ctl.signIn,
              icon: const Icon(Icons.login),
            )
          : TextButton.icon(
              onPressed: ctl.signIn,
              icon: const Icon(Icons.login, size: 18),
              label: const Text('Belépés Google-lal'),
            );
    }

    final stale =
        s.lastSync != null &&
        DateTime.now().difference(s.lastSync!) > const Duration(minutes: 10);
    final (IconData icon, String label, Color color) = s.syncing
        ? (Icons.sync, 'Szinkronizál…', scheme.primary)
        : s.error != null
        ? (Icons.error_outline, 'Hiba', scheme.error)
        : s.pending > 0
        ? (
            Icons.cloud_upload_outlined,
            '${s.pending} függőben',
            scheme.tertiary,
          )
        : stale
        ? (Icons.schedule, 'Régi adat', scheme.tertiary)
        : (
            Icons.cloud_done_outlined,
            s.lastSync == null
                ? 'Szinkronban'
                : 'Szinkronban ${_hm(s.lastSync!)}',
            scheme.primary,
          );

    return PopupMenuButton<String>(
      tooltip: compact ? label : 'Szinkron és fiók',
      onSelected: (v) {
        switch (v) {
          case 'sync':
            ctl.syncNow();
          case 'details':
            () async {
              final build = await ref.read(currentBuildProvider.future);
              if (!context.mounted) return;
              _info(
                context,
                'Szinkronállapot',
                'Verzió: build $build\n'
                    'Utolsó sikeres szinkron: ${s.lastSync == null ? 'még nem volt' : '${fmtDate(s.lastSync!)} ${_hm(s.lastSync!)}'}\n'
                    'Függő módosítás: ${s.pending}\n'
                    'Naptár: Google „Naptar”\n'
                    '${s.financeNote == null ? '' : '${s.financeNote}\n'}'
                    '${s.error == null ? 'Hiba: nincs' : 'Hiba: ${s.error}'}',
              );
            }();
          case 'update':
            onCheckUpdate();
          case 'out':
            ctl.signOut();
        }
      },
      itemBuilder: (c) => [
        const PopupMenuItem(value: 'sync', child: Text('Szinkron most')),
        const PopupMenuItem(value: 'details', child: Text('Részletek')),
        const PopupMenuItem(value: 'update', child: Text('Frissítés keresése')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'out',
          child: Text('Kilépés a Google-fiókból'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            s.syncing
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(icon, size: 18, color: color),
            if (!compact) ...[
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  static String _hm(DateTime t) => fmtTime(t);

  static void _info(BuildContext context, String title, String body) =>
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SelectableText(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Rendben'),
            ),
          ],
        ),
      );
}
