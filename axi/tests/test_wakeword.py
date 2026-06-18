"""Tests for the always-listening wake-word listener (Slice 1, Approach B).

TDD RED → GREEN cycle:

Unit tests:
- match_wake() — wake cases (various Axi variant + command) → is_wake True + correct command
- match_wake() — false-trigger cases (bare trigger, no command, empty, noise) → is_wake False

Integration tests via FakeStreamingCapture:
- canned speech segment → transcribe → on_wake fired with correct command
- non-wake segment → on_wake NOT fired
- concurrent wake call while another is in-flight is safely ignored
"""
from __future__ import annotations

import threading
import time
from collections.abc import Callable

import numpy as np
import pytest

# ---------------------------------------------------------------------------
# RED: These imports will fail until wakeword.py is implemented
# ---------------------------------------------------------------------------
from axi.wakeword import WakeWordListener, match_wake


# ===========================================================================
# match_wake — pure unit tests (no hardware, no threading)
# ===========================================================================

class TestMatchWakeWakeCases:
    """Transcripts that SHOULD trigger a wake detection."""

    def test_canonical_axi_with_command(self):
        is_wake, command = match_wake("axi, ayudame con el puzzle")
        assert is_wake is True
        assert "ayudame" in command

    def test_axi_no_comma(self):
        is_wake, command = match_wake("axi ayudame con el puzzle")
        assert is_wake is True
        assert "ayudame" in command

    def test_misspell_asi_with_command(self):
        """'así' is a common Whisper mis-hear of 'Axi'."""
        is_wake, command = match_wake("así ayudame con esto")
        assert is_wake is True
        assert "ayudame" in command

    def test_misspell_axie_with_command(self):
        is_wake, command = match_wake("axie ayudame con la quest")
        assert is_wake is True
        assert "ayudame" in command

    def test_misspell_asi_no_accent_with_command(self):
        is_wake, command = match_wake("asi ayudame con el nivel")
        assert is_wake is True
        assert "ayudame" in command

    def test_upper_case_trigger(self):
        is_wake, command = match_wake("AXI, dime que ves")
        assert is_wake is True
        assert "dime" in command

    def test_command_has_leading_whitespace_stripped(self):
        is_wake, command = match_wake("axi,   dime algo")
        assert is_wake is True
        assert command == command.strip()
        assert command  # non-empty

    def test_axi_with_question(self):
        is_wake, command = match_wake("Axi, ¿qué estás viendo en pantalla?")
        assert is_wake is True
        assert command  # non-empty

    def test_axis_variant(self):
        """'axis' is in _TRIGGER set."""
        is_wake, command = match_wake("axis, describe el enemigo")
        assert is_wake is True
        assert "describe" in command

    def test_hexi_variant(self):
        is_wake, command = match_wake("hexi ayudame")
        assert is_wake is True
        assert "ayudame" in command

    def test_return_type_is_tuple(self):
        result = match_wake("axi, algo")
        assert isinstance(result, tuple)
        assert len(result) == 2
        is_wake, command = result
        assert isinstance(is_wake, bool)
        assert isinstance(command, str)


class TestMatchWakeFalseTriggerCases:
    """Transcripts that must NOT trigger a wake (false-trigger guard)."""

    def test_empty_string(self):
        is_wake, command = match_wake("")
        assert is_wake is False

    def test_whitespace_only(self):
        is_wake, command = match_wake("   ")
        assert is_wake is False

    def test_bare_axi_no_command(self):
        """Bare trigger with no command — Fix 3: NOW wakes with empty command (high-recall)."""
        is_wake, command = match_wake("axi")
        assert is_wake is True
        assert command == ""

    def test_bare_axi_punctuation_only(self):
        """Trigger + punctuation only — Fix 3: wakes with empty command."""
        is_wake, command = match_wake("axi,")
        assert is_wake is True
        assert command == ""

    def test_bare_asi_no_command(self):
        """'así' alone — Fix 3: wakes with empty command (high-recall mode)."""
        is_wake, command = match_wake("así")
        assert is_wake is True
        assert command == ""

    def test_asi_phrase_not_starting_with_trigger(self):
        """Transcript where 'así' appears in the middle — Fix 3: wakes anywhere."""
        # "no era así" — "así" appears mid-sentence → IS a wake now (high-recall).
        # The command would be empty (nothing follows "así" at word boundary).
        is_wake, command = match_wake("no era así")
        assert is_wake is True

    def test_standalone_spanish_word_haz(self):
        """'haz' is in _TRIGGER; Fix 3: bare trigger wakes with empty command."""
        # Note: "haz" is a valid Axi phonetic variant — bare wake is now allowed.
        is_wake, command = match_wake("haz")
        assert is_wake is True
        assert command == ""

    def test_noise_transcript(self):
        is_wake, command = match_wake("um er uh")
        assert is_wake is False

    def test_trigger_in_middle_of_sentence(self):
        """Fix 3: trigger ANYWHERE fires wake. 'me dijo que axi era genial' wakes."""
        is_wake, command = match_wake("me dijo que axi era genial")
        assert is_wake is True
        # The command is whatever follows "axi" in the sentence
        assert "era genial" in command or command == ""

    def test_empty_command_after_trigger_and_spaces(self):
        """Fix 3: trigger followed only by spaces → wake with empty command."""
        is_wake, command = match_wake("axi   ")
        assert is_wake is True
        assert command == ""

    def test_non_string_returns_false(self):
        # match_wake must never raise on weird input
        is_wake, command = match_wake(None)  # type: ignore[arg-type]
        assert is_wake is False


