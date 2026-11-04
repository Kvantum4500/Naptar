/// Self-update settings. The token is a read-only GitHub token (Contents: read,
/// only this repository) injected at build time with --dart-define=UPDATE_TOKEN.
class UpdateConfig {
  static const token = String.fromEnvironment('UPDATE_TOKEN');
  static const repo = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'Kvantum4500/Naptar',
  );
  static bool get configured => token.isNotEmpty;
}
