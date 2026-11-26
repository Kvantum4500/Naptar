import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/error_catalog.dart';
import '../sync/sync_controller.dart';
import 'day_utils.dart';
import 'event_editor.dart' show openEditor;
import 'quick_entry_ops.dart';
import 'tasks_page.dart' show openTaskEditor;
import 'undo_service.dart';

/// What the quick entry dialog was closed with.
sealed class QuickOutcome {
  const QuickOutcome();
}

/// The item was made.
class QuickAdded extends QuickOutcome {
  const QuickAdded(this.created);
  final QuickCreated created;
}

/// "Szerkesztés…": the full editor opens with what was understood.
class QuickToEdit extends QuickOutcome {
  const QuickToEdit(this.entry);
  final QuickEntry entry;
}

/// Examples of what can be written (they are also buttons: a tap fills them in).
const quickExamples = <String>[
  'holnap 18:00 edzés',
  'péntekig számla befizetése',
  'minden hétfőn 7:00 futás',
];

/// Whether the line says a day (a date, an hour, a repeat: all of them come
/// with a day) next to a title: the search offers to make it then.
bool looksLikeQuickEntry(QuickEntry e) => e.hasTitle && e.date != null;

/// The wall clock of the display zone right now.
DateTime wallNow(WidgetRef ref) =>
    toWallClock(defaultTz, ref.read(appClockProvider)().toUtc());

/// One line of text -> an event or a task: asks what was understood, shows it
/// and makes it. "Visszavonás" takes it back for a few seconds afterwards.
///
/// [initialText] fills the line in (the search page hands over what was typed
/// there).
Future<void> showQuickEntry(
  BuildContext context,
  WidgetRef ref, {
  String initialText = '',
}) async {
  // (everything the end needs is taken before the dialog: its own widgets
  // are gone by then)
  final site = UndoSite.of(context);
  final undo = ref.read(undoServiceProvider);
  final outcome = await showDialog<QuickOutcome>(
    context: context,
    builder: (_) => QuickEntryDialog(initialText: initialText),
  );
  switch (outcome) {
    case QuickAdded(:final created):
      undo.offer(
        site,
        message: created.message,
        undo: created.undo,
        hold: created.hold,
      );
    case QuickToEdit(:final entry):
      if (!context.mounted) return;
      await _openEditor(context, ref, entry);
    case null:
      break;
  }
}

Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref,
  QuickEntry e,
) async {
  if (e.kind == QuickKind.task) {
    await openTaskEditor(
      context,
      ref,
      initialTitle: e.title,
      initialDue: e.date,
      initialRule: e.date == null ? null : e.rrule,
    );
    return;
  }
  final allDay = e.allDay || e.startMinute == null;
  await openEditor(
    context,
    ref,
    initialTitle: e.title,
    initialStart: allDay ? null : e.start,
    initialEnd: allDay ? null : e.end,
    initialDay: e.date,
    initialAllDay: allDay,
    initialRrule: e.rrule,
  );
}

class QuickEntryDialog extends ConsumerStatefulWidget {
  const QuickEntryDialog({super.key, this.initialText = ''});
  final String initialText;

  @override
  ConsumerState<QuickEntryDialog> createState() => _QuickEntryDialogState();
}

class _QuickEntryDialogState extends ConsumerState<QuickEntryDialog> {
  late final TextEditingController _text;
  final _focus = FocusNode(debugLabel: 'quick entry');

