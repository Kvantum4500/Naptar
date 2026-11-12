import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diag/diag_log.dart';
import '../diag/diag_snapshot.dart';
import '../diag/request_stats.dart';
import '../providers.dart';
import '../sync/channel_status.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import 'backup_io.dart';
import 'sync_status.dart' show showResetDialog;

/// Puts text on the clipboard (replaced by tests).
final clipboardWriterProvider = Provider<Future<void> Function(String)>(
  (_) =>
      (text) => Clipboard.setData(ClipboardData(text: text)),
);

/// What the app knows about its own health: the state of every sync channel,
/// the uploads Google refused (with the buttons to retry or give up on them),
/// how many requests were made, warnings, the log, and a report that can be
/// copied or saved. Everything stays on the device until the user copies it.
class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(diagSnapshotProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnosztika'),
        actions: [
          IconButton(
            key: const Key('diag-refresh'),
            tooltip: 'Frissítés',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(diagSnapshotProvider),
          ),
        ],
      ),
      body: snap.when(
        data: (s) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _Body(snapshot: s),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(errorInfoFor(e).text),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.snapshot});
  final DiagSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = snapshot;
    final ctl = ref.read(syncControllerProvider.notifier);
    final theme = Theme.of(context);

    Widget section(String title, List<Widget> children) => Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // ------------------------------------------------ warnings first
          section('Figyelmeztetések', [
            if (s.warnings.isEmpty)
              const Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 18),
                  SizedBox(width: 8),
                  Text('Nincs figyelmeztetés.'),
                ],
              )
            else
              for (final w in s.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(w.text, key: Key('diag-warning-${w.code}')),
                      ),
                    ],
                  ),
                ),
          ]),
          // ---------------------------------------------------- the app
          section('Alkalmazás', [
            Text(
              'Verzió: ${s.build == null ? 'ismeretlen' : 'build ${s.build}'}',
            ),
            Text('Platform: ${s.platform}'),
            Text(
              'Adatbázis: séma ${s.schema}'
              '${s.dbBytes == null ? '' : ', ${sizeText(s.dbBytes!)}'}',
            ),
            Text(
              'Tárolt elemek: '
              '${s.counts.entries.map((e) => '${e.key} ${e.value}').join(' · ')}',
            ),
          ]),
          // ---------------------------------------------------- the sync
          section('Szinkron', [
            Text('Bejelentkezve: ${s.signedIn ? 'igen' : 'nem'}'),
            Text(
              'Függő módosítás: ${s.pending}'
              '${s.parked > 0 ? ' (feladva: ${s.parked})' : ''}',
            ),
            if (s.nextAttempt != null)
              Text('Következő próba: ${diagTime(s.nextAttempt!)}'),
            const SizedBox(height: 8),
            for (final ch in syncChannels)
              _ChannelRow(name: channelLabels[ch]!, status: s.channels[ch]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('diag-sync-now'),
                  onPressed: s.signedIn
                      ? () => ctl.syncNow(manual: true)
                      : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('Szinkron most'),
                ),
                OutlinedButton.icon(
                  key: const Key('diag-reset'),
                  onPressed: s.signedIn
                      ? () => showResetDialog(context, ref)
                      : null,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Szinkron alaphelyzetbe…'),
                ),
              ],
            ),
          ]),
          // ------------------------------------------------ refused uploads
          if (s.failed.isNotEmpty)
            section('Elutasított módosítások', [
              const Text(
                'Ezeket a Google nem fogadta el. Az „Újrapróbálás” új esélyt '
                'ad nekik; az „Elvetés” leállítja a feltöltésüket (az esemény '
                'az eszközön marad).',
              ),
              const SizedBox(height: 8),
              for (final f in s.failed)
                ListTile(
                  key: Key('diag-failed-${f.seq}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(f.title.isEmpty ? '(cím nélkül)' : f.title),
                  subtitle: Text(
                    '${f.op == 'delete' ? 'Törlés' : 'Módosítás'}, '
                    '${f.attempts}. próba · ${f.reason}'
                    '${f.parked ? ' · feladva' : ''}',
                  ),
                  trailing: TextButton(
                    key: Key('diag-discard-${f.seq}'),
                    onPressed: () => _discard(context, ref, f),
                    child: const Text('Elvetés'),
                  ),
                ),
              const SizedBox(height: 4),
              FilledButton.tonalIcon(
                key: const Key('diag-retry'),
                onPressed: s.signedIn ? () => ctl.syncNow(manual: true) : null,
                icon: const Icon(Icons.replay),
                label: const Text('Újrapróbálás most'),
              ),
            ]),
          // ----------------------------------------------------- requests
          section('Google-kérések', _requestLines(s, ref)),
          // ----------------------------------------------------------- log
          section('Napló (utolsó ${s.log.length})', [
            if (s.log.isEmpty)
              const Text('A napló üres.')
            else
              for (final e in s.log.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    entryLine(e),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
          ]),
          // ---------------------------------------------------- the report
          section('Jelentés', [
            const Text(
              'A jelentésben számok, kódok, magyar mondatok és a hibák rövid, '
              'megtisztított első sora van; esemény-cím, összeg, jegyzet, '
              'e-mail-cím és kulcs nem kerül bele. A napló csak ezen az '
              'eszközön van; te döntöd el, kinek mutatod meg.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('diag-copy'),
                  onPressed: () => _copy(context, ref, s),
                  icon: const Icon(Icons.copy),
                  label: const Text('Másolás'),
                ),
                OutlinedButton.icon(
                  key: const Key('diag-save'),
                  onPressed: () => _save(context, ref, s),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Mentés fájlba'),
                ),
                TextButton.icon(
                  key: const Key('diag-clear'),
                  onPressed: () => _clearLog(context, ref),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Napló törlése…'),
                ),
              ],
            ),
          ]),
        ],
      ),
    );
  }

  List<Widget> _requestLines(DiagSnapshot s, WidgetRef ref) {
    final now = ref.read(appClockProvider)();
    final today = dayKeyOf(now);
    final yesterday = dayKeyOf(now.subtract(const Duration(days: 1)));
    final lines = <Widget>[];
    for (final day in [today, yesterday]) {
      for (final svc in requestServices) {
        final c = s.requests[day]?[svc];
        if (c == null || c.calls == 0) continue;
        final parts = [
          '${c.ok} rendben',
          if (c.client > 0) '${c.client} elutasítva',
          if (c.throttled > 0) '${c.throttled} korlátozva',
          if (c.server > 0) '${c.server} szerverhiba',
          if (c.failed > 0) '${c.failed} nem ért célba',
        ];
        lines.add(
          Text(
            '${day == today ? 'Ma' : 'Tegnap'} · ${serviceLabels[svc]}: '
            '${c.calls} hívás (${parts.join(', ')})',
            key: Key('diag-req-$day-$svc'),
          ),
        );
      }
    }
    return lines.isEmpty ? [const Text('Még nincs adat.')] : lines;
  }

  Future<void> _copy(
    BuildContext context,
    WidgetRef ref,
    DiagSnapshot s,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(clipboardWriterProvider)(renderReport(s));
      messenger.showSnackBar(
        const SnackBar(content: Text('A jelentés a vágólapra került.')),
      );
    } on Object catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'report.copy_failed', e, st);
      messenger.showSnackBar(
        SnackBar(
          content: Text('A másolás nem sikerült: ${errorInfoFor(e).text}'),
        ),
      );
    }
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    DiagSnapshot s,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    final t = s.at.toLocal();
    final name =
        'kvantum-diagnosztika-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}.txt';
    try {
      final saved = await ref
          .read(backupIoProvider)
          .save(
            name,
            renderReport(s),
            mimeType: 'text/plain',
            dialogTitle: 'Diagnosztikai jelentés mentése',
          );
      if (saved) {
        messenger.showSnackBar(const SnackBar(content: Text('Elmentve.')));
      }
    } on Object catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'report.save_failed', e, st);
      messenger.showSnackBar(
        SnackBar(
          content: Text('A mentés nem sikerült: ${errorInfoFor(e).text}'),
        ),
      );
    }
  }

  Future<void> _clearLog(BuildContext context, WidgetRef ref) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Törlöd a naplót?'),
        content: const Text(
          'A napló csak ezen az eszközön van. Törlés után a hibakeresés '
          'nehezebb lehet, ha valami ismétlődik.',
        ),
        actions: [
          TextButton(
            key: const Key('diag-clear-cancel'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            key: const Key('diag-clear-go'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Törlöm'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await ref.read(diagLogProvider).clear();
    ref.invalidate(diagSnapshotProvider);
  }

  Future<void> _discard(
    BuildContext context,
    WidgetRef ref,
    DiagFailedItem f,
  ) async {
    final what = f.title.isEmpty ? 'az esemény' : '„${f.title}”';
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Elveted a feltöltést?'),
        content: Text(
          f.op == 'delete'
              ? 'A(z) $what törlése nem kerül át a Google-naptárba: az '
                    'esemény ott megmarad (egy teljes újraszinkron '
                    'visszahozhatja ide is).'
              : 'A(z) $what módosítása nem kerül fel a Google-naptárba. Az '
                    'esemény az eszközön marad; ha újra szerkeszted, újra '
                    'sorba kerül.',
        ),
        actions: [
          TextButton(
            key: const Key('diag-discard-cancel'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            key: const Key('diag-discard-go'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Elvetem'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await ref.read(repoProvider).discardOutbox(f.seq);
    ref
        .read(diagLogProvider)
        .info('ui', 'outbox.discarded', data: {'op': f.op, 'try': f.attempts});
    ref.invalidate(diagSnapshotProvider);
    ref.read(syncControllerProvider.notifier).requestSync();
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.name, required this.status});
  final String name;
  final ChannelStatus? status;

  @override
  Widget build(BuildContext context) {
    final st = status;
    final scheme = Theme.of(context).colorScheme;
    final String detail;
    if (st == null) {
      detail = 'még nem volt futás';
    } else {
      detail =
          'utolsó próba ${st.lastTry == null ? '–' : diagTime(st.lastTry!)}'
          ' · utolsó siker ${st.lastOk == null ? '–' : diagTime(st.lastOk!)}';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            st == null || st.ok
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: 18,
            color: st == null || st.ok ? null : scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.labelLarge),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
                if (st?.text != null)
                  Text(
                    st!.text!,
                    key: Key('diag-channel-${st.code}'),
                    style: TextStyle(color: scheme.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
