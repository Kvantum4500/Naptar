import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'format.dart';

const _freqLabels = {
  RepeatFreq.daily: 'Naponta',
  RepeatFreq.weekly: 'Hetente',
  RepeatFreq.monthly: 'Havonta',
  RepeatFreq.yearly: 'Évente',
};
const _dayShort = ['H', 'K', 'Sze', 'Cs', 'P', 'Szo', 'V'];
const _dayName = [
  'hétfő',
  'kedd',
  'szerda',
  'csütörtök',
  'péntek',
  'szombat',
  'vasárnap',
];

/// Editor for [RecurrenceSpec]: frequency, interval, weekdays, monthly mode,
/// end condition and a live preview of the next occurrences.
class RepeatEditor extends StatefulWidget {
  const RepeatEditor({
    super.key,
    required this.start,
    required this.spec,
    required this.onChanged,
  });

  /// Floating start of the event (the rule is anchored on it).
  final DateTime start;
  final RecurrenceSpec? spec; // null = does not repeat
  final ValueChanged<RecurrenceSpec?> onChanged;

  @override
  State<RepeatEditor> createState() => _RepeatEditorState();
}

class _RepeatEditorState extends State<RepeatEditor> {
  late final TextEditingController _interval;
  late final TextEditingController _count;

  @override
  void initState() {
    super.initState();
    _interval = TextEditingController(text: '${widget.spec?.interval ?? 1}');
    _count = TextEditingController(text: '${widget.spec?.count ?? 10}');
  }

  @override
  void dispose() {
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  RecurrenceSpec? get _s => widget.spec;

  void _set(RecurrenceSpec? s) => widget.onChanged(s);

  void _pickFreq(RepeatFreq? f) {
    if (f == null) return _set(null);
    final old = _s;
    _set(
      RecurrenceSpec(
        freq: f,
        interval: old?.interval ?? 1,
        weekdays: f == RepeatFreq.weekly
            ? (old?.weekdays.isNotEmpty == true
                  ? old!.weekdays
                  : {widget.start.weekday})
            : const {},
        monthlyMode: old?.monthlyMode ?? MonthlyMode.dayOfMonth,
        end: old?.end ?? RepeatEnd.never,
        count: old?.count ?? int.tryParse(_count.text) ?? 10,
        until: old?.until,
      ),
    );
  }

  Future<void> _pickUntil() async {
    final s = _s!;
    final init = s.until ?? widget.start.add(const Duration(days: 90));
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(init.year, init.month, init.day),
      firstDate: DateTime(
        widget.start.year,
        widget.start.month,
        widget.start.day,
      ),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      _set(
        s.copyWith(
          end: RepeatEnd.until,
          until: DateTime.utc(d.year, d.month, d.day),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<RepeatFreq?>(
          initialValue: s?.freq,
          decoration: const InputDecoration(labelText: 'Ismétlődés'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Nem ismétlődik')),
            for (final f in RepeatFreq.values)
              DropdownMenuItem(value: f, child: Text(_freqLabels[f]!)),
          ],
          onChanged: _pickFreq,
        ),
        if (s != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Minden'),
              const SizedBox(width: 10),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null && n >= 1) _set(s.copyWith(interval: n));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Text(switch (s.freq) {
                RepeatFreq.daily => 'naponta',
                RepeatFreq.weekly => 'héten',
                RepeatFreq.monthly => 'hónapban',
                RepeatFreq.yearly => 'évben',
              }),
            ],
          ),
          if (s.freq == RepeatFreq.weekly) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(_dayShort[d - 1]),
                    tooltip: _dayName[d - 1],
                    selected:
                        (s.weekdays.isEmpty
                                ? {widget.start.weekday}
                                : s.weekdays)
                            .contains(d),
                    onSelected: (on) {
                      final cur = {
                        ...(s.weekdays.isEmpty
                            ? {widget.start.weekday}
                            : s.weekdays),
                      };
                      on ? cur.add(d) : cur.remove(d);
                      if (cur.isNotEmpty) _set(s.copyWith(weekdays: cur));
                    },
                  ),
              ],
            ),
          ],
          if (s.freq == RepeatFreq.monthly) ...[
            const SizedBox(height: 6),
            RadioGroup<MonthlyMode>(
              groupValue: s.monthlyMode,
              onChanged: (v) => _set(s.copyWith(monthlyMode: v)),
              child: Column(
                children: [
                  RadioListTile<MonthlyMode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: MonthlyMode.dayOfMonth,
                    title: Text('Minden hónap ${widget.start.day}. napján'),
                  ),
                  if ((widget.start.day - 1) ~/ 7 + 1 < 5)
                    RadioListTile<MonthlyMode>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: MonthlyMode.nthWeekday,
                      title: Text(
                        'Minden hónap ${(widget.start.day - 1) ~/ 7 + 1}. ${_dayName[widget.start.weekday - 1]}',
                      ),
                    ),
                  RadioListTile<MonthlyMode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: MonthlyMode.lastWeekday,
                    title: Text(
                      'Minden hónap utolsó ${_dayName[widget.start.weekday - 1]}',
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<RepeatEnd>(
                  initialValue: s.end,
                  decoration: const InputDecoration(labelText: 'Befejezés'),
                  items: const [
                    DropdownMenuItem(
                      value: RepeatEnd.never,
                      child: Text('Soha'),
                    ),
                    DropdownMenuItem(
                      value: RepeatEnd.count,
                      child: Text('Alkalmak száma után'),
                    ),
                    DropdownMenuItem(
                      value: RepeatEnd.until,
                      child: Text('Adott dátumig'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _set(
                      s.copyWith(
                        end: v,
                        count: s.count ?? int.tryParse(_count.text) ?? 10,
                        until: v == RepeatEnd.until
                            ? (s.until ??
                                  widget.start.add(const Duration(days: 90)))
                            : s.until,
                      ),
                    );
                  },
                ),
              ),
              if (s.end == RepeatEnd.count) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _count,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'Alkalom'),
                    onChanged: (v) {
                      final n = int.tryParse(v.trim());
                      _set(s.copyWith(count: n ?? 0));
                    },
                  ),
                ),
              ],
              if (s.end == RepeatEnd.until) ...[
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _pickUntil,
                  child: Text(s.until == null ? 'Dátum…' : fmtDate(s.until!)),
                ),
              ],
            ],
          ),
          Builder(
            builder: (context) {
              final err = s.validate();
              if (err != null) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err, style: TextStyle(color: scheme.error)),
                );
              }
              final next = s.preview(widget.start);
              final f = DateFormat('MMM d. (E)', 'hu');
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Következő alkalmak: ${next.map((d) => f.format(DateTime(d.year, d.month, d.day))).join(' · ')}'
                  '${s.end == RepeatEnd.never ? ' …' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}
