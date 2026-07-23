package com.lifeos.lifeos.ime

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.math.sqrt

/**
 * Microphone capture + chunking for the Axi keyboard's LONG dictations.
 *
 * Records 16 kHz mono PCM on a dedicated thread and slices the take into
 * chunks that are transcribed AND committed progressively while the user
 * keeps talking (laptop parity: dictation tuned for long takes, not a single
 * do-or-die buffer):
 *
 *  - a chunk is emitted when a natural pause is detected (~1.2 s of trailing
 *    silence after at least ~1.5 s of speech) — Whisper gets sentence-shaped
 *    audio, which is where it is most accurate;
 *  - a hard cap of ~25 s forces a chunk even without a pause, keeping every
 *    window comfortably inside Whisper's 30 s receptive field;
 *  - on stop, whatever remains (if it contains any speech) is emitted as the
 *    final chunk.
 *
 * All callbacks fire on the recorder thread; the caller marshals to the main
 * thread as needed.
 */
class DictationRecorder(
    /** Receives each finished chunk as 16 kHz mono float PCM (-1..1). */
    private val onChunk: (FloatArray) -> Unit,
    /** Fired once after stop() when the last chunk (if any) was delivered. */
    private val onFinished: () -> Unit,
    /** Fired when the mic cannot be opened or read. */
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val SAMPLE_RATE = WhisperTranscriber.SAMPLE_RATE

        // Chunking knobs (in samples where applicable).
        private const val MAX_CHUNK_SECONDS = 25
        private const val MAX_CHUNK_SAMPLES = SAMPLE_RATE * MAX_CHUNK_SECONDS
        private const val PAUSE_MS = 1_200          // trailing silence that closes a chunk
        private const val MIN_SPEECH_MS = 1_500     // don't cut before this much voiced audio
        private const val MIN_FINAL_MS = 300        // drop a final chunk shorter than this

        // RMS below this (on -1..1 samples) reads as silence. Deliberately a
        // touch above typical room noise; a fancier adaptive floor is not
        // worth it for a push-to-talk keyboard.
        private const val SILENCE_RMS = 0.010f
    }

    @Volatile
    private var running = false
    private var thread: Thread? = null

    val isRecording: Boolean get() = running

    /** Start capturing. Caller must already hold RECORD_AUDIO. */
    @SuppressLint("MissingPermission") // checked by AxiImeService before calling
    fun start() {
        if (running) return
        running = true
        thread = Thread({ captureLoop() }, "axi-ime-recorder").also { it.start() }
    }

    /** Stop capturing; the final chunk and onFinished still fire (async). */
    fun stop() {
        running = false
    }

    /** Stop and wait for the recorder thread to wind down (service teardown). */
    fun stopAndJoin() {
        running = false
        thread?.join(2_000)
        thread = null
    }

    private fun captureLoop() {
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            onError("mic-unavailable")
            return
        }
        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            // Generous buffer so a busy main thread never drops audio.
            maxOf(minBuf * 4, SAMPLE_RATE), // >= 0.5 s
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            onError("mic-unavailable")
            return
        }

        // ~100 ms read granularity — fine enough for pause detection.
        val readBuf = ShortArray(SAMPLE_RATE / 10)
        val chunk = ArrayList<FloatArray>()
        var chunkSamples = 0
        var speechMs = 0
        var trailingSilenceMs = 0
        var chunkHasSpeech = false

        fun emitChunk(minMs: Int) {
            if (!chunkHasSpeech || chunkSamples < SAMPLE_RATE * minMs / 1_000) {
                // Nothing worth transcribing — discard (pure silence chunks
                // only invite Whisper hallucinations).
                chunk.clear(); chunkSamples = 0; speechMs = 0
                trailingSilenceMs = 0; chunkHasSpeech = false
                return
            }
            val merged = FloatArray(chunkSamples)
            var offset = 0
            for (part in chunk) {
                part.copyInto(merged, offset)
                offset += part.size
            }
            chunk.clear(); chunkSamples = 0; speechMs = 0
            trailingSilenceMs = 0; chunkHasSpeech = false
            onChunk(merged)
        }

        try {
            record.startRecording()
            while (running) {
                val n = record.read(readBuf, 0, readBuf.size)
                if (n <= 0) {
                    onError("mic-read-failed")
                    break
                }
                // Convert to float PCM and measure loudness in one pass.
                val floats = FloatArray(n)
                var sumSq = 0.0
                for (i in 0 until n) {
                    val s = readBuf[i] / 32768.0f
                    floats[i] = s
                    sumSq += (s * s).toDouble()
                }
                chunk.add(floats)
                chunkSamples += n
                val ms = n * 1_000 / SAMPLE_RATE
                if (sqrt(sumSq / n) >= SILENCE_RMS) {
                    chunkHasSpeech = true
                    speechMs += ms
                    trailingSilenceMs = 0
                } else {
                    trailingSilenceMs += ms
                }
                // Natural-pause cut (sentence boundary) or hard 25 s cap.
                val pauseCut = speechMs >= MIN_SPEECH_MS && trailingSilenceMs >= PAUSE_MS
                if (pauseCut || chunkSamples >= MAX_CHUNK_SAMPLES) {
                    emitChunk(minMs = 0)
                }
            }
            emitChunk(minMs = MIN_FINAL_MS)
        } finally {
            try {
                record.stop()
            } catch (_: IllegalStateException) {
                // never started — nothing to stop
            }
            record.release()
            running = false
            onFinished()
        }
    }
}
