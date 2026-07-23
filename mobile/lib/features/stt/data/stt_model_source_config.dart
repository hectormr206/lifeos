// Where the app fetches the offline Whisper STT model from (roadmap slice B2).
//
// The ~80 MB Whisper base int8 multilingual model is NOT bundled in the APK —
// it is downloaded on FIRST USE from a PUBLIC base URL (the VPS), exactly like
// the self-hosted app-update config (features/app_update/.../update_source_config.dart).
// Each of the three model files lives at `<baseUrl>/<filename>`.
//
// ─────────────────────────────────────────────────────────────────────────
// HOSTING (VPS): publish these three files under one base path, e.g.
//   https://models.example/lifeos/stt/base-encoder.int8.onnx
//   https://models.example/lifeos/stt/base-decoder.int8.onnx
//   https://models.example/lifeos/stt/base-tokens.txt
// (the standard sherpa-onnx `sherpa-onnx-whisper-base` release artifacts).
//
// Then point the app at that base, EITHER by editing `kSttModelBaseUrl` below,
// OR — without editing source — at build time:
//   flutter build apk \
//     --dart-define=STT_MODEL_BASE_URL=https://models.example/lifeos/stt
// The `--dart-define` value wins over the placeholder below.
//
// While the placeholder is in place (or the URL is empty), `isConfigured` is
// false and STT degrades gracefully (the canned "descarga el modelo de voz"
// reply) instead of hitting a bogus host.
// ─────────────────────────────────────────────────────────────────────────

/// Public base URL the three Whisper model files are fetched from (no trailing
/// slash needed). `--dart-define=STT_MODEL_BASE_URL=...` overrides this
/// placeholder at build time.
///
/// TODO(release): replace the placeholder with the real VPS URL.
const String kSttModelBaseUrl = String.fromEnvironment(
  'STT_MODEL_BASE_URL',
  defaultValue: 'https://models.PLACEHOLDER.example/lifeos/stt',
);

/// One remote model file plus the smallest byte size a valid copy can be.
///
/// The size floor is a cheap sanity check (the design's "sha256 or size
/// check"): a captive-portal HTML page or a truncated download is a few KB and
/// fails it, so a bogus file can never be handed to the recognizer.
class SttModelFile {
  const SttModelFile({required this.name, required this.minBytes});

  /// File name, used BOTH as the remote path segment (`<baseUrl>/<name>`) and
  /// the local file name under the model dir.
  final String name;

  /// Minimum plausible size in bytes for a complete, valid file.
  final int minBytes;
}

/// Immutable snapshot of the STT model source (base URL + file manifest).
/// Injected into the downloader gateway so tests can supply their own
/// (configured or deliberately-unconfigured) values.
class SttModelSourceConfig {
  const SttModelSourceConfig({
    this.baseUrl = kSttModelBaseUrl,
    this.encoder = const SttModelFile(name: 'base-encoder.int8.onnx', minBytes: 1 * 1024 * 1024),
    this.decoder = const SttModelFile(name: 'base-decoder.int8.onnx', minBytes: 1 * 1024 * 1024),
    this.tokens = const SttModelFile(name: 'base-tokens.txt', minBytes: 1 * 1024),
  });

  /// Public base URL for `<baseUrl>/<file.name>`.
  final String baseUrl;

  final SttModelFile encoder;
  final SttModelFile decoder;
  final SttModelFile tokens;

  /// The three files, in download order.
  List<SttModelFile> get files => [encoder, decoder, tokens];

  /// True only once the placeholder URL has been replaced with a real one.
  /// Guards the download from firing against the placeholder host.
  bool get isConfigured => baseUrl.isNotEmpty && !baseUrl.contains('PLACEHOLDER');
}
