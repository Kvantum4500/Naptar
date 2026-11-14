import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/event_repository.dart';
import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import 'breakpoints.dart';
import 'day_utils.dart';
import 'delete_ops.dart';
import 'format.dart';
import 'palette.dart';
import 'repeat_editor.dart';
import 'text_scale.dart';
import 'undo_service.dart';

const calendarIdLocal = kNaptarCalendar;

enum Scope { only, following, all }

/// Everything the editor needs about what is being edited.
class EditTarget {
  const EditTarget({
    this.event,
    this.master,
    this.overrides = const [],
    this.originalStart,
    this.initialStart,
    this.initialDay,
    this.initialTitle,
    this.initialEnd,
    this.initialAllDay = false,
    this.initialRrule,
  });

  /// The stored event being edited (a master, a single event, or an override).
  final CalEvent? event;

  /// The series master when [event] belongs to a series (may be [event] itself).
  final CalEvent? master;
  final List<CalEvent> overrides;

  /// Floating original start of the tapped occurrence of a series.
  final DateTime? originalStart;

  /// For new events: start slot (wall-clock) or just the day.
  final DateTime? initialStart;
  final DateTime? initialDay;

  /// For new events made from a line of text ("Szerkesztés…" of the quick
  /// entry): what is already known. [initialEnd] is the floating end of a
  /// timed event; an all-day event is one day long.
  final String? initialTitle;
  final DateTime? initialEnd;
  final bool initialAllDay;
  final String? initialRrule;

  bool get isSeriesOccurrence => master != null && originalStart != null;
}

/// Opens the editor for a tapped occurrence (or a new event when [o] is null).
Future<bool?> openEditor(
  BuildContext context,
  WidgetRef ref, {
  Occurrence? occurrence,
  DateTime? initialStart,
  DateTime? initialDay,
  String? initialTitle,
  DateTime? initialEnd,
  bool initialAllDay = false,
  String? initialRrule,
}) async {
  final repo = ref.read(repoProvider);
  var target = EditTarget(
    initialStart: initialStart,
    initialDay: initialDay ?? ref.read(selectedDayProvider),
    initialTitle: initialTitle,
    initialEnd: initialEnd,
    initialAllDay: initialAllDay,
    initialRrule: initialRrule,
  );
  if (occurrence != null) {
    final e = await repo.byId(occurrence.eventId);
    if (e == null) return null;
    final master = e.isException
        ? await repo.byId(e.recurringEventId!)
        : (e.isRecurring ? e : null);
    target = EditTarget(
      event: e,
      master: master,
      overrides: master == null ? const [] : await repo.overridesOf(master.id),
      originalStart: master == null ? null : occurrence.originalStart,
    );
  }
  if (!context.mounted) return null;
  final wide = useRail(MediaQuery.sizeOf(context).width);
  final editor = EventEditor(target: target);
  if (wide) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 760),
          child: editor,
        ),
      ),
    );
  }
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
  );
}

class EventEditor extends ConsumerStatefulWidget {
  const EventEditor({super.key, required this.target});
  final EditTarget target;

  @override
  ConsumerState<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends ConsumerState<EventEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title, _notes, _location;
  late bool _allDay;
  late DateTime _start; // floating
  late DateTime _end; // floating; for all-day: INCLUSIVE last day in the UI
  late String? _colorId;
  RecurrenceSpec? _spec;
  String? _rawRule; // a rule this editor cannot express; kept untouched
  String? _error;
  late final String _initialSignature;
  bool _busy = false;

  EditTarget get t => widget.target;
  CalEvent? get _e => t.event;
  CalEvent? get _master => t.master;
  bool get _isSeries => t.isSeriesOccurrence;

