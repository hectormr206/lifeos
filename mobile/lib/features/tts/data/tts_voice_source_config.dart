// Where the app fetches the on-device Piper TTS voices from (roadmap slice B3).
//
// The ~60 MB-per-language Piper VITS voices are NOT bundled in the APK — each
// is downloaded on FIRST USE from a PUBLIC base URL (the VPS), exactly like
// the STT model config (features/stt/data/stt_model_source_config.dart).
// Every file lives FLAT at `<baseUrl>/<filename>`.
//
// ─────────────────────────────────────────────────────────────────────────
// HOSTING (VPS): publish these files under one base path, e.g.
//   https://models.example/lifeos/tts/es_MX-ald-medium.onnx
//   https://models.example/lifeos/tts/es_MX-ald-medium.onnx.json
//   https://models.example/lifeos/tts/en_US-lessac-medium.onnx
//   https://models.example/lifeos/tts/en_US-lessac-medium.onnx.json
//   https://models.example/lifeos/tts/espeak-ng-data.tar.gz
//
// IMPORTANT — where those files come from:
//  * The `.onnx` + `.onnx.json` MUST be the sherpa-onnx-converted Piper
//    exports (the `vits-piper-es_MX-ald-medium` / `vits-piper-en_US-lessac-
//    medium` release bundles keep the original filenames) — the conversion
//    embeds the VITS metadata sherpa-onnx's OfflineTts needs. A raw upstream
//    piper release .onnx will NOT load.
//  * `espeak-ng-data.tar.gz` is the `espeak-ng-data/` directory from any one
//    of those same bundles, re-packed as a GZIP tar with the `espeak-ng-data/`
//    folder at the archive root:  `tar czf espeak-ng-data.tar.gz espeak-ng-data`
//    (gzip, NOT bzip2 — the app extracts it with the Dart-native gzip codec,
//    keeping the extraction dependency-free).
//  * `tokens.txt` is NOT hosted: the app derives it locally from the
//    `.onnx.json` `phoneme_id_map` after download (same table the sherpa-onnx
//    conversion script writes).
//
// Then point the app at that base, EITHER by editing `kTtsModelBaseUrl` below,
// OR — without editing source — at build time:
//   flutter build apk \
//     --dart-define=TTS_MODEL_BASE_URL=https://models.example/lifeos/tts
// The `--dart-define` value wins over the placeholder below.
//
// While the placeholder is in place (or the URL is empty), `isConfigured` is
// false and speak-aloud silently stays on the system voice instead of hitting
// a bogus host.
// ─────────────────────────────────────────────────────────────────────────

/// Public base URL the Piper voice files are fetched from (no trailing slash
/// needed). `--dart-define=TTS_MODEL_BASE_URL=...` overrides this placeholder
/// at build time.
///
/// TODO(release): replace the placeholder with the real VPS URL.
const String kTtsModelBaseUrl = String.fromEnvironment(
  'TTS_MODEL_BASE_URL',
  defaultValue: 'https://models.PLACEHOLDER.example/lifeos/tts',
);

/// One remote voice file plus the smallest byte size a valid copy can be.
///
/// The size floor is the same cheap sanity check the STT manifest uses: a
/// captive-portal HTML page or a truncated download is a few KB and fails it,
/// so a bogus file can never be handed to the synthesizer.
class TtsVoiceFile {
  const TtsVoiceFile({required this.name, required this.minBytes});

  /// File name, used BOTH as the remote path segment (`<baseUrl>/<name>`) and
  /// the local file name under the voice dir.
  final String name;

  /// Minimum plausible size in bytes for a complete, valid file.
  final int minBytes;
}

/// One per-language Piper voice: the acoustic model and its piper JSON config
/// (which the app turns into the sherpa-onnx `tokens.txt` locally).
class TtsVoiceSpec {
  const TtsVoiceSpec({required this.model, required this.config});

  /// sherpa-onnx-converted Piper VITS model (`*.onnx`, ~60 MB for a medium).
  final TtsVoiceFile model;

  /// Piper voice config (`*.onnx.json`), source of the phoneme→id table.
  final TtsVoiceFile config;

  /// Local file name of the DERIVED sherpa-onnx token table (never hosted).
  String get tokensFileName => '${model.name}.tokens.txt';

  /// Remote files to download for this voice, in order.
  List<TtsVoiceFile> get files => [model, config];
}

/// Immutable snapshot of the TTS voice source (base URL + per-language voice
/// manifest + the shared espeak-ng-data archive). Injected into the downloader
/// gateway so tests can supply their own values.
class TtsVoiceSourceConfig {
  const TtsVoiceSourceConfig({
    this.baseUrl = kTtsModelBaseUrl,
    this.spanish = const TtsVoiceSpec(
      model: TtsVoiceFile(name: 'es_MX-ald-medium.onnx', minBytes: 10 * 1024 * 1024),
      config: TtsVoiceFile(name: 'es_MX-ald-medium.onnx.json', minBytes: 1024),
    ),
    this.english = const TtsVoiceSpec(
      model: TtsVoiceFile(name: 'en_US-lessac-medium.onnx', minBytes: 10 * 1024 * 1024),
      config: TtsVoiceFile(name: 'en_US-lessac-medium.onnx.json', minBytes: 1024),
    ),
    this.espeakData = const TtsVoiceFile(name: 'espeak-ng-data.tar.gz', minBytes: 1024 * 1024),
  });

  /// Public base URL for `<baseUrl>/<file.name>`.
  final String baseUrl;

  /// es → neutral-Mexican Piper voice.
  final TtsVoiceSpec spanish;

  /// en → US-English Piper voice.
  final TtsVoiceSpec english;

  /// GZIP tar of the `espeak-ng-data/` directory (shared by ALL voices),
  /// extracted once next to the models.
  final TtsVoiceFile espeakData;

  /// Name of the directory the archive extracts to (and that
  /// `OfflineTtsVitsModelConfig.dataDir` points at).
  static const String espeakDataDirName = 'espeak-ng-data';

  /// The voice for app language [languageCode], or null when the language has
  /// no Piper voice yet (the system voice keeps covering it). ADDING A
  /// LANGUAGE = one more case here + two hosted files.
  TtsVoiceSpec? voiceForLanguage(String languageCode) => switch (languageCode) {
        'es' => spanish,
        'en' => english,
        _ => null,
      };

  /// True only once the placeholder URL has been replaced with a real one.
  /// Guards the download from firing against the placeholder host.
  bool get isConfigured => baseUrl.isNotEmpty && !baseUrl.contains('PLACEHOLDER');
}