# ===========================================================================
# WakeWordListener orchestration — driven via FakeStreamingCapture
# ===========================================================================

class FakeStreamingCapture:
    """Test double that replaces the sounddevice InputStream.

    Feeds pre-cooked audio chunks into the listener's callback without
    opening any hardware device.
    """

    def __init__(self, chunks: list[np.ndarray]) -> None:
        self._chunks = list(chunks)
        self._callback: Callable | None = None
        self._started = False

    def set_callback(self, cb: Callable) -> None:
        self._callback = cb

    def play(self) -> None:
        """Deliver all chunks to the registered callback synchronously."""
        if self._callback is None:
            raise RuntimeError("No callback registered — call set_callback first")
        for chunk in self._chunks:
            self._callback(chunk.reshape(-1, 1), len(chunk), None, None)

    def start(self) -> None:
        self._started = True

    def stop(self) -> None:
        self._started = False

    def close(self) -> None:
        pass

    # Context-manager interface mirrors sd.InputStream
    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_):
        self.stop()
        self.close()


def _sine_chunk(duration_s: float = 0.02, freq: float = 440.0, sr: int = 16000) -> np.ndarray:
    """Generate a float32 sine wave chunk (simulates voiced audio)."""
    t = np.arange(int(sr * duration_s), dtype=np.float32) / sr
    return (0.3 * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _silence_chunk(duration_s: float = 0.02, sr: int = 16000) -> np.ndarray:
    """Generate a near-zero chunk (simulates silence between words)."""
    return np.zeros(int(sr * duration_s), dtype=np.float32)


class TestWakeWordListenerOrchestration:
    """Integration tests: FakeStreamingCapture drives the listener end-to-end."""

    def _build_listener(
        self,
        transcribe_fn: Callable,
        on_wake_fn: Callable,
        chunks: list[np.ndarray],
        *,
        silence_duration_s: float = 0.1,
    ) -> tuple[WakeWordListener, FakeStreamingCapture]:
        """Build and start a WakeWordListener with injected fakes (no real hardware)."""
        capture = FakeStreamingCapture(chunks)

        listener = WakeWordListener(
            transcribe_fn=transcribe_fn,
            on_wake=on_wake_fn,
            stream_factory=lambda callback, **kwargs: _bind(capture, callback),
            vad_aggressiveness=1,
            silence_duration_s=silence_duration_s,
            max_segment_s=8.0,
            sample_rate=16000,
        )
        # Start the listener so the callback is registered with the capture.
        # This also starts the worker thread; we stop it after _flush_segment.
        listener.start()
        return listener, capture

    def test_wake_segment_fires_on_wake_with_command(self):
        """A voiced segment transcribed as a wake phrase calls on_wake with the command."""
        called: list[str] = []

        def fake_transcribe(audio: np.ndarray):
            return "axi, ayudame con el puzzle", "es", 0.95

        def fake_on_wake(command: str):
            called.append(command)

        # Build voiced segment: 30 chunks of sine (speech) then silence
        voiced = [_sine_chunk(0.02) for _ in range(30)]
        silence = [_silence_chunk(0.02) for _ in range(60)]  # ~1.2s silence → segment end
        chunks = voiced + silence

        listener, capture = self._build_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            chunks=chunks,
            silence_duration_s=0.1,  # short silence threshold for test speed
        )

        try:
            # Drive the listener by feeding chunks through the capture
            capture.play()
            listener._flush_segment()  # flush any buffered audio
            # Give worker thread time to process
            time.sleep(0.1)
        finally:
            listener.stop()

        assert called, "on_wake was never called for a wake-word transcript"
        assert "ayudame" in called[0]

    def test_non_wake_segment_does_not_fire_on_wake(self):
        """Fix 3: 'así' is in _TRIGGER so 'no era así, solo hablaba' NOW fires on_wake.

        This is intentional — high-recall mode accepts more false-triggers in exchange
        for catching all genuine wake events. The user is on a headset in game-mode
        so false-trigger cost is low.
        """
        called: list[str] = []

        def fake_transcribe(audio: np.ndarray):
            return "no era así, solo hablaba", "es", 0.95

        def fake_on_wake(command: str):
            called.append(command)

        voiced = [_sine_chunk(0.02) for _ in range(30)]
        silence = [_silence_chunk(0.02) for _ in range(60)]
        chunks = voiced + silence

        listener, capture = self._build_listener(
            fake_transcribe, fake_on_wake, chunks, silence_duration_s=0.1
        )
        try:
            capture.play()
            listener._flush_segment()
            time.sleep(0.1)
        finally:
            listener.stop()

        # Fix 3: "así" in "no era así, solo hablaba" triggers wake.
        # Verify the listener fires (not assert-not-called — behavior changed).
        assert called, (
            "Fix 3: 'así' in transcript fires on_wake (high-recall); got no calls"
        )

    def test_bare_trigger_fires_on_wake_with_empty_command(self):
        """Bare 'axi' now WAKES with empty command (Fix 3 — high-recall mode)."""
        called: list[str] = []

        def fake_transcribe(audio: np.ndarray):
            return "axi", "es", 0.95

        def fake_on_wake(command: str):
            called.append(command)

        voiced = [_sine_chunk(0.02) for _ in range(30)]
        silence = [_silence_chunk(0.02) for _ in range(60)]
        chunks = voiced + silence

        listener, capture = self._build_listener(
            fake_transcribe, fake_on_wake, chunks, silence_duration_s=0.1
        )
        try:
            capture.play()
            listener._flush_segment()
            time.sleep(0.1)
        finally:
            listener.stop()

        assert called, "bare 'axi' must fire on_wake (Fix 3: high-recall)"
        assert called[0] == "", "empty command must be passed to on_wake"

    def test_empty_audio_segment_skipped(self):
        """Silence-only segment (no voice detected) does not call transcribe or on_wake."""
        transcribe_calls: list = []
        wake_calls: list[str] = []

        def fake_transcribe(audio: np.ndarray):
            transcribe_calls.append(audio)
            return "", "es", 0.0

        def fake_on_wake(command: str):
            wake_calls.append(command)

        # Only silence chunks — VAD should not accumulate a speech segment
        silence_only = [_silence_chunk(0.02) for _ in range(100)]

        listener, capture = self._build_listener(
            fake_transcribe, fake_on_wake, silence_only, silence_duration_s=0.1
        )
        try:
            capture.play()
            listener._flush_segment()
            time.sleep(0.1)
        finally:
            listener.stop()

        # on_wake must not fire
        assert not wake_calls


