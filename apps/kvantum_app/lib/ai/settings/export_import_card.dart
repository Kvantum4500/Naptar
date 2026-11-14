import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup_ops.dart';
import '../../data/event_repository.dart' show kNaptarCalendar;
import '../../diag/diag_log.dart';
import '../../providers.dart';
import '../../sync/error_catalog.dart';
import '../../sync/sync_controller.dart';
import '../../ui/backup_io.dart';
import '../../ui/import_choice.dart';
import 'settings_toast.dart';

/// The four file jobs of the backup section.
enum _FileJob { exportIcs, importIcs, exportFinance, importFinance }

/// The body of the "Mentés és visszaállítás" card: the calendar and the money
/// data to a file and back. What is going on here (a backup being read,
/// restored …) belongs to the card, and the card is kept alive while it is
/// scrolled out of sight, so the buttons still wait for a job that runs.
class ExportImportBody extends ConsumerStatefulWidget {
  const ExportImportBody({super.key});

  @override
  ConsumerState<ExportImportBody> createState() => _ExportImportBodyState();
}

class _ExportImportBodyState extends ConsumerState<ExportImportBody>
    with AutomaticKeepAliveClientMixin {
  /// The file work in progress (a backup being read, restored …): the four
  /// buttons wait, and the one that was pressed shows a spinner.
  _FileJob? _fileJob;

  @override
  bool get wantKeepAlive => true;

  /// The results of the buttons appear as a snack bar: they sit far below the
  /// key section, where the page's own messages are not visible.
  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    showSettingsToast(context, m, error: error);
  }

  /// Marks the file work that is going on (null: none). The system's own file
  /// dialogs and our own questions are the user's turn, not work: they are not
  /// marked.
  void _working(_FileJob? job) {
    if (mounted) setState(() => _fileJob = job);
  }

  /// The icon of a file button: a small spinner while its own work goes on.
  Widget _fileIcon(_FileJob job, IconData icon) => _fileJob == job
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon);

  Future<void> _export() async {
    try {
      _working(_FileJob.exportIcs);
      final text = await exportBackup(ref.read(repoProvider));
      final d = DateTime.now();
      final name =
          'naptar-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.ics';
      _working(null); // (the save dialog is the system's)
      final ok = await ref.read(backupIoProvider).save(name, text);
      if (ok) _toast('A naptár elmentve.');
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.save_failed', e, st);
      _toast('A mentés nem sikerült: ${errorInfoFor(e).text}', error: true);
    } finally {
      _working(null);
    }
  }

  Future<void> _exportFinance() async {
    try {
      _working(_FileJob.exportFinance);
      final text = await ref.read(financeRepoProvider).exportJson();
      final d = DateTime.now();
      final name =
          'penzugyek-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json';
      _working(null); // (the save dialog is the system's)
      final ok = await ref.read(backupIoProvider).save(name, text);
      if (ok) _toast('A pénzügyi adatok elmentve.');
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.save_failed', e, st);
      _toast('A mentés nem sikerült: ${errorInfoFor(e).text}', error: true);
    } finally {
      _working(null);
    }
  }

  Future<void> _importFinance() async {
    try {
      final text = await ref.read(backupIoProvider).pick();
      if (text == null) return;
      // the file is chosen: from here on it is our work, and it shows
      _working(_FileJob.importFinance);
      await WidgetsBinding.instance.endOfFrame;
      final r = await ref.read(financeRepoProvider).importJson(text);
      final any = r.added + r.updated > 0;
      if (!r.recognized) {
        _toast('Ez nem pénzügyi mentésfájl.', error: true);
        return;
      }
      if (r.newer) {
        _toast(
          'Ezt a mentést az alkalmazás egy újabb verziója készítette; frissítsd az alkalmazást, hogy visszaállíthasd.',
          error: true,
        );
        return;
      }
      _toast(
        any
            ? 'Pénzügyi adat visszaállítva: ${r.added} új, ${r.updated} frissítve${r.skipped > 0 ? ', ${r.skipped} elem kihagyva' : ''}.'
            : r.skipped > 0
            ? 'Nem találtam használható pénzügyi adatot a fájlban.'
            : 'Nincs mit visszaállítani: minden adat naprakész.',
        error: !any && r.skipped > 0,
      );
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.restore_failed', e, st);
      _toast(
        'A visszaállítás nem sikerült: ${errorInfoFor(e).text}',
        error: true,
      );
    } finally {
      _working(null);
    }
  }

  Future<void> _import() async {
    try {
      final text = await ref.read(backupIoProvider).pick();
      if (text == null) return;
      // the file is chosen: from here on it is our work, and it shows (one
      // frame is let through, so the spinner is there before a big file is
      // read)
      _working(_FileJob.importIcs);
      await WidgetsBinding.instance.endOfFrame;
      final repo = ref.read(repoProvider);
      final plan = await previewBackup(repo, text, calendarId: kNaptarCalendar);
      // Events that changed on this device since the file was written are
      // only overwritten when the user says so.
      var overwrite = false;
      if (plan.changes.isNotEmpty) {
        if (!mounted) return;
        _working(null); // the question is the user's turn, not work
        final choice = await askImportChoice(context, plan);
        if (choice == null) return;
        overwrite = choice == ImportChoice.all;
        _working(_FileJob.importIcs);
      }
      final r = await applyBackup(repo, plan, overwrite: overwrite);
      if (r.total > 0) {
        ref.read(syncControllerProvider.notifier).requestSync();
      }
      // what the file says is told in words: the first thing as it is, and how
      // many more follow (a bare count told nobody what to look at)
      final more = r.problems.length - 1;
      final extra = r.problems.isEmpty
          ? ''
          : ' ${r.problems.first}${more > 0 ? ' (és még $more figyelmeztetés)' : ''}';
      final nothing = r.total == 0 && r.unchanged == 0 && r.kept == 0;
      final kept = r.kept > 0
          ? ' ${r.kept} módosult eseményt nem írtam felül.'
          : '';
      _toast(
        nothing
            ? 'Nem találtam beolvasható eseményt a fájlban.$extra'
            : 'Visszaállítva: ${r.added} új, ${r.updated} frissítve, ${r.unchanged} változatlan.$kept$extra',
        error: nothing,
      );
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'settings.restore_failed', e, st);
      _toast(
        'A visszaállítás nem sikerült: ${errorInfoFor(e).text}',
        error: true,
      );
    } finally {
      _working(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'A naptár egy .ics fájlba menthető, amit bármely naptárprogram megnyit. A visszaállítás csak hozzáad vagy frissít, soha nem töröl.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _fileJob == null ? _export : null,
              icon: _fileIcon(_FileJob.exportIcs, Icons.download),
              label: const Text('Mentés fájlba'),
            ),
            OutlinedButton.icon(
              onPressed: _fileJob == null ? _import : null,
              icon: _fileIcon(_FileJob.importIcs, Icons.upload_file),
              label: const Text('Visszaállítás fájlból'),
            ),
            OutlinedButton.icon(
              onPressed: _fileJob == null ? _exportFinance : null,
              icon: _fileIcon(
                _FileJob.exportFinance,
                Icons.account_balance_wallet_outlined,
              ),
              label: const Text('Pénzügyek mentése'),
            ),
            OutlinedButton.icon(
              onPressed: _fileJob == null ? _importFinance : null,
              icon: _fileIcon(_FileJob.importFinance, Icons.restore),
              label: const Text('Pénzügyek visszaállítása'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'A pénzügyi adatok csak az eszközödön vannak meg (a Drive-ba csak a változások kerülnek), ezért érdemes időnként elmenteni őket.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
