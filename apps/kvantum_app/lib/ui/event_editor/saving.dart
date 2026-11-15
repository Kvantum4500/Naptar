part of '../event_editor.dart';

// What the editor does with the form: the event it describes, the question
// about which events of a series, saving (one event, or a series cut in two or
// changed as a whole) and deleting. Part of the library of the editor.
extension _EditorSaving on _EventEditorState {
  // --------------------------------------------------------------- save

  String? get _ruleString => _spec != null ? _spec!.toRrule(_start) : _rawRule;

  /// The event as described by the form (id/links are filled in later).
  CalEvent _formEvent() {
    final start = _allDay
        ? floating(_start.year, _start.month, _start.day)
        : _start;
    final end = _allDay
        ? floating(_end.year, _end.month, _end.day).add(const Duration(days: 1))
        : _end;
    final base = _master ?? _e;
    var notes = _notes.text.trim();
    // a generated shift whose title or hours the user changed is "modified":
    // regenerating the pattern then keeps it
    if (base != null &&
        base.notes == kShiftMarker &&
        notes == kShiftMarker &&
        (_title.text.trim() != base.title ||
            start != base.start ||
            end != base.end)) {
      notes = kShiftEditedMarker;
    }
    return CalEvent(
      id: base?.id ?? 'form',
      calendarId: base?.calendarId ?? calendarIdLocal,
      title: _title.text.trim(),
      notes: notes,
      location: _location.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      tzid: _allDay ? null : (base?.tzid ?? defaultTz),
      rrule: _ruleString,
      colorId: _colorId,
    );
  }

  bool get _ruleChanged =>
      _isSeries && (_ruleString ?? '') != (_master!.rrule ?? '');

