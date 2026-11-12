import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/error_catalog.dart';
import '../sync/remote.dart' show SyncBindingMismatch;
import '../sync/sync_controller.dart';
import '../update/update_dialog.dart' show currentBuildProvider;
import 'format.dart';
import 'diagnostics_page.dart';

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
        'Nincs Google-hozzáférés',
        'Ebben a buildben nincs beállítva a Google-bejelentkezés, ezért a '
            'naptár és a Drive szinkronja nem érhető el. A kiadott csomagban '
            'ez be van állítva: azt telepítsd.',
      );
      return compact
          ? IconButton(
              tooltip: 'Nincs Google-hozzáférés',
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
        : s.mismatch != null
        ? (Icons.sync_problem, 'Döntés kell', scheme.error)
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
            ctl.syncNow(manual: true);
          case 'decide':
            showBindingDialog(context, ref, s.mismatch!);
          case 'reset':
            showResetDialog(context, ref);
          case 'diag':
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
            );
          case 'details':
            () async {
              final build = await ref.read(currentBuildProvider.future);
              if (!context.mounted) return;
              _info(
                context,
                'Szinkronállapot',
                'Verzió: build $build\n'
                    'Utolsó sikeres szinkron: ${s.lastSync == null ? 'még nem volt' : '${fmtDate(s.lastSync!)} ${_hm(s.lastSync!)}'}\n'
                    '${s.nextAttempt == null ? '' : 'Következő automatikus próba: ${_hm(s.nextAttempt!)}\n'}'
                    'Függő módosítás: ${s.pending}\n'
                    '${s.parked == 0 ? '' : 'Ebből feladva: ${s.parked} (a „Szinkron most” újra megpróbálja)\n'}'
                    'Naptár: Google „Naptar”\n'
                    '${s.mismatch == null ? '' : 'Döntés kell: másik Google-fiók vagy naptár\n'}'
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
        if (s.mismatch != null)
          const PopupMenuItem(
            value: 'decide',
            child: Text('Másik fiók / naptár: döntés kell…'),
          ),
        const PopupMenuItem(value: 'sync', child: Text('Szinkron most')),
        const PopupMenuItem(value: 'details', child: Text('Részletek')),
        const PopupMenuItem(value: 'diag', child: Text('Diagnosztika')),
        const PopupMenuItem(
          value: 'reset',
          child: Text('Szinkron alaphelyzetbe…'),
        ),
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

/// "Szinkron alaphelyzetbe": explains and asks before it does anything.
Future<void> showResetDialog(BuildContext context, WidgetRef ref) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text(resetTitle),
      content: const SingleChildScrollView(child: Text(resetBody)),
      actions: [
        TextButton(
          key: const Key('reset-cancel'),
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Mégse'),
        ),
        FilledButton(
          key: const Key('reset-go'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Alaphelyzetbe'),
        ),
      ],
    ),
  );
  if (go == true) await ref.read(syncControllerProvider.notifier).resetSync();
}

/// This device was linked to another Google account / calendar: three ways
/// out, none of which loses anything without asking.
Future<void> showBindingDialog(
  BuildContext context,
  WidgetRef ref,
  SyncBindingMismatch m,
) async {
  final ctl = ref.read(syncControllerProvider.notifier);
  final count = await ctl.localEventCount();
  if (!context.mounted) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(
        m.accountChanged ? bindingTitleAccount : bindingTitleCalendar,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bindingBody(
                accountChanged: m.accountChanged,
                stored: m.stored.maskedAccount,
                current: m.current.maskedAccount,
              ),
            ),
            const SizedBox(height: 12),
            Text(bindingKeepTitle, style: Theme.of(c).textTheme.labelLarge),
            const Text(bindingKeepBody),
            const SizedBox(height: 8),
            Text(bindingFreshTitle, style: Theme.of(c).textTheme.labelLarge),
            const Text(bindingFreshBody),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('binding-later'),
          onPressed: () => Navigator.pop(c),
          child: const Text('Később'),
        ),
        TextButton(
          key: const Key('binding-fresh'),
          onPressed: () => Navigator.pop(c, 'fresh'),
          child: const Text('Üres indulás…'),
        ),
        FilledButton(
          key: const Key('binding-keep'),
          onPressed: () => Navigator.pop(c, 'keep'),
          child: const Text('Megtartom és feltöltöm'),
        ),
      ],
    ),
  );
  if (choice == 'keep') {
    await ctl.keepLocalAfterMismatch();
  } else if (choice == 'fresh') {
    if (count > 0) {
      if (!context.mounted) return;
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text(bindingFreshTitle),
          content: Text(bindingFreshConfirm(count)),
          actions: [
            TextButton(
              key: const Key('fresh-cancel'),
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Mégse'),
            ),
            FilledButton(
              key: const Key('fresh-go'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Törlöm és letöltöm'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    await ctl.startFreshAfterMismatch();
  }
}
