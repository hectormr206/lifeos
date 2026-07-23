// Where the app fetches the on-device chat model (BRAIN) from — OUR VPS, not
// HuggingFace (local-first: we own the hosting, the version, and the rollout).
//
// Exactly the STT/TTS/EMBED house pattern: a PUBLIC base URL (no access key)
// hosting the files flat:
//   <base>/manifest.json            → {modelName, versionCode, filename,
//                                      sha256, sizeBytes, notes, publishedAt}
//   <base>/<filename>               → gemma-4-E2B-it.litertlm (~2.6GB)
//
// Point the app at the base EITHER by editing `kBrainModelBaseUrl` below, OR —
// without editing source — at build time:
//   flutter build apk \
//     --dart-define=BRAIN_MODEL_BASE_URL=https://updates.example/lifeos/model
// (publish-to-vps.sh passes `$UPDATE_BASE_URL/model` by default; the real host
// is https://updates.lifeos.hectormr.com/model.)
//
// While the placeholder is in place (or the URL is empty), `isConfigured` is
// false: the update check is skipped entirely and the model download falls
// back to the legacy in-engine network install, so dev builds keep working.

/// Public base URL the manifest + weights are fetched from (no trailing slash
/// needed). `--dart-define=BRAIN_MODEL_BASE_URL=...` overrides this
/// placeholder at build time.
const String kBrainModelBaseUrl = String.fromEnvironment(
  'BRAIN_MODEL_BASE_URL',
  defaultValue: 'https://models.PLACEHOLDER.example/lifeos/model',
);

/// Immutable snapshot of the brain-model OTA source. Injected into the
/// gateway so tests can supply their own (configured or deliberately-
/// unconfigured) values.
class BrainModelSourceConfig {
  const BrainModelSourceConfig({this.baseUrl = kBrainModelBaseUrl});

  /// Public base URL for `<baseUrl>/manifest.json` and `<baseUrl>/<filename>`.
  final String baseUrl;

  /// True only once the placeholder URL has been replaced with a real one.
  /// Guards both the update check and the download from firing against the
  /// placeholder host.
  bool get isConfigured => baseUrl.isNotEmpty && !baseUrl.contains('PLACEHOLDER');
}
