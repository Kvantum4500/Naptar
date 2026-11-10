import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';
import 'wallet_ingest.dart';

/// Settings block for reading Google Wallet payment notifications (Android).
class WalletSettings extends ConsumerStatefulWidget {
  const WalletSettings({super.key});

  @override
  ConsumerState<WalletSettings> createState() => _WalletSettingsState();
}

class _WalletSettingsState extends ConsumerState<WalletSettings>
    with WidgetsBindingObserver {
  bool? _enabled;
  bool _auto = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // coming back from the system settings page
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final bridge = ref.read(walletBridgeProvider);
    if (!bridge.supported) return;
    final enabled = await bridge.isEnabled();
    final auto = await ref.read(walletIngestProvider).auto;
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _auto = auto;
      });
    }
  }

  Future<void> _showLog() async {
    final log = await ref.read(walletIngestProvider).log();
    if (!mounted) return;
    String line(WalletLogEntry e) {
      final t = DateFormat(
        'MM.dd HH:mm',
        'hu',
      ).format(DateTime.fromMillisecondsSinceEpoch(e.timeMs));
      final what = switch (e.result) {
        'booked' =>
          'felvéve: ${formatHuf(e.amount ?? 0)}${e.merchant.isEmpty ? '' : ' · ${e.merchant}'}',
        'foreign' => 'más pénznem, nem vettem fel',
        'duplicate' => 'már fel volt véve',
        _ => 'nem fizetés, kihagytam',
      };
      return '$t | ${e.title} | ${e.text}\n   → $what';
    }

    final text = log.isEmpty
        ? 'Még nem érkezett Wallet-értesítés.'
        : log.reversed.map(line).join('\n\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Legutóbbi Wallet-értesítések'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          if (log.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx)
                      .showSnackBar(const SnackBar(content: Text('Kimásolva')));
                }
              },
              child: const Text('Másolás'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Bezár'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(walletBridgeProvider);
    if (!bridge.supported) {
      return const Text(
        'A Google Wallet értesítéseinek beolvasása csak Androidon működik. A telefonon felvett tételek a Drive-on át átmennek ide is.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'A fizetési értesítésekből (összeg, kereskedő) magától tételt vesz fel. Csak a Google Wallet értesítéseit olvassa, csak ezen a telefonon, és csak a címet, a szöveget és az időt tárolja (a kártyaszám-szerű számokat kimaszkolja).',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              _enabled == true ? Icons.check_circle : Icons.error_outline,
              color: _enabled == true
                  ? Colors.green
                  : Theme.of(context).colorScheme.error,
              size: 18,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _enabled == null
                    ? 'Állapot ellenőrzése…'
                    : _enabled!
                    ? 'Az értesítés-hozzáférés meg van adva.'
                    : 'Az értesítés-hozzáférés nincs megadva.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: bridge.openListenerSettings,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Hozzáférés megadása'),
            ),
            OutlinedButton.icon(
              onPressed: _showLog,
              icon: const Icon(Icons.list_alt),
              label: const Text('Legutóbbi értesítések'),
            ),
          ],
        ),
        if (_enabled == false) ...[
          const SizedBox(height: 8),
          Text(
            'Ha a rendszer szürkén mutatja vagy tiltja a hozzáférést (az APK-t nem az áruházból telepítetted): Alkalmazás-infó → jobb felső ⋮ → „Korlátozott beállítások engedélyezése”, utána próbáld újra.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton(
            onPressed: bridge.openAppInfo,
            child: const Text('Alkalmazás-infó megnyitása'),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatikus felvétel'),
          subtitle: const Text(
            'Ha kikapcsolod, az értesítésekből nem készül tétel.',
          ),
          value: _auto,
          onChanged: (v) async {
            await ref.read(walletIngestProvider).setAuto(v);
            setState(() => _auto = v);
          },
        ),
      ],
    );
  }
}
