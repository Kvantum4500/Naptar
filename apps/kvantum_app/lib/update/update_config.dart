import 'update_signature.dart';

/// Self-update settings. The repository is public, so the updater needs no
/// key: the token below is OPTIONAL (a read-only GitHub token, Contents: read,
/// only this repository, injected at build time with --dart-define=UPDATE_TOKEN)
/// and the builds are made without one. It stays supported for the builds that
/// were made with one.
class UpdateConfig {
  static const token = String.fromEnvironment('UPDATE_TOKEN');
  static const repo = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'Kvantum4500/Naptar',
  );

  /// The public key (or keys, separated by commas) the releases are signed
  /// with: raw 32-byte Ed25519 keys in base64, injected with
  /// --dart-define=UPDATE_PUBLIC_KEY. It is no secret. Empty: no signature is
  /// checked (a signed release is then accepted on its checksum alone, as
  /// before). See docs/alairt-frissites.md.
  static const _publicKey = String.fromEnvironment('UPDATE_PUBLIC_KEY');
  static List<String> get publicKeys => parseUpdatePublicKeys(_publicKey);

  /// Whether a release without a valid signature is refused,
  /// --dart-define=UPDATE_REQUIRE_SIGNATURE=true. Off until the signing works
  /// for every release: turned on too early, it stops the updates it protects.
  static const requireSignature = bool.fromEnvironment(
    'UPDATE_REQUIRE_SIGNATURE',
  );
}

/// The settings the updater runs with: what the build has in it (see
/// [UpdateConfig]), replaceable in tests.
class UpdateSettings {
  const UpdateSettings({
    required this.token,
    required this.repo,
    this.publicKeys = const [],
    this.requireSignature = false,
  });

  /// What this build was made with.
  factory UpdateSettings.fromBuild() => UpdateSettings(
    token: UpdateConfig.token,
    repo: UpdateConfig.repo,
    publicKeys: UpdateConfig.publicKeys,
    requireSignature: UpdateConfig.requireSignature,
  );

  final String token;
  final String repo;
  final List<String> publicKeys;
  final bool requireSignature;
}
