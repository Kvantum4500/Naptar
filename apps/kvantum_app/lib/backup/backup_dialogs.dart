import 'package:flutter/material.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_snapshot.dart' show sizeText;
import '../drive/drive_remote.dart' show DriveName;
import '../ui/format.dart';
import 'backup_service.dart';
import 'drive_backup.dart';

/// "2026. november 13. 09:15" (the time on this device's clock, as the name
/// of a backup file shows it).
String backupWhen(DateTime at) {
  final w = at.toLocal();
  return '${fmtDate(w)} ${fmtTime(w)}';
}

/// "142 esemény · 37 feladat" (what a backup holds; zeros left out).
String backupCountsText(Map<String, int> counts) {
  const labels = [
    ('events', 'esemény'),
    ('finance', 'pénzügyi adat'),
    (kindTask, 'feladat'),
    (kindCheckIn, 'napi check-in'),
    (kindHandbook, 'kézikönyv-fájl'),
    (kindWorkoutLog, 'edzésnapló-bejegyzés'),
    (kindIntake, 'étkezési hónap'),
    (kindJournal, 'napló-bejegyzés'),
    (kindSettings, 'beállítás-csoport'),
  ];
  final parts = [
    for (final (key, label) in labels)
      if ((counts[key] ?? 0) > 0) '${counts[key]} $label',
  ];
  return parts.isEmpty ? 'üres' : parts.join(' · ');
}

/// "Mentés ideje" line of the preview.
String backupHeadline(BackupPreview p) {
  final build = p.meta.build;
  return '${backupWhen(p.meta.createdAt)}'
      '${build == null ? '' : ' (build $build)'}';
}

// ---------------------------------------------------------------- passwords

/// Asks for the password a backup file is to be locked with. Returns null when
/// the user cancels; a result whose password is null means "no password".
Future<({String? password})?> askSavePassword(
  BuildContext context,
) => askNewPassword(
  context,
  title: 'Mentés fájlba',
  intro:
      'A fájlba minden belekerül: a naptár, a pénzügyek, a feladatok, a '
      'check-inek, a kézikönyv, az edzésnapló, az étkezési napló és a napló '
      'bejegyzéseinek szövege, a beállításaid (bér, célok, terv-kívánságok); '
      'a napló képei nem (azok a Drive-szinkronnal kerülnek a Drive-ra). '
      'Jelszóval '
      'zárhatod '
      '(AES-256-os zip, bármely tömörítő megnyitja a jelszóval); hagyd '
      'üresen, ha nem kérsz jelszót.',
  required: false,
);

/// Asks for a new password, twice. With [required] it must be given (at least
/// 8 characters); otherwise an empty answer means "no password". Returns null
/// when the user cancels.
Future<({String? password})?> askNewPassword(
  BuildContext context, {
  required String title,
  required String intro,
  required bool required,
  String dialogKey = 'backup-save-password',
}) => showDialog<({String? password})>(
  context: context,
  builder: (_) => _NewPasswordDialog(
    title: title,
    intro: intro,
    required: required,
    dialogKey: dialogKey,
  ),
);

/// The shortest password the Drive copy accepts.
const minPasswordLength = 8;

class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog({
    required this.title,
    required this.intro,
    required this.required,
    required this.dialogKey,
  });
  final String title;
  final String intro;
  final bool required;
  final String dialogKey;

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _show = false;
  bool _mismatch = false;
  bool _short = false;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _save() {
    if (widget.required && _first.text.length < minPasswordLength) {
      setState(() => _short = true);
      return;
    }
    if (_first.text != _second.text) {
      setState(() => _mismatch = true);
      return;
    }
    Navigator.pop(context, (
      password: _first.text.isEmpty ? null : _first.text,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: Key(widget.dialogKey),
    scrollable: true,
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.intro),
        const SizedBox(height: 12),
        TextField(
          key: const Key('backup-password'),
          controller: _first,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: widget.required ? 'Jelszó' : 'Jelszó (nem kötelező)',
            errorText: _short
                ? 'Legalább $minPasswordLength karakter legyen.'
                : null,
            suffixIcon: IconButton(
              tooltip: _show ? 'Jelszó elrejtése' : 'Jelszó megmutatása',
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onChanged: (_) => setState(() {
            _mismatch = false;
            _short = false;
          }),
        ),
        TextField(
          key: const Key('backup-password-again'),
          controller: _second,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Jelszó még egyszer',
            errorText: _mismatch ? 'A két jelszó nem egyezik.' : null,
          ),
          onChanged: (_) => setState(() => _mismatch = false),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Text(
          'A jelszót a program nem tudja visszafejteni és nem küldi el '
          'sehova: ha elfelejted, a zárolt mentés nem nyitható meg.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('backup-password-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Mégse'),
      ),
      FilledButton(
        key: const Key('backup-password-save'),
        onPressed: _save,
        child: const Text('Mentés'),
      ),
    ],
  );
}

/// Asks for the password of a locked backup. Returns null when cancelled.
Future<String?> askOpenPassword(BuildContext context, {bool wrong = false}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _OpenPasswordDialog(wrong: wrong),
    );

class _OpenPasswordDialog extends StatefulWidget {
  const _OpenPasswordDialog({required this.wrong});
  final bool wrong;

  @override
  State<_OpenPasswordDialog> createState() => _OpenPasswordDialogState();
}

