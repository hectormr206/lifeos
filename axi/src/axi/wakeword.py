"""Always-listening wake-word listener for the gaming co-pilot (Slice 1, Approach B).

Architecture:
    Continuous sounddevice InputStream → WebRTCVAD gate → on speech segment end,
    call the injected transcribe_fn → run match_wake() → if wake detected,
    call the injected on_wake(command) callback.

Design principles:
- Dependency-injected for testability: stream_factory, transcribe_fn, on_wake.
- No real hardware in tests: FakeStreamingCapture drives callbacks.
- Thread-safe: buffer protected by a Lock; callbacks from the sounddevice thread
  never touch mutable state without acquiring the lock.
- Never modifies the existing Recorder class.

Public API:
    match_wake(transcript) -> (is_wake: bool, command: str)
    WakeWordListener(...)
        .start()  — opens stream, begins listening
        .stop()   — closes stream gracefully
        ._flush_segment()  — force-process buffered audio (used in tests)
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

import numpy as np

log = logging.getLogger("axi.wakeword")

SAMPLE_RATE = 16_000

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
    """Return the compiled _TRIGGER regex, importing from intents on first call."""
    global _TRIGGER_RE
    if _TRIGGER_RE is None:
        from axi.intents import _TRIGGER  # noqa: PLC0415
        # Match trigger at the START of the (normalized) transcript.
        # The trigger must be followed by a word boundary (not just another letter)
        # to avoid "ax" consuming "axi" and treating "i" as the command.
        # Then: optional punctuation/spaces, then a non-empty command remainder.
        # Separator chars we skip between trigger and command (comma, colon, etc.).
        # The command itself must contain at least one word character (letter/digit)
        # so bare punctuation after the trigger doesn't count as a command.
        _TRIGGER_RE = re.compile(
            rf"^\s*{_TRIGGER}\b\s*[,:.!\-\s]*(?P<command>[^\s,:.!\-].*?)$",
            re.IGNORECASE | re.DOTALL,
        )
    return _TRIGGER_RE


def match_wake(transcript: Any) -> tuple[bool, str]:
    """Determine whether a transcript contains a wake word followed by a command.

    Pure function — no I/O, no side effects. Unit-testable without hardware.

    Rules:
    1. transcript must be a non-empty string.
    2. One of the _TRIGGER variants must appear at the START of the transcript.
    3. After stripping the trigger and any punctuation/spaces, a non-empty
       command remainder must exist. A bare trigger with no command is NOT a wake.

    Returns:
        (True, command_str)  — wake detected; command_str is stripped and ready to route.
        (False, "")          — not a wake; caller should ignore this segment.
    """
    if not transcript or not isinstance(transcript, str):
        return False, ""

    text = transcript.strip()
    if not text:
        return False, ""

    pattern = _get_trigger_re()
    m = pattern.match(text)
    if m is None:
        return False, ""

    command = m.group("command").strip()
    if not command:
        # Trigger present but no command after it — false-trigger guard.
        return False, ""

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
        is_wake, command = match_wake(text)

        if not is_wake:
            log.info("wakeword: no wake match for transcript %r", text)
            return

        log.info("wakeword: WAKE DETECTED — command=%r", command)
        try:
            self._on_wake(command)
        except Exception as e:  # noqa: BLE001
            log.warning("on_wake callback raised: %s", e)
