import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_controller.dart';
import 'ai_providers.dart';
import 'handbook_store.dart';

/// The handbook files with a "modified" marker; tap one to edit it.
class HandbookPage extends ConsumerStatefulWidget {
  const HandbookPage({super.key});
  @override
  ConsumerState<HandbookPage> createState() => _HandbookPageState();
}

class _HandbookPageState extends ConsumerState<HandbookPage> {
  Map<String, bool> _custom = {};

  Future<void> _load() async {
    final store = ref.read(handbookStoreProvider);
    final m = {
      for (final (id, _) in handbookFiles) id: await store.isCustomized(id),
    };
    if (mounted) setState(() => _custom = m);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kézikönyv')),
    body: ListView(
      children: [
        for (final (id, title) in handbookFiles)
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(title),
            subtitle: Text(
              _custom[id] == true ? 'Módosítva' : 'Alapértelmezett',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HandbookEditorPage(id: id, title: title),
                ),
              );
              unawaited(_load());
            },
          ),
      ],
    ),
  );
}

class HandbookEditorPage extends ConsumerStatefulWidget {
  const HandbookEditorPage({super.key, required this.id, required this.title});
  final String id;
  final String title;
  @override
  ConsumerState<HandbookEditorPage> createState() => _HandbookEditorPageState();
}

class _HandbookEditorPageState extends ConsumerState<HandbookEditorPage> {
  final _text = TextEditingController();
  bool _loaded = false;
  String _initial = '';

  @override
  void initState() {
    super.initState();
    ref.read(handbookStoreProvider).textOf(widget.id).then((t) {
      if (!mounted) return;
      setState(() {
        _text.text = t;
        _initial = t;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(handbookStoreProvider).save(widget.id, _text.text);
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Alapértelmezett visszaállítása'),
        content: const Text('A saját módosításaid elvesznek ebben a fájlban.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Visszaállít'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(handbookStoreProvider).reset(widget.id);
    ref.read(syncControllerProvider.notifier).requestSync();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _loaded && _text.text != _initial;
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Elveted a módosításokat?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Maradok'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Elvetem'),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Alapértelmezett',
              onPressed: _loaded ? _reset : null,
              icon: const Icon(Icons.restore),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: dirty ? _save : null,
                child: const Text('Mentés'),
              ),
            ),
          ],
        ),
        body: !_loaded
            ? const Center(
                child: CircularProgressIndicator(semanticsLabel: 'Betöltés'),
              )
            : Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _text,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
      ),
    );
  }
}
