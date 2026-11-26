import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/event_change.dart';
import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_hold.dart';

/// How long "Visszavonás" is on offer (and a held deletion waits to go up).
const undoWindow = Duration(seconds: 10);

/// Where the bar is shown, captured while the page that asked for it is still
/// there: the editor closes right after a deletion, and its context is dead by
/// the time the user taps "Visszavonás".
class UndoSite {
  const UndoSite(this.messenger, this.width);

  /// The messenger above the whole app (the bar shows on the main frame).
  final ScaffoldMessengerState messenger;

  /// The window width, so the bar does not stretch across a wide window.
  final double width;

  factory UndoSite.of(BuildContext context) =>
      UndoSite(ScaffoldMessenger.of(context), MediaQuery.sizeOf(context).width);
}

class _Offer {
  _Offer(this.hold);
  final SyncHoldToken? hold;
  Timer? timer;

  /// "Visszavonás" was tapped: the undo is running and will finish the offer.
  bool acted = false;
  bool finished = false;
}

/// The text and the "Visszavonás" button of the bar. They wrap onto two lines
/// when they do not fit side by side, and the text is held to 1.5 times the
/// normal size for the few seconds the bar is up: at twice the size the button
/// alone is wider than a phone's bar.
class _UndoContent extends StatelessWidget {
  const _UndoContent({required this.message, required this.onUndo});
  final String message;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(maxScaleFactor: 1.5),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(message),
          TextButton(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              // (the bar's own action colour: made for the dark bar)
              foregroundColor:
                  Theme.of(context).snackBarTheme.actionTextColor ??
                  scheme.inversePrimary,
            ),
            child: const Text('Visszavonás'),
          ),
        ],
      ),
    );
  }
}

/// The "… törölve  [Visszavonás]" bar, and the hold that keeps the change
/// from being uploaded while it is on offer.
///
/// One offer at a time: a new one makes the previous one final (the user has
/// moved on). When an offer ends without being taken back, the hold is
/// released and a sync is requested, so what waited goes up.
class UndoService {
  UndoService(this._ref) {
    _ref.onDispose(_dispose);
  }
  final Ref _ref;
  _Offer? _current;

  /// Shows [message] with a "Visszavonás" button for [undoWindow].
  ///
  /// [undo] puts the change back and says whether it could (false: something
  /// changed meanwhile). [hold], if given, is released when the offer ends
  /// (after the undo has finished, when it was used).
  void offer(
    UndoSite site, {
    required String message,
    required Future<bool> Function() undo,
    SyncHoldToken? hold,
    String failedMessage =
        'A visszavonás már nem lehetséges: közben megváltozott.',
  }) {
    final previous = _current;
    // the previous deletion is final now (unless its undo is running: that
    // one ends the offer itself)
    if (previous != null && !previous.acted) _finish(previous);
    final offer = _Offer(hold);
    _current = offer;
    try {
      site.messenger.clearSnackBars(); // ours must not wait behind another
      // Flutter 3.50 keeps a bar with an action on screen for ever unless it
      // is told not to (`persist: false`).
      final bar = site.messenger.showSnackBar(
        SnackBar(
          // (the button is part of the content, not the bar's own action: at
          // the largest system text size the bar's action row does not fit
          // a phone; see [_UndoContent])
          content: _UndoContent(
            message: message,
            onUndo: () {
              _undo(offer, site, undo, failedMessage);
              site.messenger.hideCurrentSnackBar(
                reason: SnackBarClosedReason.action,
              );
            },
          ),
          duration: undoWindow,
          // (Flutter 3.50 keeps a bar with an action on screen for ever; ours
          // goes by itself)
          persist: false,
          behavior: SnackBarBehavior.floating,
          // above the round button of the pages (their buttons are not the
          // main frame's, so the frame cannot lift the bar by itself), and not
          // wider than a phone-sized bar on a big window
          margin: EdgeInsets.fromLTRB(
            _side(site.width),
            0,
            _side(site.width),
            88,
          ),
        ),
      );
      bar.closed.then((_) {
        if (!offer.acted) _finish(offer);
      });
    } catch (e, st) {
      // no messenger any more (the app is closing): nothing to take back
      _ref.read(diagLogProvider).error('ui', 'undo.show_failed', e, st);
      _finish(offer);
      return;
    }
    // The bar closes itself after [undoWindow]; this is the safety net for the
    // hold, in case the bar never gets to report it.
    offer.timer = Timer(undoWindow + const Duration(seconds: 1), () {
      if (!offer.acted) _finish(offer);
    });
  }

