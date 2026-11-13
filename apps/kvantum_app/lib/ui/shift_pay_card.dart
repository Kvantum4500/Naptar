import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../providers.dart';

/// Where the pay settings are kept: on this device only. They are not a record
/// the sync copies, the assistant is never told of them, and the backup does
/// not hold them (they have to be entered again on a new device).
const paySettingsKey = 'pay.settings';

class PaySettingsNotifier extends AsyncNotifier<PaySettings> {
  @override
  Future<PaySettings> build() async => PaySettings.decode(
    await ref.watch(recordRepoProvider).meta(paySettingsKey),
  );

  Future<void> save(PaySettings settings) async {
    await ref
        .read(recordRepoProvider)
        .setMeta(paySettingsKey, settings.encode());
    state = AsyncData(settings);
  }
}

final paySettingsProvider =
    AsyncNotifierProvider<PaySettingsNotifier, PaySettings>(
      PaySettingsNotifier.new,
    );

/// 720 -> "12 óra", 450 -> "7 ó 30 p".
String payHoursLabel(int minutes) => minutes % 60 == 0
    ? '${minutes ~/ 60} óra'
    : '${minutes ~/ 60} ó ${minutes % 60} p';

/// The estimate of the month on the Shifts page: what the shifts of the shown
/// month pay, from the wage and the premiums the user set - or an invitation to
/// set them.
class ShiftPayCard extends ConsumerWidget {
  const ShiftPayCard({
    super.key,
    required this.events,
    required this.year,
    required this.month,
  });

