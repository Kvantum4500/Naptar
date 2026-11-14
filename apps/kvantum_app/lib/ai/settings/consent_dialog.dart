import 'package:flutter/material.dart';

import '../ai_settings.dart';
import '../provider_catalog.dart';

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
