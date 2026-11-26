import 'recurrence.dart' show parseRule;
import 'sync_record.dart';

const kindTask = 'task';
const kindCheckIn = 'checkin';
const kindHandbook = 'handbook';

/// The feedback after a workout (how hard it was, the energy, how it felt).
const kindWorkoutLog = 'workoutlog';

/// The food and fluid log: one record per month (see intake.dart).
const kindIntake = 'intake';

/// The diary: one record per entry (see journal.dart).
const kindJournal = 'journal';

/// The settings the user wants on every device they use, so that they are
/// entered once: three small records, one per group of settings ([settingsPayId],
/// [settingsGoalsId], [settingsPlanId]). Every setting is a field of its own,
/// so a wage changed on one device and a premium changed on another both stay.
const kindSettings = 'settings';

/// The pay estimate: the hourly wage and the premiums (see pay_estimate.dart).
const settingsPayId = 'pay';

/// The goals of the food and fluid log (see intake.dart).
const settingsGoalsId = 'goals';

/// The wishes of the local workout planner (see local_plan.dart).
const settingsPlanId = 'plan';

/// Kinds that are stored as record files in Drive.
const syncedKinds = [
  kindTask,
  kindCheckIn,
  kindHandbook,
  kindWorkoutLog,
  kindIntake,
  kindJournal,
  kindSettings,
];

/// Drive file name of a record (one file per task / per check-in day).
String recordFileName(String kind, String id) => '$kind-$id.json';

/// The name of a record file of any synced kind: group 1 is the kind, group 2
/// the id. One place for it, so a new kind cannot be forgotten somewhere.
final recordFileNamePattern = RegExp(
  '^(${syncedKinds.join('|')})-(.+)\\.json\$',
);

/// The same for an id that is safe in a Drive file name (what the remote lists).
final safeRecordFileNamePattern = RegExp(
  '^(${syncedKinds.join('|')})-([A-Za-z0-9._-]+)\\.json\$',
);

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "2026-11-16", the way a floating date is stored in a record.
String isoDay(DateTime d) => _ymd(d);

DateTime? _parseYmd(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
  return m == null
      ? null
      : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

int? _intIn(Object? v, int lo, int hi) {
  // (an infinite number, "1e999" in a file, has no integer: toInt() would throw)
  final n = v is num && v.isFinite ? v.toInt() : null;
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

  /// The task this one is a checklist item of, or null (see [checklists] for
  /// when the link counts).
  String? get parentId {
    final v = record['parent'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  /// Where a checklist item stands among the others (smaller is first).
  int? get pos {
    final v = record['pos'];
    return v is num && v.isFinite ? v.toInt() : null;
  }

  /// How the task comes back once it is done: an RRULE body, anchored on
  /// [due]. Null for a task that is done once.
  String? get repeatRule {
    final v = record['repeat'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

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
  String? parent,
  int? pos,
  String? repeat,
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
  final rule = repeat?.trim();
  if (rule != null && rule.isNotEmpty) {
    if (due == null) {
      throw ArgumentError('Az ismétlődő feladatnak határidő kell.');
    }
    if (parent != null && parent.trim().isNotEmpty) {
      throw ArgumentError('A részfeladat nem ismétlődhet.');
    }
    try {
      parseRule(rule);
    } catch (_) {
      throw ArgumentError('Az ismétlődési szabály nem érthető.');
    }
  }
  return {
    'title': t,
    'notes': notes.trim(),
    'due': due == null ? null : _ymd(due),
    'estimateMin': estimateMin,
    'priority': priority,
    'energyNeed': energyNeed,
    'done': done,
    'parent': parent == null || parent.trim().isEmpty ? null : parent.trim(),
    'pos': pos,
    'repeat': rule == null || rule.isEmpty ? null : rule,
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

// ------------------------------------------------------------ workout log

/// Typed view of the feedback on one workout (the id names the event and the
/// start of the occurrence, so a recurring workout has one feedback per day,
/// and two devices answer the same one).
class WorkoutLogView {
  WorkoutLogView(this.record) : assert(record.kind == kindWorkoutLog);
  final SyncRecord record;

  String get id => record.id;
  String get title => '${record['title'] ?? ''}';

  /// The day of the workout (floating date).
  DateTime? get date => _parseYmd(record['date']);

  /// How long it lasted.
  int? get minutes => _intIn(record['minutes'], 1, 24 * 60);

  /// The kind of workout ("gym", "calisthenics" …), see `sportKey`.
  String get sport => '${record['sport'] ?? ''}';

  /// False when the user said it did not happen.
  bool get done => record['done'] != false;

  /// How hard it felt, 1 (easy) .. 5 (very hard).
  int? get bodyLoad => _intIn(record['bodyLoad'], 1, 5);
  int? get mindLoad => _intIn(record['mindLoad'], 1, 5);

  /// The energy at the start and at the end, 1 (exhausted) .. 5 (full).
  int? get energyStart => _intIn(record['energyStart'], 1, 5);
  int? get energyEnd => _intIn(record['energyEnd'], 1, 5);

  /// How it was, 1 (bad) .. 5 (great).
  int? get experience => _intIn(record['experience'], 1, 5);
  String get note => '${record['note'] ?? ''}';
  bool get deleted => record.deleted;

  /// Whether any of the five questions was answered.
  bool get answered =>
      bodyLoad != null ||
      mindLoad != null ||
      energyStart != null ||
      energyEnd != null ||
      experience != null;
}

/// The id of the feedback on one occurrence of an event: only characters that
/// are safe in a Drive file name.
String workoutLogId(String eventId, DateTime originalStart) {
  final safe = eventId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final head = safe.length > 64 ? safe.substring(0, 64) : safe;
  String two(int n) => n.toString().padLeft(2, '0');
  final s = originalStart;
  return '$head-${s.year.toString().padLeft(4, '0')}${two(s.month)}${two(s.day)}${two(s.hour)}${two(s.minute)}';
}

/// Builds the field changes of a workout feedback, validating every value.
/// Only the answered questions are written (an unanswered one must never
/// overwrite an answer another device already gave); a workout that did not
/// happen carries no ratings at all.
Map<String, Object?> workoutLogFields({
  required String title,
  required DateTime date,
  required int minutes,
  required String sport,
  bool done = true,
  int? bodyLoad,
  int? mindLoad,
  int? energyStart,
  int? energyEnd,
  int? experience,
  String note = '',
}) {
  for (final v in [bodyLoad, mindLoad, energyStart, energyEnd, experience]) {
    if (v != null && (v < 1 || v > 5)) {
      throw ArgumentError('Az értékek 1–5 közöttiek.');
    }
  }
  if (minutes < 1 || minutes > 24 * 60) {
    throw ArgumentError('Az időtartam 1 perc és 24 óra között lehet.');
  }
  String cut(String s, int max) {
    final t = s.trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  return {
    'title': cut(title, 80),
    'date': _ymd(date),
    'minutes': minutes,
    'sport': sport,
    'done': done,
    if (done) ...{
      'bodyLoad': ?bodyLoad,
      'mindLoad': ?mindLoad,
      'energyStart': ?energyStart,
      'energyEnd': ?energyEnd,
      'experience': ?experience,
    },
    'note': cut(note, 120),
    'deleted': false,
  };
}
