import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the password of the Drive copy of the backup lives. The real
/// implementation uses the OS secure store (Windows DPAPI / Android Keystore);
/// the password is never written to the database, to Drive, to a log or to a
/// backup file. Without it the copy in Drive cannot be opened - not even by
/// us - so a new device needs it typed in.
abstract class BackupKeyStore {
  Future<String?> read();

  /// Stores [password]; null or empty removes it.
  Future<void> write(String? password);
}

class SecureBackupKeyStore implements BackupKeyStore {
  SecureBackupKeyStore([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  static const _name = 'backup_password_v1';

  @override
  Future<String?> read() async {
    final v = await _s.read(key: _name);
    // (not trimmed: a space may be part of a password)
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Future<void> write(String? password) => (password == null || password.isEmpty)
      ? _s.delete(key: _name)
      : _s.write(key: _name, value: password);
}

class MemoryBackupKeyStore implements BackupKeyStore {
  MemoryBackupKeyStore([this.value]);
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? password) async =>
      value = (password == null || password.isEmpty) ? null : password;
}
