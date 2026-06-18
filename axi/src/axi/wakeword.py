"""Always-listening wake-word listener for the gaming co-pilot.

Two detection engines are available and selected via config (wakeword_engine):

  openwakeword (default):
    Approach A — State machine.  Continuous sounddevice InputStream fires
    20 ms (320-sample) frames.  Every 4 frames (80 ms / 1280 samples) are
    fed to openwakeword Model.predict().  When the score for the active
    model exceeds wakeword_threshold the listener transitions to
    COMMAND_CAPTURE.  The existing VAD+Whisper path then captures and
    transcribes the command utterance, calling on_wake(command).  Instant
    acoustic detection; Whisper only runs for the actual command, not the
    wake keyword itself.

  vad_whisper (legacy fallback):
    Approach B — Original design.  VAD gate accumulates every voiced
    segment and Whisper transcribes each one to look for the wake word.
    Higher latency but works without openwakeword installed.

Design principles:
- Dependency-injected for testability: stream_factory, transcribe_fn, on_wake.
- No real hardware in tests: FakeStreamingCapture drives callbacks.
- Thread-safe: buffer protected by a Lock; callbacks from the sounddevice thread
  never touch mutable state without acquiring the lock.
- Never modifies the existing Recorder class.
- oww_predict_fn is injectable so tests never load real ONNX models.

Public API:
    match_wake(transcript) -> (is_wake: bool, command: str)
    WakeWordListener(...)           # legacy vad_whisper engine
        .start()  — opens stream, begins listening
        .stop()   — closes stream gracefully
        ._flush_segment()  — force-process buffered audio (used in tests)
    OWWWakeWordListener(...)        # openwakeword engine (default)
        .start() / .stop()
        ._oww_ingest_frame(frame)  — inject a 320-sample frame (tests)
        ._oww_state                — 'idle' | 'command_capture'
"""
from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections import deque
from collections.abc import Callable
from typing import Any

import unicodedata

import numpy as np

log = logging.getLogger("axi.wakeword")

SAMPLE_RATE = 16_000

# Minimum repetitions of a short phrase before treating it as a hallucination loop.
_REPETITION_HALLUCINATION_THRESHOLD = 3

# VAD frame size must be one of 10, 20, or 30 ms per the webrtcvad spec.
_VAD_FRAME_MS = 20
_VAD_FRAME_SAMPLES = int(SAMPLE_RATE * _VAD_FRAME_MS / 1000)  # 320 samples

# After this many consecutive silent frames, treat the speech segment as done.
# Default: 1.0 s ÷ 0.02 s per frame = 50 frames.
_DEFAULT_SILENCE_DURATION_S = 1.0

# Maximum speech segment length before we force-flush to avoid unbounded memory.
_DEFAULT_MAX_SEGMENT_S = 8.0

# Minimum voiced frames required before we bother transcribing.
_MIN_VOICED_FRAMES = 5  # 100 ms of actual speech

# Reuse the _TRIGGER regex from intents.py — single source of truth for Axi variants.
# Imported lazily to avoid circular dependency at module load time.
_TRIGGER_RE: re.Pattern[str] | None = None

# ---------------------------------------------------------------------------
# Hallucination detection
# ---------------------------------------------------------------------------

def _normalize_for_hallucination(text: str) -> str:
    """Lowercase, strip accent marks and punctuation for blocklist comparison."""
    # Decompose Unicode (e.g. é → e + combining accent), then drop non-ASCII combining chars.
    nfd = unicodedata.normalize("NFD", text.lower())
    stripped = "".join(c for c in nfd if unicodedata.category(c) != "Mn")
    # Remove punctuation characters.
    cleaned = re.sub(r"[^\w\s]", "", stripped, flags=re.UNICODE)
    return cleaned.strip()


# Known Whisper hallucination phrases (normalized, no accents/punctuation).
# These appear when Whisper receives near-silence or very short audio and generates
# YouTube-style filler text instead of the actual utterance.
_HALLUCINATION_BLOCKLIST: frozenset[str] = frozenset({
    "suscribete al canal",
    "gracias por ver el video",
    "subtitulos realizados por la comunidad",
    "subtitulos por la comunidad de amaraorg",
    "no olvides suscribirte",
    "dale like y suscribete",
    "gracias por ver",
    "no te olvides de suscribirte",
    "subtitulado por la comunidad de amaraorg",
    "amara dot org",
})


