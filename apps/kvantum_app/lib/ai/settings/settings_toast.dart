import 'package:flutter/material.dart';

/// A message at the bottom of the page, for a result that shows up far from
/// the button that was pressed. [context] must still be in the tree.
void showSettingsToast(BuildContext context, String m, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(m),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
}
