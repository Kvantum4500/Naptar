import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../drive/photo_sync.dart';
import '../providers.dart';
import 'sync_controller.dart';

/// What the switch says about itself. (The size is what a picture of the
/// diary takes after it has been made smaller.)
const photoSyncSwitchHelp =
    'A napló képei a Google Drive rejtett app-mappájába kerülnek (kb. 0,4 MB '
    'képenként), és a többi eszközödön is megjelennek. Kikapcsolva csak ezen az '
    'eszközön vannak. Mobilneten is használhat adatot.';

/// The switch "Képek szinkronja" of this device (Beállítások → Fiók és
/// szinkron): whether the pictures of the diary go to the hidden folder of
/// Drive and come from it. On from the start; the choice is kept on this device
/// only (what one wants of the mobile data is no business of the others).
class PhotoSyncSwitch extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    final on = await photoSyncEnabled(ref.read(recordRepoProvider));
    if (ref.mounted) state = on;
  }

  /// Turns the pictures on or off; turning them on asks the sync to run.
  Future<void> set(bool on) async {
    state = on;
    await ref.read(recordRepoProvider).setMeta(photoSyncKey, on ? null : 'off');
    if (on) ref.read(syncControllerProvider.notifier).requestSync();
  }
}

final photoSyncSwitchProvider = NotifierProvider<PhotoSyncSwitch, bool>(
  PhotoSyncSwitch.new,
);

/// Whether the pictures are on their way to and from this device: signed in to
/// Google, and the switch on. (What a place-holder says depends on it: a
/// picture that is not here yet is coming, or it is on another device.)
final photoSyncActiveProvider = Provider<bool>(
  (ref) =>
      ref.watch(syncControllerProvider.select((s) => s.signedIn)) &&
      ref.watch(photoSyncSwitchProvider),
);