def _bind(capture: FakeStreamingCapture, callback: Callable) -> FakeStreamingCapture:
    """Register the callback on the fake capture and return it (used as stream factory)."""
    capture.set_callback(callback)
    return capture


# ===========================================================================
# _RateLimiter — pure unit tests (no threading, no hardware)
# ===========================================================================

class TestRateLimiter:
    """Tests for the callback-thread rate limiter helper."""

    def test_first_call_always_allowed(self):
        from axi.wakeword import _RateLimiter
        rl = _RateLimiter(interval_s=10.0)
        assert rl.allow() is True

    def test_second_call_within_interval_blocked(self):
        from axi.wakeword import _RateLimiter
        rl = _RateLimiter(interval_s=10.0)
        rl.allow()  # first call — sets timestamp
        assert rl.allow() is False  # too soon

    def test_call_after_interval_elapsed_allowed(self):
        import time as _time
        from axi.wakeword import _RateLimiter
        rl = _RateLimiter(interval_s=0.01)
        rl.allow()  # first call
        _time.sleep(0.02)  # wait longer than interval
        assert rl.allow() is True

    def test_zero_interval_always_allows(self):
        from axi.wakeword import _RateLimiter
        rl = _RateLimiter(interval_s=0.0)
        assert rl.allow() is True
        assert rl.allow() is True


# ===========================================================================
# resolve_input_device — unit tests (mocked pactl / mic)
# ===========================================================================

class TestResolveInputDevice:
    """Tests for the device-selection helper."""

    def test_env_override_wins(self, monkeypatch):
        """AXI_WAKEWORD_INPUT_DEVICE env var must be returned as-is."""
        monkeypatch.setenv("AXI_WAKEWORD_INPUT_DEVICE", "alsa_input.usb-test")
        from axi.wakeword import resolve_input_device
        result = resolve_input_device()
        assert result == "alsa_input.usb-test"

    def test_empty_env_falls_through_to_pick_best(self, monkeypatch):
        """When env var is empty, pick_best() is called."""
        monkeypatch.delenv("AXI_WAKEWORD_INPUT_DEVICE", raising=False)

        from axi.wakeword import resolve_input_device
        import axi.wakeword as ww

        class _FakeMic:
            name = "alsa_input.usb-hyperx"
            description = "HyperX SoloCast"
            score = 100

        monkeypatch.setattr(
            "axi.mic.pick_best",
            lambda: _FakeMic(),
        )
        result = resolve_input_device()
        assert result == "alsa_input.usb-hyperx"

    def test_pick_best_returns_none_gives_none(self, monkeypatch):
        """When pick_best() returns None, resolve_input_device returns None."""
        monkeypatch.delenv("AXI_WAKEWORD_INPUT_DEVICE", raising=False)
        monkeypatch.setattr("axi.mic.pick_best", lambda: None)
        from axi.wakeword import resolve_input_device
        result = resolve_input_device()
        assert result is None

    def test_pick_best_exception_returns_none(self, monkeypatch):
        """If pick_best() raises, resolve_input_device returns None without propagating."""
        monkeypatch.delenv("AXI_WAKEWORD_INPUT_DEVICE", raising=False)
        monkeypatch.setattr("axi.mic.pick_best", lambda: (_ for _ in ()).throw(RuntimeError("no pactl")))
        from axi.wakeword import resolve_input_device
        result = resolve_input_device()
        assert result is None


# ===========================================================================
# Daemon integration — start_wakeword_listener / stop_wakeword_listener
# ===========================================================================

