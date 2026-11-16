import 'package:flutter/material.dart';

/// The diary entries (the first page of the "Napló" tab).
class JournalEntriesPage extends StatelessWidget {
  const JournalEntriesPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Itt lesznek a napló-bejegyzéseid.'),
      ),
    ),
  );
}
