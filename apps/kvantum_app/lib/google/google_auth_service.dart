import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis/calendar/v3.dart' as cal;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// OAuth client values come from `--dart-define-from-file=secrets.json`
/// (git-ignored). They never live in the repository.
class GoogleConfig {
  static const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const clientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');
  static bool get isConfigured =>
      clientId.isNotEmpty && clientSecret.isNotEmpty;
  static const scopes = [
    cal.CalendarApi.calendarScope,
    drive.DriveApi.driveAppdataScope,
  ];
}

/// What the sync controller needs from authentication (fakeable in tests).
abstract class AuthGateway {
  Future<http.Client?> restore();
  Future<http.Client> signIn();
  Future<void> signOut();
}

abstract class CredentialStore {
  Future<String?> read();
  Future<void> write(String? value);
}

/// Refresh token + access token live in the OS secure store
/// (Windows DPAPI / Android Keystore), never in plain files.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'google_credentials_v1';
  @override
  Future<String?> read() => _s.read(key: _key);
  @override
  Future<void> write(String? value) =>
      value == null ? _s.delete(key: _key) : _s.write(key: _key, value: value);
}

class MemoryCredentialStore implements CredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? v) async => value = v;
}

String encodeCredentials(AccessCredentials c) => jsonEncode({
  'type': c.accessToken.type,
  'data': c.accessToken.data,
  'expiry': c.accessToken.expiry.toUtc().toIso8601String(),
  'refresh': c.refreshToken,
  'scopes': c.scopes,
});

AccessCredentials? decodeCredentials(String? s) {
  if (s == null) return null;
  try {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return AccessCredentials(
      AccessToken(
        m['type'] as String,
        m['data'] as String,
        DateTime.parse(m['expiry'] as String).toUtc(),
      ),
      m['refresh'] as String?,
      (m['scopes'] as List).cast<String>(),
    );
  } catch (_) {
    return null; // corrupt entry -> treat as signed out
  }
}

class GoogleAuthService implements AuthGateway {
  GoogleAuthService(this._store);
  final CredentialStore _store;
  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _sub;

  ClientId get _id =>
      ClientId(GoogleConfig.clientId, GoogleConfig.clientSecret);

  @override
  Future<http.Client?> restore() async {
    final creds = decodeCredentials(await _store.read());
    if (creds == null || creds.refreshToken == null) return null;
    return _adopt(autoRefreshingClient(_id, creds, http.Client()));
  }

  @override
  Future<http.Client> signIn() async {
    final c = await clientViaUserConsent(_id, GoogleConfig.scopes, (url) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    });
    await _store.write(encodeCredentials(c.credentials));
    return _adopt(c);
  }

  http.Client _adopt(AutoRefreshingAuthClient c) {
    _sub?.cancel();
    _client = c;
    // Persist refreshed access tokens so a restart does not need a new login.
    _sub = c.credentialUpdates.listen(
      (u) => _store.write(encodeCredentials(u)),
    );
    return c;
  }

  @override
  Future<void> signOut() async {
    await _sub?.cancel();
    _client?.close();
    _client = null;
    await _store.write(null);
  }
}
