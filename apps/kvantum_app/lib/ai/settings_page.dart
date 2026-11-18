import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup_card.dart';
import '../finance/wallet_settings.dart';
import '../notify/autostart_tile.dart';
import '../notify/budget_alerts.dart';
import '../notify/budget_notify.dart' show budgetNotifierProvider;
import '../notify/reminder_test_button.dart';
import '../notify/reminders.dart';
import '../notify/windows_autostart.dart' show autostartProvider;
import '../ui/diagnostics_page.dart';
import '../ui/setup_guide.dart';
import '../ui/shortcuts.dart' show showShortcutHelp;
import '../ui/theme.dart';
import '../update/update_dialog.dart';
import '../widget/widget_bridge.dart';
import 'ai_providers.dart';
import 'ai_settings.dart';
import 'handbook_page.dart';
import 'location_service.dart';
import 'place.dart';
import 'settings/account_card.dart';
import 'settings/ai_provider_card.dart';
import 'settings/export_import_card.dart';
import 'settings/local_plan_card.dart';
import 'settings/settings_toast.dart';

export 'settings/ai_provider_card.dart' show spaced;
export 'settings/consent_dialog.dart';

/// App settings: AI provider + key + model, what the assistant may see, handbook.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// Bumped when the system refuses the notifications: the choice a field
  /// shows is not the one in force, so the fields are built anew.
  int _remindersRev = 0;
  final _city = TextEditingController();
  var _found = const <Place>[];
  var _locBusy = false;

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
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

  /// The results of the buttons far below the key section (where [_say] is not
  /// visible) appear as a snack bar.
  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    showSettingsToast(context, m, error: error);
  }

  /// Turning a reminder on asks for the notification permission first; when
  /// it is refused nothing is switched on and the user is told why.
  Future<void> _setReminders(ReminderSettings next) async {
    if (next.any) {
      final ok = await ref.read(reminderSchedulerProvider).ensurePermission();
      if (!ok) {
        _toast(remindersBlockedHelp(), error: true);
        if (mounted) setState(() => _remindersRev++);
        return;
      }
    }
    await ref.read(reminderSettingsProvider.notifier).change(next);
  }

  /// Turning the budget alerts on asks for the notification permission first;
  /// when it is refused nothing is switched on and the user is told why.
  Future<void> _setBudgetAlerts(bool on) async {
    final setting = ref.read(budgetAlertsSettingProvider.notifier);
    if (!on) return setting.disable();
    if (await setting.enable() == BudgetAlertsStart.denied) {
      _toast(remindersBlockedHelp(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider).value ?? const AiSettings();
    final reminders =
        ref.watch(reminderSettingsProvider).value ?? const ReminderSettings();
    final notifier = ref.read(aiSettingsProvider.notifier);
    final build = ref.watch(currentBuildProvider).value;
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
              SettingsGroupHeader('Fiók és szinkron'),
              section('Google-fiók', const [AccountSyncBody()]),
              SettingsGroupHeader('Asszisztens'),
              section('AI-asszisztens', const [AiProviderBody()]),
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
                        isExpanded: true,
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
                        isExpanded: true,
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
              section('Helyi terv (AI nélkül)', const [LocalPlanBody()]),
              SettingsGroupHeader('Értesítések'),
              section('Emlékeztetők', [
                if (!ref.watch(reminderSchedulerProvider).supported)
                  const Text(
                    'Az emlékeztetők ezen az eszközön nem érhetők el (Androidon és Windowson működnek).',
                  )
                else ...[
                  Text(
                    defaultTargetPlatform == TargetPlatform.windows
                        ? 'Helyi értesítések, nem megy el hozzá adat sehová. '
                              'A Windows jeleníti meg őket a kitűzött időben, '
                              'akkor is, ha a program be van zárva; az '
                              'ütemezést a program frissíti, amikor fut.'
                        : 'Helyi értesítések, nem megy el hozzá adat sehová. Pár percet késhetnek.',
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    key: ValueKey('lead-$_remindersRev'),
                    initialValue: reminders.shiftLeadMinutes,
                    isExpanded: true,
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
                  DropdownButtonFormField<int>(
                    key: ValueKey('summary-$_remindersRev'),
                    initialValue: reminders.summaryMinutes,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Reggeli összefoglaló',
                    ),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('Ki')),
                      for (final m in summaryChoices)
                        DropdownMenuItem(
                          value: m,
                          child: Text(summaryTimeLabel(m)),
                        ),
                    ],
                    onChanged: (v) => v == null
                        ? null
                        : _setReminders(reminders.copyWith(summaryMinutes: v)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Egy értesítés a nap elején: a mai események, a határidős '
                    'feladatok, az ünnepnap, és ha megadtál helyet (és az '
                    'Időjárás be van kapcsolva), az időjárás. A szövege a '
                    'zárolt képernyőn is látszhat. A program előre, a '
                    'következő nyolc napra írja meg, és minden változásnál '
                    'újraírja; ha sokáig nem nyitod meg, a régi szöveg jön.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  // (starting with Windows: only where there is such a thing)
                  if (ref.watch(autostartProvider) != null)
                    const AutostartTile(),
                  // (a way to see at once that the reminders reach the user)
                  const ReminderTestButton(),
                ],
              ]),
              // (only where such notifications can be shown)
              if (ref.watch(budgetNotifierProvider).supported)
                section('Költségkeret', [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Értesítés a költségkeretről'),
                    subtitle: const Text(
                      'Szól, ha egy kategória eléri a keret 80%-át, és ha '
                      'túllépi.',
                    ),
                    value:
                        ref.watch(budgetAlertsSettingProvider).value ?? false,
                    onChanged: _setBudgetAlerts,
                  ),
                  Text(
                    'Helyi értesítés, nem megy el hozzá adat sehová. A tétel '
                    'felvételekor jön; a Google Wallet-tételeknél akkor, '
                    'amikor megnyitod a programot (a háttérben a program nem '
                    'dolgoz fel semmit). Amit az ismétlődő tételek (például '
                    'a lakbér) okoznak, azt nem jelzi, csak ami fölötte van. '
                    'A bekapcsoláskor már közeli vagy túllépett kategóriáról '
                    'nem szól, csak az utána jövő lépésekről.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]),
              // (the widget is an Android thing: only there is it mentioned)
              if (ref.watch(widgetBridgeProvider).active)
                section('Főképernyő-widget', [
                  const Text(
                    'A főképernyőre kitehető egy „Kvantum Naptár” widget: a '
                    'mai események, a határidős feladatok, az ünnepnap és a '
                    'következő műszak látszik rajta. Kitételhez tartsd '
                    'nyomva a főképernyő egy üres helyét, válaszd a Widgetek '
                    'pontot, és húzd ki a Kvantum Naptárt.',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'A tartalma akkor frissül, amikor az app fut (megnyitáskor, '
                    'szinkron után); az új napra magától vált, és a következő '
                    'hét napot előre tudja. Az események címe a főképernyőn '
                    'annak is látszik, aki a telefonodra néz.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]),
              section('Google Wallet értesítések', const [WalletSettings()]),
              SettingsGroupHeader('Adatok'),
              section('Automatikus mentés', const [BackupBody()]),
              section('Mentés és visszaállítás', const [ExportImportBody()]),
              SettingsGroupHeader('Névjegy'),
              section('A program', [
                Text('Verzió: ${build == null ? '…' : 'build $build'}'),
                const SizedBox(height: 8),
                DropdownButtonFormField<ThemeMode>(
                  key: ValueKey('theme-${ref.watch(themeModeProvider).name}'),
                  initialValue: ref.watch(themeModeProvider),
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Téma'),
                  items: const [
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text('Rendszer szerint'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text('Világos'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text('Sötét'),
                    ),
                  ],
                  onChanged: (m) => m == null
                      ? null
                      : ref.read(themeModeProvider.notifier).set(m),
                ),
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
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('reset-setup'),
                  onPressed: () {
                    ref.read(setupFlagsProvider.notifier).reset();
                    _toast(
                      'Az első lépések újra megjelennek a naptár tetején.',
                    );
                  },
                  icon: const Icon(Icons.checklist),
                  label: const Text('Első lépések újra'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
