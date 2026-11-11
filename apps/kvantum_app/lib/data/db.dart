import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'db_open.dart';

part 'db.g.dart';

class EventRows extends Table {
  TextColumn get id => text()();
  TextColumn get calendarId => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get location => text().withDefault(const Constant(''))();
  // Floating wall-clock as 'yyyy-MM-ddTHH:mm:ss' (no zone).
  TextColumn get startWall => text()();
  TextColumn get endWall => text()();
  TextColumn get tzid => text().nullable()();
  BoolColumn get allDay => boolean().withDefault(const Constant(false))();
  TextColumn get rrule => text().nullable()();
  TextColumn get exdates =>
      text().withDefault(const Constant(''))(); // comma list
  TextColumn get recurringEventId => text().nullable()();
  TextColumn get originalStart => text().nullable()();
  BoolColumn get cancelled => boolean().withDefault(const Constant(false))();
  IntColumn get version => integer().withDefault(const Constant(1))();
  TextColumn get googleId => text().nullable()();
  TextColumn get etag => text().nullable()();
  TextColumn get iCalUid => text().nullable()();
  TextColumn get colorId => text().nullable()();
  BoolColumn get aiGenerated => boolean().withDefault(const Constant(false))();
  // Tombstone: kept until the deletion has been pushed to Google.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Pending local changes waiting to be pushed (offline-safe outbox).
class OutboxRows extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get eventId => text()();
  TextColumn get op => text()(); // 'upsert' | 'delete'
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

/// Synced records (tasks, check-ins) stored as their merged JSON.
class RecordRows extends Table {
  TextColumn get kind => text()();
  TextColumn get id => text()();
  TextColumn get json => text()();
  // True while local changes have not been written to Drive yet.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {kind, id};
}

/// Drive file id per record file name (so updates go to the same file).
class DriveFileRows extends Table {
  TextColumn get name => text()();
  TextColumn get fileId => text()();

  @override
  Set<Column> get primaryKey => {name};
}

/// Finance records (transactions, categories, budgets, recurring rules, goals,
/// deposits) as JSON, one row each. The local file is the source of truth;
/// [dirty] marks changes that still have to be mailed to the other devices.
class FinRows extends Table {
  TextColumn get kind => text()();
  TextColumn get id => text()();
  TextColumn get json => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {kind, id};
}

class MetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [EventRows, OutboxRows, MetaRows, RecordRows, DriveFileRows, FinRows],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// The default place (see [AppDatabase.openAt] for the startup path).
  AppDatabase.open() : super(driftDatabase(name: 'kvantum'));

  /// Opens the file at [path]. Before drift migrates it, a database of a
  /// newer version is refused ([NewerDatabaseError]) and an older one is
  /// copied to `<path>.bak-v<version>`.
  AppDatabase.openAt(String path)
    : super(
        driftDatabase(
          name: 'kvantum',
          native: DriftNativeOptions(
            databasePath: () async => path,
            setup: (raw) => prepareRawDatabase(
              raw,
              path: path,
              schemaVersion: currentSchemaVersion,
            ),
          ),
        ),
      );

  /// The schema version this build writes (a database with a higher one
  /// belongs to a newer build).
  static const currentSchemaVersion = 4;

  @override
  int get schemaVersion => currentSchemaVersion;

  /// Indexes of the lookups the sync does per row. Created idempotently on
  /// every start (no schema version change needed).
  static const _indexes = [
    'CREATE INDEX IF NOT EXISTS event_rows_series ON event_rows (recurring_event_id)',
    'CREATE INDEX IF NOT EXISTS event_rows_google ON event_rows (google_id)',
    'CREATE INDEX IF NOT EXISTS outbox_rows_event ON outbox_rows (event_id)',
    'CREATE INDEX IF NOT EXISTS record_rows_dirty ON record_rows (dirty)',
    'CREATE INDEX IF NOT EXISTS fin_rows_kind ON fin_rows (kind, deleted)',
    'CREATE INDEX IF NOT EXISTS fin_rows_dirty ON fin_rows (dirty)',
  ];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // A file labelled with a newer version must not be "upgraded" backwards:
      // drift would write the old number into it.
      if (from > to) throw NewerDatabaseError(from, to);
      // All steps are one unit: a failure half-way leaves the file as it was.
      await transaction(() async {
        if (from < 2) {
          await m.addColumn(eventRows, eventRows.colorId);
          await m.addColumn(eventRows, eventRows.aiGenerated);
          // The app now only shows its own "Naptar" calendar. Rows that
          // came from the user's primary calendar are dropped locally
          // (nothing is deleted in Google).
          await customStatement(
            "DELETE FROM outbox_rows WHERE event_id IN (SELECT id FROM event_rows WHERE calendar_id <> 'naptar')",
          );
          await customStatement(
            "DELETE FROM event_rows WHERE calendar_id <> 'naptar'",
          );
          await customStatement(
            "DELETE FROM meta_rows WHERE key LIKE 'syncToken:%'",
          );
        }
        if (from < 3) {
          await m.createTable(recordRows);
          await m.createTable(driveFileRows);
        }
        if (from < 4) {
          await m.createTable(finRows);
        }
      });
    },
    beforeOpen: (details) async {
      for (final statement in _indexes) {
        await customStatement(statement);
      }
    },
  );
}