def is_hallucination(transcript: str) -> bool:
    """Return True if the transcript is a known Whisper hallucination.

    Checks two conditions:
    1. The normalized transcript matches (or starts with) a known blocklist phrase.
    2. The transcript is a repetition loop: the same short phrase repeated
       _REPETITION_HALLUCINATION_THRESHOLD or more times.

    Pure function — no I/O, no side effects. Unit-testable without hardware.
    """
    if not transcript or not isinstance(transcript, str):
        return False

    normalized = _normalize_for_hallucination(transcript)
    if not normalized:
        return False

    # Blocklist check — exact or prefix match.
    for phrase in _HALLUCINATION_BLOCKLIST:
        if normalized == phrase or normalized.startswith(phrase):
            return True

    # Repetition loop detection: split into words, find if any short sub-phrase
    # repeats _REPETITION_HALLUCINATION_THRESHOLD or more times consecutively.
    words = normalized.split()
    n = len(words)
    if n < 2:
        return False

    # Try sub-phrase lengths from 1 to half the total words.
    for phrase_len in range(1, max(2, n // 2) + 1):
        phrase_words = words[:phrase_len]
        count = 1
        i = phrase_len
        while i + phrase_len <= n:
            if words[i : i + phrase_len] == phrase_words:
                count += 1
                i += phrase_len
            else:
                break
        if count >= _REPETITION_HALLUCINATION_THRESHOLD:
            return True

    return False


# ---------------------------------------------------------------------------
# Rate-limit helpers for callback logging
# ---------------------------------------------------------------------------

# Minimum seconds between repeated log messages from the callback thread.
_CALLBACK_LOG_INTERVAL_S = 2.0


class _RateLimiter:
    """Lightweight token-bucket style rate limiter for use inside audio callbacks.

    Thread-safe via a lock because the callback thread and the worker thread
    may both call it (e.g. for VAD-error logging).
    """

    def __init__(self, interval_s: float) -> None:
        self._interval = interval_s
        self._last: float = 0.0
        self._lock = threading.Lock()

    def allow(self) -> bool:
        """Return True and update timestamp if the interval has elapsed."""
        now = time.monotonic()
        with self._lock:
            if now - self._last >= self._interval:
                self._last = now
                return True
        return False


def _get_trigger_re() -> re.Pattern[str]:
    """Return the compiled _TRIGGER regex, importing from intents on first call.

    Loosened for high recall (Fix 3):
    - Trigger may appear ANYWHERE in the transcript (not only at the start).
    - Word boundary enforced so "axi" inside "maximal" does not match.
    - The command (text after the trigger + separators) may be empty — bare
      "Axi" is a valid wake with an empty command.
    """
    global _TRIGGER_RE
    if _TRIGGER_RE is None:
        from axi.intents import _TRIGGER  # noqa: PLC0415
        # Pattern: optional leading text, then trigger with word boundaries,
        # then optional separators, then an optional command remainder.
        # (?:^|(?<=\s)|(?<=\W)) ensures the trigger is a standalone word:
        # it must be preceded by start-of-string, whitespace, or a non-word char.
        _TRIGGER_RE = re.compile(
            rf"(?:^|(?<=\s)|(?<=\W)){_TRIGGER}\b\s*[,:.!\-\s]*(?P<command>.*?)$",
            re.IGNORECASE | re.DOTALL,
        )
    return _TRIGGER_RE


def match_wake(transcript: Any) -> tuple[bool, str]:
    """Determine whether a transcript contains a wake word (anywhere) for Axi.

    Pure function — no I/O, no side effects. Unit-testable without hardware.

    Rules (Fix 3 — high-recall mode):
    1. transcript must be a non-empty string.
    2. One of the _TRIGGER variants must appear ANYWHERE in the transcript,
       at a word boundary (so "axi" inside "maximal" does not match).
    3. The command is whatever follows the trigger after stripping separators.
       An empty command is ALLOWED — "Axi" alone returns (True, "").
    4. The daemon handles an empty command by speaking an acknowledgment
       instead of routing to the brain.

    Returns:
        (True, command_str)  — wake detected; command_str may be empty.
        (False, "")          — not a wake; caller should ignore this segment.
    """
    if not transcript or not isinstance(transcript, str):
        return False, ""

    text = transcript.strip()
    if not text:
        return False, ""

    pattern = _get_trigger_re()
    m = pattern.search(text)
    if m is None:
        return False, ""

    command = m.group("command").strip()
    # command may legitimately be empty (bare "Axi") — that is a valid wake.
    return True, command


# ---------------------------------------------------------------------------
# Device selection helper
# ---------------------------------------------------------------------------

def resolve_input_device() -> str | None:
    """Choose the best available PulseAudio microphone source for the wakeword listener.

    Reuses axi.mic.pick_best() — the same logic used by the push-to-talk Recorder —
    so both the PTT recorder and the always-listening wakeword listener use the
    SAME physical microphone.

    Additionally honours the AXI_WAKEWORD_INPUT_DEVICE environment variable as
    an explicit override (useful for debugging or unusual setups).  The env var
    should contain a PulseAudio source name (e.g. "alsa_input.usb-...").

    Returns the PulseAudio source name to pass to pactl, or None if detection
    fails or is not available.  The caller logs the result.
    """
    # Explicit override wins.
    env_device = os.environ.get("AXI_WAKEWORD_INPUT_DEVICE", "").strip()
    if env_device:
        log.info("wakeword input device override via AXI_WAKEWORD_INPUT_DEVICE: %r", env_device)
        return env_device

    try:
        from axi.mic import pick_best  # noqa: PLC0415
        best = pick_best()
        if best is not None:
            return best.name
    except Exception as e:  # noqa: BLE001
        log.warning("wakeword: mic.pick_best() failed: %s — will use system default", e)

    return None


def _apply_pulse_default_source(source_name: str) -> None:
    """Set the PulseAudio default source so that the subsequent InputStream gets the right mic.

    This mirrors what Recorder.start() does, ensuring both PTT and wake-word
    listener always use the same physical microphone.
    """
    import subprocess  # noqa: PLC0415
    try:
        subprocess.run(
            ["pactl", "set-default-source", source_name],
            check=True,
            timeout=2,
            capture_output=True,
        )
        log.info("wakeword: set PulseAudio default source to %r", source_name)
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        log.warning("wakeword: could not set default source %r: %s", source_name, e)


# ---------------------------------------------------------------------------
# Stream factory default — wraps sounddevice.InputStream
# ---------------------------------------------------------------------------

def _default_stream_factory(callback: Callable, *, sample_rate: int = SAMPLE_RATE, **kwargs) -> Any:
    """Create and return a started sounddevice InputStream.

    Before opening the stream, resolves the best input device using the same
    pick_best() logic as the push-to-talk Recorder, and forces it as the
    PulseAudio default source via pactl.  This ensures the wake-word listener
    captures from the same physical microphone as the rest of Axi.
    """
    import sounddevice as sd  # noqa: PLC0415

    # --- Device selection (OBSERVABILITY + FIX) ---
    source_name = resolve_input_device()
    if source_name:
        _apply_pulse_default_source(source_name)
    else:
        log.info("wakeword: no explicit device selected — sounddevice will use system default")

    # Log the device sounddevice will actually open (after we set PulseAudio default).
    try:
        default_dev = sd.query_devices(kind="input")
        dev_name = default_dev.get("name", "unknown") if isinstance(default_dev, dict) else str(default_dev)
        dev_index = sd.default.device[0] if hasattr(sd.default, "device") else "?"
        log.info(
            "wakeword: opening InputStream — device_index=%s name=%r samplerate=%d blocksize=%d",
            dev_index,
            dev_name,
            sample_rate,
            _VAD_FRAME_SAMPLES,
        )
    except Exception as e:  # noqa: BLE001
        log.warning("wakeword: could not query default input device: %s", e)

    stream = sd.InputStream(
        samplerate=sample_rate,
        channels=1,
        dtype="float32",
        blocksize=_VAD_FRAME_SAMPLES,
        callback=callback,
    )
    return stream


# ---------------------------------------------------------------------------
# VAD helper — wraps webrtcvad
# ---------------------------------------------------------------------------

def _make_vad(aggressiveness: int = 2) -> Any:
    import webrtcvad  # noqa: PLC0415
    vad = webrtcvad.Vad(aggressiveness)
    return vad


def _to_pcm16_bytes(frame: np.ndarray) -> bytes:
    """Convert float32 frame to int16 little-endian bytes for webrtcvad."""
    # Clip to [-1, 1] then scale.
    clipped = np.clip(frame.flatten(), -1.0, 1.0)
    pcm16 = (clipped * 32767).astype(np.int16)
    return pcm16.tobytes()


# ---------------------------------------------------------------------------
# WakeWordListener
# ---------------------------------------------------------------------------

class WakeWordListener:
    """Continuously listens on the microphone and fires on_wake when triggered.

    Parameters
    ----------
    transcribe_fn:
        Callable(audio: np.ndarray) -> (text, lang, prob).
        Should be the daemon's existing Whisper path (with _transcribe_lock).
    on_wake:
        Callable(command: str) -> None.
        Called on the listener's worker thread when a wake command is detected.
    stream_factory:
        Callable(callback, *, sample_rate, ...) -> stream object with start()/stop()/close().
        Defaults to sounddevice.InputStream. Override in tests with FakeStreamingCapture.
    vad_aggressiveness:
        0 (least aggressive, passes most audio) to 3 (most aggressive).
        Default 2 is a good balance for a headset mic in a quiet room.
    silence_duration_s:
        Seconds of consecutive silence that mark the end of a speech segment.
    max_segment_s:
        Hard cap on segment length to bound memory usage.
    sample_rate:
        Audio sample rate in Hz (must be 16000 for webrtcvad).
    """

    def __init__(
        self,
        *,
        transcribe_fn: Callable,
        on_wake: Callable,
        stream_factory: Callable | None = None,
        vad_aggressiveness: int = 2,
        silence_duration_s: float = _DEFAULT_SILENCE_DURATION_S,
        max_segment_s: float = _DEFAULT_MAX_SEGMENT_S,
        sample_rate: int = SAMPLE_RATE,
    ) -> None:
        self._transcribe_fn = transcribe_fn
        self._on_wake = on_wake
        self._stream_factory = stream_factory or _default_stream_factory
        self._vad_aggressiveness = vad_aggressiveness
        self._silence_duration_s = silence_duration_s
        self._max_segment_s = max_segment_s
        self._sample_rate = sample_rate

        # Mutable state — all protected by _lock.
        self._lock = threading.Lock()
        self._voiced_frames: list[np.ndarray] = []   # accumulated speech frames
        self._silent_frame_count: int = 0             # consecutive silent frames
        self._voiced_frame_count: int = 0             # total voiced frames in segment

        # Derived thresholds.
        self._silence_frames_threshold = int(
            silence_duration_s / (_VAD_FRAME_MS / 1000)
        )
        self._max_frames = int(max_segment_s * sample_rate / _VAD_FRAME_SAMPLES)

        # Live objects.
        self._vad: Any = None
        self._stream: Any = None
        self._running = False

        # Worker thread for segment processing (avoids blocking the audio callback).
        # deque gives O(1) popleft() vs O(n) list.pop(0).
        self._segment_queue: deque[np.ndarray] = deque()
        self._queue_lock = threading.Lock()
        self._queue_event = threading.Event()
        self._worker: threading.Thread | None = None

        # Rate limiters for callback-thread logging (one per concern).
        self._rl_activity = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)   # callback heartbeat
        self._rl_vad_error = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)  # VAD exception
        self._rl_overflow = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)   # portaudio overflow

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Open the microphone stream and start listening."""
        if self._running:
            return
        self._vad = _make_vad(self._vad_aggressiveness)
        self._running = True

        # Start the worker thread first so it is ready before audio arrives.
        self._worker = threading.Thread(
            target=self._worker_loop, name="axi-wakeword-worker", daemon=True
        )
        self._worker.start()

        self._stream = self._stream_factory(
            self._audio_callback, sample_rate=self._sample_rate
        )
        self._stream.start()
        log.info("wake-word listener started (vad=%d, silence=%.1fs)",
                 self._vad_aggressiveness, self._silence_duration_s)

    def stop(self) -> None:
        """Stop listening and clean up resources."""
        self._running = False
        # Signal the worker to exit.
        self._queue_event.set()
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception as e:  # noqa: BLE001
                log.warning("error closing stream: %s", e)
            self._stream = None
        if self._worker is not None:
            self._worker.join(timeout=5.0)
            self._worker = None
        log.info("wake-word listener stopped")

    # ------------------------------------------------------------------
    # Audio callback — runs on the sounddevice callback thread
    # ------------------------------------------------------------------

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info: Any, status: Any) -> None:
        """Called by sounddevice for each audio block.

        MUST be fast — no blocking I/O, no Whisper calls.
        Classifies each frame via VAD and accumulates voiced frames.
        When silence threshold reached or buffer too large, enqueues segment.
        """
        # PortAudio overflow/underrun — promote to WARNING so dropped audio is visible.
        if status:
            if self._rl_overflow.allow():
                log.warning("wakeword portaudio status: %s", status)

        frame = indata.copy().flatten()

        # Pad/trim to exactly VAD_FRAME_SAMPLES to satisfy webrtcvad.
        if len(frame) < _VAD_FRAME_SAMPLES:
            frame = np.pad(frame, (0, _VAD_FRAME_SAMPLES - len(frame)))
        elif len(frame) > _VAD_FRAME_SAMPLES:
            frame = frame[:_VAD_FRAME_SAMPLES]

        # Rate-limited heartbeat: proves the callback is firing AND shows audio levels.
        if self._rl_activity.allow():
            rms = float(np.sqrt(np.mean(frame ** 2)))
            peak = float(np.abs(frame).max())
            # Run a quick VAD check for the heartbeat log (before the guarded block).
            # We run it here outside the main try/except so the heartbeat itself
            # does not mask a VAD error that the next block will catch.
            log.info(
                "wakeword callback active — rms=%.5f peak=%.5f voiced_frames=%d silent_frames=%d",
                rms,
                peak,
                self._voiced_frame_count,
                self._silent_frame_count,
            )

        # Run VAD — convert to int16 bytes as required by webrtcvad.
        try:
            is_speech = self._vad.is_speech(_to_pcm16_bytes(frame), self._sample_rate)
        except Exception as exc:  # noqa: BLE001
            # Log the exception (rate-limited) so we can see what webrtcvad is
            # rejecting instead of swallowing the error silently.
            if self._rl_vad_error.allow():
                log.error(
                    "wakeword VAD exception (frame_len=%d sample_rate=%d): %s",
                    len(frame),
                    self._sample_rate,
                    exc,
                    exc_info=True,
                )
            return

        # Heartbeat also logs is_speech so we can confirm VAD is classifying correctly.
        if self._rl_activity.allow():
            log.info("wakeword VAD result: is_speech=%s", is_speech)

        with self._lock:
            if is_speech:
                self._voiced_frames.append(frame)
                self._voiced_frame_count += 1
                self._silent_frame_count = 0
            else:
                self._silent_frame_count += 1
                # If we have any voiced frames, keep accumulating through silence
                # so we capture the complete word (including trailing sounds).
                if self._voiced_frame_count > 0:
                    self._voiced_frames.append(frame)

            # Conditions to flush the accumulated segment:
            # 1. Enough silence after voice activity.
            # 2. Hard cap on segment length.
            should_flush = False
            if (
                self._voiced_frame_count >= _MIN_VOICED_FRAMES
                and self._silent_frame_count >= self._silence_frames_threshold
            ):
                should_flush = True
            elif len(self._voiced_frames) >= self._max_frames:
                should_flush = True

            if should_flush:
                self._enqueue_segment()

    def _enqueue_segment(self) -> None:
        """Extract buffered audio and enqueue for worker processing.

        Called with self._lock held.
        """
        if not self._voiced_frames:
            return
        segment = np.concatenate(self._voiced_frames).flatten()
        duration_s = len(self._voiced_frames) * _VAD_FRAME_MS / 1000.0
        frame_count = len(self._voiced_frames)
        self._voiced_frames = []
        self._voiced_frame_count = 0
        self._silent_frame_count = 0

        log.info(
            "wakeword: flushing speech segment — frames=%d duration=%.2fs",
            frame_count,
            duration_s,
        )

        with self._queue_lock:
            self._segment_queue.append(segment)
        self._queue_event.set()

    def _flush_segment(self) -> None:
        """Force-flush any buffered audio (used in tests to avoid waiting for silence).

        If the worker thread is running, enqueues the segment for it to process.
        If there is no worker (synchronous test mode), processes inline.
        """
        with self._lock:
            self._enqueue_segment()
        # Wake the worker if running.
        self._queue_event.set()

    # ------------------------------------------------------------------
    # Worker thread — handles Whisper calls off the audio callback thread
    # ------------------------------------------------------------------

    def _worker_loop(self) -> None:
        """Drain the segment queue and process each segment.

        Single-worker-thread invariant: this loop is the ONLY consumer of
        _segment_queue.  The on_wake callback's guard (`state in ("idle",)`)
        is safe to use without additional locking BECAUSE segments are
        processed serially here — there is never more than one concurrent
        _process_segment call.  Do not add a second worker thread without
        revisiting the daemon._on_wake state check.

        Drain guarantee: the outer loop re-checks queue emptiness under
        _queue_lock before deciding to block on _queue_event.  This closes
        the TOCTOU window where a segment enqueued between the inner drain
        finishing and the outer condition being re-evaluated could be missed
        if _running has already been set to False by stop().
        """
        while True:
            self._queue_event.wait(timeout=0.5)
            self._queue_event.clear()
            # Drain all currently queued segments.
            while True:
                with self._queue_lock:
                    if not self._segment_queue:
                        break
                    segment = self._segment_queue.popleft()
                self._process_segment(segment)
            # Re-check under the lock: if _running is False AND the queue is
            # still empty, it is safe to exit — no segment can be dropped.
            with self._queue_lock:
                if not self._running and not self._segment_queue:
                    break

    def _process_segment(self, audio: np.ndarray) -> None:
        """Transcribe a voiced segment and check for wake word.

        Called on the worker thread (or synchronously in tests).
        """
        if audio.size == 0:
            return
        try:
            result = self._transcribe_fn(audio)
            # transcribe_fn returns (text, lang, prob) tuple
            if isinstance(result, tuple):
                text = result[0] or ""
            else:
                text = str(result) if result else ""
        except Exception as e:  # noqa: BLE001
            log.warning("wakeword transcribe failed: %s", e)
            return

        if not text:
            log.debug("wakeword: transcribe returned empty text — skipping")
            return

        log.info("wakeword: transcript=%r", text)

        # Discard known Whisper hallucination phrases before attempting a wake match.
        # These appear when the model receives near-silence and generates YouTube filler.
        if is_hallucination(text):
            log.info("wakeword: transcript is a known hallucination — discarding: %r", text)
            return

        is_wake, command = match_wake(text)

        if not is_wake:
            log.info("wakeword: no wake match for transcript %r", text)
            return

        log.info("wakeword: WAKE DETECTED — command=%r", command)
        try:
            self._on_wake(command)
        except Exception as e:  # noqa: BLE001
            log.warning("on_wake callback raised: %s", e)


# ---------------------------------------------------------------------------
# OWWWakeWordListener — openWakeWord state-machine engine (Approach A)
# ---------------------------------------------------------------------------

# openWakeWord processes 80 ms chunks of int16 audio at 16 kHz.
# 80 ms × 16000 Hz = 1280 samples per chunk.
# The sounddevice callback delivers 320-sample (20 ms) frames, so we
# accumulate 4 frames before calling predict().
_OWW_CHUNK_SAMPLES = 1280       # samples per openwakeword predict() call
_OWW_FRAME_SAMPLES = _VAD_FRAME_SAMPLES  # 320 — same as VAD frame size


def _resolve_oww_model_paths(name_or_path: str) -> list[str]:
    """Resolve a pretrained model name or .onnx path to a list of absolute paths.

    Accepts:
      - A pretrained model name fragment (e.g. 'alexa', 'hey_jarvis') —
        matched against the bundled pretrained models in the openwakeword package.
      - An absolute path to a custom .onnx file (e.g. the trained Axi model).

    Returns a list of resolved paths to pass to Model(wakeword_model_paths=...).
    """
    import os as _os  # noqa: PLC0415
    import openwakeword as _oww  # noqa: PLC0415

    # Custom .onnx path: use as-is.
    if name_or_path.endswith(".onnx") or _os.path.isabs(name_or_path):
        return [name_or_path]

    # Pretrained name: match against bundled models (e.g. 'alexa' → 'alexa_v0.1.onnx').
    try:
        pretrained = _oww.get_pretrained_model_paths()
        matches = [p for p in pretrained if name_or_path in _os.path.basename(p)]
        if matches:
            return matches
    except Exception:  # noqa: BLE001
        pass

    # Fallback: pass the name directly and let openWakeWord handle it.
    return [name_or_path]


def _load_oww_model(model_path: str) -> Any:
    """Load an openWakeWord Model for the given pretrained name or .onnx path.

    Accepts either:
      - A pretrained model name (e.g. 'alexa', 'hey_jarvis') — matched against
        bundled models in the openwakeword package directory.
      - An absolute path to a custom .onnx file (e.g. the trained Axi model).

    Returns an object with a .predict(chunk: np.ndarray) -> dict[str, float] method.
    """
    from openwakeword.model import Model  # noqa: PLC0415
    resolved_paths = _resolve_oww_model_paths(model_path)
    log.info("oww: loading model from paths=%s", resolved_paths)
    return Model(wakeword_model_paths=resolved_paths)


class OWWWakeWordListener:
    """Wake-word listener using openWakeWord for instant acoustic detection.

    State machine:
      IDLE:
        - Accumulate 320-sample (20 ms) frames into 1280-sample (80 ms) chunks.
        - Call oww_model.predict(chunk) after every 4 frames.
        - If the active model's score >= oww_threshold → COMMAND_CAPTURE.

      COMMAND_CAPTURE:
        - Reuse the existing VAD accumulation to capture the command audio
          after the wake event (until silence or max segment length).
        - Enqueue segment → transcribe_fn → is_hallucination filter →
          match_wake() → on_wake(command).
        - Return to IDLE.

    Parameters
    ----------
    transcribe_fn:
        Callable(audio: np.ndarray) -> (text, lang, prob).
    on_wake:
        Callable(command: str) -> None.  Fired on worker thread.
    stream_factory:
        Callable(callback, *, sample_rate, ...) -> stream with start/stop/close.
    oww_predict_fn:
        Injectable predict function for tests. Signature:
          (chunk: np.ndarray) -> dict[str, float]
        If None, a real openWakeWord Model is loaded from oww_model_path.
    oww_model_path:
        Pretrained model name or path to .onnx file (used when oww_predict_fn
        is None).  Default 'alexa'.
    oww_threshold:
        Confidence score [0.0–1.0] above which wake is declared. Default 0.5.
    silence_duration_s:
        Seconds of consecutive silence marking the end of a command segment.
    max_segment_s:
        Hard cap on command segment length.
    sample_rate:
        Audio sample rate in Hz (must be 16000).
    vad_aggressiveness:
        VAD aggressiveness for COMMAND_CAPTURE accumulation (0–3).
    """

    def __init__(
        self,
        *,
        transcribe_fn: Callable,
        on_wake: Callable,
        stream_factory: Callable | None = None,
        oww_predict_fn: Callable | None = None,
        oww_model_path: str = "alexa",
        oww_threshold: float = 0.5,
        silence_duration_s: float = _DEFAULT_SILENCE_DURATION_S,
        max_segment_s: float = _DEFAULT_MAX_SEGMENT_S,
        sample_rate: int = SAMPLE_RATE,
        vad_aggressiveness: int = 2,
    ) -> None:
        self._transcribe_fn = transcribe_fn
        self._on_wake = on_wake
        self._stream_factory = stream_factory or _default_stream_factory
        self._oww_threshold = oww_threshold
        self._oww_model_path = oww_model_path
        self._silence_duration_s = silence_duration_s
        self._max_segment_s = max_segment_s
        self._sample_rate = sample_rate
        self._vad_aggressiveness = vad_aggressiveness

        # Lazy-loaded OWW model (real ONNX).  If oww_predict_fn is supplied,
        # _oww_model is never loaded — test isolation without real ONNX.
        self._oww_model: Any = None
        self._oww_predict_fn: Callable | None = oww_predict_fn

        # State machine.
        self._oww_state: str = "idle"          # 'idle' | 'command_capture'
        self._oww_frame_buf: list[np.ndarray] = []  # accumulate 320-sample frames

        # COMMAND_CAPTURE VAD accumulation (mirrors WakeWordListener).
        self._lock = threading.Lock()
        self._voiced_frames: list[np.ndarray] = []
        self._silent_frame_count: int = 0
        self._voiced_frame_count: int = 0
        self._silence_frames_threshold = int(
            silence_duration_s / (_VAD_FRAME_MS / 1000)
        )
        self._max_frames = int(max_segment_s * sample_rate / _VAD_FRAME_SAMPLES)

        # Worker queue (same pattern as WakeWordListener).
        self._segment_queue: deque[np.ndarray] = deque()
        self._queue_lock = threading.Lock()
        self._queue_event = threading.Event()
        self._worker: threading.Thread | None = None
        self._vad: Any = None
        self._stream: Any = None
        self._running = False

        # Rate limiters.
        self._rl_activity = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)
        self._rl_vad_error = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)
        self._rl_overflow = _RateLimiter(_CALLBACK_LOG_INTERVAL_S)

    # ------------------------------------------------------------------
    # Internal OWW predict dispatch
    # ------------------------------------------------------------------

    def _predict(self, chunk: np.ndarray) -> dict:
        """Call predict on the OWW model or injected predict function."""
        if self._oww_predict_fn is not None:
            return self._oww_predict_fn(chunk)
        if self._oww_model is None:
            self._oww_model = _load_oww_model(self._oww_model_path)
        # openWakeWord expects int16 audio.
        chunk_int16 = (np.clip(chunk, -1.0, 1.0) * 32767).astype(np.int16)
        return self._oww_model.predict(chunk_int16)

    def _max_score(self, scores: dict) -> float:
        """Return the highest score across all active model outputs."""
        if not scores:
            return 0.0
        return max(scores.values())

    # ------------------------------------------------------------------
    # Frame ingestion — called directly in tests; by audio callback in production
    # ------------------------------------------------------------------

    def _oww_ingest_frame(self, frame: np.ndarray) -> None:
        """Process a single 320-sample frame through the state machine.

        IDLE: accumulate frames into 1280-sample chunks and call predict.
        COMMAND_CAPTURE: run VAD accumulation to build the command segment.

        Thread-safe: called from the audio callback (sounddevice thread) and
        from tests (main thread).  The lock guards COMMAND_CAPTURE mutable state.
        """
        # Ensure the frame is exactly 320 samples (pad/trim like WakeWordListener).
        if len(frame) < _OWW_FRAME_SAMPLES:
            frame = np.pad(frame, (0, _OWW_FRAME_SAMPLES - len(frame)))
        elif len(frame) > _OWW_FRAME_SAMPLES:
            frame = frame[:_OWW_FRAME_SAMPLES]

        if self._oww_state == "idle":
            self._oww_frame_buf.append(frame.copy())
            if len(self._oww_frame_buf) >= _OWW_CHUNK_SAMPLES // _OWW_FRAME_SAMPLES:
                chunk = np.concatenate(self._oww_frame_buf).flatten()
                self._oww_frame_buf = []
                scores = self._predict(chunk)
                score = self._max_score(scores)
                log.debug("oww predict scores=%s max=%.4f threshold=%.2f", scores, score, self._oww_threshold)
                if score >= self._oww_threshold:
                    log.info(
                        "oww: WAKE DETECTED (score=%.4f >= threshold=%.2f) — entering COMMAND_CAPTURE",
                        score, self._oww_threshold,
                    )
                    self._oww_state = "command_capture"
                    # Reset VAD accumulation buffers for the command.
                    with self._lock:
                        self._voiced_frames = []
                        self._voiced_frame_count = 0
                        self._silent_frame_count = 0

        elif self._oww_state == "command_capture":
            # VAD-gate the command audio (same logic as WakeWordListener._audio_callback).
            if self._vad is None:
                return  # VAD not yet initialized (before start())
            try:
                is_speech = self._vad.is_speech(_to_pcm16_bytes(frame), self._sample_rate)
            except Exception as exc:  # noqa: BLE001
                if self._rl_vad_error.allow():
                    log.error("oww command_capture VAD error: %s", exc)
                return

            with self._lock:
                if is_speech:
                    self._voiced_frames.append(frame)
                    self._voiced_frame_count += 1
                    self._silent_frame_count = 0
                else:
                    self._silent_frame_count += 1
                    if self._voiced_frame_count > 0:
                        self._voiced_frames.append(frame)

                should_flush = False
                if (
                    self._voiced_frame_count >= _MIN_VOICED_FRAMES
                    and self._silent_frame_count >= self._silence_frames_threshold
                ):
                    should_flush = True
                elif len(self._voiced_frames) >= self._max_frames:
                    should_flush = True

                if should_flush:
                    self._enqueue_command_segment()
                    self._oww_state = "idle"

    def _enqueue_command_segment(self) -> None:
        """Extract buffered command audio and enqueue for transcription.

        Called with self._lock held.
        """
        if not self._voiced_frames:
            # No voiced audio captured — return to IDLE without calling on_wake.
            return
        segment = np.concatenate(self._voiced_frames).flatten()
        duration_s = len(self._voiced_frames) * _VAD_FRAME_MS / 1000.0
        log.info(
            "oww: enqueuing command segment — frames=%d duration=%.2fs",
            len(self._voiced_frames), duration_s,
        )
        self._voiced_frames = []
        self._voiced_frame_count = 0
        self._silent_frame_count = 0
        with self._queue_lock:
            self._segment_queue.append(segment)
        self._queue_event.set()

    # ------------------------------------------------------------------
    # Audio callback — runs on sounddevice callback thread
    # ------------------------------------------------------------------

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info: Any, status: Any) -> None:
        """Sounddevice callback: route each 320-sample frame to _oww_ingest_frame."""
        if status:
            if self._rl_overflow.allow():
                log.warning("oww portaudio status: %s", status)

        frame = indata.copy().flatten()
        if self._rl_activity.allow():
            rms = float(np.sqrt(np.mean(frame ** 2)))
            log.info(
                "oww callback active — state=%s rms=%.5f",
                self._oww_state, rms,
            )
        self._oww_ingest_frame(frame)

    # ------------------------------------------------------------------
    # Worker thread — transcribes command segments and fires on_wake
    # ------------------------------------------------------------------

    def _worker_loop(self) -> None:
        """Drain segment queue and process each command segment."""
        while True:
            self._queue_event.wait(timeout=0.5)
            self._queue_event.clear()
            while True:
                with self._queue_lock:
                    if not self._segment_queue:
                        break
                    segment = self._segment_queue.popleft()
                self._process_command_segment(segment)
            with self._queue_lock:
                if not self._running and not self._segment_queue:
                    break

    def _process_command_segment(self, audio: np.ndarray) -> None:
        """Transcribe a command segment and fire on_wake if wake is detected."""
        if audio.size == 0:
            return
        try:
            result = self._transcribe_fn(audio)
            text = result[0] if isinstance(result, tuple) else str(result or "")
        except Exception as e:  # noqa: BLE001
            log.warning("oww command transcribe failed: %s", e)
            return

        if not text:
            log.debug("oww: transcribe returned empty — returning to idle")
            return

        log.info("oww: command transcript=%r", text)

        if is_hallucination(text):
            log.info("oww: hallucination detected — discarding: %r", text)
            return

        is_wake, command = match_wake(text)
        if not is_wake:
            log.info("oww: no wake match in command transcript %r — returning to idle", text)
            return

        log.info("oww: COMMAND CONFIRMED — command=%r", command)
        try:
            self._on_wake(command)
        except Exception as e:  # noqa: BLE001
            log.warning("oww on_wake callback raised: %s", e)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Open the microphone stream and start listening."""
        if self._running:
            return
        self._vad = _make_vad(self._vad_aggressiveness)
        self._oww_state = "idle"
        self._oww_frame_buf = []
        self._running = True

        self._worker = threading.Thread(
            target=self._worker_loop, name="axi-oww-worker", daemon=True
        )
        self._worker.start()

        self._stream = self._stream_factory(
            self._audio_callback, sample_rate=self._sample_rate
        )
        self._stream.start()
        log.info(
            "oww wake-word listener started (model=%r threshold=%.2f)",
            self._oww_model_path, self._oww_threshold,
        )

    def stop(self) -> None:
        """Stop listening and clean up resources."""
        self._running = False
        self._queue_event.set()
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception as e:  # noqa: BLE001
                log.warning("oww: error closing stream: %s", e)
            self._stream = None
        if self._worker is not None:
            self._worker.join(timeout=5.0)
            self._worker = None
        log.info("oww wake-word listener stopped")
