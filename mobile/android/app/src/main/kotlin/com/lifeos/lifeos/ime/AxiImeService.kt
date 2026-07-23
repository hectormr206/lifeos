package com.lifeos.lifeos.ime

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.core.content.ContextCompat
import com.lifeos.lifeos.R
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The "Axi" keyboard — a system-wide dictation IME for LifeOS.
 *
 * The user enables it once (Settings > input methods), switches to it in ANY
 * app, taps the big mic, talks, and the ON-DEVICE Whisper transcript is
 * committed into whatever text field is focused. All processing is local
 * (sherpa-onnx + the Whisper model the LifeOS app already downloaded); the
 * audio and the transcript never leave the phone.
 *
 * Long dictations (laptop parity): [DictationRecorder] slices the take at
 * natural pauses / 25 s windows and each chunk is transcribed and committed
 * progressively while the user keeps talking, so arbitrarily long speech
 * lands correctly instead of hitting Whisper's 30 s window.
 *
 * Threading: mic capture on the recorder thread; Whisper on a single-thread
 * executor (chunks stay in spoken order); UI + commitText on main.
 */
class AxiImeService : InputMethodService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var transcriber: WhisperTranscriber? = null
    private var recorder: DictationRecorder? = null
    private var executor: ExecutorService? = null

    /** Chunks queued/running on the executor but not yet committed. */
    private val pendingChunks = AtomicInteger(0)
    /** True from mic-tap(start) until mic-tap(stop). */
    private var listening = false
    /** True while the model is being loaded (first chunkless phase). */
    private var loadingModel = false

    private var statusView: TextView? = null
    private var micButton: ImageButton? = null

    // ── IME lifecycle ────────────────────────────────────────────────────

    override fun onCreateInputView(): View {
        val view = layoutInflater.inflate(R.layout.axi_ime_keyboard, null)
        statusView = view.findViewById(R.id.axi_status)
        micButton = view.findViewById(R.id.axi_mic)
        micButton?.setOnClickListener { onMicTap() }
        view.findViewById<View>(R.id.axi_backspace).setOnClickListener {
            // A real DEL key event so it works with selections and empty fields.
            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        }
        view.findViewById<View>(R.id.axi_switch_keyboard).setOnClickListener {
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .showInputMethodPicker()
        }
        view.findViewById<View>(R.id.axi_open_app).setOnClickListener { openLifeOs() }
        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        refreshIdleUi()
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        // Keyboard dismissed mid-dictation: stop the mic; queued chunks still
        // finish (the input connection may survive; if not, commits no-op).
        if (listening) stopListening()
    }

    override fun onDestroy() {
        recorder?.stopAndJoin()
        recorder = null
        executor?.shutdown()
        executor = null
        transcriber?.release()
        transcriber = null
        super.onDestroy()
    }

    // ── Mic state machine ────────────────────────────────────────────────

    private fun onMicTap() {
        if (loadingModel) return // ignore taps while the model spins up
        if (listening) {
            stopListening()
            return
        }
        if (!WhisperTranscriber.isModelInstalled(this)) {
            // TODO(i18n): keyboard copy is hardcoded neutral Spanish for now.
            setStatus("Descarga el modelo de voz en LifeOS primero")
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // A service cannot prompt; the LifeOS app requests the mic
            // permission (voice notes) and the grant is app-wide.
            setStatus("Permite el micrófono en LifeOS (Ajustes > Permisos)")
            return
        }
        startListening()
    }

    private fun startListening() {
        listening = true
        loadingModel = true
        setMicActive(true)
        setStatus("Cargando modelo de voz…")

        val exec = executor ?: Executors.newSingleThreadExecutor { r ->
            Thread(r, "axi-ime-whisper")
        }.also { executor = it }
        val stt = transcriber ?: WhisperTranscriber(this).also { transcriber = it }

        // Load Whisper off the UI thread, then open the mic. Recording only
        // starts after the model is ready so no audio is captured while a
        // failure is still possible.
        exec.execute {
            try {
                stt.ensureLoaded(Locale.getDefault().language)
            } catch (e: Exception) {
                mainHandler.post {
                    loadingModel = false
                    listening = false
                    setMicActive(false)
                    setStatus("No se pudo cargar el modelo de voz")
                }
                transcriber?.release()
                transcriber = null
                return@execute
            }
            mainHandler.post {
                loadingModel = false
                if (!listening) { // user bailed while loading
                    releaseWhenDrained()
                    return@post
                }
                setStatus("Escuchando…")
                recorder = DictationRecorder(
                    onChunk = ::enqueueChunk,
                    onFinished = { mainHandler.post { onRecorderFinished() } },
                    onError = { mainHandler.post { onRecorderError() } },
                ).also { it.start() }
            }
        }
    }

    private fun stopListening() {
        listening = false
        recorder?.stop() // final chunk + onFinished still arrive async
        recorder = null
        setMicActive(false)
        if (loadingModel) {
            setStatus("Toca el micrófono para dictar")
        } else {
            refreshBusyUi()
        }
    }

    /** Called on the recorder thread with one pause/25 s-sliced audio chunk. */
    private fun enqueueChunk(samples: FloatArray) {
        val stt = transcriber ?: return
        pendingChunks.incrementAndGet()
        mainHandler.post { refreshBusyUi() }
        executor?.execute {
            val text = try {
                stt.transcribe(samples)
            } catch (e: Exception) {
                "" // one bad chunk must not kill the dictation
            }
            mainHandler.post {
                pendingChunks.decrementAndGet()
                if (text.isNotEmpty()) {
                    // Progressive commit: each chunk lands as soon as it is
                    // ready, with a trailing space separating it from the next.
                    currentInputConnection?.commitText("$text ", 1)
                }
                refreshBusyUi()
                if (!listening && pendingChunks.get() == 0) releaseWhenDrained()
            }
        }
    }

    private fun onRecorderFinished() {
        if (!listening && pendingChunks.get() == 0) releaseWhenDrained()
    }

    private fun onRecorderError() {
        listening = false
        recorder = null
        setMicActive(false)
        setStatus("No se pudo usar el micrófono")
    }

    /**
     * Free the native recognizer once the dictation session fully drained —
     * same RAM discipline as the app: Whisper is never kept hot between
     * sessions (load is ~1 s; the on-device LLM owns the RAM budget).
     */
    private fun releaseWhenDrained() {
        val stt = transcriber ?: return
        transcriber = null
        executor?.execute { stt.release() }
        refreshIdleUi()
    }

    // ── UI helpers ───────────────────────────────────────────────────────

    private fun refreshIdleUi() {
        if (listening || pendingChunks.get() > 0) return
        setMicActive(false)
        setStatus(
            if (WhisperTranscriber.isModelInstalled(this)) {
                "Toca el micrófono para dictar"
            } else {
                "Descarga el modelo de voz en LifeOS primero"
            },
        )
    }

    private fun refreshBusyUi() {
        when {
            listening -> setStatus("Escuchando…")
            pendingChunks.get() > 0 -> setStatus("Transcribiendo…")
            else -> refreshIdleUi()
        }
    }

    private fun setStatus(text: String) {
        statusView?.text = text
    }

    /** Teal idle / brand-pink recording, matching the LifeOS two-color system. */
    private fun setMicActive(active: Boolean) {
        micButton?.backgroundTintList = ColorStateList.valueOf(
            Color.parseColor(if (active) "#FF4D8D" else "#00D4AA"),
        )
    }

    private fun openLifeOs() {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return
        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }
}