class _OpenPasswordDialogState extends State<_OpenPasswordDialog> {
  final _controller = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('backup-open-password'),
    scrollable: true,
    title: const Text('Jelszó kell'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Ez a mentés jelszóval védett.'),
        const SizedBox(height: 8),
        TextField(
          key: const Key('backup-password'),
          controller: _controller,
          autofocus: true,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Jelszó',
            errorText: widget.wrong ? 'Hibás jelszó.' : null,
            suffixIcon: IconButton(
              tooltip: _show ? 'Jelszó elrejtése' : 'Jelszó megmutatása',
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('backup-password-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Mégse'),
      ),
      FilledButton(
        key: const Key('backup-password-open'),
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Megnyitás'),
      ),
    ],
  );
}

// ------------------------------------------------------------------ restore

/// Shows what restoring [preview] would do and asks. Returns null when the
/// user cancels, otherwise whether events that were changed on this device
/// since the backup may be overwritten by their backed-up form.
Future<bool?> askRestore(BuildContext context, BackupPreview preview) =>
    showDialog<bool>(context: context, builder: (_) => _RestoreDialog(preview));

class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog(this.preview);
  final BackupPreview preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final changed = p.events.changes.length;
    final names = <String>{for (final c in p.events.changes) c.current.title}
        .take(5)
        .toList();
    final more = changed - names.length;

    Widget line(String head, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$head: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: body),
          ],
        ),
      ),
    );

    String eventsText() {
      final parts = <String>[
        if (p.events.fresh.isNotEmpty) '${p.events.fresh.length} új',
        if (changed > 0) '$changed azóta módosult',
        if (p.events.unchanged > 0) '${p.events.unchanged} változatlan',
      ];
      return parts.isEmpty ? 'nincs' : parts.join(' · ');
    }

    String recordsText() {
      final r = p.records;
      final parts = <String>[
        if (r.added > 0) '${r.added} új',
        if (r.updated > 0) '${r.updated} frissül',
        if (r.same > 0) '${r.same} változatlan',
      ];
      return parts.isEmpty ? 'nincs' : parts.join(' · ');
    }

    String financeText() {
      final f = p.finance;
      final parts = <String>[
        if (f.added > 0) '${f.added} új',
        if (f.updated > 0) '${f.updated} frissül',
      ];
      return parts.isEmpty ? 'nincs új' : parts.join(' · ');
    }

    final nothing = p.changesNothing;
    return AlertDialog(
      key: const Key('backup-restore'),
      scrollable: true,
      title: const Text('Visszaállítás előnézete'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line('A mentés ideje', backupHeadline(p)),
          line('Tartalma', backupCountsText(p.meta.counts)),
          const SizedBox(height: 4),
          Text(
            nothing
                ? 'Nincs mit visszaállítani: ami a mentésben van, az már így '
                      'megvan ezen az eszközön.'
                : 'Ez történne most:',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          line('Naptár', eventsText()),
          line('Pénzügyek', financeText()),
          line(
            'Feladatok, check-inek, kézikönyv, edzésnapló, étkezés, napló, '
            'beállítások',
            recordsText(),
          ),
          if (changed > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Az eszközön azóta módosult események: ${names.join(', ')}'
              '${more > 0 ? ' és még $more' : ''}. Ha felülírod őket, a '
              'mentés szerinti állapotra állnak vissza, és a mostani '
              'módosításaid elvesznek.',
            ),
          ],
          if (p.problems.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final problem in p.problems.take(5))
              Text('• $problem', style: small),
            if (p.problems.length > 5)
              Text('• és még ${p.problems.length - 5}…', style: small),
          ],
          const SizedBox(height: 8),
          Text(
            'A visszaállítás soha nem töröl. A feladatoknál és a pénzügyeknél '
            'csak azt hozza vissza, ami hiányzik vagy régebbi az eszközön; '
            'amit a mentés óta töröltél vagy átírtál, az marad.',
            style: small,
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('restore-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(nothing ? 'Rendben' : 'Mégse'),
        ),
        if (!nothing && changed > 0)
          OutlinedButton(
            key: const Key('restore-keep'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('A módosultak nélkül'),
          ),
        if (!nothing)
          FilledButton(
            key: const Key('restore-go'),
            onPressed: () => Navigator.pop(context, changed > 0),
            child: Text(
              changed > 0 ? 'Mindent, felülírással' : 'Visszaállítás',
            ),
          ),
      ],
    );
  }
}

/// Lets the user choose one of the copies in Drive (newest first). Returns
/// null when cancelled.
Future<DriveName?> askDriveCopy(BuildContext context, List<DriveName> copies) =>
    showDialog<DriveName>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('drive-copies'),
        title: const Text('Mentések a Drive-ban'),
        children: [
          for (final c in copies)
            SimpleDialogOption(
              key: Key('drive-copy-${c.name}'),
              onPressed: () => Navigator.pop(ctx, c),
              child: Text(_copyTitle(c)),
            ),
        ],
      ),
    );

String _copyTitle(DriveName c) {
  final t = DriveBackup.timeOf(c.name);
  return t == null ? c.name : '${fmtDate(t)} ${fmtTime(t)}';
}

/// One line for the toast after a restore.
String restoreSummary(RestoreResult r) {
  final parts = <String>[
    if (r.events.added > 0) '${r.events.added} új esemény',
    if (r.events.updated > 0) '${r.events.updated} esemény felülírva',
    if (r.finance.added + r.finance.updated > 0)
      '${r.finance.added + r.finance.updated} pénzügyi adat',
    if (r.records.added + r.records.updated > 0)
      '${r.records.added + r.records.updated} feladat / check-in / egyéb',
  ];
  final head = parts.isEmpty
      ? 'Visszaállítva: nem változott semmi.'
      : 'Visszaállítva: ${parts.join(', ')}.';
  return r.problems.isEmpty
      ? head
      : '$head (${r.problems.length} figyelmeztetéssel)';
}

/// "3,2 MB" (re-exported for the card).
String backupSizeText(int bytes) => sizeText(bytes);
