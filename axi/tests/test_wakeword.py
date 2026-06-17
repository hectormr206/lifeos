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
        """Bare trigger with no command remainder — must be rejected."""
        is_wake, command = match_wake("axi")
        assert is_wake is False

    def test_bare_axi_punctuation_only(self):
        is_wake, command = match_wake("axi,")
        assert is_wake is False

    def test_bare_asi_no_command(self):
        """'así' alone without command — false trigger guard."""
        is_wake, command = match_wake("así")
        assert is_wake is False

    def test_asi_phrase_not_starting_with_trigger(self):
        """Transcript where 'así' does NOT appear at the start."""
        is_wake, command = match_wake("no era así")
        assert is_wake is False

    def test_standalone_spanish_word_haz(self):
        """'haz' is in _TRIGGER but with no command it must not fire."""
        is_wake, command = match_wake("haz")
        assert is_wake is False

    def test_noise_transcript(self):
        is_wake, command = match_wake("um er uh")
        assert is_wake is False

    def test_trigger_in_middle_of_sentence(self):
        """Wake requires trigger at START of transcript, not embedded."""
        is_wake, command = match_wake("me dijo que axi era genial")
        assert is_wake is False

    def test_empty_command_after_trigger_and_spaces(self):
        """Trigger followed only by spaces — not a real command."""
        is_wake, command = match_wake("axi   ")
        assert is_wake is False

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
        """A voiced segment transcribed as a non-wake phrase does NOT call on_wake."""
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

        assert not called, f"on_wake should NOT have fired but got: {called}"

    def test_bare_trigger_no_command_does_not_fire(self):
        """Bare 'axi' with no command does not fire on_wake (false-trigger guard)."""
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

        assert not called, "bare 'axi' without command must not fire on_wake"

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

        # Patch WakeWordListener with a no-op stand-in so no audio hardware needed
        from axi import wakeword as ww

        class _FakeListener:
            def start(self): pass
            def stop(self): pass

        monkeypatch.setattr(ww, "WakeWordListener", lambda **kw: _FakeListener())

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

        monkeypatch.setattr(ww, "WakeWordListener", lambda **kw: _FakeListener())

        daemon.start_wakeword_listener()
        daemon.start_wakeword_listener()  # second call — must be a no-op

        assert len(instances) == 1, "start_wakeword_listener must be idempotent"
