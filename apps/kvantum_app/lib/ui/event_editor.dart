import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../providers.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart';

const calendarIdLocal = 'primary';

enum Repeat { none, daily, weekly, monthly, yearly }

const _repeatLabels = {
  Repeat.none: 'Nem ismétlődik',
  Repeat.daily: 'Naponta',
  Repeat.weekly: 'Hetente',
  Repeat.monthly: 'Havonta',
  Repeat.yearly: 'Évente',
};

String? ruleFor(Repeat r, DateTime start, int? count) {
  final c = count == null ? '' : ';COUNT=$count';
  const days = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
  switch (r) {
    case Repeat.none:
      return null;
    case Repeat.daily:
      return 'FREQ=DAILY$c';
    case Repeat.weekly:
      return 'FREQ=WEEKLY;BYDAY=${days[start.weekday - 1]}$c';
    case Repeat.monthly:
      return 'FREQ=MONTHLY;BYMONTHDAY=${start.day}$c';
    case Repeat.yearly:
      return 'FREQ=YEARLY$c';
  }
}

Repeat repeatOf(String? rule) {
  if (rule == null || rule.isEmpty) return Repeat.none;
  if (rule.contains('FREQ=DAILY')) return Repeat.daily;
  if (rule.contains('FREQ=WEEKLY')) return Repeat.weekly;
  if (rule.contains('FREQ=MONTHLY')) return Repeat.monthly;
  if (rule.contains('FREQ=YEARLY')) return Repeat.yearly;
  return Repeat.none;
}

class EventEditor extends ConsumerStatefulWidget {
  const EventEditor({super.key, this.event, required this.initialDay});
  final CalEvent? event; // null = new
  final DateTime initialDay;

  @override
  ConsumerState<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends ConsumerState<EventEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title, _notes, _location, _count;
  late bool _allDay;
  late DateTime _start; // floating
  late DateTime _end; // floating; for all-day: INCLUSIVE last day in the UI
  late Repeat _repeat;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _title = TextEditingController(text: e?.title ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _location = TextEditingController(text: e?.location ?? '');
    _count = TextEditingController();
    _allDay = e?.allDay ?? false;
    if (e != null) {
      _start = e.start;
      _end = e.allDay ? e.end.subtract(const Duration(days: 1)) : e.end;
    } else {
      final d = widget.initialDay;
      _start = floating(d.year, d.month, d.day, 9);
      _end = floating(d.year, d.month, d.day, 10);
    }
    _repeat = repeatOf(e?.rrule);
  }

  @override
  void dispose() {
    for (final c in [_title, _notes, _location, _count]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate(bool isStart) async {
    final cur = isStart ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(cur.year, cur.month, cur.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      final n = floating(d.year, d.month, d.day, cur.hour, cur.minute);
      if (isStart) {
        final len = _end.difference(_start);
        _start = n;
        _end = n.add(len);
      } else {
        _end = n;
      }
    });
  }

  Future<void> _pickTime(bool isStart) async {
    final cur = isStart ? _start : _end;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
    );
    if (t == null) return;
    setState(() {
      final n = floating(cur.year, cur.month, cur.day, t.hour, t.minute);
      if (isStart) {
        final len = _end.difference(_start);
        _start = n;
        _end = n.add(len);
      } else {
        _end = n;
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_end.isBefore(_start)) {
      setState(() => _error = 'A befejezés nem lehet a kezdés előtt.');
      return;
    }
    if (!_allDay && !_end.isAfter(_start)) {
      setState(() => _error = 'A befejezésnek a kezdés után kell lennie.');
      return;
    }
    final count = int.tryParse(_count.text.trim());
    final old = widget.event;
    final start = _allDay
        ? floating(_start.year, _start.month, _start.day)
        : _start;
    final end = _allDay
        ? floating(_end.year, _end.month, _end.day).add(const Duration(days: 1))
        : _end;
    final ev = CalEvent(
      id: old?.id ?? const Uuid().v4(),
      calendarId: old?.calendarId ?? calendarIdLocal,
      title: _title.text.trim(),
      notes: _notes.text.trim(),
      location: _location.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      tzid: _allDay ? null : (old?.tzid ?? defaultTz),
      rrule: ruleFor(_repeat, start, count),
      exdates: old?.exdates ?? const [],
      recurringEventId: old?.recurringEventId,
      originalStart: old?.originalStart,
      version: (old?.version ?? 0) + 1,
      googleId: old?.googleId,
      etag: old?.etag,
      iCalUid: old?.iCalUid,
    );
    await ref.read(repoProvider).saveLocal(ev);
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final e = widget.event!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Törlés'),
        content: Text(
          e.isRecurring
              ? 'Az egész ismétlődő sorozat törlődik. Biztos vagy benne?'
              : 'Biztosan törlöd?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Törlés'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repoProvider).deleteLocal(e.id);
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat.yMMMEd('hu');
    final tf = DateFormat.Hm('hu');
    String d(DateTime x) => df.format(x);
    String t(DateTime x) => tf.format(x);
    final editing = widget.event != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Esemény szerkesztése' : 'Új esemény'),
        actions: [
          if (editing)
            IconButton(
              tooltip: 'Törlés',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton(onPressed: _save, child: const Text('Mentés')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Cím'),
              autofocus: !editing,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Adj meg egy címet' : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Egész napos'),
              value: _allDay,
              onChanged: (v) => setState(() => _allDay = v),
            ),
            _row(
              'Kezdés',
              d(_start),
              _allDay ? null : t(_start),
              () => _pickDate(true),
              () => _pickTime(true),
            ),
            _row(
              'Befejezés',
              d(_end),
              _allDay ? null : t(_end),
              () => _pickDate(false),
              () => _pickTime(false),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<Repeat>(
              initialValue: _repeat,
              decoration: const InputDecoration(labelText: 'Ismétlődés'),
              items: [
                for (final r in Repeat.values)
                  DropdownMenuItem(value: r, child: Text(_repeatLabels[r]!)),
              ],
              onChanged: (v) => setState(() => _repeat = v ?? Repeat.none),
            ),
            if (_repeat != Repeat.none)
              TextFormField(
                controller: _count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Ismétlések száma (üres = végtelen)',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final n = int.tryParse(v.trim());
                  return (n == null || n < 1 || n > 1000)
                      ? '1–1000 közötti szám'
                      : null;
                },
              ),
            if (editing && widget.event!.isRecurring)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'A módosítás az egész sorozatra vonatkozik.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            TextFormField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Helyszín'),
            ),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Megjegyzés'),
              maxLines: 3,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    String label,
    String date,
    String? time,
    VoidCallback onDate,
    VoidCallback onTime,
  ) => Row(
    children: [
      SizedBox(width: 90, child: Text(label)),
      TextButton(onPressed: onDate, child: Text(date)),
      if (time != null) TextButton(onPressed: onTime, child: Text(time)),
    ],
  );
}
