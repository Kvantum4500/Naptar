import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../diag/diag_log.dart';
import '../../sync/error_catalog.dart';
import '../../ui/setup_guide.dart';
import '../ai_providers.dart';
import '../ai_settings.dart';
import '../endpoint_policy.dart';
import '../llm_provider.dart';
import '../provider_catalog.dart';
import 'consent_dialog.dart';

/// The body of the "AI-asszisztens" card: the provider, its key (checked before
/// it is kept), the model, and what was used today. What was typed and what
/// was said belongs to the card, and the card is kept alive while it is
/// scrolled out of sight, so a key half typed is still there when it comes
/// back.
class AiProviderBody extends ConsumerStatefulWidget {
  const AiProviderBody({super.key});

  @override
  ConsumerState<AiProviderBody> createState() => _AiProviderBodyState();
}

class _AiProviderBodyState extends ConsumerState<AiProviderBody>
    with AutomaticKeepAliveClientMixin {
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
  bool get wantKeepAlive => true;

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
    String? warning;
    if (base != null) {
      // the key and the data go there: public servers need https
      final check = checkCustomEndpoint(base);
      if (!check.ok) {
        _say(check.error!, error: true);
        return;
      }
      warning = check.warning;
    }
    setState(() => _busy = true);
    try {
      final checker = ref.read(llmFactoryProvider)(
        LlmConfig(provider: info.id, apiKey: key ?? '', baseUrl: base),
      );
      final List<LlmModel> models;
      try {
        models = await checker.listModels();
      } finally {
        checker.close(); // one connection per check, closed when it is over
      }
      if (models.isEmpty) {
        _say(
          'A kulcs érvényes, de nem találtam használható modellt.',
          error: true,
        );
        return;
      }
      // The first key at a provider: say what goes out BEFORE anything is kept.
      final aiStore = ref.read(aiSettingsStoreProvider);
      var chosen = settings;
      if (!await aiStore.consentGiven(info.id)) {
        if (!mounted) return;
        final agreed = await showDialog<AiSettings>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ConsentDialog(provider: info, settings: settings),
        );
        if (agreed == null) {
          _say(
            'A kulcsot nem mentettem el: az asszisztens ennél a szolgáltatónál addig nem használható.',
          );
          return;
        }
        chosen = agreed;
        await aiStore.giveConsent(info.id);
      }
      await store.write(
        key,
        provider: info.id,
      ); // only a key that works is kept
      ref.invalidate(setupFactsProvider); // (the first-run guide looks again)
      _key.clear();
      final notifier = ref.read(aiSettingsProvider.notifier);
      final known = models.any((m) => m.id == chosen.model);
      await notifier.change(
        chosen.copyWith(
          customBaseUrl: base,
          model: known ? chosen.model : pickModelFor(info.id, models),
        ),
      );
      setState(() {
        _hasKey = key != null;
        _models = models;
      });
      _say(
        'Rendben van, elmentve. ${models.length} modell érhető el.'
        '${warning == null ? '' : ' $warning'}',
      );
    } on LlmException catch (e) {
      _say(e.message, error: true);
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.check_failed', e, st);
      _say('Az ellenőrzés nem sikerült: ${errorInfoFor(e).text}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteKey(String provider) async {
    await ref.read(apiKeyStoreProvider).write(null, provider: provider);
    ref.invalidate(setupFactsProvider);
    setState(() {
      _hasKey = false;
      _models = const [];
    });
    _say('A kulcs törölve.');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = ref.watch(aiSettingsProvider).value ?? const AiSettings();
    if (_loadedFor != settings.provider &&
        ref.watch(aiSettingsProvider).hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(settings));
    }
    final info = providerById(settings.provider);
    final usage = ref.watch(aiUsageProvider).value ?? const AiUsageDay();
    final notifier = ref.read(aiSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('provider-${settings.provider}'),
          initialValue: settings.provider,
          isExpanded: true,
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
        // (a Wrap: the link goes under the state where they do not fit
        // side by side, a narrow window, large text)
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _hasKey ? Icons.check_circle : Icons.info_outline,
                  size: 18,
                  color: _hasKey ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _hasKey
                        ? 'API-kulcs megadva'
                        : (info.keyOptional
                              ? 'Kulcs nem kötelező'
                              : 'Nincs API-kulcs'),
                  ),
                ),
              ],
            ),
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
            helperText:
                'A kulcs csak ezen az eszközön, a biztonságos tárolóban él.',
            suffixIcon: IconButton(
              tooltip: _show ? 'Elrejt' : 'Mutat',
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
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
            onChanged: (v) =>
                v == null ? null : notifier.change(settings.copyWith(model: v)),
          )
        else
          Text(
            'Modell: ${settings.model ?? 'még nincs kiválasztva (az első ellenőrzés után automatikus)'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        Text(
          usage.requests == 0
              ? 'Ma még nem volt kérés ennél a szolgáltatónál.'
              : 'Ma ennél a szolgáltatónál: ${usage.requests} kérés · ${spaced(usage.tokens.total)} token (be ${spaced(usage.tokens.prompt)} · ki ${spaced(usage.tokens.output + usage.tokens.thinking)})',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 18400 -> "18 400".
String spaced(int n) {
  final digits = '${n.abs()}';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write('\u00A0');
    out.write(digits[i]);
  }
  return n < 0 ? '-$out' : '$out';
}
