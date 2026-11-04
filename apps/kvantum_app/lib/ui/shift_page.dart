import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart';
import 'format.dart';

enum ShiftType { night, day, off }

const _typeLabels = {
  ShiftType.night: 'Éjszakai műszak',
  ShiftType.day: 'Nappali műszak',
  ShiftType.off: 'Szabadnap',
};

class _Row {
  _Row(this.type, this.days);
  ShiftType type;
  int days;
}

/// Turns the repeating shift cycle into real events in the Naptar calendar.
/// Re-running from a date replaces the shifts generated earlier from that date
/// on; events typed in by hand are never touched.
class ShiftPage extends ConsumerStatefulWidget {
  const ShiftPage({super.key});

  @override
  ConsumerState<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends ConsumerState<ShiftPage> {
  final _rows = <_Row>[
    _Row(ShiftType.night, 3),
    _Row(ShiftType.off, 3),
    _Row(ShiftType.day, 3),
    _Row(ShiftType.off, 3),
  ];
  var _nightStart = const TimeOfDay(hour: 18, minute: 0);
  var _nightEnd = const TimeOfDay(hour: 6, minute: 0);
  var _dayStart = const TimeOfDay(hour: 6, minute: 0);
  var _dayEnd = const TimeOfDay(hour: 18, minute: 0);
  late DateTime _from = ref.read(selectedDayProvider);
  var _months = 6;
  var _busy = false;
  String? _msg;

  int _len(TimeOfDay s, TimeOfDay e) {
    final a = s.hour * 60 + s.minute;
    var b = e.hour * 60 + e.minute;
    if (b <= a) b += 24 * 60; // runs past midnight
    return b - a;
  }

  List<ShiftStep> get _cycle => [
    for (final r in _rows)
      switch (r.type) {
        ShiftType.night => ShiftStep.work(
          _typeLabels[ShiftType.night]!,
          r.days,
          startMinutes: _nightStart.hour * 60 + _nightStart.minute,
          minutes: _len(_nightStart, _nightEnd),
        ),
        ShiftType.day => ShiftStep.work(
          _typeLabels[ShiftType.day]!,
          r.days,
          startMinutes: _dayStart.hour * 60 + _dayStart.minute,
          minutes: _len(_dayStart, _dayEnd),
        ),
        ShiftType.off => ShiftStep.off(r.days),
      },
  ];

  DateTime get _until =>
      DateTime.utc(_from.year, _from.month + _months, _from.day);

  List<PlannedShift> get _plan =>
      generateShiftPlan(_cycle, startDay: _from, untilDay: _until);

  Future<TimeOfDay?> _time(TimeOfDay t) => showTimePicker(
    context: context,
    initialTime: t,
    builder: (c, w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
      child: w!,
    ),
  );

  Future<void> _create() async {
    final plan = _plan;
    if (plan.isEmpty) {
      setState(() => _msg = 'A ciklusban nincs egyetlen munkanap sem.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final repo = ref.read(repoProvider);
      var removed = 0;
      for (final e in await repo.all()) {
        if (e.notes == kShiftMarker &&
            !e.isRecurring &&
            !e.start.isBefore(_from)) {
          await repo.deleteLocal(e.id);
          removed++;
        }
      }
      for (final s in plan) {
        await repo.saveLocal(
          CalEvent(
            id: const Uuid().v4(),
            calendarId: kNaptarCalendar,
            title: s.title,
            notes: kShiftMarker,
            start: s.start,
            end: s.end,
            tzid: defaultTz,
          ),
        );
      }
      ref.read(syncControllerProvider.notifier).requestSync();
      if (!mounted) return;
      setState(
        () => _msg =
            '${plan.length} műszak létrehozva${removed > 0 ? ', $removed korábbi generált műszak cseréjével' : ''}.',
      );
    } catch (e) {
      if (mounted) setState(() => _msg = 'Nem sikerült: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _timeRow(
    String label,
    TimeOfDay s,
    TimeOfDay e,
    void Function(TimeOfDay) setS,
    void Function(TimeOfDay) setE,
  ) => Row(
    children: [
      SizedBox(width: 140, child: Text(label)),
      OutlinedButton(
        onPressed: () async {
          final t = await _time(s);
          if (t != null) setState(() => setS(t));
        },
        child: Text(
          '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}',
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('–'),
      ),
      OutlinedButton(
        onPressed: () async {
          final t = await _time(e);
          if (t != null) setState(() => setE(t));
        },
        child: Text(
          '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}',
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: const Text('Beosztás')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Add meg az ismétlődő ciklust, a kezdőnapot és hogy meddig készüljön. Minden műszak külön eseményként kerül a naptárba.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text('Ciklus', style: Theme.of(context).textTheme.titleMedium),
              for (var i = 0; i < _rows.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<ShiftType>(
                        isExpanded: true,
                        value: _rows[i].type,
                        items: [
                          for (final t in ShiftType.values)
                            DropdownMenuItem(
                              value: t,
                              child: Text(_typeLabels[t]!),
                            ),
                        ],
                        onChanged: (v) => setState(() => _rows[i].type = v!),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Kevesebb nap',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: _rows[i].days > 1
                          ? () => setState(() => _rows[i].days--)
                          : null,
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${_rows[i].days} nap',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Több nap',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => setState(() => _rows[i].days++),
                    ),
                    IconButton(
                      tooltip: 'Lépés törlése',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _rows.length > 1
                          ? () => setState(() => _rows.removeAt(i))
                          : null,
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _rows.add(_Row(ShiftType.off, 1))),
                  icon: const Icon(Icons.add),
                  label: const Text('Lépés hozzáadása'),
                ),
              ),
              const Divider(height: 28),
              Text(
                'Műszakidők',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _timeRow(
                'Éjszakai',
                _nightStart,
                _nightEnd,
                (t) => _nightStart = t,
                (t) => _nightEnd = t,
              ),
              const SizedBox(height: 8),
              _timeRow(
                'Nappali',
                _dayStart,
                _dayEnd,
                (t) => _dayStart = t,
                (t) => _dayEnd = t,
              ),
              const Divider(height: 28),
              Row(
                children: [
                  const SizedBox(width: 140, child: Text('Kezdőnap')),
                  OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime(
                          _from.year,
                          _from.month,
                          _from.day,
                        ),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) {
                        setState(
                          () => _from = DateTime.utc(d.year, d.month, d.day),
                        );
                      }
                    },
                    child: Text(fmtDateLong(_from)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 140, child: Text('Meddig')),
                  DropdownButton<int>(
                    value: _months,
                    items: const [
                      DropdownMenuItem(value: 3, child: Text('3 hónapig')),
                      DropdownMenuItem(value: 6, child: Text('6 hónapig')),
                      DropdownMenuItem(value: 12, child: Text('12 hónapig')),
                    ],
                    onChanged: (v) => setState(() => _months = v!),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Előnézet: ${plan.length} műszak',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final s in plan.take(6))
                        Text(
                          '${fmtDate(s.start)} ${fmtTime(s.start)} – ${fmtDate(s.end)} ${fmtTime(s.end)}  ${s.title}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      if (plan.length > 6)
                        const Text('…', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A kezdőnaptól kezdve a korábban innen generált műszakokat lecseréli. A kézzel felvett eseményeket nem érinti.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.event_repeat),
                label: const Text('Létrehozás a naptárban'),
              ),
              if (_msg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_msg!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
