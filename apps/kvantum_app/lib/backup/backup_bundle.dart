import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The name and version of the backup file format this build writes and reads.
const backupFormat = 'kvantum-backup';
const backupVersion = 1;

/// Everything a backup holds, as texts: the calendar as an .ics file, the
/// finance data as the finance backup JSON, and the synced records (tasks,
/// check-ins, handbook, workout logs) as one encoded record each.
class BackupData {
  const BackupData({
    this.calendarIcs = '',
    this.financeJson = '',
    this.records = const [],
  });
  final String calendarIcs;
  final String financeJson;
  final List<String> records;
}

/// What a backup says about itself (readable without restoring it).
class BackupMeta {
  const BackupMeta({
    required this.createdAt,
    this.build,
    this.counts = const {},
  });

  /// When the backup was made (UTC).
  final DateTime createdAt;

  /// The build of the app that made it.
  final int? build;

  /// How many of each thing it holds: `events`, `finance`, `task`, `checkin`,
  /// `handbook`, `workoutlog`.
  final Map<String, int> counts;

  Map<String, Object?> toJson() => {
    'format': backupFormat,
    'version': backupVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'build': ?build,
    'counts': counts,
  };
}

/// A backup read back.
class BackupFile {
  const BackupFile(this.meta, this.data);
  final BackupMeta meta;
  final BackupData data;
}

/// Why a file is not a backup that can be used.
enum BackupProblem {
  /// Not a zip file, or not made by this program.
  notABackup,

  /// The backup is locked with a password and none was given.
  passwordNeeded,

  /// The password does not open it.
  wrongPassword,

  /// Made by a newer version of the app: it may hold what this one does not
  /// know, and restoring half of it would look like success.
  newerVersion,

  /// A part is missing or damaged.
  damaged,

  /// A copy in the Drive that is not locked with a password. The program
  /// always locks what it puts there, so somebody else put this in.
  notLocked,
}

class BackupException implements Exception {
  const BackupException(this.problem);
  final BackupProblem problem;

  /// What to tell the user.
  String get message => switch (problem) {
    BackupProblem.notABackup => 'Ez a fájl nem a Kvantum Naptár mentése.',
    BackupProblem.passwordNeeded =>
      'Ez a mentés jelszóval védett: add meg a jelszót.',
    BackupProblem.wrongPassword => 'Hibás jelszó.',
    BackupProblem.newerVersion =>
      'Ezt a mentést a program újabb változata készítette; frissítsd a '
          'programot, mielőtt visszaállítod.',
    BackupProblem.damaged => 'A mentés sérült, nem lehet beolvasni.',
    BackupProblem.notLocked =>
      'Ez a Drive-másolat nincs jelszóval lezárva, pedig a program mindig '
          'lezárva tölti fel: valaki más írhatta át. Nem állítom vissza.',
  };

  @override
  String toString() => 'BackupException($problem)';
}

/// Whether the zip [bytes] is locked with a password: there is at least one
/// entry with content, and every entry with content carries the zip's own
/// "encrypted" flag. (An entry with no content is never locked by the zip
/// format, so it does not count either way.) Anything that cannot be read as
/// a zip is not locked.
bool zipIsLocked(List<int> bytes) {
  try {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    final withContent = [
      for (final h in directory.fileHeaders)
        if (h.uncompressedSize > 0) h,
    ];
    return withContent.isNotEmpty &&
        withContent.every((h) => h.generalPurposeBitFlag & 0x1 != 0);
  } catch (_) {
    return false;
  }
}

const _metaName = 'meta.json';
const _calendarName = 'calendar.ics';
const _financeName = 'finance.json';
const _recordsName = 'records.json';

/// Makes the backup file (a zip). With a [password] it is locked with AES-256
/// (a zip that any archive program opens with that password).
Uint8List packBackup(BackupData data, BackupMeta meta, {String? password}) {
  final archive = Archive()
    ..add(ArchiveFile.string(_metaName, jsonEncode(meta.toJson())))
    ..add(ArchiveFile.string(_calendarName, data.calendarIcs))
    ..add(ArchiveFile.string(_financeName, data.financeJson))
    ..add(ArchiveFile.string(_recordsName, jsonEncode(data.records)));
  final bytes = ZipEncoder(
    password: (password == null || password.isEmpty) ? null : password,
  ).encodeBytes(archive);
  return Uint8List.fromList(bytes);
}

/// Reads a backup file. Throws a [BackupException] saying what is wrong.
BackupFile unpackBackup(List<int> bytes, {String? password}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(
      bytes,
      verify: true,
      password: (password == null || password.isEmpty) ? null : password,
    );
  } on ArchivePasswordException {
    throw BackupException(
      password == null || password.isEmpty
          ? BackupProblem.passwordNeeded
          : BackupProblem.wrongPassword,
    );
  } on ArchiveException {
    throw const BackupException(BackupProblem.notABackup);
  } on FormatException {
    throw const BackupException(BackupProblem.notABackup);
  } on RangeError {
    throw const BackupException(BackupProblem.notABackup);
  }

  // (the zip is read lazily: a missing or wrong password shows when a file's
  // content is asked for, not when the zip is opened)
  String? text(String name) {
    final f = archive.find(name);
    if (f == null || !f.isFile) return null;
    try {
      return utf8.decode(f.content, allowMalformed: false);
    } on ArchivePasswordException {
      throw BackupException(
        password == null || password.isEmpty
            ? BackupProblem.passwordNeeded
            : BackupProblem.wrongPassword,
      );
    } on FormatException {
      throw const BackupException(BackupProblem.damaged);
    }
  }

  final metaText = text(_metaName);
  if (metaText == null) {
    throw const BackupException(BackupProblem.notABackup);
  }
  final Object? meta;
  try {
    meta = jsonDecode(metaText);
  } on FormatException {
    throw const BackupException(BackupProblem.notABackup);
  }
  if (meta is! Map || meta['format'] != backupFormat) {
    throw const BackupException(BackupProblem.notABackup);
  }
  final version = meta['version'];
  if (version is! num) {
    throw const BackupException(BackupProblem.damaged);
  }
  if (version > backupVersion) {
    throw const BackupException(BackupProblem.newerVersion);
  }
  final created = DateTime.tryParse('${meta['createdAt']}');
  if (created == null) throw const BackupException(BackupProblem.damaged);

  final counts = <String, int>{};
  final rawCounts = meta['counts'];
  if (rawCounts is Map) {
    rawCounts.forEach((k, v) {
      if (v is num) counts['$k'] = v.toInt();
    });
  }

  final recordsText = text(_recordsName);
  final records = <String>[];
  if (recordsText != null) {
    final Object? list;
    try {
      list = jsonDecode(recordsText);
    } on FormatException {
      throw const BackupException(BackupProblem.damaged);
    }
    if (list is! List) throw const BackupException(BackupProblem.damaged);
    for (final r in list) {
      if (r is String) records.add(r);
    }
  }

  return BackupFile(
    BackupMeta(
      createdAt: created.toUtc(),
      build: (meta['build'] as num?)?.toInt(),
      counts: counts,
    ),
    BackupData(
      calendarIcs: text(_calendarName) ?? '',
      financeJson: text(_financeName) ?? '',
      records: records,
    ),
  );
}