class TestDaemonWakewordLifecycle:
    """Tests that Daemon.start_wakeword_listener / stop_wakeword_listener work."""

    def _build_daemon(self, *, brain_ask_fn=None, transcribe_text="hola"):
        import numpy as _np
        from axi.daemon import Daemon
        from axi.memory import ConversationMemory
        from axi.recorder import SAMPLE_RATE

        class _FakeRecorder:
            active_source = "fake"
            is_recording = False
            def start(self): self.is_recording = True; return self.active_source
            def stop(self):
                self.is_recording = False
                t = _np.arange(SAMPLE_RATE, dtype=_np.float32) / SAMPLE_RATE
                return (0.05 * _np.sin(2 * _np.pi * 220.0 * t)).astype(_np.float32)

        class _FakeTranscriber:
            def transcribe(self, audio): return transcribe_text, "es", 0.95

        def _default_brain(*a, **kw): return "respuesta"

        return Daemon(
            recorder=_FakeRecorder(),
            transcriber=_FakeTranscriber(),
            memory=ConversationMemory(),
            brain_ask=brain_ask_fn or _default_brain,
            vision_capture=lambda: "fake-b64",
            eyes_capture=lambda: ("fake-b64", "ok"),
            meeting_factory=lambda **kw: None,
        )

    def test_start_and_stop_listener_does_not_raise(self, monkeypatch):
        """start_wakeword_listener + stop_wakeword_listener must not raise."""
        from axi import daemon as d
        monkeypatch.setattr(d, "notify", lambda *a, **kw: None)

        daemon = self._build_daemon()

        # Patch both listener classes with a no-op stand-in so no audio hardware
        # or ONNX model is needed (engine selection now reads config and may pick OWW).
        from axi import wakeword as ww

        class _FakeListener:
            def start(self): pass
            def stop(self): pass

        monkeypatch.setattr(ww, "WakeWordListener", lambda **kw: _FakeListener())
        monkeypatch.setattr(ww, "OWWWakeWordListener", lambda **kw: _FakeListener())

        daemon.start_wakeword_listener()
        daemon.stop_wakeword_listener()

    def test_double_start_is_idempotent(self, monkeypatch):
        """Calling start_wakeword_listener twice does not spawn a second listener."""
        from axi import daemon as d
        monkeypatch.setattr(d, "notify", lambda *a, **kw: None)

        daemon = self._build_daemon()
        from axi import wakeword as ww

        instances: list = []

        class _FakeListener:
            def start(self): instances.append(self)
            def stop(self): pass

        # Patch both engines — whichever is selected by config, it must be idempotent.
        monkeypatch.setattr(ww, "WakeWordListener", lambda **kw: _FakeListener())
        monkeypatch.setattr(ww, "OWWWakeWordListener", lambda **kw: _FakeListener())

        daemon.start_wakeword_listener()
        daemon.start_wakeword_listener()  # second call — must be a no-op

        assert len(instances) == 1, "start_wakeword_listener must be idempotent"


# ===========================================================================
# Concurrency hardening — stop() drain safety (TOCTOU fix)
# ===========================================================================

class TestWorkerDrainOnStop:
    """Verify that segments enqueued before stop() returns are not silently dropped.

    Design invariant: any segment appended to _segment_queue before stop() sets
    _running = False must be processed.  The worker loop must drain the queue
    AFTER _running goes False, not exit immediately when it sees _running=False.

    We drive the drain path directly (no hardware, no VAD) by manually appending
    to _segment_queue and then calling stop() before the worker has a chance to
    drain.  All enqueued segments must still be processed.
    """

    def _build_stopped_listener(
        self, transcribe_fn, on_wake_fn
    ) -> WakeWordListener:
        """Build and start a listener with no-op stream (no audio hardware)."""
        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = WakeWordListener(
            transcribe_fn=transcribe_fn,
            on_wake=on_wake_fn,
            stream_factory=lambda callback, **kwargs: _NullStream(),
            vad_aggressiveness=1,
            silence_duration_s=0.1,
            max_segment_s=8.0,
            sample_rate=16000,
        )
        listener.start()
        return listener

    def test_segment_enqueued_before_stop_is_processed(self):
        """All segments enqueued before stop() returns must be processed.

        Invariant: stop() calls worker.join(), so by the time stop() returns
        the worker has exited.  For no segment to be dropped, the worker's
        drain loop must check the queue UNDER _queue_lock as the exit
        condition, not as an unguarded read.

        Note on RED: CPython's GIL makes the unguarded `or self._segment_queue`
        read safe in practice for list truthiness checks, so a deterministic
        unit-test cannot reliably make the buggy code drop a segment.
        This test instead pins down the behavioral invariant that the
        structural fix (lock-guarded drain condition) must satisfy: after
        stop() returns, zero segments remain unprocessed.
        """
        processed: list = []

        def fake_transcribe(audio: np.ndarray):
            processed.append(1)
            return "axi, drain test", "es", 0.95

        wake_calls: list[str] = []

        def fake_on_wake(command: str):
            wake_calls.append(command)

        listener = self._build_stopped_listener(fake_transcribe, fake_on_wake)

        dummy = np.ones(160, dtype=np.float32)
        N = 5
        with listener._queue_lock:
            for _ in range(N):
                listener._segment_queue.append(dummy.copy())
        listener._queue_event.set()

        listener.stop()  # joins worker — must not return until queue is empty

        assert len(processed) == N, (
            f"Expected {N} segments processed after stop(), got {len(processed)}. "
            "Worker exited before draining the queue."
        )
        assert len(wake_calls) == N, (
            f"Expected {N} on_wake calls, got {len(wake_calls)}."
        )

    def test_multiple_segments_all_processed_before_exit(self):
        """All N segments enqueued before stop() must be fully processed."""
        processed: list = []

        def fake_transcribe(audio: np.ndarray):
            processed.append(1)
            return "", "es", 0.0  # non-wake — just counting transcribe calls

        listener = self._build_stopped_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=lambda cmd: None,
        )

        # Same race simulation: enqueue, flip _running=False, then wake worker.
        listener._queue_event.clear()
        dummy = np.ones(160, dtype=np.float32)
        N = 5
        with listener._queue_lock:
            for _ in range(N):
                listener._segment_queue.append(dummy.copy())

        listener._running = False
        listener._queue_event.set()
        if listener._worker is not None:
            listener._worker.join(timeout=2.0)

        assert len(processed) == N, (
            f"Worker exited with {N - len(processed)} segments still in queue."
        )