  @override
  void initState() {
    super.initState();
    final e = _e;
    _title = TextEditingController(text: e?.title ?? t.initialTitle ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _location = TextEditingController(text: e?.location ?? '');
    _allDay = e?.allDay ?? t.initialAllDay;
    _colorId = e?.colorId;
    if (e == null) {
      final s =
          t.initialStart ??
          (() {
            final today = ref.read(todayProvider);
            final d = t.initialDay ?? today;
            return floating(d.year, d.month, d.day, 9);
          })();
      _start = s;
      _end = t.initialEnd ?? s.add(const Duration(hours: 1));
    } else if (_isSeries && !e.isException) {
      // plain occurrence of a series: show THIS occurrence's date/time
      final m = _master!;
      _start = t.originalStart!;
      final len = m.end.difference(m.start);
      _end = m.allDay
          ? _start.add(len).subtract(const Duration(days: 1))
          : _start.add(len);
    } else {
      _start = e.start;
      _end = e.allDay ? e.end.subtract(const Duration(days: 1)) : e.end;
    }
    // Rule of the series (also when editing an exception instance).
    final ruleOwner = _master ?? e;
    if (ruleOwner != null && ruleOwner.isRecurring) {
      _spec = RecurrenceSpec.fromRrule(ruleOwner.rrule!, ruleOwner.start);
      if (_spec == null) _rawRule = ruleOwner.rrule;
    } else if (ruleOwner == null && t.initialRrule != null) {
      _spec = RecurrenceSpec.fromRrule(t.initialRrule!, _start);
      if (_spec == null) _rawRule = t.initialRrule;
    }
    _initialSignature = _signature();
  }

  String _signature() => [
    _title.text,
    _notes.text,
    _location.text,
    _allDay,
    _start,
    _end,
    _colorId,
    _spec?.toRrule(_start),
    _rawRule,
  ].join('|');

  bool get _dirty => _signature() != _initialSignature;

  @override
  void dispose() {
    for (final c in [_title, _notes, _location]) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ pickers

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
    final tm = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (tm == null) return;
    setState(() {
      final n = floating(cur.year, cur.month, cur.day, tm.hour, tm.minute);
      if (isStart) {
        final len = _end.difference(_start);
        _start = n;
        _end = n.add(len);
      } else {
        _end = n;
      }
    });
  }

  void _quickDuration(Duration d) => setState(() => _end = _start.add(d));

  // --------------------------------------------------------------- save

  String? get _ruleString => _spec != null ? _spec!.toRrule(_start) : _rawRule;

  /// The event as described by the form (id/links are filled in later).
  CalEvent _formEvent() {
    final start = _allDay
        ? floating(_start.year, _start.month, _start.day)
        : _start;
    final end = _allDay
        ? floating(_end.year, _end.month, _end.day).add(const Duration(days: 1))
        : _end;
    final base = _master ?? _e;
    var notes = _notes.text.trim();
    // a generated shift whose title or hours the user changed is "modified":
    // regenerating the pattern then keeps it
    if (base != null &&
        base.notes == kShiftMarker &&
        notes == kShiftMarker &&
        (_title.text.trim() != base.title ||
            start != base.start ||
            end != base.end)) {
      notes = kShiftEditedMarker;
    }
    return CalEvent(
      id: base?.id ?? 'form',
      calendarId: base?.calendarId ?? calendarIdLocal,
      title: _title.text.trim(),
      notes: notes,
      location: _location.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      tzid: _allDay ? null : (base?.tzid ?? defaultTz),
      rrule: _ruleString,
      colorId: _colorId,
    );
  }

  bool get _ruleChanged =>
      _isSeries && (_ruleString ?? '') != (_master!.rrule ?? '');

  Future<Scope?> _askScope({required bool delete}) => showDialog<Scope>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(
        delete ? 'Ismétlődő esemény törlése' : 'Ismétlődő esemény módosítása',
      ),
      children: [
        if (!_ruleChanged || delete)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, Scope.only),
            child: const Text('Csak ez az esemény'),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, Scope.following),
          child: const Text('Ez és a következő események'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, Scope.all),
          child: const Text('Az összes esemény'),
        ),
        if (!delete && _ruleChanged)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              'Az ismétlődési szabály módosításánál a „csak ez” nem választható.',
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    ),
  );

  Future<void> _save() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) return;
    if (_spec?.validate() != null) {
      setState(() => _error = _spec!.validate());
      return;
    }
    if (_allDay ? _end.isBefore(_start) : !_end.isAfter(_start)) {
      setState(
        () => _error = _allDay
            ? 'A befejezés nem lehet a kezdés előtt.'
            : 'A befejezésnek a kezdés után kell lennie.',
      );
      return;
    }
    setState(() => _error = null);
    final repo = ref.read(repoProvider);
    final formEv = _formEvent();
    const uuid = Uuid();
    setState(() => _busy = true);
    try {
      if (!_isSeries) {
        final old = _e;
        final ev = CalEvent(
          id: old?.id ?? uuid.v4(),
          calendarId: old?.calendarId ?? calendarIdLocal,
          title: formEv.title,
          notes: formEv.notes,
          location: formEv.location,
          start: formEv.start,
          end: formEv.end,
          allDay: formEv.allDay,
          tzid: formEv.tzid,
          rrule: formEv.rrule,
          exdates: old?.exdates ?? const [],
          colorId: formEv.colorId,
          aiGenerated: old?.aiGenerated ?? false,
          version: (old?.version ?? 0) + 1,
          googleId: old?.googleId,
          etag: old?.etag,
          iCalUid: old?.iCalUid,
        );
        await repo.saveLocal(ev);
      } else {
        final scope = await _askScope(delete: false);
        if (scope == null) {
          setState(() => _busy = false);
          return;
        }
        // a split into two series, the exceptions that move with it ...: all
        // or nothing, and one change for the screens
        await repo.atomically(() => _saveSeries(scope, formEv, repo, uuid));
      }
      ref.read(syncControllerProvider.notifier).requestSync();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'event.save_failed', e, st);
      if (mounted) {
        setState(() => _error = 'Mentés sikertelen: ${errorInfoFor(e).text}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSeries(
    Scope scope,
    CalEvent formEv,
    EventRepository repo,
    Uuid uuid,
  ) async {
    final m = _master!;
    final orig = t.originalStart!;
    switch (scope) {
      case Scope.only:
        final existing = _e!.isException ? _e : null;
        if (existing != null) {
          await repo.saveLocal(
            existing.copyWith(
              title: formEv.title,
              notes: formEv.notes,
              location: formEv.location,
              start: formEv.start,
              end: formEv.end,
              colorId: formEv.colorId,
              clearColor: formEv.colorId == null,
            ),
          );
        } else {
          await repo.saveLocal(
            makeOverride(
              master: m,
              originalStart: orig,
              edited: formEv,
              newId: uuid.v4(),
            ),
          );
        }
      case Scope.following:
        final r = splitSeries(
          master: m,
          splitAt: orig,
          edited: formEv,
          newId: uuid.v4(),
          overrides: t.overrides,
        );
        if (r.truncated == null) {
          // first instance chosen: the whole series is replaced = edit all
          await _saveAll(m, formEv, orig, repo);
        } else {
          await repo.saveLocal(r.truncated!);
          await repo.saveLocal(r.newSeries);
          for (final o in r.droppedOverrides) {
            await repo.deleteLocal(o.id);
          }
        }
      case Scope.all:
        await _saveAll(m, formEv, orig, repo);
    }
  }

  Future<void> _saveAll(
    CalEvent m,
    CalEvent formEv,
    DateTime orig,
    EventRepository repo,
  ) async {
    // The instance the user edited moved by (formStart - orig): shift the
    // whole series by the same amount, keep its length.
    final shift = formEv.start.difference(orig);
    final newStart = m.start.add(shift);
    final newEnd = newStart.add(formEv.end.difference(formEv.start));
    final edited = CalEvent(
      id: m.id,
      calendarId: m.calendarId,
      title: formEv.title,
      notes: formEv.notes,
      location: formEv.location,
      start: newStart,
      end: newEnd,
      allDay: formEv.allDay,
      tzid: formEv.tzid,
      rrule: _spec != null ? _spec!.toRrule(newStart) : _rawRule,
      colorId: formEv.colorId,
    );
    final res = editAll(master: m, edited: edited, overrides: t.overrides);
    await repo.saveLocal(res.master);
    for (final o in res.overrides) {
      await repo.saveLocal(o);
    }
  }

  // ------------------------------------------------------------- delete

  Future<void> _delete() async {
    final e = _e!;
    // A recurring event: which part goes is a choice, not a confirmation.
    // A single event goes at once: "Visszavonás" takes it back.
    var scope = Scope.only;
    if (_isSeries) {
      final asked = await _askScope(delete: true);
      if (asked == null || !mounted) return;
      scope = asked;
    }
    // This page closes below, and its context and `ref` are dead when the
    // user taps "Visszavonás": everything that is needed is taken now.
    final repo = ref.read(repoProvider);
    final undo = ref.read(undoServiceProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    final site = UndoSite.of(context);
    final originalStart = t.originalStart ?? e.start;
    final recurring = _isSeries;
    await undo.run(
      site,
      holdIds: [e.id],
      change: () => deleteEvent(
        repo,
        eventId: e.id,
        originalStart: originalStart,
        recurring: recurring,
        scope: scope,
      ),
      message: (_) => switch ((recurring, scope)) {
        (false, _) => 'Esemény törölve',
        (true, Scope.only) => 'Az előfordulás törölve',
        (true, Scope.following) => 'Az előfordulás és a következők törölve',
        (true, Scope.all) => 'A sorozat törölve',
      },
    );
    sync.requestSync();
    if (mounted) Navigator.of(context).pop(true);
  }

  // ----------------------------------------------------------------- UI

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Elveted a módosításokat?'),
        content: const Text('A mentetlen változtatások elvesznek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Maradok'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Elvetem'),
          ),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    final editing = _e != null;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop(false);
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.escape): () async {
            if (await _confirmDiscard() && context.mounted) {
              Navigator.of(context).pop(false);
            }
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: IconButton(
                tooltip: 'Bezár',
                icon: const Icon(Icons.close),
                onPressed: () async {
                  if (await _confirmDiscard() && context.mounted) {
                    Navigator.of(context).pop(false);
                  }
                },
              ),
              title: Text(editing ? 'Esemény szerkesztése' : 'Új esemény'),
              actions: [
                if (editing)
                  IconButton(
                    tooltip: 'Törlés',
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Mentés'),
                  ),
                ),
              ],
            ),
            body: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _title,
                    autofocus: !editing,
                    style: Theme.of(context).textTheme.titleLarge,
                    decoration: const InputDecoration(labelText: 'Cím'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Adj meg egy címet'
                        : null,
                  ),
                  if (_isSeries)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.repeat, size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Ismétlődő sorozat tagja: ${describeRrule(_master!.rrule, _master!.start)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  _section(
                    'Időpont',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Egész napos'),
                          value: _allDay,
                          onChanged: (v) => setState(() => _allDay = v),
                        ),
                        _row(
                          'Kezdés',
                          fmtDateLong(_start),
                          _allDay ? null : fmtTime(_start),
                          () => _pickDate(true),
                          () => _pickTime(true),
                        ),
                        _row(
                          'Befejezés',
                          fmtDateLong(_end),
                          _allDay ? null : fmtTime(_end),
                          () => _pickDate(false),
                          () => _pickTime(false),
                        ),
                        if (!_allDay)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final d in const [
                                  Duration(minutes: 30),
                                  Duration(hours: 1),
                                  Duration(hours: 2),
                                ])
                                  ActionChip(
                                    label: Text(fmtDuration(d)),
                                    onPressed: () => _quickDuration(d),
                                  ),
                                if (_end.isAfter(_start))
                                  Text(
                                    '(${fmtDuration(_end.difference(_start))})',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  _section(
                    'Ismétlődés',
                    _rawRule != null && _spec == null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Egyedi szabály: $_rawRule'),
                              const SizedBox(height: 6),
                              const Text(
                                'Ezt a szabályt az Google-ből kaptuk, a szerkesztő nem tudja megjeleníteni; változatlanul megmarad.',
                                style: TextStyle(fontSize: 12),
                              ),
                              TextButton(
                                onPressed: () => setState(() {
                                  _rawRule = null;
                                  _spec = const RecurrenceSpec(
                                    freq: RepeatFreq.weekly,
                                  );
                                }),
                                child: const Text(
                                  'Átállás szerkeszthető szabályra',
                                ),
                              ),
                            ],
                          )
                        : RepeatEditor(
                            start: _start,
                            spec: _spec,
                            onChanged: (s) => setState(() {
                              _spec = s;
                              _rawRule = null;
                            }),
                          ),
                  ),
                  _section(
                    'Részletek',
                    Column(
                      children: [
                        TextFormField(
                          controller: _location,
                          decoration: const InputDecoration(
                            labelText: 'Helyszín',
                            prefixIcon: Icon(Icons.place_outlined),
                          ),
                        ),
                        TextFormField(
                          controller: _notes,
                          decoration: const InputDecoration(
                            labelText: 'Megjegyzés',
                            prefixIcon: Icon(Icons.notes),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Szín',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _ColorPicker(
                          value: _colorId,
                          onChanged: (c) => setState(() => _colorId = c),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  const SizedBox(height: 12),
                  _SourceBadge(event: _master ?? _e),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    ),
  );

  Widget _row(
    String label,
    String date,
    String? time,
    VoidCallback onDate,
    VoidCallback onTime,
  ) {
    // At a large text size the label and the date do not fit side by side
    // (a label broken in the middle of its word, a date over four lines): the
    // buttons flow under the label then.
    if (context.textFactor() >= 1.3) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 84),
            child: Text(label),
          ),
          TextButton(onPressed: onDate, child: Text(date)),
          if (time != null) TextButton(onPressed: onTime, child: Text(time)),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label)),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onDate, child: Text(date)),
          ),
        ),
        if (time != null) TextButton(onPressed: onTime, child: Text(time)),
      ],
    );
  }
}

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget dot(String? id, Color c, String tip) => Tooltip(
      message: tip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onChanged(id),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: value == id
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: value == id
              ? Icon(Icons.check, size: 16, color: onEventColor(c))
              : null,
        ),
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        dot(null, defaultEventColor, 'Alapértelmezett'),
        for (final e in eventColorChoices)
          dot(e.key, e.value, eventColorNames[e.key] ?? e.key),
      ],
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.event});
  final CalEvent? event;
  @override
  Widget build(BuildContext context) {
    if (event == null) {
      return const Text(
        'Mentés után a Google „Naptar” naptárába szinkronizálódik.',
        style: TextStyle(fontSize: 12),
      );
    }
    final synced = event!.googleId != null;
    return Row(
      children: [
        Icon(
          synced ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
          size: 16,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            [
              synced
                  ? 'Szinkronban a Google-lel'
                  : 'Még nincs elküldve a Google-nek',
              if (event!.aiGenerated) 'AI-javaslatból jött',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
