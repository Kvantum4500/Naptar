import 'sync_record.dart';

const kindTask = 'task';
const kindCheckIn = 'checkin';
const kindHandbook = 'handbook';

/// Kinds that are stored as record files in Drive.
const syncedKinds = [kindTask, kindCheckIn, kindHandbook];

/// Drive file name of a record (one file per task / per check-in day).
String recordFileName(String kind, String id) => '$kind-$id.json';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parseYmd(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
  return m == null
      ? null
      : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

int? _intIn(Object? v, int lo, int hi) {
  final n = v is num ? v.toInt() : null;
  return (n == null || n < lo || n > hi) ? null : n;
}

/// Typed read-only view of a task record.
class TaskView {
  TaskView(this.record) : assert(record.kind == kindTask);
  final SyncRecord record;

  String get id => record.id;
  String get title => '${record['title'] ?? ''}';
  String get notes => '${record['notes'] ?? ''}';

  /// Due date (floating date) or null.
  DateTime? get due => _parseYmd(record['due']);

  /// Estimated minutes, null when unknown.
  int? get estimateMin => _intIn(record['estimateMin'], 1, 24 * 60);

  /// 1 = low, 2 = normal, 3 = high.
  int get priority => _intIn(record['priority'], 1, 3) ?? 2;

  /// How much energy the task needs, 1 (little) .. 5 (a lot).
  int get energyNeed => _intIn(record['energyNeed'], 1, 5) ?? 3;
  bool get done => record['done'] == true;
  bool get deleted => record.deleted;

  bool isOverdue(DateTime today) =>
      !done &&
      due != null &&
      due!.isBefore(DateTime.utc(today.year, today.month, today.day));
}

/// Builds the field changes of a task, validating every value.
Map<String, Object?> taskFields({
  required String title,
  String notes = '',
  DateTime? due,
  int? estimateMin,
  int priority = 2,
  int energyNeed = 3,
  bool done = false,
}) {
  final t = title.trim();
  if (t.isEmpty) throw ArgumentError('A feladat címe nem lehet üres.');
  if (priority < 1 || priority > 3) throw ArgumentError('Prioritás: 1–3.');
  if (energyNeed < 1 || energyNeed > 5) {
    throw ArgumentError('Energiaigény: 1–5.');
  }
  if (estimateMin != null && (estimateMin < 1 || estimateMin > 24 * 60)) {
    throw ArgumentError('A becsült idő 1 perc és 24 óra között lehet.');
  }
  return {
    'title': t,
    'notes': notes.trim(),
    'due': due == null ? null : _ymd(due),
    'estimateMin': estimateMin,
    'priority': priority,
    'energyNeed': energyNeed,
    'done': done,
    'deleted': false,
  };
}

/// Typed view of a daily check-in (id = the date, yyyy-MM-dd).
class CheckInView {
  CheckInView(this.record) : assert(record.kind == kindCheckIn);
  final SyncRecord record;

  DateTime? get date => _parseYmd(record.id);

  /// Each 1 (bad / low) .. 5 (great / high); null = not answered.
  int? get physical => _intIn(record['physical'], 1, 5);
  int? get mental => _intIn(record['mental'], 1, 5);
  int? get mood => _intIn(record['mood'], 1, 5);
  int? get sleep => _intIn(record['sleep'], 1, 5);
  String get note => '${record['note'] ?? ''}';
  bool get deleted => record.deleted;
}

String checkInId(DateTime date) => _ymd(date);

Map<String, Object?> checkInFields({
  int? physical,
  int? mental,
  int? mood,
  int? sleep,
  String note = '',
}) {
  for (final v in [physical, mental, mood, sleep]) {
    if (v != null && (v < 1 || v > 5)) {
      throw ArgumentError('A check-in értékek 1–5 közöttiek.');
    }
  }
  // Only answered questions are written: an unanswered one must never
  // overwrite an answer another device already gave.
  return {
    'physical': ?physical,
    'mental': ?mental,
    'mood': ?mood,
    'sleep': ?sleep,
    'note': note.trim(),
    'deleted': false,
  };
}
