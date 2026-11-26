import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

/// Events whose queued changes must not be uploaded yet: a deletion (or another
/// change) the user can still take back with "Visszavonás".
///
/// It lives in memory on purpose. If the app is closed during the window, the
/// change simply goes up later: the safe direction.
///
/// A hold is placed on an event id. It covers that event and, for a series
/// master, every exception that hangs on it, so holding the master of a series
/// is enough for all its rows.
class SyncHold {
  final _counts = <String, int>{};

  /// Holds [ids] until the returned token is released. Holds add up: two
  /// overlapping holds on one id keep it held until both are released.
  SyncHoldToken acquire(Iterable<String> ids) {
    final held = {...ids};
    for (final id in held) {
      _counts[id] = (_counts[id] ?? 0) + 1;
    }
    return SyncHoldToken._(this, held);
  }

  /// Whether the queued changes of the event [id] have to wait. [seriesId] is
  /// the master of the series when the event is an exception of it.
  bool isHeld(String id, {String? seriesId}) =>
      (_counts[id] ?? 0) > 0 ||
      (seriesId != null && (_counts[seriesId] ?? 0) > 0);

  /// [isHeld] for an event as the sync queue knows it: an exception is held
  /// when its series is.
  bool holdsEvent(CalEvent e) => isHeld(e.id, seriesId: e.recurringEventId);

  /// Nothing is held.
  bool get isEmpty => _counts.isEmpty;

  void _release(Set<String> ids) {
    for (final id in ids) {
      final n = (_counts[id] ?? 0) - 1;
      if (n <= 0) {
        _counts.remove(id);
      } else {
        _counts[id] = n;
      }
    }
  }
}

/// What [SyncHold.acquire] hands out. Releasing it more than once is harmless.
class SyncHoldToken {
  SyncHoldToken._(this._hold, this._ids);
  final SyncHold _hold;
  final Set<String> _ids;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    _hold._release(_ids);
  }
}

final syncHoldProvider = Provider<SyncHold>((ref) => SyncHold());
