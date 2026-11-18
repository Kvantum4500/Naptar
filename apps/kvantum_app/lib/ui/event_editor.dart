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

part 'event_editor/saving.dart';
part 'event_editor/widgets.dart';

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

  // The save and delete code lives in an extension of its own file, which
  // cannot call the protected [setState] itself.
  void _set(VoidCallback change) => setState(change);

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
