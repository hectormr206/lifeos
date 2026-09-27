// Where the app fetches its self-update manifest + APK from.
//
// Unlike the original OTA flow (which polled the *paired engine* over the
// authenticated `dioProvider`), updates now come from a PUBLIC URL guarded by
// a bundled access key — so an update check works for ANY user, WITHOUT
// pairing. The manifest lives at `<baseUrl>/manifest` and the APK at
// `<baseUrl>/download`; every request carries the key in the
// `kUpdateAccessKeyHeader` header.
//
// ─────────────────────────────────────────────────────────────────────────
// FILL THESE IN before a real release (two ways, either works):
//
//   1. Edit `kUpdateBaseUrl` / `kUpdateAccessKey` below (single source of
//      truth — swap the placeholders for the real Cloudflare URL + secret).
//   2. OR inject them at build time WITHOUT editing source:
//        flutter build apk \
//          --dart-define=UPDATE_BASE_URL=https://updates.example.com/lifeos \
//          --dart-define=UPDATE_ACCESS_KEY=the-real-secret
//      The `--dart-define` value wins over the placeholder below.
//
// While the placeholders are still in place (or the base URL is empty), the
// config reports `isConfigured` == false and the update check degrades to
// `UpdateUnknown` instead of hitting a bogus host.
// ─────────────────────────────────────────────────────────────────────────

/// HTTP header carrying the bundled access key on every manifest/download
/// request (the public URL's only auth — no pairing bearer token involved).
const String kUpdateAccessKeyHeader = 'X-LifeOS-Update-Key';

/// Public base URL of the update source (no trailing slash needed).
/// `--dart-define=UPDATE_BASE_URL=...` overrides this placeholder at build time.
///
/// TODO(release): replace the placeholder with the real Cloudflare URL.
const String kUpdateBaseUrl = String.fromEnvironment(
  'UPDATE_BASE_URL',
  defaultValue: 'https://updates.PLACEHOLDER.example/lifeos',
);

/// Bundled access key sent as [kUpdateAccessKeyHeader].
/// `--dart-define=UPDATE_ACCESS_KEY=...` overrides this placeholder at build
/// time.
///
/// TODO(release): replace the placeholder with the real access key/secret.
const String kUpdateAccessKey = String.fromEnvironment(
  'UPDATE_ACCESS_KEY',
  defaultValue: 'PLACEHOLDER_UPDATE_ACCESS_KEY',
);

// A single compile-time constant from the existing release defines. The
// environment constructor reads this exact frame at runtime; its presence in
// AOT therefore attests the configured source, not an unused marker variable.
const String _bakedUpdateConfig =
    'LIFEOS_OTA_CONFIG_V1\n$kUpdateBaseUrl\n$kUpdateAccessKey\nEND_LIFEOS_OTA_CONFIG_V1';

/// Immutable snapshot of the update source (base URL + access key). Injected
/// into [AppUpdateService] / [ApkDownloadService] so tests can supply their
/// own (configured or deliberately-unconfigured) values.
class UpdateSourceConfig {
  // Public named arguments remain stable; private nullable storage lets the
  // environment constructor derive its getters from the baked frame instead.
  const UpdateSourceConfig({required String baseUrl, required String accessKey})
      // ignore: prefer_initializing_formals
      : _baseUrl = baseUrl,
        // ignore: prefer_initializing_formals
        _accessKey = accessKey,
        _frame = null;

  /// The build-time config (dart-define overrides, else the placeholders).
  const UpdateSourceConfig.fromEnvironment()
      : _baseUrl = null,
        _accessKey = null,
        _frame = _bakedUpdateConfig;

  final String? _baseUrl;
  final String? _accessKey;
  final String? _frame;

  // Reject broken delimiters or embedded line breaks without exposing either
  // value. Invalid environment frames behave as unconfigured sources.
  String _framedPart(int index) {
    final parts = _frame!.split('\n');
    if (parts.length != 4 ||
        parts[0] != 'LIFEOS_OTA_CONFIG_V1' ||
        parts[3] != 'END_LIFEOS_OTA_CONFIG_V1' ||
        parts[1].isEmpty ||
        parts[2].isEmpty ||
        parts[1].codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        parts[2].codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      return '';
    }
    return parts[index];
  }

  /// Public base URL for `<baseUrl>/manifest` and `<baseUrl>/download`.
  String get baseUrl => _frame == null ? _baseUrl! : _framedPart(1);

  /// Secret sent as [kUpdateAccessKeyHeader].
  String get accessKey => _frame == null ? _accessKey! : _framedPart(2);

  /// True only once the placeholders have been replaced with real values.
  /// Guards the update check from firing against the placeholder host (which
  /// would surface a scary network error instead of a quiet "no update info").
  bool get isConfigured =>
      baseUrl.isNotEmpty &&
      accessKey.isNotEmpty &&
      !baseUrl.contains('PLACEHOLDER') &&
      !accessKey.contains('PLACEHOLDER');
}
