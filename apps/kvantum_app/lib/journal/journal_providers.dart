import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_log.dart';
import '../providers.dart';
import '../sync/sync_controller.dart';
import 'journal_ops.dart';
import 'photo_arrivals.dart';
import 'photo_import.dart';

/// The diary: the entries that are not deleted, the newest first.
final journalEntriesProvider = StreamProvider<List<JournalEntry>>(
  (ref) => ref.watch(recordRepoProvider).watch(kindJournal).map(journalEntries),
);

/// What the changes of the diary are done by (and ask the sync to run after).
final journalOpsProvider = Provider<JournalOps>(
  (ref) => JournalOps(
    ref.watch(recordRepoProvider),
    onChanged: () => ref.read(syncControllerProvider.notifier).requestSync(),
  ),
);

/// What takes the chosen pictures into the diary.
final photoImporterProvider = Provider<PhotoImporter>(
  (ref) => PhotoImporter(
    files: ref.watch(photoFilesProvider),
    log: ref.watch(diagLogProvider),
  ),
);

/// The bytes of a picture file of this device, or null when it is not here
/// (it was taken on another device, and has not come yet). Kept while a screen
/// shows it; read again when the file arrives from Drive ([PhotoArrivals]).
final photoBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, fileName) {
      ref.watch(photoArrivalsProvider.select((m) => m[fileName]));
      return ref.watch(photoFilesProvider).read(fileName);
    });
