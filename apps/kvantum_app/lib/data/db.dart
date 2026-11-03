import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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

class MetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [EventRows, OutboxRows, MetaRows])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);
  AppDatabase.open() : super(driftDatabase(name: 'kvantum'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
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
    },
  );
}
