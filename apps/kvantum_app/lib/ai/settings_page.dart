import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/backup_ops.dart';
import '../data/event_repository.dart' show kNaptarCalendar;
import '../finance/wallet_settings.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import '../ui/backup_io.dart';
import '../ui/import_choice.dart';
import '../update/update_dialog.dart';
import 'ai_providers.dart';
import 'location_service.dart';
import 'place.dart';
import '../notify/reminders.dart';
import 'ai_settings.dart';
import 'endpoint_policy.dart';
import 'handbook_page.dart';
import 'llm_provider.dart';
import 'provider_catalog.dart';
import '../diag/diag_log.dart';
import '../sync/error_catalog.dart';
import '../ui/diagnostics_page.dart';
import '../ui/shortcuts.dart' show showShortcutHelp;

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
  final _city = TextEditingController();
  var _found = const <Place>[];
  var _locBusy = false;

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    _city.dispose();
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

  Future<void> _useGps() async {
    setState(() => _locBusy = true);
    final r = await ref.read(locationProvider).current();
    if (!mounted) return;
    setState(() => _locBusy = false);
    final p = r.place;
    if (p != null) {
      await ref
          .read(aiSettingsProvider.notifier)
          .change(
            (ref.read(aiSettingsProvider).value ?? const AiSettings()).copyWith(
              place: p,
            ),
          );
      _toast('Helyszín beállítva: ${p.label} (kb.).');
      return;
    }
    _toast(switch (r.failure) {
      LocationFailure.serviceOff =>
        'A helymeghatározás ki van kapcsolva az eszközön.',
      LocationFailure.denied => 'A helyhozzáférést nem engedélyezted.',
      LocationFailure.deniedForever => 'A helyhozzáférés tiltva van. Engedélyezd a rendszer beállításaiban (Alkalmazások → Kvantum Naptár → Engedélyek → Hely).',
      _ => 'Nem sikerült meghatározni a helyzetet. Gépen gyakran nincs GPS: keress rá a városodra.',
    }, error: true);
  }

  Future<void> _searchCity() async {
    setState(() => _locBusy = true);
    final found = await ref.read(weatherServiceProvider).search(_city.text);
    if (!mounted) return;
    setState(() {
      _found = found;
      _locBusy = false;
    });
    if (found.isEmpty) {
      _toast('Nem találtam ilyen helyet (vagy nincs kapcsolat).', error: true);
    }
  }

  Future<void> _pickPlace(Place p) async {
    await ref
        .read(aiSettingsProvider.notifier)
        .change(
          (ref.read(aiSettingsProvider).value ?? const AiSettings()).copyWith(
            place: p,
          ),
        );
    if (!mounted) return;
    setState(() {
      _found = const [];
      _city.clear();
    });
  }

  /// The backup buttons sit far below the key section, where [_say] is not
  /// visible, so their results appear as a snack bar.
  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(m),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  Future<void> _export() async {
    try {
      final text = await exportBackup(ref.read(repoProvider));
      final d = DateTime.now();
      final name =
          'naptar-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.ics';
      final ok = await ref.read(backupIoProvider).save(name, text);
      if (ok) _toast('A naptár elmentve.');
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.save_failed', e, st);
      _toast('A mentés nem sikerült: ${errorInfoFor(e).text}', error: true);
    }
  }

  Future<void> _exportFinance() async {
    try {
      final text = await ref.read(financeRepoProvider).exportJson();
      final d = DateTime.now();
      final name =
          'penzugyek-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json';
      final ok = await ref.read(backupIoProvider).save(name, text);
      if (ok) _toast('A pénzügyi adatok elmentve.');
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.save_failed', e, st);
      _toast('A mentés nem sikerült: ${errorInfoFor(e).text}', error: true);
    }
  }

  Future<void> _importFinance() async {
    try {
      final text = await ref.read(backupIoProvider).pick();
      if (text == null) return;
      final r = await ref.read(financeRepoProvider).importJson(text);
      final any = r.added + r.updated > 0;
      if (!r.recognized) {
        _toast('Ez nem pénzügyi mentésfájl.', error: true);
        return;
      }
      if (r.newer) {
        _toast(
          'Ezt a mentést az alkalmazás egy újabb verziója készítette; frissítsd az alkalmazást, hogy visszaállíthasd.',
          error: true,
        );
        return;
      }
      _toast(
        any
            ? 'Pénzügyi adat visszaállítva: ${r.added} új, ${r.updated} frissítve${r.skipped > 0 ? ', ${r.skipped} elem kihagyva' : ''}.'
            : r.skipped > 0
            ? 'Nem találtam használható pénzügyi adatot a fájlban.'
            : 'Nincs mit visszaállítani: minden adat naprakész.',
        error: !any && r.skipped > 0,
      );
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.restore_failed', e, st);
      _toast(
        'A visszaállítás nem sikerült: ${errorInfoFor(e).text}',
        error: true,
      );
    }
  }

  Future<void> _import() async {
    try {
      final text = await ref.read(backupIoProvider).pick();
      if (text == null) return;
      final repo = ref.read(repoProvider);
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      // Events that changed on this device since the file was written are
      // only overwritten when the user says so.
      var overwrite = false;
      if (plan.changes.isNotEmpty) {
        if (!mounted) return;
        final choice = await askImportChoice(context, plan);
        if (choice == null) return;
        overwrite = choice == ImportChoice.all;
      }
      final r = await applyBackup(repo, plan, overwrite: overwrite);
      if (r.total > 0) {
        ref.read(syncControllerProvider.notifier).requestSync();
      }
      final extra = r.problems.isEmpty
          ? ''
          : ' (${r.problems.length} elemet kihagytam vagy figyelmeztetéssel olvastam be)';
      final nothing = r.total == 0 && r.unchanged == 0 && r.kept == 0;
      final kept = r.kept > 0
          ? ' ${r.kept} módosult eseményt nem írtam felül.'
          : '';
      _toast(
        nothing
            ? 'Nem találtam beolvasható eseményt a fájlban.$extra'
            : 'Visszaállítva: ${r.added} új, ${r.updated} frissítve, ${r.unchanged} változatlan.$kept$extra',
        error: nothing,
      );
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.restore_failed', e, st);
      _toast(
        'A visszaállítás nem sikerült: ${errorInfoFor(e).text}',
        error: true,
      );
    }
  }

  /// Turning a reminder on asks for the notification permission first; when
  /// it is refused nothing is switched on and the user is told why.
  Future<void> _setReminders(ReminderSettings next) async {
    if (next.any) {
      final ok = await ref.read(reminderSchedulerProvider).ensurePermission();
      if (!ok) {
        _toast(
          'Az értesítések le vannak tiltva. Engedélyezd az Android beállításaiban (Alkalmazások → Kvantum Naptár → Értesítések).',
          error: true,
        );
        return;
      }
    }
    await ref.read(reminderSettingsProvider.notifier).change(next);
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
    final reminders =
        ref.watch(reminderSettingsProvider).value ?? const ReminderSettings();
    if (_loadedFor != settings.provider &&
        ref.watch(aiSettingsProvider).hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(settings));
    }
    final info = providerById(settings.provider);
    final usage = ref.watch(aiUsageProvider).value ?? const AiUsageDay();
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
                  usage.requests == 0
                      ? 'Ma még nem volt kérés ennél a szolgáltatónál.'
                      : 'Ma ennél a szolgáltatónál: ${usage.requests} kérés · ${spaced(usage.tokens.total)} token (be ${spaced(usage.tokens.prompt)} · ki ${spaced(usage.tokens.output + usage.tokens.thinking)})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
              section('Mit láthat az asszisztens?', [
                const Text(
                  'Kikapcsolt adat sosem megy el a szolgáltatóhoz. Az ütközéseket ilyenkor is a program ellenőrzi. Mindig megy: a kérésed szövege (legfeljebb 500 karakter) és a beépített szabályok. Tervezésnél a kézzel felvett rövid események címe nem megy el, a modell csak azt látja, hogy foglalt; törlésnél és áthelyezésnél a címek elmennek, mert abból tudja, melyik eseményről van szó. A check-in megjegyzése soha nem megy el.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Kézikönyv (szabályok, profil, tanult szokások)',
                  ),
                  subtitle: const Text(
                    'Kikapcsolva csak a beépített szabályok mennek el, a saját szabályaid nem.',
                  ),
                  value: settings.handbook,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(handbook: v)),
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
                  subtitle: const Text(
                    'Ide tartozik az edzés utáni visszajelzés összegzése is (a megjegyzések nem mennek el).',
                  ),
                  value: settings.checkins,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(checkins: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pénzügyek (csak olvasás)'),
                  subtitle: const Text(
                    'Csak az összesítés megy el (kategóriánként, kerettel, célokkal); az egyes tételek csak akkor, ha a modell egy hónap részleteit kéri. Felvenni vagy törölni nem tud.',
                  ),
                  value: settings.finance,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(finance: v)),
                ),
              ]),
              section('Időjárás és helyszín', [
                const Text(
                  'A szabadtéri hobbisportokat (kajak, kerékpár, falmászás…) az időjárás-előrejelzés alapján javasolja. Az előrejelzést az Open-Meteo adja (ingyenes, kulcs nélkül). Az Open-Meteóhoz csak a kerekített koordináta (kb. 1 km pontosságú) megy ki, a naptáradatod nem; a modellnek a napi előrejelzés megy, a helyszín neve nem.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Időjárás használata a tervezéshez'),
                  value: settings.weather,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(weather: v)),
                ),
                if (settings.weather) ...[
                  Text(
                    settings.place == null
                        ? 'Helyszín: nincs megadva (időjárás nélkül tervez).'
                        : 'Helyszín: ${settings.place!.label}',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _locBusy ? null : _useGps,
                        icon: const Icon(Icons.my_location),
                        label: const Text('Helyzet meghatározása (GPS)'),
                      ),
                      if (settings.place != null)
                        TextButton(
                          onPressed: () => notifier.change(
                            settings.copyWith(clearPlace: true),
                          ),
                          child: const Text('Helyszín törlése'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _city,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchCity(),
                    decoration: InputDecoration(
                      labelText: 'Vagy keress rá a városodra',
                      suffixIcon: IconButton(
                        tooltip: 'Keresés',
                        icon: const Icon(Icons.search),
                        onPressed: _locBusy ? null : _searchCity,
                      ),
                    ),
                  ),
                  for (final p in _found)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(p.label),
                      onTap: () => _pickPlace(p),
                    ),
                ],
              ]),
              section('Google Wallet értesítések', const [WalletSettings()]),
              section('Emlékeztetők', [
                if (!ref.watch(reminderSchedulerProvider).supported)
                  const Text(
                    'Az emlékeztetők ezen az eszközön még nem érhetők el (egyelőre csak Androidon működnek).',
                  )
                else ...[
                  const Text(
                    'Helyi értesítések, nem megy el hozzá adat sehová. Pár percet késhetnek.',
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: reminders.shiftLeadMinutes,
                    decoration: const InputDecoration(
                      labelText: 'Emlékeztető a műszak előtt',
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Ki')),
                      DropdownMenuItem(
                        value: 60,
                        child: Text('1 órával előtte'),
                      ),
                      DropdownMenuItem(
                        value: 120,
                        child: Text('2 órával előtte'),
                      ),
                      DropdownMenuItem(
                        value: 180,
                        child: Text('3 órával előtte'),
                      ),
                    ],
                    onChanged: (v) => v == null
                        ? null
                        : _setReminders(
                            reminders.copyWith(shiftLeadMinutes: v),
                          ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Napi check-in emlékeztető (20:00)'),
                    value: reminders.checkIn,
                    onChanged: (v) =>
                        _setReminders(reminders.copyWith(checkIn: v)),
                  ),
                ],
              ]),
              section('Edzés utáni visszajelzés', [
                const Text(
                  'Egy edzés után (a címéből ismeri fel: Gym, Calisthenics, futás, kajak …) a főoldalon rákérdez, milyen nehéz volt, mennyi energiával kezdted és fejezted be, és milyen élmény volt. Pár koppintás, és nem kötelező. Ebből tanul: ha egy edzés-típus a visszajelzéseid szerint nehezebb, mint amit a program feltételez, magától szigorít; ha könnyebb, csak a jóváhagyásoddal lazít (a jóváhagyás a Kézikönyv „Tanult szokások” fájljába kerül, ott törölheted).',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Edzés utáni visszajelzés kérése'),
                  subtitle: const Text(
                    'Kikapcsolva nem kérdez, és nem tanul újat; a már megadott válaszok megmaradnak.',
                  ),
                  value: settings.workoutFeedback,
                  onChanged: (v) =>
                      notifier.change(settings.copyWith(workoutFeedback: v)),
                ),
              ]),
              section('Mentés és visszaállítás', [
                const Text(
                  'A naptár egy .ics fájlba menthető, amit bármely naptárprogram megnyit. A visszaállítás csak hozzáad vagy frissít, soha nem töröl.',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _export,
                      icon: const Icon(Icons.download),
                      label: const Text('Mentés fájlba'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Visszaállítás fájlból'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exportFinance,
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                      label: const Text('Pénzügyek mentése'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _importFinance,
                      icon: const Icon(Icons.restore),
                      label: const Text('Pénzügyek visszaállítása'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'A pénzügyi adatok csak az eszközödön vannak meg (a Drive-ba csak a változások kerülnek), ezért érdemes időnként elmenteni őket.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
              section('Alvási sáv', [
                const Text(
                  'Ebben az időszakban az asszisztens semmit nem tervez. Éjszakás időszakban állítsd át arra, amikor ténylegesen alszol (pl. 08:00–16:00).',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: settings.sleepStartHour,
                        decoration: const InputDecoration(
                          labelText: 'Alvás kezdete',
                        ),
                        items: [
                          for (var h = 0; h < 24; h++)
                            DropdownMenuItem(
                              value: h,
                              enabled: h != settings.sleepEndHour,
                              child: Text('${h.toString().padLeft(2, '0')}:00'),
                            ),
                        ],
                        onChanged: (v) => v == null
                            ? null
                            : notifier.change(
                                settings.copyWith(sleepStartHour: v),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: settings.sleepEndHour,
                        decoration: const InputDecoration(
                          labelText: 'Alvás vége',
                        ),
                        items: [
                          for (var h = 0; h < 24; h++)
                            DropdownMenuItem(
                              value: h,
                              enabled: h != settings.sleepStartHour,
                              child: Text('${h.toString().padLeft(2, '0')}:00'),
                            ),
                        ],
                        onChanged: (v) => v == null
                            ? null
                            : notifier.change(
                                settings.copyWith(sleepEndHour: v),
                              ),
                      ),
                    ),
                  ],
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
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('open-diagnostics'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiagnosticsPage(),
                    ),
                  ),
                  icon: const Icon(Icons.monitor_heart_outlined),
                  label: const Text('Diagnosztika'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('open-shortcuts'),
                  onPressed: () => showShortcutHelp(context),
                  icon: const Icon(Icons.keyboard_outlined),
                  label: const Text('Billentyűparancsok'),
                ),
              ]),
            ],
          ),
        ),
      ),
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

/// Said once per provider, before its first key is kept: what goes out, and the
/// switches for the optional parts. "Mégsem használom" keeps nothing.
class ConsentDialog extends StatefulWidget {
  const ConsentDialog({
    super.key,
    required this.provider,
    required this.settings,
  });
  final ProviderInfo provider;
  final AiSettings settings;

  @override
  State<ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<ConsentDialog> {
  late AiSettings _s = widget.settings;

  Widget _switch(
    String title,
    bool value,
    AiSettings Function(bool) apply, {
    String? subtitle,
  }) => SwitchListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: (v) => setState(() => _s = apply(v)),
  );

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: Text('Mi megy ki a(z) ${widget.provider.label} felé?'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Minden kérésnél elmegy a szolgáltatóhoz:'),
              const Text('• a kérésed szövege (legfeljebb 500 karakter)'),
              const Text(
                '• a beépített szabályok (alvási sáv, puffer, energia-korlátok)',
              ),
              const SizedBox(height: 10),
              const Text('Ezeket te kapcsolod (később a Beállításokban is):'),
              _switch(
                'Kézikönyv',
                _s.handbook,
                (v) => _s.copyWith(handbook: v),
                subtitle: 'a saját szabályaid, a profilod, a tanult szokásaid',
              ),
              _switch(
                'Naptáresemények',
                _s.events,
                (v) => _s.copyWith(events: v),
                subtitle: 'az időpontok; tervezésnél a kézzel felvett rövid események címe nem megy el, törlésnél és áthelyezésnél igen',
              ),
              _switch(
                'Feladatok',
                _s.tasks,
                (v) => _s.copyWith(tasks: v),
                subtitle:
                    'a nyitott feladataid címe, határideje, becsült ideje',
              ),
              _switch(
                'Napi check-in',
                _s.checkins,
                (v) => _s.copyWith(checkins: v),
                subtitle: 'energia, hangulat, alvás és az edzés utáni visszajelzések összegzése; a megjegyzés nem megy el',
              ),
              _switch(
                'Pénzügyek',
                _s.finance,
                (v) => _s.copyWith(finance: v),
                subtitle: 'alapból csak az összesítés; az egyes tételek csak akkor, ha a modell egy hónap részleteit kéri (felvenni vagy törölni nem tud)',
              ),
              _switch(
                'Időjárás',
                _s.weather,
                (v) => _s.copyWith(weather: v),
                subtitle: 'a napi előrejelzés megy el, a helyszín neve nem',
              ),
              const SizedBox(height: 8),
              Text(
                'A kulcsod csak ezen az eszközön marad. Az ingyenes szintű szolgáltatások gyakran felhasználhatják a kéréseket a saját fejlesztésükhöz; nézd meg a szolgáltató feltételeit.',
                style: small,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Mégsem használom'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_s),
          child: const Text('Rendben, folytatom'),
        ),
      ],
    );
  }
}
