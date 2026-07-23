package com.lifeos.lifeos.ime

import android.content.Context
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import java.io.File

/**
 * On-device Whisper transcription for the Axi keyboard (IME).
 *
 * The IME runs OUTSIDE the Flutter engine, so it cannot use the `sherpa_onnx`
 * Dart plugin. Instead it uses sherpa-onnx's official Kotlin/JNI API (the
 * `sherpa-onnx-static-link-onnxruntime` AAR wired in app/build.gradle.kts —
 * same version as the Dart plugin, and statically linked so it does NOT clash
 * with the plugin's own `libonnxruntime.so`).
 *
 * MODEL REUSE: it reads the exact same three Whisper files the Flutter app
 * downloads (features/stt, `background_downloader` with
 * `BaseDirectory.applicationSupport` + directory `stt_model`, which on Android
 * resolves to `context.filesDir/stt_model/`). Nothing is downloaded here — if
 * the files are missing the keyboard tells the user to download the voice
 * model in LifeOS first. Everything stays on-device; audio and text never
 * leave the phone.
 */
class WhisperTranscriber(private val context: Context) {

    companion object {
        const val SAMPLE_RATE = 16_000

        // Mirror of lib/features/stt/data/stt_model_source_config.dart —
        // same file names AND same minimum-size sanity floors, so the IME
        // never feeds a truncated download to the recognizer.
        private const val MODEL_DIR = "stt_model"
        private const val ENCODER = "base-encoder.int8.onnx"
        private const val DECODER = "base-decoder.int8.onnx"
        private const val TOKENS = "base-tokens.txt"
        private const val MIN_ONNX_BYTES = 1L * 1024 * 1024
        private const val MIN_TOKENS_BYTES = 1L * 1024

        private fun modelDir(context: Context) = File(context.filesDir, MODEL_DIR)

        /** True when all three model files exist and pass their size floors. */
        fun isModelInstalled(context: Context): Boolean {
            val dir = modelDir(context)
            return File(dir, ENCODER).length() >= MIN_ONNX_BYTES &&
                File(dir, DECODER).length() >= MIN_ONNX_BYTES &&
                File(dir, TOKENS).length() >= MIN_TOKENS_BYTES
        }
    }

    private var recognizer: OfflineRecognizer? = null

    /**
     * Lazily build the recognizer from the on-disk model. Heavy (~1-2 s):
     * call from a background thread only. No-op when already loaded.
     *
     * [language] is an ISO-639-1 code; like the Flutter side
     * (`sttWhisperLanguage`) only 'en' is honored, anything else falls back
     * to Spanish, the app's neutral default.
     */
    fun ensureLoaded(language: String) {
        if (recognizer != null) return
        val dir = modelDir(context)
        val config = OfflineRecognizerConfig().apply {
            featConfig = FeatureConfig().apply {
                sampleRate = SAMPLE_RATE
                featureDim = 80
            }
            modelConfig = OfflineModelConfig().apply {
                whisper = OfflineWhisperModelConfig().apply {
                    encoder = File(dir, ENCODER).absolutePath
                    decoder = File(dir, DECODER).absolutePath
                    this.language = if (language == "en") "en" else "es"
                    task = "transcribe"
                }
                tokens = File(dir, TOKENS).absolutePath
                modelType = "whisper"
                numThreads = 2
                debug = false
            }
        }
        // First arg is an optional AssetManager (models bundled in assets);
        // ours live on disk, so pass null and sherpa loads from file paths.
        recognizer = OfflineRecognizer(null, config)
    }

    /**
     * Transcribe one chunk of 16 kHz mono float PCM (-1..1). Blocking —
     * call from a background thread. Returns trimmed text ("" for silence).
     */
    fun transcribe(samples: FloatArray): String {
        val rec = recognizer ?: throw IllegalStateException("call ensureLoaded() first")
        val stream = rec.createStream()
        try {
            stream.acceptWaveform(samples, SAMPLE_RATE)
            rec.decode(stream)
            return rec.getResult(stream).text.trim()
        } finally {
            stream.release()
        }
    }

    /**
     * Free the native recognizer. Same RAM discipline as the Flutter STT
     * service: the ~80 MB of weights are never kept hot between dictation
     * sessions (the on-device LLM owns the RAM budget).
     */
    fun release() {
        recognizer?.release()
        recognizer = null
    }
}
