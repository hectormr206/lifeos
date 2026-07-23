// Where the app fetches the on-device embedding model from (roadmap SLICE B1b).
//
// The ~179 MB EmbeddingGemma-300M LiteRT model is NOT bundled in the APK — it
// is downloaded on FIRST USE from a PUBLIC base URL (the VPS), exactly like the
// offline Whisper STT model (features/stt/data/stt_model_source_config.dart).
// Each file lives at `<baseUrl>/<filename>`.
//
// ─────────────────────────────────────────────────────────────────────────
// HOSTING (VPS): publish these two files under the base path:
//   https://updates.lifeos.hectormr.com/embed/embeddinggemma-300M_seq256_mixed-precision.tflite
//   https://updates.lifeos.hectormr.com/embed/sentencepiece.model
//
// CANONICAL UPSTREAM (license-gated on HuggingFace — accept the Gemma license
// with your account, then download and re-host):
//   https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite
//   https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model
//
// The base URL can be overridden without editing source at build time:
//   flutter build apk \
//     --dart-define=EMBED_MODEL_BASE_URL=https://models.example/lifeos/embed
// ─────────────────────────────────────────────────────────────────────────

/// Public base URL the embedding model files are fetched from (no trailing
/// slash needed). `--dart-define=EMBED_MODEL_BASE_URL=...` overrides the
/// VPS default at build time.
const String kEmbedModelBaseUrl = String.fromEnvironment(
  'EMBED_MODEL_BASE_URL',
  defaultValue: 'https://updates.lifeos.hectormr.com/embed',
);

/// One remote model file plus the smallest byte size a valid copy can be.
///
/// The size floor is the same cheap sanity check the STT gateway uses: a
/// captive-portal HTML page or a truncated download is a few KB and fails it,
/// so a bogus file can never be handed to the embedding runtime.
class EmbedModelFile {
  const EmbedModelFile({required this.name, required this.minBytes});

  /// File name, used BOTH as the remote path segment (`<baseUrl>/<name>`) and
  /// the local file name under the model dir.
  final String name;

  /// Minimum plausible size in bytes for a complete, valid file.
  final int minBytes;
}

/// Immutable snapshot of the embedding-model source (base URL + file
/// manifest). Injected into the downloader gateway so tests can supply their
/// own (configured or deliberately-unconfigured) values.
class EmbedModelSourceConfig {
  const EmbedModelSourceConfig({
    this.baseUrl = kEmbedModelBaseUrl,
    // The seq256 mixed-precision LiteRT export (~179 MB) — chat facts are
    // short, so the smallest sequence-length variant is the right tradeoff.
    this.model = const EmbedModelFile(
      name: 'embeddinggemma-300M_seq256_mixed-precision.tflite',
      minBytes: 100 * 1024 * 1024,
    ),
    // Matching SentencePiece tokenizer (~4.7 MB).
    this.tokenizer = const EmbedModelFile(
      name: 'sentencepiece.model',
      minBytes: 1 * 1024 * 1024,
    ),
  });

  /// Public base URL for `<baseUrl>/<file.name>`.
  final String baseUrl;

  final EmbedModelFile model;
  final EmbedModelFile tokenizer;

  /// The files, in download order (model first — it dominates the progress bar).
  List<EmbedModelFile> get files => [model, tokenizer];

  /// Guards the download from firing against an empty/placeholder host.
  bool get isConfigured => baseUrl.isNotEmpty && !baseUrl.contains('PLACEHOLDER');
}