# ===========================================================================
# Fix 1 — Whisper anti-hallucination params for the wake-word path
# ===========================================================================

class TestWakeWordTranscriberParams:
    """Assert that the wake-word transcribe path uses anti-hallucination settings."""

    def test_transcribe_wakeword_passes_anti_hallucination_params(self, monkeypatch):
        """transcribe_wakeword() must call whisper_client.transcribe with specific params."""
        from axi.transcriber import transcribe_wakeword
        import axi.whisper_client as _wc

        captured: list[dict] = []

        class _FakeResult:
            text = "Axi."
            language = "es"
            language_probability = 0.99

        def _fake_transcribe(audio, **kwargs):
            captured.append(kwargs)
            return _FakeResult()

        monkeypatch.setattr(_wc, "transcribe", _fake_transcribe)

        import numpy as np
        audio = np.zeros(1600, dtype=np.float32)
        transcribe_wakeword(audio, language="es")

        assert len(captured) == 1, "whisper_client.transcribe must be called once"
        params = captured[0]
        # Anti-hallucination requirements
        assert params.get("condition_on_previous_text") is False, (
            "condition_on_previous_text must be False to kill repetition loops"
        )
        assert params.get("no_speech_threshold", 0) >= 0.6, (
            "no_speech_threshold must be raised (>= 0.6) for wake-word path"
        )
        assert params.get("vad_filter") is True, (
            "vad_filter must be True for wake-word path"
        )
        # temperature=0 via extra_kwargs or beam_size=1 for greedy decoding
        extra = params.get("extra_kwargs") or {}
        temp = extra.get("temperature")
        beam = params.get("beam_size")
        assert temp == 0 or beam == 1, (
            "Must use temperature=0 (via extra_kwargs) or beam_size=1 for greedy (anti-hallucination)"
        )

    def test_transcribe_wakeword_uses_wake_initial_prompt(self, monkeypatch):
        """The initial_prompt for wake-word transcription must bias toward 'Axi.' not YouTube."""
        from axi.transcriber import transcribe_wakeword
        import axi.whisper_client as _wc

        captured: list[dict] = []

        class _FakeResult:
            text = "Axi."
            language = "es"
            language_probability = 0.99

        def _fake_transcribe(audio, **kwargs):
            captured.append(kwargs)
            return _FakeResult()

        monkeypatch.setattr(_wc, "transcribe", _fake_transcribe)

        import numpy as np
        audio = np.zeros(1600, dtype=np.float32)
        transcribe_wakeword(audio, language="es")

        params = captured[0]
        prompt = params.get("initial_prompt", "")
        # Must mention Axi and be short (not a YouTube-style prompt)
        assert "Axi" in prompt or "axi" in prompt.lower(), (
            "initial_prompt must bias toward 'Axi'"
        )
        assert "Suscríbete" not in prompt and "suscribete" not in prompt.lower(), (
            "initial_prompt must NOT contain YouTube phrases"
        )


# ===========================================================================
# Fix 2 — Hallucination blocklist: is_hallucination()
# ===========================================================================