  Future<Scope?> _askScope({required bool delete}) => showDialog<Scope>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(
        delete ? 'Ismétlődő esemény törlése' : 'Ismétlődő esemény módosítása',
      ),
      children: [
        if (!_ruleChanged || delete)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, Scope.only),
            child: const Text('Csak ez az esemény'),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, Scope.following),
          child: const Text('Ez és a következő események'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, Scope.all),
          child: const Text('Az összes esemény'),
        ),
        if (!delete && _ruleChanged)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              'Az ismétlődési szabály módosításánál a „csak ez” nem választható.',
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    ),
  );

  Future<void> _save() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) return;
    if (_spec?.validate() != null) {
      _set(() => _error = _spec!.validate());
      return;
    }
    if (_allDay ? _end.isBefore(_start) : !_end.isAfter(_start)) {
      _set(
        () => _error = _allDay
            ? 'A befejezés nem lehet a kezdés előtt.'
            : 'A befejezésnek a kezdés után kell lennie.',
      );
      return;
    }
    _set(() => _error = null);
    final repo = ref.read(repoProvider);
    final formEv = _formEvent();
    const uuid = Uuid();
    _set(() => _busy = true);
    try {
      if (!_isSeries) {
        final old = _e;
        final ev = CalEvent(
          id: old?.id ?? uuid.v4(),
          calendarId: old?.calendarId ?? calendarIdLocal,
          title: formEv.title,
          notes: formEv.notes,
          location: formEv.location,
          start: formEv.start,
          end: formEv.end,
          allDay: formEv.allDay,
          tzid: formEv.tzid,
          rrule: formEv.rrule,
          exdates: old?.exdates ?? const [],
          colorId: formEv.colorId,
          aiGenerated: old?.aiGenerated ?? false,
          version: (old?.version ?? 0) + 1,
          googleId: old?.googleId,
          etag: old?.etag,
          iCalUid: old?.iCalUid,
        );
        await repo.saveLocal(ev);
      } else {
        final scope = await _askScope(delete: false);
        if (scope == null) {
          _set(() => _busy = false);
          return;
        }
        // a split into two series, the exceptions that move with it ...: all
        // or nothing, and one change for the screens
        await repo.atomically(() => _saveSeries(scope, formEv, repo, uuid));
      }
      ref.read(syncControllerProvider.notifier).requestSync();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      ref.read(diagLogProvider).error('ui', 'event.save_failed', e, st);
      if (mounted) {
        _set(() => _error = 'Mentés sikertelen: ${errorInfoFor(e).text}');
      }
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _saveSeries(
    Scope scope,
    CalEvent formEv,
    EventRepository repo,
    Uuid uuid,
  ) async {
    final m = _master!;
    final orig = t.originalStart!;
    switch (scope) {
      case Scope.only:
        final existing = _e!.isException ? _e : null;
        if (existing != null) {
          await repo.saveLocal(
            existing.copyWith(
              title: formEv.title,
              notes: formEv.notes,
              location: formEv.location,
              start: formEv.start,
              end: formEv.end,
              colorId: formEv.colorId,
              clearColor: formEv.colorId == null,
            ),
          );
        } else {
          await repo.saveLocal(
            makeOverride(
              master: m,
              originalStart: orig,
              edited: formEv,
              newId: uuid.v4(),
            ),
          );
        }
      case Scope.following:
        final r = splitSeries(
          master: m,
          splitAt: orig,
          edited: formEv,
          newId: uuid.v4(),
          overrides: t.overrides,
        );
        if (r.truncated == null) {
          // first instance chosen: the whole series is replaced = edit all
          await _saveAll(m, formEv, orig, repo);
        } else {
          await repo.saveLocal(r.truncated!);
          await repo.saveLocal(r.newSeries);
          for (final o in r.droppedOverrides) {
            await repo.deleteLocal(o.id);
          }
        }
      case Scope.all:
        await _saveAll(m, formEv, orig, repo);
    }
  }

  Future<void> _saveAll(
    CalEvent m,
    CalEvent formEv,
    DateTime orig,
    EventRepository repo,
  ) async {
    // The instance the user edited moved by (formStart - orig): shift the
    // whole series by the same amount, keep its length.
    final shift = formEv.start.difference(orig);
    final newStart = m.start.add(shift);
    final newEnd = newStart.add(formEv.end.difference(formEv.start));
    final edited = CalEvent(
      id: m.id,
      calendarId: m.calendarId,
      title: formEv.title,
      notes: formEv.notes,
      location: formEv.location,
      start: newStart,
      end: newEnd,
      allDay: formEv.allDay,
      tzid: formEv.tzid,
      rrule: _spec != null ? _spec!.toRrule(newStart) : _rawRule,
      colorId: formEv.colorId,
    );
    final res = editAll(master: m, edited: edited, overrides: t.overrides);
    await repo.saveLocal(res.master);
    for (final o in res.overrides) {
      await repo.saveLocal(o);
    }
  }

  // ------------------------------------------------------------- delete

  Future<void> _delete() async {
    final e = _e!;
    // A recurring event: which part goes is a choice, not a confirmation.
    // A single event goes at once: "Visszavonás" takes it back.
    var scope = Scope.only;
    if (_isSeries) {
      final asked = await _askScope(delete: true);
      if (asked == null || !mounted) return;
      scope = asked;
    }
    // This page closes below, and its context and `ref` are dead when the
    // user taps "Visszavonás": everything that is needed is taken now.
    final repo = ref.read(repoProvider);
    final undo = ref.read(undoServiceProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    final site = UndoSite.of(context);
    final originalStart = t.originalStart ?? e.start;
    final recurring = _isSeries;
    await undo.run(
      site,
      holdIds: [e.id],
      change: () => deleteEvent(
        repo,
        eventId: e.id,
        originalStart: originalStart,
        recurring: recurring,
        scope: scope,
      ),
      message: (_) => switch ((recurring, scope)) {
        (false, _) => 'Esemény törölve',
        (true, Scope.only) => 'Az előfordulás törölve',
        (true, Scope.following) => 'Az előfordulás és a következők törölve',
        (true, Scope.all) => 'A sorozat törölve',
      },
    );
    sync.requestSync();
    if (mounted) Navigator.of(context).pop(true);
  }
}
