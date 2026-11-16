import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../../diag/diag_log.dart';
import '../../journal/journal_providers.dart';
import '../../journal/photo_import.dart';
import '../../journal/photo_picker.dart';
import '../../providers.dart';
import '../../sync/error_catalog.dart';
import '../format.dart';
import '../quick_entry_dialog.dart' show wallNow;
import '../undo_service.dart';
import 'photo_viewer.dart';
import 'photo_widgets.dart';

/// Opens the editor: for a new entry, or for [entry] (changed in place).
Future<void> openEntryEditor(BuildContext context, {JournalEntry? entry}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => JournalEntryEditor(entry: entry)),
    );

/// Writes (or changes) one entry of the diary: when it is about, a title, the
/// text, and the pictures.
///
/// What is written is not lost to a closed app: a new entry is kept as a draft
/// (on this device) before the picture chooser opens, where the system may
/// close an app that has been left, and when the app goes to the background;
/// the next new entry offers to go on with it.
class JournalEntryEditor extends ConsumerStatefulWidget {
  const JournalEntryEditor({super.key, this.entry});

  /// The entry to change; null for a new one.
  final JournalEntry? entry;

  @override
  ConsumerState<JournalEntryEditor> createState() => _JournalEntryEditorState();
}

class _JournalEntryEditorState extends ConsumerState<JournalEntryEditor>
    with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _text = TextEditingController();
  late String _id;
  late DateTime _at;
  var _photos = <PhotoRef>[];

  /// Saving, or taking pictures in.
  bool _busy = false;
  String? _error;
  String? _notice;

  bool get _isNew => widget.entry == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final e = widget.entry;
    if (e != null) {
      _id = e.id;
      _at = e.at;
      _title.text = e.title;
      _text.text = e.text;
      _photos = [...e.photos];
    } else {
      _id = const Uuid().v4();
      _at = wallNow(ref);
      // (what an earlier start left is offered once the page is up)
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerDraft());
    }
    _title.addListener(_changed);
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // (an app that goes to the background may be closed there)
    if (state != AppLifecycleState.resumed) unawaited(_saveDraft());
  }

  void _changed() => setState(() {});

  // ------------------------------------------------------------- the draft

  Future<void> _saveDraft() async {
    if (!_isNew) return;
    try {
      await ref
          .read(journalDraftStoreProvider)
          .save(
            JournalDraft(
              id: _id,
              at: _at,
              title: _title.text,
              text: _text.text,
              photos: _photos,
            ),
          );
    } catch (e, st) {
      // (the draft is a safety net: never in the way of the writing)
      ref.read(diagLogProvider).error('journal', 'draft.save_failed', e, st);
    }
  }

  Future<void> _clearDraft() async {
    if (!_isNew) return;
    try {
      await ref.read(journalDraftStoreProvider).clear();
    } catch (e, st) {
      ref.read(diagLogProvider).error('journal', 'draft.clear_failed', e, st);
    }
  }

  Future<void> _offerDraft() async {
    final JournalDraft? draft;
    try {
      draft = await ref.read(journalDraftStoreProvider).load();
    } catch (_) {
      return;
    }
    if (draft == null || !mounted) return;
    final d = draft;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('draft-dialog'),
        title: const Text('Félbehagyott bejegyzés'),
        content: Text(
          'Van egy félbehagyott bejegyzésed'
          '${d.title.trim().isEmpty ? '' : ': „${d.title.trim()}”'}. '
          'Folytatod, vagy újat kezdesz?',
        ),
        actions: [
          TextButton(
            key: const Key('draft-discard'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Újat kezdek'),
          ),
          FilledButton(
            key: const Key('draft-continue'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Folytatom'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (go == true) {
      setState(() {
        _id = d.id;
        _at = d.at;
        _title.text = d.title;
        _text.text = d.text;
        _photos = [...d.photos];
      });
    } else if (go == false) {
      await _clearDraft();
    }
  }

  // ----------------------------------------------------------- the pictures

  Future<void> _addPhotos() async {
    if (_busy || _photos.length >= maxJournalPhotos) return;
    // (before the chooser opens: the system may close the app meanwhile)
    await _saveDraft();
    final List<PickedPhoto> picked;
    try {
      picked = await ref.read(photoPickerProvider).pick();
    } catch (e, st) {
      ref.read(diagLogProvider).error('journal', 'photo.pick_failed', e, st);
      if (mounted) {
        setState(() => _notice = 'A képválasztó nem nyílt meg.');
      }
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    PhotoImportResult? result;
    try {
      result = await ref
          .read(photoImporterProvider)
          .import(picked, room: maxJournalPhotos - _photos.length);
    } catch (e, st) {
      ref.read(diagLogProvider).error('journal', 'photo.import_failed', e, st);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result == null) {
        _notice = 'A képeket nem sikerült felvenni.';
      } else {
        _photos = [..._photos, ...result.added];
        _notice = result.notice;
      }
    });
    await _saveDraft();
  }

  void _removePhoto(PhotoRef p) {
    setState(() {
      _photos = [
        for (final x in _photos)
          if (x.id != p.id) x,
      ];
      _notice = null;
    });
  }

  // ------------------------------------------------------------- the time

  Future<void> _pickDay() async {
    final first = DateTime(2000), last = DateTime(2100);
    var initial = DateTime(_at.year, _at.month, _at.day);
    // (an entry from outside the picker's years still opens it)
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (d == null || !mounted) return;
    setState(
      () => _at = DateTime.utc(d.year, d.month, d.day, _at.hour, _at.minute),
    );
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _at.hour, minute: _at.minute),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null || !mounted) return;
    setState(
      () => _at = DateTime.utc(_at.year, _at.month, _at.day, t.hour, t.minute),
    );
  }

  // ---------------------------------------------------------- leaving it

  bool get _dirty {
    final o = widget.entry;
    if (o == null) {
      return _title.text.trim().isNotEmpty ||
          _text.text.trim().isNotEmpty ||
          _photos.isNotEmpty;
    }
    return _title.text.trim() != o.title ||
        _text.text.trim() != o.text ||
        _at != o.at ||
        !_samePhotos(_photos, o.photos);
  }

  static bool _samePhotos(List<PhotoRef> a, List<PhotoRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (_busy) return;
    final JournalEntry entry;
    try {
      entry = JournalEntry.checked(
        id: _id,
        at: _at,
        title: _title.text,
        text: _text.text,
        photos: _photos,
      );
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(journalOpsProvider).save(entry);
      await _clearDraft();
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      ref.read(diagLogProvider).error('journal', 'entry.save_failed', e, st);
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorInfoFor(e).text;
        });
      }
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final ops = ref.read(journalOpsProvider);
    final undo = ref.read(undoServiceProvider);
    final site = UndoSite.of(context);
    final id = _id;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ops.delete(id);
    } catch (e, st) {
      ref.read(diagLogProvider).error('journal', 'entry.delete_failed', e, st);
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorInfoFor(e).text;
        });
      }
      return;
    }
    undo.offer(site, message: 'Bejegyzés törölve', undo: () => ops.restore(id));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _askDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('discard-dialog'),
        title: const Text('Elveted a változtatásokat?'),
        content: Text(
          _isNew
              ? 'A bejegyzés még nincs elmentve.'
              : 'A bejegyzés változásai még nincsenek elmentve.',
        ),
        actions: [
          TextButton(
            key: const Key('discard-stay'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Maradok'),
          ),
          FilledButton(
            key: const Key('discard-yes'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elvetem'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    await _clearDraft();
    if (mounted) Navigator.of(context).pop();
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = maxJournalPhotos - _photos.length;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'Új bejegyzés' : 'Bejegyzés'),
          actions: [
            if (!_isNew)
              IconButton(
                key: const Key('entry-delete'),
                tooltip: 'Bejegyzés törlése',
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_outline),
              ),
            TextButton(
              key: const Key('entry-save'),
              onPressed: _busy ? null : _save,
              child: const Text('Mentés'),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('entry-day'),
                      onPressed: _pickDay,
                      icon: const Icon(Icons.event),
                      label: Text(fmtDateLong(_at)),
                    ),
                    OutlinedButton.icon(
                      key: const Key('entry-time'),
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text(fmtTime(_at)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('entry-title'),
                  controller: _title,
                  maxLength: maxJournalTitle,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.sentences,
                  buildCounter: _counter(maxJournalTitle),
                  decoration: const InputDecoration(
                    labelText: 'Cím (nem kötelező)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('entry-text'),
                  controller: _text,
                  minLines: 6,
                  maxLines: null,
                  maxLength: maxJournalText,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  buildCounter: _counter(maxJournalText),
                  decoration: const InputDecoration(
                    labelText: 'Mi történt?',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    'Képek (${_photos.length}/$maxJournalPhotos)',
                    key: const Key('entry-photos-header'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _photos.length; i++)
                      _PhotoCell(
                        key: Key('entry-photo-${_photos[i].id}'),
                        photo: _photos[i],
                        label: 'Kép ${i + 1} / ${_photos.length}',
                        onOpen: () =>
                            openPhotoViewer(context, _photos, initial: i),
                        onRemove: () => _removePhoto(_photos[i]),
                      ),
                  ],
                ),
                if (_photos.isNotEmpty) const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('entry-add-photo'),
                      onPressed: _busy || left <= 0 ? null : _addPhotos,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Kép hozzáadása'),
                    ),
                    if (left <= 0)
                      Text(
                        'Legföljebb $maxJournalPhotos kép lehet.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
                if (_busy && _error == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(key: Key('entry-busy')),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _notice!,
                      key: const Key('entry-notice'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        key: const Key('entry-error'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The counter of a text field: shown only when the end is near, so that it
  /// does not take a line of every field.
  InputCounterWidgetBuilder _counter(int max) =>
      (context, {required currentLength, required isFocused, maxLength}) =>
          currentLength > max * 0.9
          ? Text(
              '$currentLength / $max',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null;
}

/// A picture in the editor: tap it to see it big, the button under it takes it
/// out of the entry.
class _PhotoCell extends StatelessWidget {
  const _PhotoCell({
    super.key,
    required this.photo,
    required this.label,
    required this.onOpen,
    required this.onRemove,
  });
  final PhotoRef photo;
  final String label;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: Column(
      children: [
        PhotoThumb(photo: photo, side: 96, label: label, onTap: onOpen),
        IconButton(
          key: Key('entry-photo-remove-${photo.id}'),
          tooltip: 'Kép eltávolítása',
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
  );
}
