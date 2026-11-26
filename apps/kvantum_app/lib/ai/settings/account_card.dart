import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/photo_sync_switch.dart';
import '../../sync/sync_controller.dart';
import '../../ui/diagnostics_page.dart';
import '../../ui/format.dart';
import '../../ui/sync_status.dart';

/// The heading above a group of cards in Settings. The page is one list that
/// scrolls; the headings tell the groups apart (and a screen reader jumps
/// from heading to heading).
class SettingsGroupHeader extends StatelessWidget {
  const SettingsGroupHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// The Google account and the sync, in Settings: signed in or not, how the
/// last run went, and the same buttons as the sync menu of the calendar bar
/// (which is not on every screen).
class AccountSyncBody extends ConsumerWidget {
  const AccountSyncBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);
    final ctl = ref.read(syncControllerProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;

    if (!s.configured) {
      return const Text(noGoogleBody, key: Key('account-not-configured'));
    }

    if (!s.signedIn) {
      // a login that expired says so; one tap signs in again
      final expired = s.error != null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            expired
                ? s.error!
                : 'Nem vagy bejelentkezve. A naptár, a feladatok és a '
                      'pénzügyek addig csak ezen az eszközön vannak, amíg be '
                      'nem lépsz Google-fiókkal.',
            key: const Key('account-signed-out'),
            style: expired ? TextStyle(color: scheme.error) : null,
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const Key('account-sign-in'),
            onPressed: ctl.signIn,
            icon: const Icon(Icons.login),
            label: Text(expired ? 'Belépés szükséges' : 'Belépés Google-lal'),
          ),
        ],
      );
    }

    final summary = syncSummary(s, now: ref.watch(syncClockProvider)());
    final color = syncToneColor(summary.tone, scheme);
    // a failed or given-up sync is retried from the same button
    final retry = s.error != null || s.parked > 0;
    final last = s.lastSync == null
        ? 'még nem volt'
        : '${fmtDate(s.lastSync!)} ${fmtTime(s.lastSync!)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            s.syncing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(summary.icon, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary.label,
                key: const Key('account-status'),
                style: theme.textTheme.titleSmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('Utolsó sikeres szinkron: $last', style: small),
        if (s.nextAttempt != null)
          Text(
            'Következő automatikus próba: ${fmtTime(s.nextAttempt!)}',
            style: small,
          ),
        if (s.pending > 0)
          Text(
            '${s.pending} módosítás vár feltöltésre'
            '${s.parked > 0 ? ' (${s.parked} elakadt)' : ''}',
            style: small,
          ),
        if (s.error != null)
          Text(
            s.error!,
            key: const Key('account-error'),
            style: small?.copyWith(color: scheme.error),
          ),
        if (s.photoNote != null)
          Text(
            s.photoNote!,
            key: const Key('account-photo-note'),
            style: small,
          ),
        const SizedBox(height: 4),
        SwitchListTile(
          key: const Key('photo-sync-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Képek szinkronja'),
          subtitle: const Text(photoSyncSwitchHelp),
          value: ref.watch(photoSyncSwitchProvider),
          onChanged: (on) => ref.read(photoSyncSwitchProvider.notifier).set(on),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (s.mismatch != null)
              FilledButton(
                key: const Key('account-decide'),
                onPressed: () => showBindingDialog(context, ref, s.mismatch!),
                child: const Text('Másik fiók / naptár: döntés kell…'),
              ),
            FilledButton.tonalIcon(
              key: const Key('account-sync-now'),
              onPressed: () => ctl.syncNow(manual: true),
              icon: const Icon(Icons.sync),
              label: Text(retry ? 'Újrapróbálás most' : 'Szinkron most'),
            ),
            OutlinedButton.icon(
              key: const Key('account-diagnostics'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DiagnosticsPage(),
                ),
              ),
              icon: const Icon(Icons.monitor_heart_outlined),
              label: const Text('Diagnosztika'),
            ),
            OutlinedButton.icon(
              key: const Key('account-reset'),
              onPressed: () => showResetDialog(context, ref),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Szinkron alaphelyzetbe…'),
            ),
            TextButton.icon(
              key: const Key('account-sign-out'),
              onPressed: ctl.signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Kilépés a Google-fiókból'),
            ),
          ],
        ),
      ],
    );
  }
}
