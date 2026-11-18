import 'db.dart';
import 'db_open.dart';

/// What the app learns about its database before it opens it.
class StartupResult {
  const StartupResult(this.path, {this.problem, this.move});

  /// The file to open.
  final String path;

  /// Why the database must not be opened ([NewerDatabaseError],
  /// [UnreadableDatabaseError]), or null.
  final Object? problem;

  /// What the move of the database to its new place did (Windows), if any.
  final DbMoveResult? move;
}

/// Decides where the database is, moves it to its proper place when needed,
/// and checks that this build may open it. Runs before the first query.
Future<StartupResult> prepareStartup({
  required bool windows,
  required String documentsDir,
  String? localAppData,
  int schemaVersion = AppDatabase.currentSchemaVersion,
}) async {
  final where = locateDatabase(
    windows: windows,
    documentsDir: documentsDir,
    localAppData: localAppData,
  );
  var path = where.path;
  DbMoveResult? move;
  if (where.legacyPath != null) {
    move = moveLegacyDatabase(path: path, legacyPath: where.legacyPath!);
    path = move.path;
  }
  return StartupResult(
    path,
    problem: checkDatabaseFile(path, schemaVersion: schemaVersion),
    move: move,
  );
}
