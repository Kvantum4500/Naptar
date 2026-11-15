import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../local_plan_prefs.dart';

/// The most sports the list holds (the program keeps no more, see
/// [LocalPlanPrefs.decode]).
const maxPlanSports = 12;

String _bandText(PlanBand b) => b == PlanBand.any
    ? '${b.label} (inkább ${b.fromHour}–${b.toHour} óra között)'
    : '${b.label} (${b.fromHour}–${b.toHour} óra)';

/// The wishes of the plan the program makes by itself ("Terv AI nélkül" on the
/// Asszisztens page): which sports, how long a session is, how many a week, at
/// what time of the day. Kept on this device only.
class LocalPlanBody extends ConsumerWidget {
  const LocalPlanBody({super.key});

  Future<void> _save(WidgetRef ref, LocalPlanPrefs p) =>
      ref.read(localPlanPrefsProvider.notifier).save(p);

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    LocalPlanPrefs prefs, {
    int? index,
  }) async {
    final sport = await showDialog<PlanSport>(
      context: context,
      builder: (_) =>
          _SportDialog(initial: index == null ? null : prefs.sports[index]),
    );
    if (sport == null) return;
    final list = [...prefs.sports];
    if (index == null) {
      list.add(sport);
    } else {
      list[index] = sport;
    }
    await _save(ref, prefs.copyWith(sports: list));
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alapértékek visszaállítása?'),
        content: const Text(
          'A saját sportlistád és a heti célod elvész: marad a Calisthenics 45 perc, a Gym 60 perc és a heti 3 edzés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            key: const Key('plan-reset-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Visszaállítom'),
          ),
        ],
      ),
    );
    if (ok == true) await _save(ref, const LocalPlanPrefs());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs =
        ref.watch(localPlanPrefsProvider).value ?? const LocalPlanPrefs();
    final small = Theme.of(context).textTheme.bodySmall;
    final isDefault =
        prefs.perWeek == 3 &&
        prefs.band == PlanBand.any &&
        prefs.sports.length == defaultPlanSports.length &&
        [
          for (var i = 0; i < prefs.sports.length; i++)
            prefs.sports[i] == defaultPlanSports[i],
        ].every((e) => e);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ha elfogyott az AI-kereted, nincs kulcsod, vagy csak nem akarsz modellt használni: az Asszisztens oldalon a „Terv AI nélkül” gomb a következő 7 napra tervez edzést a naptárad szabad idejéből, ugyanazokkal a szabályokkal, mint a modell javaslatai (alvás, műszak, pihenő, heti plafon, energia, időjárás). Itt adod meg, milyen sportokkal és mennyit.',
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          key: ValueKey('plan-perweek-${prefs.perWeek}'),
          initialValue: prefs.perWeek,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Heti cél',
            helperText: 'A naptárban már lévő edzések is beleszámítanak.',
            helperMaxLines: 2,
          ),
          items: [
            for (var n = 1; n <= 7; n++)
              DropdownMenuItem(value: n, child: Text('$n edzés hetente')),
          ],
          onChanged: (v) {
            if (v != null) _save(ref, prefs.copyWith(perWeek: v));
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<PlanBand>(
          key: ValueKey('plan-band-${prefs.band.id}'),
          initialValue: prefs.band,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Kedvelt napszak',
            helperText: 'Csak kedvezmény: ha abban nem fér be, máskor tervez.',
            helperMaxLines: 2,
          ),
          items: [
            for (final b in PlanBand.values)
              DropdownMenuItem(
                value: b,
                child: Text(_bandText(b), softWrap: true),
              ),
          ],
          onChanged: (v) {
            if (v != null) _save(ref, prefs.copyWith(band: v));
          },
        ),
        const SizedBox(height: 16),
        Text('Sportok', style: Theme.of(context).textTheme.titleSmall),
        if (prefs.sports.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Nincs sport megadva: a helyi terv így nem tud mit tervezni.',
            ),
          ),
        for (var i = 0; i < prefs.sports.length; i++)
          ListTile(
            key: Key('plan-sport-$i'),
            contentPadding: EdgeInsets.zero,
            title: Text(prefs.sports[i].name),
            subtitle: Text(
              '${prefs.sports[i].minutes} perc${prefs.sports[i].outdoor ? ' · szabadtéri' : ''}',
            ),
            onTap: () => _edit(context, ref, prefs, index: i),
            trailing: IconButton(
              key: Key('plan-sport-del-$i'),
              tooltip: 'Törlés: ${prefs.sports[i].name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _save(
                ref,
                prefs.copyWith(
                  sports: [
                    for (var j = 0; j < prefs.sports.length; j++)
                      if (j != i) prefs.sports[j],
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (prefs.sports.length < maxPlanSports)
              OutlinedButton.icon(
                key: const Key('plan-sport-add'),
                onPressed: () => _edit(context, ref, prefs),
                icon: const Icon(Icons.add),
                label: const Text('Sport hozzáadása'),
              ),
            if (!isDefault)
              TextButton(
                key: const Key('plan-reset'),
                onPressed: () => _reset(context, ref),
                child: const Text('Alapértékek'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Ezek a beállítások csak ezen az eszközön vannak: nem szinkronizálódnak, nem kerülnek a mentésbe, és a modell sem tud róluk. A szabadtéri sport csak a szezonjában kerül a tervbe (kajak: május–szeptember, a többi: április–október), és ha van előrejelzés, az dönt a napról. A 45 perces vagy hosszabb edzés a műszaktól legalább 8 órára kerül (ez a szabályok része).',
          style: small,
        ),
      ],
    );
  }
}

class _SportDialog extends StatefulWidget {
  const _SportDialog({this.initial});
  final PlanSport? initial;

  @override
  State<_SportDialog> createState() => _SportDialogState();
}

class _SportDialogState extends State<_SportDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _minutes = TextEditingController(
    text: '${widget.initial?.minutes ?? 45}',
  );
  late bool _outdoor = widget.initial?.outdoor ?? false;
  bool _bad = false;

  @override
  void dispose() {
    _name.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _ok() {
    final sport = PlanSport.tryParse({
      'name': _name.text,
      'minutes': int.tryParse(_minutes.text.trim()),
      'outdoor': _outdoor,
    });
    if (sport == null) {
      setState(() => _bad = true);
      return;
    }
    Navigator.pop(context, sport);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Új sport' : 'Sport szerkesztése'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('plan-sport-name'),
              controller: _name,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Neve',
                hintText: 'pl. Calisthenics, Kajak, Úszás',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('plan-sport-minutes'),
              controller: _minutes,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Egy alkalom hossza',
                suffixText: 'perc',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              key: const Key('plan-sport-outdoor'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Szabadtéri'),
              subtitle: const Text(
                'Csak a szezonjában és megfelelő időben kerül a tervbe.',
              ),
              value: _outdoor,
              onChanged: (v) => setState(() => _outdoor = v),
            ),
            if (_bad)
              Text(
                'Adj meg egy nevet (legfeljebb 40 karakter) és 15 és 180 perc közötti hosszt.',
                key: const Key('plan-sport-bad'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(
          key: const Key('plan-sport-ok'),
          onPressed: _ok,
          child: const Text('Mentés'),
        ),
      ],
    );
  }
}
