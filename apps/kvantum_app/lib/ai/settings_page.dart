import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/update_dialog.dart';
import 'ai_providers.dart';
import 'ai_settings.dart';
import 'handbook_page.dart';
import 'llm_provider.dart';
import 'provider_catalog.dart';

/// App settings: AI provider + key + model, what the assistant may see, handbook.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _key = TextEditingController();
  final _base = TextEditingController();
  bool _hasKey = false;
  bool _busy = false;
  bool _show = false;
  String? _message;
  bool _messageIsError = false;
  List<LlmModel> _models = const [];
  String? _loadedFor;

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    super.dispose();
  }

  /// Reads whether a key exists for [provider] (called when it changes).
  Future<void> _refresh(AiSettings s) async {
    _loadedFor = s.provider;
    final k = await ref.read(apiKeyStoreProvider).read(provider: s.provider);
    if (!mounted) return;
    setState(() {
      _hasKey = k != null;
      _models = const [];
      _message = null;
      _key.clear();
      _base.text = s.customBaseUrl ?? '';
    });
  }

  void _say(String m, {bool error = false}) => setState(() {
    _message = m;
    _messageIsError = error;
  });

  Future<void> _saveAndCheck(AiSettings settings) async {
    final info = providerById(settings.provider);
    final typed = _key.text.trim();
    final store = ref.read(apiKeyStoreProvider);
    final key = typed.isNotEmpty ? typed : await store.read(provider: info.id);
    if (key == null && !info.keyOptional) {
      _say('Írd be az API-kulcsot.', error: true);
      return;
    }
    final base = info.id == 'custom' ? _base.text.trim() : null;
    if (info.id == 'custom' && (base == null || base.isEmpty)) {
      _say('Add meg a szolgáltató címét.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final models = await ref
          .read(llmFactoryProvider)(
            LlmConfig(provider: info.id, apiKey: key ?? '', baseUrl: base),
          )
          .listModels();
      if (models.isEmpty) {
        _say(
          'A kulcs érvényes, de nem találtam használható modellt.',
          error: true,
        );
        return;
      }
      await store.write(
        key,
        provider: info.id,
      ); // only a key that works is kept
      _key.clear();
      final notifier = ref.read(aiSettingsProvider.notifier);
      final known = models.any((m) => m.id == settings.model);
      await notifier.change(
        settings.copyWith(
          customBaseUrl: base,
          model: known ? settings.model : pickModelFor(info.id, models),
        ),
      );
      setState(() {
        _hasKey = key != null;
        _models = models;
      });
      _say('Rendben van, elmentve. ${models.length} modell érhető el.');
    } on LlmException catch (e) {
      _say(e.message, error: true);
    } catch (e) {
      _say('Az ellenőrzés nem sikerült: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteKey(String provider) async {
    await ref.read(apiKeyStoreProvider).write(null, provider: provider);
    setState(() {
      _hasKey = false;
      _models = const [];
    });
    _say('A kulcs törölve.');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider).value ?? const AiSettings();
    if (_loadedFor != settings.provider &&
        ref.watch(aiSettingsProvider).hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(settings));
    }
    final info = providerById(settings.provider);
    final usage = ref.watch(aiUsageProvider).value ?? 0;
    final notifier = ref.read(aiSettingsProvider.notifier);
    final build = ref.watch(currentBuildProvider).value;
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title, List<Widget> children) => Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Beállítások')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              section('AI-asszisztens', [
                DropdownButtonFormField<String>(
                  key: ValueKey('provider-${settings.provider}'),
                  initialValue: settings.provider,
                  decoration: const InputDecoration(labelText: 'Szolgáltató'),
                  items: [
                    for (final p in kProviders)
                      DropdownMenuItem(value: p.id, child: Text(p.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => v == null ? null : notifier.selectProvider(v),
                ),
                const SizedBox(height: 6),
                Text(info.note, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      _hasKey ? Icons.check_circle : Icons.info_outline,
                      size: 18,
                      color: _hasKey ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _hasKey
                          ? 'API-kulcs megadva'
                          : (info.keyOptional
                                ? 'Kulcs nem kötelező'
                                : 'Nincs API-kulcs'),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(info.keyUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Kulcs létrehozása'),
                    ),
                  ],
                ),
                if (info.id == 'custom')
                  TextField(
                    controller: _base,
                    decoration: const InputDecoration(
                      labelText: 'Szolgáltató címe',
                      hintText: 'http://localhost:11434/v1',
                    ),
                  ),
                TextField(
                  controller: _key,
                  obscureText: !_show,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: _hasKey
                        ? 'Új API-kulcs (üresen hagyva a mostanit ellenőrzi)'
                        : 'API-kulcs',
                    helperText: 'A kulcs csak ezen az eszközön, a biztonságos tárolóban él.',
                    suffixIcon: IconButton(
                      tooltip: _show ? 'Elrejt' : 'Mutat',
                      icon: Icon(
                        _show ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _saveAndCheck(settings),
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined),
                      label: const Text('Mentés és ellenőrzés'),
                    ),
                    if (_hasKey)
                      OutlinedButton(
                        onPressed: _busy ? null : () => _deleteKey(info.id),
                        child: const Text('Kulcs törlése'),
                      ),
                  ],
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _messageIsError ? scheme.error : scheme.primary,
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                if (_models.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey('${settings.provider}-${settings.model}'),
                    initialValue: _models.any((m) => m.id == settings.model)
                        ? settings.model
                        : null,
                    decoration: const InputDecoration(labelText: 'Modell'),
                    items: [
                      for (final m in _models)
                        DropdownMenuItem(
                          value: m.id,
                          child: Text(m.id, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => v == null
                        ? null
                        : notifier.change(settings.copyWith(model: v)),
                  )
                else
                  Text(
                    'Modell: ${settings.model ?? 'még nincs kiválasztva (az első ellenőrzés után automatikus)'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  'Ma elküldött kérések: $usage',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
              section('Mit láthat az asszisztens?', [
                const Text(
                  'Kikapcsolt adat sosem megy el a szolgáltatóhoz. Az ütközéseket ilyenkor is a program ellenőrzi.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Naptáresemények'),
                  value: settings.events,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(events: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Feladatok'),
                  value: settings.tasks,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(tasks: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Napi check-in (energia, hangulat, alvás)'),
                  value: settings.checkins,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(checkins: v)),
                ),
              ]),
              section('Kézikönyv', [
                const Text(
                  'Az asszisztens szabályai, a profilod és az összefüggések. Szerkesztheted, és a Google Drive-on át minden eszközön ugyanaz.',
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const HandbookPage(),
                    ),
                  ),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Kézikönyv szerkesztése'),
                ),
              ]),
              section('A program', [
                Text('Verzió: ${build == null ? '…' : 'build $build'}'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => showUpdateDialog(context, ref),
                  icon: const Icon(Icons.system_update_alt),
                  label: const Text('Frissítés keresése'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