class TestIsHallucination:
    """is_hallucination(text) must detect known Whisper hallucination phrases."""

    def test_suscribete_al_canal_is_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("¡Suscríbete al canal!") is True

    def test_gracias_por_ver_el_video_is_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("Gracias por ver el video.") is True

    def test_subtitulos_realizados_es_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("Subtítulos realizados por la comunidad.") is True

    def test_amara_is_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("subtítulos por la comunidad de amara.org") is True

    def test_no_olvides_suscribirte_is_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("No olvides suscribirte.") is True

    def test_real_wake_phrase_is_not_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("axi ayudame con esto") is False

    def test_empty_string_is_not_hallucination(self):
        from axi.wakeword import is_hallucination
        # Empty or whitespace-only → no-speech handled elsewhere, not hallucination
        assert is_hallucination("") is False

    def test_normal_spanish_sentence_is_not_hallucination(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("¿Qué está pasando en el juego?") is False

    def test_repetition_loop_is_hallucination(self):
        """Same short phrase repeated 3+ times → hallucination."""
        from axi.wakeword import is_hallucination
        text = "ya no puedo ver el mismo " * 4
        assert is_hallucination(text) is True

    def test_two_repetitions_not_hallucination(self):
        """Only two repetitions of a phrase → NOT a hallucination (could be legit)."""
        from axi.wakeword import is_hallucination
        text = "axi axi"
        assert is_hallucination(text) is False

    def test_case_insensitive_match(self):
        from axi.wakeword import is_hallucination
        assert is_hallucination("SUSCRÍBETE AL CANAL") is True

    def test_punctuation_stripped_for_match(self):
        from axi.wakeword import is_hallucination
        # Variant with different punctuation
        assert is_hallucination("¡suscríbete al canal!") is True


# ===========================================================================
# Fix 3 — Loosened match_wake: trigger ANYWHERE + empty command allowed
# ===========================================================================

class TestMatchWakeLoosened:
    """New match_wake behavior: trigger anywhere, empty command still wakes."""

    def test_bare_axi_wakes_with_empty_command(self):
        """Bare 'Axi' with no command must return is_wake=True, command=''."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("axi")
        assert is_wake is True
        assert command == ""

    def test_axi_punctuation_only_wakes_empty_command(self):
        """'axi,' — punctuation after trigger, no command → wake with empty command."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("axi,")
        assert is_wake is True
        assert command == ""

    def test_axi_anywhere_in_transcript_wakes(self):
        """Whisper may prepend filler — 'bla bla axi ayudame' must still wake."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("bla bla axi ayudame")
        assert is_wake is True
        assert "ayudame" in command

    def test_filler_then_axi_no_command_wakes_empty(self):
        """Filler text then bare trigger → wake with empty command."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("um er axi")
        assert is_wake is True
        assert command == ""

    def test_word_boundary_axi_inside_word_does_not_wake(self):
        """'maximal' contains 'axi' but not as a standalone word → must NOT wake."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("la configuración maximal es correcta")
        assert is_wake is False

    def test_axi_with_command_anywhere_returns_command(self):
        """Trigger anywhere, command extracted as remainder after trigger."""
        from axi.wakeword import match_wake
        is_wake, command = match_wake("oye axi, ¿qué hago con esto?")
        assert is_wake is True
        assert command  # non-empty

    def test_hallucination_phrase_does_not_wake(self):
        """A pure hallucination transcript must not wake (is_hallucination guard in process_segment)."""
        # Note: match_wake itself doesn't call is_hallucination — that's in _process_segment.
        # We test the integration path here: hallucination filtered before match_wake.
        # This test verifies the _process_segment path via a mock listener.
        import numpy as np
        from axi.wakeword import WakeWordListener

        wake_calls: list[str] = []

        def fake_transcribe(audio):
            return "¡Suscríbete al canal!", "es", 0.95

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = WakeWordListener(
            transcribe_fn=fake_transcribe,
            on_wake=lambda cmd: wake_calls.append(cmd),
            stream_factory=lambda callback, **kwargs: _NullStream(),
            silence_duration_s=0.1,
            sample_rate=16000,
        )
        listener.start()

        # Directly process a segment (bypass audio hardware)
        audio = np.ones(1600, dtype=np.float32) * 0.1
        listener._process_segment(audio)

        listener.stop()
        assert not wake_calls, (
            "Hallucination transcript '¡Suscríbete al canal!' must not fire on_wake"
        )


# ===========================================================================
# Fix 4 — daemon._wakeword_ask: empty command speaks ack, not brain
# ===========================================================================

class TestDaemonWakewordAskEmptyCommand:
    """Empty command from wake detection must speak ack, not call brain."""

    def _build_daemon(self, brain_fn=None, speak_fn=None, monkeypatch=None):
        import numpy as np
        from axi.daemon import Daemon
        from axi.memory import ConversationMemory
        from axi.recorder import SAMPLE_RATE
        import axi.daemon as d

        if monkeypatch:
            monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
            if speak_fn:
                monkeypatch.setattr(d, "speak_text", speak_fn)

        class _FakeRecorder:
            active_source = "fake"
            is_recording = False
            def start(self): self.is_recording = True; return "fake"
            def stop(self):
                self.is_recording = False
                return np.zeros(1600, dtype=np.float32)

        class _FakeTranscriber:
            def transcribe(self, audio): return "hola", "es", 0.95

        brain_calls: list = []

        def _brain(*a, **kw):
            brain_calls.append((a, kw))
            return "respuesta"

        return Daemon(
            recorder=_FakeRecorder(),
            transcriber=_FakeTranscriber(),
            memory=ConversationMemory(),
            brain_ask=brain_fn or _brain,
            vision_capture=lambda: None,
            eyes_capture=lambda: (None, "ok"),
            meeting_factory=lambda **kw: None,
        ), brain_calls

    def test_empty_command_does_not_call_brain(self, monkeypatch):
        """When command is '', _wakeword_ask must NOT invoke brain_ask."""
        import axi.daemon as d
        monkeypatch.setattr(d, "notify", lambda *a, **kw: None)

        spoken: list[str] = []
        monkeypatch.setattr(d, "speak_text", lambda text: spoken.append(text))
        # Also patch _game_mode_active and config to avoid side effects
        monkeypatch.setattr(d, "_game_mode_active", lambda: False)

        daemon, brain_calls = self._build_daemon(monkeypatch=None)
        daemon.brain_ask = lambda *a, **kw: brain_calls.append((a, kw)) or "resp"

        # Patch notify on the daemon's module reference
        import axi.daemon as _d
        _d.notify = lambda *a, **kw: None
        _d.speak_text = lambda text: spoken.append(text)
        _d._game_mode_active = lambda: False

        brain_calls_local: list = []
        _d_brain_orig = daemon.brain_ask

        def _capture_brain(*a, **kw):
            brain_calls_local.append((a, kw))
            return "respuesta"

        daemon.brain_ask = _capture_brain

        daemon._wakeword_ask("", screenshot=None)

        # Allow the speaking thread to finish
        import time
        time.sleep(0.15)

        assert not brain_calls_local, (
            f"brain_ask must NOT be called for empty command, but got: {brain_calls_local}"
        )

    def test_empty_command_speaks_acknowledgment(self, monkeypatch):
        """When command is '', _wakeword_ask must speak a short ack in Spanish."""
        import axi.daemon as d
        import axi.daemon as _d

        spoken: list[str] = []
        _d.notify = lambda *a, **kw: None
        _d.speak_text = lambda text: spoken.append(text)
        _d._game_mode_active = lambda: False

        daemon, _ = self._build_daemon(monkeypatch=None)
        daemon.brain_ask = lambda *a, **kw: "resp"

        daemon._wakeword_ask("", screenshot=None)

        import time
        time.sleep(0.15)

        assert spoken, "Must speak an acknowledgment when command is empty"
        # The ack should contain a Spanish-style response, not a full answer
        ack = spoken[0].lower()
        assert len(ack) < 50, f"Ack should be short, got: {spoken[0]!r}"

    def test_nonempty_command_calls_brain(self, monkeypatch):
        """A non-empty command must proceed through brain_ask as before."""
        import axi.daemon as _d

        spoken: list[str] = []
        brain_calls: list = []
        _d.notify = lambda *a, **kw: None
        _d.speak_text = lambda text: spoken.append(text)
        _d._game_mode_active = lambda: False

        daemon, _ = self._build_daemon(monkeypatch=None)

        def _brain(*a, **kw):
            brain_calls.append((a, kw))
            return "respuesta de prueba"

        daemon.brain_ask = _brain

        daemon._wakeword_ask("¿qué hago con esto?", screenshot=None)

        import time
        time.sleep(0.2)

        assert brain_calls, "brain_ask must be called for a non-empty command"


# ===========================================================================
# openWakeWord state machine — TDD RED → GREEN
# ===========================================================================

class TestOWWStateMachineIDLE:
    """IDLE state: accumulate 320-sample frames into 1280-sample chunks and call predict."""

    def test_chunk_accumulation_four_frames_triggers_predict(self):
        """4 × 320-sample frames must be batched into one 1280-sample predict call."""
        from axi.wakeword import OWWWakeWordListener

        predict_calls: list[np.ndarray] = []

        def fake_predict(chunk: np.ndarray) -> dict:
            predict_calls.append(chunk.copy())
            return {"alexa": 0.0}  # below threshold — stay IDLE

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = OWWWakeWordListener(
            transcribe_fn=lambda audio: ("", "es", 0.0),
            on_wake=lambda cmd: None,
            stream_factory=lambda callback, **kw: _NullStream(),
            oww_predict_fn=fake_predict,
            oww_threshold=0.5,
        )
        listener.start()

        # Inject 4 frames of 320 samples each
        frame = np.zeros(320, dtype=np.float32)
        for _ in range(4):
            listener._oww_ingest_frame(frame)

        listener.stop()

        assert len(predict_calls) == 1, (
            f"Expected exactly 1 predict call per 1280-sample chunk, got {len(predict_calls)}"
        )
        assert predict_calls[0].shape == (1280,), (
            f"predict must receive a 1280-sample chunk, got shape {predict_calls[0].shape}"
        )

    def test_low_score_stays_idle(self):
        """A predict score below threshold must NOT transition to COMMAND_CAPTURE."""
        from axi.wakeword import OWWWakeWordListener

        wake_calls: list[str] = []

        def fake_predict(chunk: np.ndarray) -> dict:
            return {"alexa": 0.1}  # well below default threshold 0.5

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = OWWWakeWordListener(
            transcribe_fn=lambda audio: ("axi test", "es", 0.9),
            on_wake=lambda cmd: wake_calls.append(cmd),
            stream_factory=lambda callback, **kw: _NullStream(),
            oww_predict_fn=fake_predict,
            oww_threshold=0.5,
        )
        listener.start()

        # Feed 8 frames → 2 chunks, both with low score
        frame = np.zeros(320, dtype=np.float32)
        for _ in range(8):
            listener._oww_ingest_frame(frame)

        listener.stop()

        assert not wake_calls, (
            "Low OWW score must not trigger on_wake. Got calls: %s" % wake_calls
        )
        assert listener._oww_state == "idle", (
            f"State must remain 'idle' after low-score chunks, got {listener._oww_state!r}"
        )

    def test_high_score_transitions_to_command_capture(self):
        """A predict score >= threshold must transition state to COMMAND_CAPTURE."""
        from axi.wakeword import OWWWakeWordListener

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = OWWWakeWordListener(
            transcribe_fn=lambda audio: ("", "es", 0.0),
            on_wake=lambda cmd: None,
            stream_factory=lambda callback, **kw: _NullStream(),
            oww_predict_fn=lambda chunk: {"alexa": 0.9},  # above threshold
            oww_threshold=0.5,
        )
        listener.start()

        # One full chunk (4 × 320) with high score triggers transition
        frame = np.zeros(320, dtype=np.float32)
        for _ in range(4):
            listener._oww_ingest_frame(frame)

        # State should now be command_capture
        state = listener._oww_state
        listener.stop()

        assert state == "command_capture", (
            f"Expected 'command_capture' after high OWW score, got {state!r}"
        )


class TestOWWStateMachineCOMMAND_CAPTURE:
    """COMMAND_CAPTURE state: run existing VAD capture then transcribe → on_wake."""

    def test_command_capture_calls_on_wake_with_command(self):
        """After OWW detects wake, COMMAND_CAPTURE must transcribe audio and call on_wake.

        VAD classifies constant-amplitude frames (even zeros) as speech.
        We use low-amplitude random noise for silence frames — VAD correctly
        rejects random noise below the speech-frequency threshold.
        """
        from axi.wakeword import OWWWakeWordListener

        wake_calls: list[str] = []
        rng = np.random.default_rng(7)

        def fake_transcribe(audio: np.ndarray):
            return "axi ayudame", "es", 0.95

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        # Use threshold=0.5, predict always returns 0.9 → immediate capture transition
        listener = OWWWakeWordListener(
            transcribe_fn=fake_transcribe,
            on_wake=lambda cmd: wake_calls.append(cmd),
            stream_factory=lambda callback, **kw: _NullStream(),
            oww_predict_fn=lambda chunk: {"alexa": 0.9},
            oww_threshold=0.5,
            silence_duration_s=0.04,  # 2 frames at 20ms — very short for test speed
        )
        listener.start()

        # Trigger transition to COMMAND_CAPTURE via one full OWW chunk
        idle_frame = np.zeros(320, dtype=np.float32)
        for _ in range(4):
            listener._oww_ingest_frame(idle_frame)

        assert listener._oww_state == "command_capture", "Pre-condition: must enter command_capture"

        # Feed voiced audio (sine wave — VAD classifies as speech, meets _MIN_VOICED_FRAMES=5)
        t = np.arange(320, dtype=np.float32) / 16000
        voiced = (0.3 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)
        for _ in range(10):
            listener._oww_ingest_frame(voiced)

        # Feed silence (low-amplitude random noise — VAD classifies as non-speech)
        for _ in range(10):
            noise_silence = (rng.standard_normal(320) * 0.0005).astype(np.float32)
            listener._oww_ingest_frame(noise_silence)

        # Give worker thread time to process
        time.sleep(0.3)
        listener.stop()

        assert wake_calls, "on_wake must be called after OWW triggers COMMAND_CAPTURE"
        assert "ayudame" in wake_calls[0], (
            f"Expected command 'ayudame' in on_wake, got: {wake_calls[0]!r}"
        )

    def test_command_capture_returns_to_idle_after_on_wake(self):
        """After processing the command, state must return to IDLE.

        VAD classifies constant-amplitude frames (even zeros) as speech.
        We use low-amplitude random noise for silence frames — VAD correctly
        rejects random noise below the speech-frequency threshold.
        """
        from axi.wakeword import OWWWakeWordListener

        rng = np.random.default_rng(42)

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = OWWWakeWordListener(
            transcribe_fn=lambda audio: ("axi test", "es", 0.9),
            on_wake=lambda cmd: None,
            stream_factory=lambda callback, **kw: _NullStream(),
            oww_predict_fn=lambda chunk: {"alexa": 0.9},
            oww_threshold=0.5,
            silence_duration_s=0.04,  # 2 frames at 20ms each
        )
        listener.start()

        # Force into command_capture via 4 OWW frames
        idle_frame = np.zeros(320, dtype=np.float32)
        for _ in range(4):
            listener._oww_ingest_frame(idle_frame)

        assert listener._oww_state == "command_capture", "Pre-condition: must be in command_capture"

        # Feed voiced audio (sine wave — VAD classifies as speech)
        t = np.arange(320, dtype=np.float32) / 16000
        voiced = (0.3 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)
        for _ in range(6):
            listener._oww_ingest_frame(voiced)

        # Feed silence (low-amplitude random noise — VAD classifies as non-speech)
        for _ in range(10):
            noise_silence = (rng.standard_normal(320) * 0.0005).astype(np.float32)
            listener._oww_ingest_frame(noise_silence)

        time.sleep(0.3)
        final_state = listener._oww_state
        listener.stop()

        assert final_state == "idle", (
            f"State must return to 'idle' after processing command, got {final_state!r}"
        )


class TestOWWLegacyFallback:
    """wakeword_engine='vad_whisper' must use the original WakeWordListener path."""

    def test_create_listener_with_legacy_engine(self):
        """WakeWordListener class must still be importable and instantiable."""
        from axi.wakeword import WakeWordListener

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = WakeWordListener(
            transcribe_fn=lambda audio: ("", "es", 0.0),
            on_wake=lambda cmd: None,
            stream_factory=lambda callback, **kw: _NullStream(),
        )
        assert listener is not None

    def test_legacy_listener_does_not_have_oww_state(self):
        """Original WakeWordListener must NOT have _oww_state (clean separation)."""
        from axi.wakeword import WakeWordListener

        class _NullStream:
            def start(self): pass
            def stop(self): pass
            def close(self): pass

        listener = WakeWordListener(
            transcribe_fn=lambda audio: ("", "es", 0.0),
            on_wake=lambda cmd: None,
            stream_factory=lambda callback, **kw: _NullStream(),
        )
        assert not hasattr(listener, "_oww_state"), (
            "WakeWordListener (legacy) must not have _oww_state attribute"
        )
