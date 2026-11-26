import 'package:flutter/material.dart';

import '../intake/intake_page.dart';
import 'entries_page.dart';

/// The "Napló" tab: the diary entries, and next to them the food and fluid log
/// (both are things of the day that are written down).
class JournalTab extends StatelessWidget {
  const JournalTab({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Napló'),
        bottom: const TabBar(
          // (scrollable: at a large text size the two names do not fit side by
          // side in a tab each)
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(key: Key('journal-tab-entries'), text: 'Bejegyzések'),
            Tab(key: Key('journal-tab-intake'), text: 'Étkezés és folyadék'),
          ],
        ),
      ),
      body: const TabBarView(children: [JournalEntriesPage(), IntakePage()]),
    ),
  );
}