  /// The shifts (see [estimatePay] for the shape).
  final List<({String title, String notes, DateTime start, DateTime end})>
  events;
  final int year;
  final int month;

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    PaySettings now,
  ) async {
    final next = await showDialog<PaySettings>(
      context: context,
      builder: (_) => PaySettingsDialog(initial: now),
    );
    if (next != null) {
      await ref.read(paySettingsProvider.notifier).save(next);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(paySettingsProvider).value;
    // (what is on the device has not been read yet: nothing to say)
    if (settings == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final estimate = settings.isSet
        ? estimatePay(events, year: year, month: month, settings: settings)
        : null;
    final lines = estimate?.lines ?? const <PayLine>[];
    return Card(
      key: const Key('pay-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bérbecslés: $year. '
                    '${DateFormat('MMMM', 'hu').format(DateTime.utc(year, month))}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const Key('pay-open'),
                  tooltip: 'Bérbecslés beállítása',
                  icon: const Icon(Icons.tune),
                  onPressed: () => _edit(context, ref, settings),
                ),
              ],
            ),
            if (estimate == null) ...[
              const Text(
                'Add meg az órabéredet és a pótlékaidat, és megbecsülöm a '
                'hónap bruttó bérét a beosztásból.',
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const Key('pay-set'),
                onPressed: () => _edit(context, ref, settings),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Beállítás'),
              ),
            ] else if (estimate.shifts == 0)
              const Text('Ebben a hónapban nincs műszak, nincs mit számolni.')
            else ...[
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(payKindLabel(line.kind)),
                            Text(
                              line.kind == PayKind.base
                                  ? payHoursLabel(line.minutes)
                                  : '${payHoursLabel(line.minutes)} × '
                                        '${line.percent}%',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatHuf(line.amount)),
                    ],
                  ),
                ),
              const Divider(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Összesen (bruttó becslés)',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    key: const Key('pay-total'),
                    formatHuf(estimate.total),
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Becslés a beosztásból, nem bérszámfejtés: nem számol túlórát, '
              'jutalmat, adót és járulékot, a pótlékok pedig a te '
              'beállításaid. Egy műszak ahhoz a hónaphoz számít, amelyikben '
              'kezdődik. Az adatok csak ezen az eszközön vannak: nem '
              'szinkronizálódnak, és az asszisztensnek sem mennek el.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The wage and the premiums. Saving gives back the [PaySettings]; clearing
/// them gives back an empty one (nothing is kept then).
class PaySettingsDialog extends StatefulWidget {
  const PaySettingsDialog({super.key, required this.initial});
  final PaySettings initial;

  @override
  State<PaySettingsDialog> createState() => _PaySettingsDialogState();
}

class _PaySettingsDialogState extends State<PaySettingsDialog> {
  late final _hourly = _controller(widget.initial.hourly);
  late final _evening = _controller(widget.initial.eveningPct);
  late final _night = _controller(widget.initial.nightPct);
  late final _saturday = _controller(widget.initial.saturdayPct);
  late final _sunday = _controller(widget.initial.sundayPct);
  late final _holiday = _controller(widget.initial.holidayPct);
  var _tooBig = false;

  TextEditingController _controller(int value) =>
      TextEditingController(text: value == 0 ? '' : '$value');

  @override
  void dispose() {
    for (final c in [_hourly, _evening, _night, _saturday, _sunday, _holiday]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Empty is nothing; more digits than any sensible value is too much.
  int? _read(TextEditingController c, int max) {
    final text = c.text.trim();
    if (text.isEmpty) return 0;
    final n = int.tryParse(text);
    return n == null || n > max ? null : n;
  }

  void _save() {
    final hourly = _read(_hourly, PaySettings.maxHourly);
    final pcts = [
      for (final c in [_evening, _night, _saturday, _sunday, _holiday])
        _read(c, PaySettings.maxPercent),
    ];
    if (hourly == null || pcts.contains(null)) {
      setState(() => _tooBig = true);
      return;
    }
    Navigator.pop(
      context,
      PaySettings(
        hourly: hourly,
        eveningPct: pcts[0]!,
        nightPct: pcts[1]!,
        saturdayPct: pcts[2]!,
        sundayPct: pcts[3]!,
        holidayPct: pcts[4]!,
      ),
    );
  }

  Widget _field(
    Key key,
    TextEditingController controller,
    String label, {
    String? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bérbecslés beállítása'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A pótlékokat a munkaszerződésed, illetve a cégednél érvényes '
              'szabály szerint add meg: a program nem tudja és nem állítja, '
              'mennyi jár. Üresen hagyva 0.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            ExpansionTile(
              key: const Key('pay-rules'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              title: const Text('Hogyan számol?'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'A pótlék a sávban ledolgozott órákra jön az alapbér '
                    'mellé. Ha a 18 és 6 óra közötti órákra egy pótlék jár, '
                    'írd be mindkét sávba ugyanazt. Az ünnepnap, a vasárnap '
                    'és a szombat közül egy számít (ebben a sorrendben), és '
                    'összeadódik az idősáv pótlékával.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            _field(
              const Key('pay-hourly'),
              _hourly,
              'Órabér (bruttó)',
              suffix: 'Ft/óra',
            ),
            _field(
              const Key('pay-evening'),
              _evening,
              'Esti pótlék (18–22)',
              suffix: '%',
            ),
            _field(
              const Key('pay-night'),
              _night,
              'Éjszakai pótlék (22–6)',
              suffix: '%',
            ),
            _field(
              const Key('pay-saturday'),
              _saturday,
              'Szombati pótlék',
              suffix: '%',
            ),
            _field(
              const Key('pay-sunday'),
              _sunday,
              'Vasárnapi pótlék',
              suffix: '%',
            ),
            _field(
              const Key('pay-holiday'),
              _holiday,
              'Ünnepnapi pótlék',
              suffix: '%',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton(
                key: const Key('pay-clear'),
                onPressed: () => Navigator.pop(context, const PaySettings()),
                child: const Text('Beállítások törlése'),
              ),
            ),
            if (_tooBig)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Ennyi nem lehet: az órabér legfeljebb '
                  '${PaySettings.maxHourly} Ft, egy pótlék legfeljebb '
                  '${PaySettings.maxPercent}%.',
                  key: const Key('pay-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
          key: const Key('pay-save'),
          onPressed: _save,
          child: const Text('Mentés'),
        ),
      ],
    );
  }
}
