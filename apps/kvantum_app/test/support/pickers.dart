import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Types a time into the Material time picker that is open (its keyboard mode:
/// the dial is no place for a test to tap) and confirms it.
Future<void> typeTimeInPicker(WidgetTester tester, int hour, int minute) async {
  await tester.tap(find.byIcon(Icons.keyboard_outlined));
  await tester.pumpAndSettle();
  final fields = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), '$hour');
  await tester.enterText(fields.at(1), '$minute');
  await tester.pump();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}