  /// The choice made with the Esemény / Feladat chips for this text.
  QuickKind? _forced;
  bool _busy = false;
  String? _error;
  late String _lastText;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText)
      ..addListener(_changed);
    _lastText = _text.text;
  }

  /// A new text is a new question: the choice goes back to what is understood.
  void _changed() {
    if (_text.text == _lastText) return;
    _lastText = _text.text;
    setState(() {
      _forced = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  QuickEntry? _entry() {
    if (_text.text.trim().isEmpty) return null;
    final parsed = parseQuickEntry(_text.text, now: wallNow(ref));
    final k = _forced;
    // (an event needs a day: without one only a task can be made)
    if (k == null || (k == QuickKind.event && parsed.date == null)) {
      return parsed;
    }
    return parsed.withKind(k);
  }

  /// Whether this can be made right now.
  static bool _ready(QuickEntry? e) =>
      e != null && e.hasTitle && (e.kind == QuickKind.task || e.date != null);

  Future<void> _add() async {
    final entry = _entry();
    if (_busy || !_ready(entry)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await ref.read(quickEntryOpsProvider).create(entry!);
      ref.read(syncControllerProvider.notifier).requestSync();
      if (mounted) Navigator.of(context).pop(QuickAdded(created));
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = '${e.message}');
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'quick_entry.save_failed', e, st);
      if (mounted) {
        setState(() => _error = 'Mentés sikertelen: ${errorInfoFor(e).text}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit() {
    final entry = _entry();
    if (_busy || !_ready(entry)) return;
    Navigator.of(context).pop(QuickToEdit(entry!));
  }

  void _fill(String example) {
    _text.value = TextEditingValue(
      text: example,
      selection: TextSelection.collapsed(offset: example.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry();
    final ready = _ready(entry);
    final theme = Theme.of(context);
    return PopScope(
      // (a save in progress finishes first: its result must be handed over)
      canPop: !_busy,
      child: AlertDialog(
        // (a little wider on a phone: the line and the preview need the room)
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Gyors felvitel'),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('quick-text'),
                controller: _text,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [LengthLimitingTextInputFormatter(300)],
                decoration: const InputDecoration(
                  labelText: 'Mit vegyek fel?',
                  hintText: 'pl. holnap 18:00 edzés',
                  prefixIcon: Icon(Icons.bolt),
                ),
                onSubmitted: (_) => _add(),
              ),
              const SizedBox(height: 12),
              if (entry == null)
                _Help(onExample: _fill)
              else
                _Preview(
                  entry: entry,
                  today: ref.watch(todayProvider),
                  onKind: (k) => setState(() => _forced = k),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    key: const Key('quick-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('quick-cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Mégse'),
          ),
          TextButton(
            key: const Key('quick-edit'),
            onPressed: ready && !_busy ? _edit : null,
            child: const Text('Szerkesztés…'),
          ),
          FilledButton(
            key: const Key('quick-add'),
            onPressed: ready && !_busy ? _add : null,
            child: const Text('Felvesz'),
          ),
        ],
      ),
    );
  }
}

/// What can be written, while nothing is yet.
class _Help extends StatelessWidget {
  const _Help({required this.onExample});
  final void Function(String example) onExample;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      key: const Key('quick-help'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Írd le egy sorban, és megértem a napot, az időt és az ismétlődést. '
          'Például:',
          style: style,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final example in quickExamples)
              ActionChip(
                label: Text(example),
                onPressed: () => onExample(example),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Diktálhatsz is: a billentyűzet mikrofon-gombjával (Windowson '
          'Win+H) a beszéd szövegként kerül a sorba.',
          style: style,
        ),
      ],
    );
  }
}

/// What was understood, before anything is made.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.entry,
    required this.today,
    required this.onKind,
  });
  final QuickEntry entry;
  final DateTime today;
  final void Function(QuickKind kind) onKind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final noTitle = !entry.hasTitle;
    final repeatDate = entry.date;
    return Container(
      key: const Key('quick-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // (chips wrap onto a second line at a large text size; a switch
          // of two wide segments would not fit a phone)
          Wrap(
            key: const Key('quick-kind'),
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('quick-kind-event'),
                avatar: const Icon(Icons.event),
                label: const Text('Esemény'),
                selected: entry.kind == QuickKind.event,
                // (an event needs a day)
                onSelected: entry.date == null
                    ? null
                    : (_) => onKind(QuickKind.event),
              ),
              ChoiceChip(
                key: const Key('quick-kind-task'),
                avatar: const Icon(Icons.task_alt),
                label: const Text('Feladat'),
                selected: entry.kind == QuickKind.task,
                onSelected: (_) => onKind(QuickKind.task),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (noTitle)
            Text(
              'Mi legyen a címe? Írd a sorba, mit vegyek fel.',
              key: const Key('quick-no-title'),
              style: TextStyle(color: scheme.error),
            )
          else
            Text(
              entry.title,
              key: const Key('quick-title'),
              style: theme.textTheme.titleMedium,
            ),
          const SizedBox(height: 8),
          _Line(
            icon: entry.kind == QuickKind.task
                ? Icons.flag_outlined
                : Icons.schedule,
            text: quickWhen(entry, today),
            textKey: const Key('quick-when'),
          ),
          if (entry.repeats && repeatDate != null)
            _Line(
              icon: Icons.repeat,
              text: describeRrule(entry.rrule, repeatDate),
              textKey: const Key('quick-repeat'),
            ),
          if (entry.assumptions.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final a in entry.assumptions)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• $a',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, required this.textKey});
  final IconData icon;
  final String text;
  final Key textKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, key: textKey)),
      ],
    ),
  );
}