  /// Makes a change to the events with "Visszavonás" on offer afterwards.
  ///
  /// The series of [holdIds] and the ids in [newIds] are held back from the
  /// upload BEFORE [change] is made, and for as long as the bar is up.
  /// [change] returns what it changed (null or empty: nothing to take back,
  /// no bar). [onUndone] runs after a successful undo (a page that has to
  /// reload). Returns what [change] returned.
  Future<EventChangeSet?> run(
    UndoSite site, {
    required Future<EventChangeSet?> Function() change,
    required String Function(EventChangeSet changes) message,
    Iterable<String> holdIds = const [],
    Iterable<String> newIds = const [],
    Future<void> Function()? onUndone,
  }) async {
    final repo = _ref.read(repoProvider);
    final token = _ref.read(syncHoldProvider).acquire([
      ...await repo.seriesKeysOf(holdIds),
      ...newIds,
    ]);
    final EventChangeSet? changes;
    try {
      changes = await change();
    } catch (_) {
      token.release();
      rethrow;
    }
    if (changes == null || changes.isEmpty) {
      token.release();
      return null;
    }
    final done = changes;
    offer(
      site,
      message: message(done),
      hold: token,
      undo: () async {
        final ok = await repo.undoChange(done);
        if (ok) await onUndone?.call();
        return ok;
      },
    );
    return done;
  }

  static double _side(double width) => max(12, (width - 560) / 2);

  Future<void> _undo(
    _Offer offer,
    UndoSite site,
    Future<bool> Function() undo,
    String failedMessage,
  ) async {
    if (offer.finished || offer.acted) return;
    offer.acted = true; // the closing of the bar must not end the offer
    try {
      final ok = await undo();
      if (!ok) say(site, failedMessage);
    } catch (e, st) {
      _ref.read(diagLogProvider).error('ui', 'undo.failed', e, st);
      say(site, 'A visszavonás nem sikerült.');
    } finally {
      _finish(offer);
    }
  }

  /// Tells the user that something did not go through (a change that was not
  /// saved, an undo that could not be done): in the colours of an error, lifted
  /// over the round buttons of the page and not wider than a phone's bar, like
  /// the "Visszavonás" bar. A bar that is up is not waited for: what is told is
  /// more urgent, and what it offered is final once it has gone.
  void say(UndoSite site, String text) {
    try {
      final scheme = Theme.of(site.messenger.context).colorScheme;
      site.messenger.clearSnackBars();
      site.messenger.showSnackBar(
        SnackBar(
          // (the words say what went wrong; the colour, that it is one)
          backgroundColor: scheme.errorContainer,
          content: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
          duration: const Duration(seconds: 6),
          persist: false,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            _side(site.width),
            0,
            _side(site.width),
            88,
          ),
        ),
      );
    } catch (_) {
      // the app is closing: nobody is there to read it
    }
  }

  /// Ends an offer for good: the hold is released and what waited goes up.
  /// Harmless to call again.
  void _finish(_Offer? o) {
    if (o == null || o.finished) return;
    o.finished = true;
    o.timer?.cancel();
    o.hold?.release();
    if (identical(_current, o)) _current = null;
    _ref.read(syncControllerProvider.notifier).requestSync();
  }

  void _dispose() {
    final o = _current;
    if (o == null) return;
    o.finished = true;
    o.timer?.cancel();
    o.hold?.release();
    _current = null;
  }
}

final undoServiceProvider = Provider<UndoService>((ref) => UndoService(ref));
