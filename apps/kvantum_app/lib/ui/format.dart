import 'package:intl/intl.dart';

String _p2(int n) => n.toString().padLeft(2, '0');

/// 24-hour time of a floating wall-clock value: 09:05.
String fmtTime(DateTime wall) => '${_p2(wall.hour)}:${_p2(wall.minute)}';

/// 2026. nov. 4., szerda
String fmtDateLong(DateTime d) => DateFormat(
  'y. MMM d., EEEE',
  'hu',
).format(DateTime(d.year, d.month, d.day));

/// 2026. november 4.
String fmtDate(DateTime d) =>
    DateFormat('y. MMMM d.', 'hu').format(DateTime(d.year, d.month, d.day));

String fmtDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h == 0) return '$m perc';
  return m == 0 ? '$h óra' : '$h óra $m perc';
}
