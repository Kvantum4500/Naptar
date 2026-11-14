import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_change.dart';
import '../data/event_repository.dart';
import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart';
import 'delete_ops.dart';
import 'event_editor.dart' show Scope, openEditor;
import 'format.dart';
import 'shift_ops.dart';
import 'shift_pay_card.dart';
import 'undo_service.dart';

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
  late final DateTime _listFrom = ref.read(selectedDayProvider);
  var _months = 6;
  var _busy = false;
  String? _msg;
  late DateTime _month = DateTime.utc(_from.year, _from.month);
  var _events = const <CalEvent>[];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await ref.read(repoProvider).all();
    if (mounted) {
      setState(
        () => _events = [
          for (final e in all)
            if (isShiftNotes(e.notes)) e,
        ],
      );
    }
  }

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
    // (taken now: the day that is shown may not be changed under the work)
    final from = _from;
    if (plan.isEmpty) {
      setState(() => _msg = 'A ciklusban nincs egyetlen munkanap sem.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    final site = UndoSite.of(context);
    final undo = ref.read(undoServiceProvider);
    try {
      final repo = ref.read(repoProvider);
      final all = await repo.all();
      // days where the user changed or added a shift: kept as they are
      final keptDays = <DateTime>{
        for (final e in all)
          if (isEditedShiftNotes(e.notes))
            DateTime.utc(e.start.year, e.start.month, e.start.day),
      };
      final removeIds = [
        for (final e in all)
          if (e.notes == kShiftMarker &&
              !e.isRecurring &&
              !e.start.isBefore(from))
            e.id,
      ];
      final fresh = [
        for (final s in plan)
          if (!keptDays.contains(
            DateTime.utc(s.start.year, s.start.month, s.start.day),
          ))
            CalEvent(
              id: const Uuid().v4(),
              calendarId: kNaptarCalendar,
              title: s.title,
              notes: kShiftMarker,
              start: s.start,
              end: s.end,
              tzid: defaultTz,
            ),
      ];
      // One unit: the screens change once (not ninety times), and an
      // interruption leaves the old plan or the new one, never half of each.
      // "Visszavonás" brings the old plan back and removes the new one.
      await undo.run(
        site,
        holdIds: removeIds,
        newIds: [for (final f in fresh) f.id],
        change: () => repo.tracked(
          existing: removeIds,
          created: [for (final f in fresh) f.id],
          change: () => repo.atomically(() async {
            await repo.deleteAll(removeIds);
            await repo.saveAll(fresh);
          }),
        ),
        message: (_) => 'Beosztás elkészült: ${fresh.length} műszak',
        onUndone: () async {
          if (mounted) await _reload();
        },
      );
      final removed = removeIds.length, created = fresh.length;
      ref.read(syncControllerProvider.notifier).requestSync();
      await _reload();
      if (!mounted) return;
      setState(
        () => _msg =
            '$created műszak létrehozva${removed > 0 ? ', $removed korábbi generált műszak cseréjével' : ''}.',
      );
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'shift.generate_failed', e, st);
      if (mounted) {
        setState(() => _msg = 'Nem sikerült: ${errorInfoFor(e).text}');
      }
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
  ) => _LabelRow(
    label,
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
    ),
  );

  ShiftHours get _hours => ShiftHours(
    nightStart: _nightStart.hour * 60 + _nightStart.minute,
    nightMinutes: _len(_nightStart, _nightEnd),
    dayStart: _dayStart.hour * 60 + _dayStart.minute,
    dayMinutes: _len(_dayStart, _dayEnd),
  );

  List<CalEvent> get _upcoming => ([
    for (final e in _events)
      if (!e.start.isBefore(_listFrom)) e,
  ]..sort((a, b) => a.start.compareTo(b.start))).take(30).toList();

  Future<void> _swap(CalEvent e) async {
    final ok = await swapShiftType(ref.read(repoProvider), e, _hours);
    if (ok) ref.read(syncControllerProvider.notifier).requestSync();
    await _reload();
    if (mounted) {
      setState(
        () => _msg = ok
            ? 'Műszak cserélve, a további generálás megtartja.'
            : 'Ezt a műszakot nem lehet cserélni (a címe megváltozott).',
      );
    }
  }

  Future<void> _edit(CalEvent e) async {
    await openEditor(
      context,
      ref,
      occurrence: Occurrence(
        eventId: e.id,
        title: e.title,
        startUtc: e.startUtc,
        endUtc: e.endUtc,
        originalStart: e.start,
        allDay: false,
        tzid: e.tzid,
      ),
    );
    await _reload();
  }

  Future<void> _remove(CalEvent e) async {
    // No question: "Visszavonás" takes it back (and a regeneration brings the
    // shift back as well).
    final repo = ref.read(repoProvider);
    final undo = ref.read(undoServiceProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    final site = UndoSite.of(context);
    await undo.run(
      site,
      holdIds: [e.id],
      change: () => deleteEvent(
        repo,
        eventId: e.id,
        originalStart: e.start,
        recurring: false,
        scope: Scope.only,
      ),
      message: (_) => 'Műszak törölve',
      onUndone: () async {
        if (mounted) await _reload();
      },
    );
    sync.requestSync();
    if (mounted) await _reload();
  }

  Future<void> _addExtra() async {
    var day = _listFrom;
    var night = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Extra műszak'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text(fmtDate(day)),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: c,
                    initialDate: day,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) {
                    set(() => day = DateTime.utc(d.year, d.month, d.day));
                  }
                },
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Nappali')),
                  ButtonSegment(value: true, label: Text('Éjszakai')),
                ],
                selected: {night},
                onSelectionChanged: (v) => set(() => night = v.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Mégse'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Hozzáadom'),
            ),
          ],
        ),
      ),
    );
    if (go != true) return;
    await addExtraShift(
      ref.read(repoProvider),
      day,
      night: night,
      hours: _hours,
      tzid: defaultTz,
    );
    ref.read(syncControllerProvider.notifier).requestSync();
    await _reload();
    if (mounted) setState(() => _msg = 'Extra műszak hozzáadva.');
  }

  Widget _upcomingList() {
    final list = _upcoming;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Következő műszakok',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                TextButton.icon(
                  onPressed: _addExtra,
                  icon: const Icon(Icons.add),
                  label: const Text('Extra műszak'),
                ),
              ],
            ),
            if (list.isEmpty)
              const Text('Nincs műszak a kiválasztott naptól.')
            else
              for (final e in list)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${fmtDate(e.start)} ${fmtTime(e.start)}  ${e.title}'
                        '${isEditedShiftNotes(e.notes) ? ' (módosítva)' : ''}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Csere nappali/éjszakai',
                      icon: const Icon(Icons.swap_horiz),
                      onPressed: () => _swap(e),
                    ),
                    IconButton(
                      tooltip: 'Szerkesztés',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(e),
                    ),
                    IconButton(
                      tooltip: 'Műszak törlése',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(e),
                    ),
                  ],
                ),
            const SizedBox(height: 4),
            Text(
              'Az újragenerálás a módosított műszakokat megtartja, a törölteket visszahozhatja.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    final sum = summarizeShifts(
      [
        for (final e in _events)
          (title: e.title, notes: e.notes, start: e.start, end: e.end),
      ],
      year: _month.year,
      month: _month.month,
    );
    final theme = Theme.of(context);
    final h = sum.hours == sum.hours.roundToDouble()
        ? '${sum.hours.round()}'
        : sum.hours.toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Előző hónap',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(
                    () => _month = DateTime.utc(_month.year, _month.month - 1),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Havi összesítő: ${_month.year}. ${_month.month}. hó',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Következő hónap',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(
                    () => _month = DateTime.utc(_month.year, _month.month + 1),
                  ),
                ),
              ],
            ),
            if (sum.counts.isEmpty)
              const Text('Ebben a hónapban nincs generált műszak.')
            else ...[
              for (final e in sum.counts.entries) Text('${e.key}: ${e.value}'),
              Text('Műszakórák összesen: $h'),
            ],
            Text('Munkanap: ${sum.workDays} · szabadnap: ${sum.offDays}'),
            const SizedBox(height: 4),
            Text(
              'Egy műszak ahhoz a naphoz számít, amelyiken kezdődik.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: const Text('Beosztás')),
      // While the plan is being made nothing else on the page may be touched
      // (another day or cycle would change what is being made) and the
      // keyboard has no business here either; a spinner says why.
      body: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _busy,
            child: AbsorbPointer(absorbing: _busy, child: _form(context, plan)),
          ),
          if (_busy) const _Working(),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, List<PlannedShift> plan) {
    return Align(
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
            Text('Műszakidők', style: Theme.of(context).textTheme.titleMedium),
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
            _LabelRow(
              'Kezdőnap',
              OutlinedButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime(_from.year, _from.month, _from.day),
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
            ),
            const SizedBox(height: 8),
            _LabelRow(
              'Meddig',
              DropdownButton<int>(
                value: _months,
                items: const [
                  DropdownMenuItem(value: 3, child: Text('3 hónapig')),
                  DropdownMenuItem(value: 6, child: Text('6 hónapig')),
                  DropdownMenuItem(value: 12, child: Text('12 hónapig')),
                ],
                onChanged: (v) => setState(() => _months = v!),
              ),
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
            const SizedBox(height: 20),
            _summary(),
            const SizedBox(height: 12),
            ShiftPayCard(
              events: [
                for (final e in _events)
                  (title: e.title, notes: e.notes, start: e.start, end: e.end),
              ],
              year: _month.year,
              month: _month.month,
            ),
            const SizedBox(height: 12),
            _upcomingList(),
          ],
        ),
      ),
    );
  }
}

/// Over the page while the plan is being made.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.7),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(semanticsLabel: 'A beosztás készül'),
            SizedBox(height: 12),
            Text('A beosztás készül…'),
          ],
        ),
      ),
    ),
  );
}

/// A label and what it labels: side by side where they fit, the controls
/// under the label where they do not (a narrow window, large text).
class _LabelRow extends StatelessWidget {
  const _LabelRow(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 4,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 132),
        child: Text(label),
      ),
      child,
    ],
  );
}
