import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart' show CalView;
import 'shell_tab.dart';

/// The keyboard commands of the calendar page (a hardware keyboard: a Windows
/// PC, a tablet with a keyboard). They do their work only while no text is
/// being edited, so typing a name with an "n" in it still works.
class NewEventIntent extends Intent {
  const NewEventIntent();
}

class TodayIntent extends Intent {
  const TodayIntent();
}

/// Previous (-1) or next (+1) month, week or day, by the view.
class StepIntent extends Intent {
  const StepIntent(this.dir);
  final int dir;
}

class ViewIntent extends Intent {
  const ViewIntent(this.view);
  final CalView view;
}

class SyncIntent extends Intent {
  const SyncIntent();
}

class HelpIntent extends Intent {
  const HelpIntent();
}

/// Key -> command.
const calendarShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyN): NewEventIntent(),
  SingleActivator(LogicalKeyboardKey.keyT): TodayIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft): StepIntent(-1),
  SingleActivator(LogicalKeyboardKey.arrowRight): StepIntent(1),
  SingleActivator(LogicalKeyboardKey.digit1): ViewIntent(CalView.month),
  SingleActivator(LogicalKeyboardKey.digit2): ViewIntent(CalView.week),
  SingleActivator(LogicalKeyboardKey.digit3): ViewIntent(CalView.day),
  SingleActivator(LogicalKeyboardKey.f5): SyncIntent(),
  SingleActivator(LogicalKeyboardKey.f1): HelpIntent(),
  CharacterActivator('?'): HelpIntent(),
};

/// Whether the keyboard is typing into a text field right now.
bool isEditingText() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// An action that does nothing (and lets the key through) while text is being
/// edited.
class PageAction<T extends Intent> extends CallbackAction<T> {
  PageAction(void Function(T intent) onInvoke) : super(onInvoke: onInvoke);

  @override
  bool isEnabled(T intent) => !isEditingText();
}

/// The list the help dialog shows: what to press, what it does.
const shortcutHelp = <(String, String)>[
  ('N', 'Új esemény'),
  ('T', 'Ugrás a mai napra'),
  ('← →', 'Előző / következő hónap, hét vagy nap'),
  ('1  2  3', 'Hónap, hét, nap nézet'),
  ('F5', 'Szinkron most'),
  ('F1  vagy  ?', 'Ez a súgó'),
  ('Ctrl+S', 'Mentés (az esemény szerkesztőjében)'),
  ('Esc', 'Bezárás (a szerkesztőben)'),
];

Future<void> showShortcutHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: const Text('Billentyűparancsok'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Table(
          columnWidths: const {0: IntrinsicColumnWidth()},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (final (keys, what) in shortcutHelp)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      keys,
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Text(what),
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('shortcut-help-close'),
        onPressed: () => Navigator.pop(c),
        child: const Text('Rendben'),
      ),
    ],
  ),
);

/// Puts [actions] and the keys of [calendarShortcuts] around the calendar. It
/// takes the keyboard focus when the page appears and when the calendar tab is
/// chosen again, so the keys work without clicking first.
class CalendarKeys extends ConsumerStatefulWidget {
  const CalendarKeys({super.key, required this.actions, required this.child});
  final Map<Type, Action<Intent>> actions;
  final Widget child;

  @override
  ConsumerState<CalendarKeys> createState() => _CalendarKeysState();
}

class _CalendarKeysState extends ConsumerState<CalendarKeys> {
  final _node = FocusNode(debugLabel: 'calendar keys');

  @override
  void initState() {
    super.initState();
    ref.listenManual(shellTabProvider, (_, tab) {
      if (tab != ShellTab.calendar) return;
      // after the tab is shown (it was excluded from focus until now)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: calendarShortcuts,
    child: Actions(
      actions: widget.actions,
      child: Focus(focusNode: _node, autofocus: true, child: widget.child),
    ),
  );
}
