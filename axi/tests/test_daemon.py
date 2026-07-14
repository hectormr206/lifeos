"""Smoke tests for the Daemon DI seam.

These tests exercise the command surface (_handle_cmd) with injected fakes
so we never load Whisper, never touch a microphone, never call the brain
HTTP backend. The real production wiring (`python -m axi.daemon`) is left
intact — defaults still construct the real classes.
"""
from __future__ import annotations

import threading
import time
from typing import Any, Callable

import numpy as np
import pytest

from axi.daemon import Daemon, _handle_cmd
from axi.memory import ConversationMemory
from axi.recorder import SAMPLE_RATE


# ───────────── Fakes ─────────────

class FakeRecorder:
    """Records nothing — stop() returns a canned 1-second 16k waveform.

    The waveform is a low-amplitude sine wave just above the daemon's
    SILENCE_RMS_THRESHOLD (0.002) so the silence gate does not eat it.
    """

    def __init__(self, audio: np.ndarray | None = None) -> None:
        self._recording = False
        self.active_source = "fake"
        if audio is None:
            t = np.arange(SAMPLE_RATE, dtype=np.float32) / SAMPLE_RATE
            audio = (0.05 * np.sin(2 * np.pi * 220.0 * t)).astype(np.float32)
        self._audio = audio
        self.start_calls = 0
        self.stop_calls = 0

    @property
    def is_recording(self) -> bool:
        return self._recording

    def start(self) -> str:
        self.start_calls += 1
        self._recording = True
        return self.active_source

    def stop(self) -> np.ndarray:
        self.stop_calls += 1
        self._recording = False
        return self._audio


class FakeTranscriber:
    def __init__(self, text: str = "hola mundo", lang: str = "es", prob: float = 0.95) -> None:
        self.text = text
        self.lang = lang
        self.prob = prob
        self.calls = 0

    def transcribe(self, audio: np.ndarray) -> tuple[str, str, float]:
        self.calls += 1
        return self.text, self.lang, self.prob


class FakeBrainAsk:
    def __init__(self, answer: str = "respuesta canónica") -> None:
        self.answer = answer
        self.calls: list[dict[str, Any]] = []

    def __call__(self, prompt: str, *, system: str = "", image_b64: str | None = None,
                 history: list | None = None, **kwargs) -> str:
        self.calls.append({
            "prompt": prompt,
            "system": system,
            "image_b64": image_b64,
            "history": history,
        })
        return self.answer


class FakeMeetingSession:
    """Minimal stand-in for MeetingSession used by meeting_* tests."""

    def __init__(self, *, transcribe_fn=None, brain_ask_fn=None) -> None:
        self.meeting_id = 42
        self._started = False
        self._stopped = False

    def start(self) -> int:
        self._started = True
        return self.meeting_id

    def stop(self) -> int:
        self._stopped = True
        return self.meeting_id

    def status_summary(self) -> dict:
        return {
            "meeting_id": self.meeting_id,
            "duration_s": 7,
            "mic_chunks": 0,
            "system_chunks": 0,
            "screens": 0,
        }

    def register_dictation(self, *_a, **_kw) -> None:
        pass


# ───────────── Fixtures ─────────────

@pytest.fixture
def fake_recorder() -> FakeRecorder:
    return FakeRecorder()


@pytest.fixture
def fake_transcriber() -> FakeTranscriber:
    return FakeTranscriber()


@pytest.fixture
def fake_brain() -> FakeBrainAsk:
    return FakeBrainAsk()


@pytest.fixture
def fake_vision() -> Callable[[], str | None]:
    def _capture() -> str | None:
        return "fake-screenshot-b64"
    return _capture


@pytest.fixture
def fake_eyes() -> Callable[[], tuple[str | None, str]]:
    def _capture() -> tuple[str | None, str]:
        return "fake-webcam-b64", "ok"
    return _capture


@pytest.fixture(autouse=True)
def _silence_side_effects(monkeypatch):
    """Mute notify/clipboard/save/typing/speak in every daemon test.

    These touch DBus, X11, the filesystem, or external commands — none of
    them is what a smoke test is here to verify.
    """
    from axi import daemon as d
    from axi import extractor as e
    monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
    monkeypatch.setattr(d, "save_last", lambda *a, **kw: "/tmp/x")
    monkeypatch.setattr(d, "save_last_answer", lambda *a, **kw: None)
    monkeypatch.setattr(d, "to_clipboard", lambda *a, **kw: "ok")
    monkeypatch.setattr(d, "type_to_focused", lambda *a, **kw: False)
    monkeypatch.setattr(d, "speak_text", lambda *a, **kw: None)
    # Fact extraction would otherwise spin a thread that hits the brain.
    monkeypatch.setattr(e, "extract_and_store", lambda *a, **kw: 0)


def _build(daemon_kwargs: dict | None = None, **overrides) -> Daemon:
    """Build a Daemon with sane fakes; callers override what they need."""
    kwargs = {
        "recorder": FakeRecorder(),
        "transcriber": FakeTranscriber(),
        "memory": ConversationMemory(),
        "brain_ask": FakeBrainAsk(),
        "vision_capture": lambda: "fake-screenshot-b64",
        "eyes_capture": lambda: ("fake-webcam-b64", "ok"),
        "meeting_factory": lambda **kw: FakeMeetingSession(**kw),
    }
    if daemon_kwargs:
        kwargs.update(daemon_kwargs)
    kwargs.update(overrides)
    return Daemon(**kwargs)


def _wait_idle(daemon: Daemon, timeout: float = 3.0) -> str:
    """Spin until the daemon returns to idle (background threads finish)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if daemon.state in ("idle", "speaking"):
            # speaking is the terminal background-TTS state in _stop_and_ask;
            # the fake speak_text returns immediately so it flips to idle fast.
            if daemon.state == "idle":
                return "idle"
        time.sleep(0.02)
    return daemon.state


# ───────────── Tests ─────────────

def test_status_idle():
    """Fresh daemon should report idle status."""
    d = _build()
    resp, quit_ = _handle_cmd(d, "status")
    assert resp == "idle"
    assert quit_ is False


def test_toggle_starts_recording():
    """First toggle flips the daemon into recording state."""
    rec = FakeRecorder()
    d = _build(recorder=rec)
    resp, _ = _handle_cmd(d, "toggle")
    assert resp == "recording"
    assert rec.is_recording is True
    assert d.state == "recording"


def test_toggle_again_transcribes_and_returns_idle():
    """Second toggle stops recording, runs Whisper, ends idle."""
    rec = FakeRecorder()
    tx = FakeTranscriber(text="probando dictado")
    d = _build(recorder=rec, transcriber=tx)
    _handle_cmd(d, "toggle")  # start
    assert d.state == "recording"
    resp, _ = _handle_cmd(d, "toggle")  # stop + transcribe in background
    assert resp == "processing"
    _wait_idle(d)
    assert tx.calls == 1
    assert d.state == "idle"


def test_ask_toggle_captures_screen_and_calls_brain():
    """ask: vision is captured, brain receives image_b64."""
    rec = FakeRecorder()
    brain = FakeBrainAsk(answer="42")
    vision_calls = {"n": 0}

    def vision():
        vision_calls["n"] += 1
        return "screen-b64"

    d = _build(recorder=rec, brain_ask=brain, vision_capture=vision)
    _handle_cmd(d, "ask")
    assert vision_calls["n"] == 1
    assert d.state == "recording"
    _handle_cmd(d, "ask")  # second toggle — runs _stop_and_ask in a thread
    _wait_idle(d)
    assert len(brain.calls) == 1
    assert brain.calls[0]["image_b64"] == "screen-b64"


def test_look_toggle_captures_camera_and_calls_brain():
    """look: webcam (eyes) captured before recording starts."""
    rec = FakeRecorder()
    brain = FakeBrainAsk(answer="te veo")
    eyes_calls = {"n": 0}

    def eyes():
        eyes_calls["n"] += 1
        return "cam-b64", "ok"

    d = _build(recorder=rec, brain_ask=brain, eyes_capture=eyes)
    resp, _ = _handle_cmd(d, "look")
    assert resp == "recording"
    assert eyes_calls["n"] == 1
    _handle_cmd(d, "look")  # second toggle stops + asks
    _wait_idle(d)
    assert len(brain.calls) == 1
    assert brain.calls[0]["image_b64"] == "cam-b64"


@pytest.mark.skip(
    reason="Real MeetingSession imports torch+av in a worker thread; the "
    "test runner segfaults during import. Production is unaffected — only "
    "the test-time import cascade is broken. Refactor to fully-mocked "
    "meeting_factory tracked as future work."
)
def test_meeting_start_status_stop():
    """meeting_start → status reflects 'meeting' → stop returns stopped:<id>."""
    d = _build()
    resp, _ = _handle_cmd(d, "meeting_start")
    assert resp.startswith("started:")
    status, _ = _handle_cmd(d, "status")
    assert status == "meeting"
    mstatus, _ = _handle_cmd(d, "meeting_status")
    assert mstatus.startswith("recording:")
    stop_resp, _ = _handle_cmd(d, "meeting_stop")
    assert stop_resp.startswith("stopped:")
    # After stop, meeting status falls back to idle.
    assert _handle_cmd(d, "meeting_status")[0] == "idle"


def test_clear_resets_conversation():
    """clear empties ConversationMemory."""
    d = _build()
    d.memory.add("¿hola?", "hola, soy axi")
    d.memory.add("test", "ok")
    assert d.memory.turn_count() == 2
    resp, _ = _handle_cmd(d, "clear")
    assert resp.startswith("cleared:")
    assert d.memory.turn_count() == 0


def test_quit_command_signals_shutdown():
    """quit returns 'bye' and the second tuple element is True."""
    d = _build()
    resp, should_quit = _handle_cmd(d, "quit")
    assert resp == "bye"
    assert should_quit is True


def test_unknown_command_is_reported_not_crashed():
    """Unknown commands surface as 'unknown:' without raising."""
    d = _build()
    resp, _ = _handle_cmd(d, "wat")
    assert resp.startswith("unknown:")


def test_default_construction_still_works(monkeypatch):
    """Smoke: Daemon() with no kwargs constructs without exploding.

    We stub the heavyweight pieces (Whisper, audio I/O) so this is cheap
    in CI but still proves the no-arg constructor path is wired.
    """
    from axi import daemon as d_mod

    class _NoopRecorder:
        def __init__(self): self._rec = False; self.active_source = None
        @property
        def is_recording(self): return self._rec
        def start(self): self._rec = True; return "noop"
        def stop(self):
            self._rec = False
            return np.zeros(SAMPLE_RATE, dtype=np.float32)

    class _NoopTranscriber:
        def __init__(self): pass
        def transcribe(self, audio): return ("", "es", 1.0)

    monkeypatch.setattr(d_mod, "Recorder", _NoopRecorder)
    monkeypatch.setattr(d_mod, "Transcriber", _NoopTranscriber)
    d = Daemon()
    assert d.state == "idle"
    assert callable(d.brain_ask)
    assert callable(d.vision_capture)
    assert callable(d.eyes_capture)
    assert callable(d.meeting_factory)


# ──────────────────────────────────────────────────────────────────────────────
# PR1 — Never-hang guard tests (Phase 1.1)
# ──────────────────────────────────────────────────────────────────────────────

class _ErrorTranscriber:
    """FakeTranscriber that raises a given exception on transcribe()."""

    def __init__(self, exc: BaseException) -> None:
        self._exc = exc
        self.calls = 0

    def transcribe(self, audio: np.ndarray) -> tuple[str, str, float]:
        self.calls += 1
        raise self._exc


def _run_toggle_cycle(d: Daemon) -> str:
    """Start + stop recording via toggle×2, wait for idle."""
    _handle_cmd(d, "toggle")   # start recording
    _handle_cmd(d, "toggle")   # stop → transcribe in bg thread
    return _wait_idle(d)


def test_stop_and_transcribe_whisper_service_error(monkeypatch):
    """WhisperServiceError during transcription → daemon returns to idle.

    Phase 1.1.1 — RED test. Must FAIL before try/except is added to daemon.
    """
    from axi.whisper_client import WhisperServiceError
    tx = _ErrorTranscriber(WhisperServiceError("server gone"))
    d = _build(transcriber=tx)
    final = _run_toggle_cycle(d)
    assert final == "idle", f"state stuck at {final!r}"
    assert tx.calls == 1


def test_stop_and_transcribe_broken_pipe_error(monkeypatch):
    """BrokenPipeError during transcription → daemon returns to idle.

    Phase 1.1.2 — RED test.
    """
    tx = _ErrorTranscriber(BrokenPipeError("pipe broken"))
    d = _build(transcriber=tx)
    final = _run_toggle_cycle(d)
    assert final == "idle", f"state stuck at {final!r}"


def test_stop_and_transcribe_generic_exception(monkeypatch):
    """Any Exception during transcription → daemon returns to idle.

    Phase 1.1.3 — RED test. Also asserts that the notify mock was called
    (error notification surfaced to user).
    """
    notify_calls: list[dict] = []
    from axi import daemon as d_mod
    monkeypatch.setattr(d_mod, "notify", lambda *a, **kw: notify_calls.append({"args": a, "kwargs": kw}))

    tx = _ErrorTranscriber(RuntimeError("boom"))
    d = _build(transcriber=tx)
    final = _run_toggle_cycle(d)
    assert final == "idle", f"state stuck at {final!r}"
    # At least one notify call should carry an error indication.
    assert any("error" in str(c).lower() or "Error" in str(c) for c in notify_calls), \
        f"expected error notification, got: {notify_calls}"


def test_stop_and_transcribe_success_reaches_idle():
    """Success path ends in idle (non-regression anchor).

    Phase 1.1.4 — should PASS before and after the guard is added.
    """
    tx = FakeTranscriber(text="probando")
    d = _build(transcriber=tx)
    final = _run_toggle_cycle(d)
    assert final == "idle"
    assert tx.calls == 1


def test_stop_and_ask_error_leaves_idle(monkeypatch):
    """Exception in _stop_and_ask → daemon returns to idle.

    Phase 1.1.5 — RED test.
    """
    from axi import daemon as d_mod
    monkeypatch.setattr(d_mod, "notify", lambda *a, **kw: None)

    tx = _ErrorTranscriber(RuntimeError("ask-boom"))
    d = _build(transcriber=tx)
    _handle_cmd(d, "ask")   # start recording (ask mode)
    _handle_cmd(d, "ask")   # stop → _stop_and_ask in bg thread
    final = _wait_idle(d)
    assert final == "idle", f"state stuck at {final!r}"


def test_stop_and_ask_success_does_not_clobber_thinking_speaking():
    """Happy path of _stop_and_ask ends in idle (speaking→idle via TTS thread).

    Phase 1.1.6 — guard must NOT clobber the legitimate speaking/idle path.
    This must PASS before and after the guard is added.
    """
    tx = FakeTranscriber(text="¿cuál es la capital de Francia?")
    d = _build(transcriber=tx)
    _handle_cmd(d, "ask")
    _handle_cmd(d, "ask")   # stop → _stop_and_ask in bg
    # speaking→idle is the happy-path terminal; _wait_idle accepts idle.
    final = _wait_idle(d, timeout=4.0)
    assert final == "idle", f"expected idle, got {final!r}"


# ──────────────────────────────────────────────────────────────────────────────
# PR1 — Watchdog tests (Phase 1.2)
# ──────────────────────────────────────────────────────────────────────────────

class _BlockingTranscriber:
    """Transcriber that blocks until an Event is set (simulates infinite hang)."""

    def __init__(self) -> None:
        self.unblock = threading.Event()
        self.calls = 0
        self.started = threading.Event()

    def transcribe(self, audio: np.ndarray) -> tuple[str, str, float]:
        self.calls += 1
        self.started.set()
        self.unblock.wait()   # blocks until test releases it
        return "never", "es", 0.0


def test_watchdog_forces_idle_on_timeout(monkeypatch):
    """Watchdog fires after WATCHDOG_TIMEOUT_S → forces idle + error notify.

    Phase 1.2.1 — RED test. Must FAIL before watchdog is implemented.
    """
    import axi.daemon as d_mod
    monkeypatch.setattr(d_mod, "WATCHDOG_TIMEOUT_S", 0.05)

    notify_calls: list[dict] = []
    monkeypatch.setattr(d_mod, "notify", lambda *a, **kw: notify_calls.append({"args": a, "kwargs": kw}))

    tx = _BlockingTranscriber()
    d = _build(transcriber=tx)
    _handle_cmd(d, "toggle")   # start
    _handle_cmd(d, "toggle")   # stop → _stop_and_transcribe bg thread

    # Wait for transcriber to enter its blocking wait.
    tx.started.wait(timeout=2.0)

    # Watchdog should fire after ~50ms (monkeypatched); give 500ms margin.
    deadline = time.time() + 0.5
    while time.time() < deadline:
        if d.state == "idle":
            break
        time.sleep(0.02)

    # Unblock the transcriber so its thread doesn't leak.
    tx.unblock.set()

    assert d.state == "idle", f"watchdog did not fire; state={d.state!r}"
    assert any("error" in str(c).lower() or "timeout" in str(c).lower()
               or "watchdog" in str(c).lower() or "Error" in str(c)
               for c in notify_calls), \
        f"expected error/timeout notification, got: {notify_calls}"


def test_watchdog_does_not_fire_on_fast_completion():
    """Fast transcription completes before watchdog timeout — watchdog must
    NOT fire spuriously (no extra idle transition).

    Phase 1.2.2 — RED test. Passes implicitly once watchdog is correct.
    """
    tx = FakeTranscriber(text="rápido")
    d = _build(transcriber=tx)
    final = _run_toggle_cycle(d)
    # State should be idle from normal flow, not from watchdog.
    assert final == "idle"
    assert tx.calls == 1


def test_watchdog_armed_disarmed_via_set_state(monkeypatch):
    """_set_state(\"transcribing\") arms watchdog; _set_state(\"idle\") disarms it.

    Phase 1.2.3 — RED test. Must FAIL before _set_state integrates watchdog.
    """
    import axi.daemon as d_mod
    # Use a long timeout so it never accidentally fires during the test.
    monkeypatch.setattr(d_mod, "WATCHDOG_TIMEOUT_S", 300.0)

    arm_calls: list[str] = []
    disarm_calls: list[str] = []

    d = _build()

    original_arm = getattr(d, "_arm_watchdog", None)
    original_disarm = getattr(d, "_disarm_watchdog", None)

    # If the methods don't exist yet the test fails here (RED).
    assert original_arm is not None, "_arm_watchdog method not found on Daemon"
    assert original_disarm is not None, "_disarm_watchdog method not found on Daemon"

    import unittest.mock as mock
    with mock.patch.object(d, "_arm_watchdog", wraps=d._arm_watchdog) as mock_arm, \
         mock.patch.object(d, "_disarm_watchdog", wraps=d._disarm_watchdog) as mock_disarm:
        d._set_state("transcribing")
        assert mock_arm.called, "_arm_watchdog not called when entering transcribing"
        d._set_state("idle")
        assert mock_disarm.called, "_disarm_watchdog not called when leaving transcribing"


# ──────────────────────────────────────────────────────────────────────────────
# Voice-path confirmation localization
# ──────────────────────────────────────────────────────────────────────────────

def _lang_config_get(lang):
    """Fake axi.config.get with a fixed UI language and real-ish defaults."""
    values = {
        "language": lang,
        "timezone": "America/Mexico_City",
        "reminder_voice_enabled": False,   # keep the fastpath out of intent tests
        "intents_enabled": True,
        "intents_brain_fallback_enabled": False,
    }
    return lambda key, default=None: values.get(key, default)


def _capture_notify(monkeypatch) -> list[tuple]:
    from axi import daemon as d_mod
    calls: list[tuple] = []
    monkeypatch.setattr(d_mod, "notify", lambda *a, **kw: calls.append((a, kw)))
    return calls


def _run_intent_dictation(monkeypatch, whisper_lang: str) -> list[tuple]:
    """Dictation toggle cycle where the utterance matches an intent."""
    from axi import daemon as d_mod, intents as i_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("es-MX"))
    monkeypatch.setattr(i_mod, "classify", lambda text, **kw: ("open_dashboard", {}))
    monkeypatch.setitem(i_mod.INTENT_HANDLERS, "open_dashboard", lambda d, p: "ok")
    calls = _capture_notify(monkeypatch)

    tx = FakeTranscriber(text="axi abre el dashboard", lang=whisper_lang)
    d = _build(transcriber=tx)
    _run_toggle_cycle(d)
    return calls


def test_intent_confirmation_english_when_utterance_english(monkeypatch):
    """Whisper detects English → 'Action executed', not 'Acción ejecutada'."""
    calls = _run_intent_dictation(monkeypatch, whisper_lang="en")
    bodies = [str(a) for a, _ in calls]
    assert any("Action executed: open_dashboard" in b for b in bodies), \
        f"expected English confirmation, got: {bodies}"
    assert not any("Acción ejecutada" in b for b in bodies)


def test_intent_confirmation_spanish_when_utterance_spanish(monkeypatch):
    """Whisper detects Spanish → original Spanish confirmation, unchanged."""
    calls = _run_intent_dictation(monkeypatch, whisper_lang="es")
    bodies = [str(a) for a, _ in calls]
    assert any("Acción ejecutada: open_dashboard" in b for b in bodies), \
        f"expected Spanish confirmation, got: {bodies}"


def test_camera_busy_notify_localized(monkeypatch):
    """_start_look camera-busy notify follows the configured language."""
    from axi import daemon as d_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("en-US"))
    calls = _capture_notify(monkeypatch)
    d = _build(eyes_capture=lambda: (None, "busy:zoom"))
    resp = d._start_look()
    assert resp == "camera-busy"
    bodies = [str(a) for a, _ in calls]
    assert any("zoom" in b for b in bodies)
    assert not any("No puedo ver" in b for b in bodies), \
        f"expected English camera-busy notify, got: {bodies}"


def test_camera_busy_notify_spanish_unchanged(monkeypatch):
    from axi import daemon as d_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("es-MX"))
    calls = _capture_notify(monkeypatch)
    d = _build(eyes_capture=lambda: (None, "busy:"))  # empty holder → 'otra app'
    resp = d._start_look()
    assert resp == "camera-busy"
    bodies = [str(a) for a, _ in calls]
    assert any("No puedo ver — la cámara la usa otra app (¿reunión activa?)" in b
               for b in bodies), f"got: {bodies}"


def test_meeting_start_notify_localized(monkeypatch):
    """meeting_start confirmation follows the configured language."""
    from axi import daemon as d_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("en-US"))
    calls = _capture_notify(monkeypatch)
    d = _build()
    monkeypatch.setattr(d, "_pause_wakeword_for_meeting", lambda: None)
    resp = d.meeting_start()
    assert resp == "started:42"
    bodies = [str(a) for a, _ in calls]
    assert any("Meeting mode active" in b and "#42" in b for b in bodies), \
        f"expected English meeting notify, got: {bodies}"
    assert not any("Modo reunión activo" in b for b in bodies)


def test_meeting_start_notify_spanish_unchanged(monkeypatch):
    from axi import daemon as d_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("es-MX"))
    calls = _capture_notify(monkeypatch)
    d = _build()
    monkeypatch.setattr(d, "_pause_wakeword_for_meeting", lambda: None)
    resp = d.meeting_start()
    assert resp == "started:42"
    bodies = [str(a) for a, _ in calls]
    assert any("🎙️📷 Modo reunión activo (id #42)" in b for b in bodies), \
        f"got: {bodies}"


def test_dictation_intent_sets_utterance_lang(monkeypatch):
    """The dictation path exposes whisper's detected lang to intent handlers."""
    from axi import daemon as d_mod, intents as i_mod

    monkeypatch.setattr(d_mod.config, "get", _lang_config_get("es-MX"))
    monkeypatch.setattr(i_mod, "classify", lambda text, **kw: ("open_dashboard", {}))
    seen: list = []
    monkeypatch.setitem(
        i_mod.INTENT_HANDLERS, "open_dashboard",
        lambda d, p: seen.append(getattr(d, "_utterance_lang", None)) or "ok",
    )
    _capture_notify(monkeypatch)

    tx = FakeTranscriber(text="axi abre el dashboard", lang="en")
    d = _build(transcriber=tx)
    _run_toggle_cycle(d)
    assert seen == ["en"], f"handler saw _utterance_lang={seen!r}"


# ───────────── reflejo: self-improve deferral gate ─────────────

class TestSelfImprovePreFire:
    """The reflex gate before the nightly self-improve run.

    A stressed body defers the run WITHOUT burning the once-per-day marker
    (so the next 30-min tick retries); a calm body burns the marker and
    proceeds; a broken reflex NEVER blocks the pipeline (fail-open).
    """

    def test_deferral_skips_and_keeps_day_marker(self, monkeypatch):
        from axi import daemon as d_mod, interoception
        monkeypatch.setattr(
            interoception, "heavy_work_deferral", lambda: "GPU a 93 °C"
        )
        logged: list[str] = []
        from axi import events
        monkeypatch.setattr(
            events, "log_info",
            lambda source, message, data=None: logged.append(message),
        )
        state = {"last_date": None}
        assert d_mod._self_improve_pre_fire(state, "2026-07-13") is False
        assert state["last_date"] is None  # marker NOT burned → retry later
        assert logged == ["reflejo: self-improve diferido — GPU a 93 °C"]

    def test_calm_body_burns_marker_and_proceeds(self, monkeypatch):
        from axi import daemon as d_mod, interoception
        monkeypatch.setattr(interoception, "heavy_work_deferral", lambda: None)
        state = {"last_date": None}
        assert d_mod._self_improve_pre_fire(state, "2026-07-13") is True
        assert state["last_date"] == "2026-07-13"

    def test_reflex_error_fails_open(self, monkeypatch):
        from axi import daemon as d_mod, interoception

        def boom():
            raise RuntimeError("sensors exploded")

        monkeypatch.setattr(interoception, "heavy_work_deferral", boom)
        state = {"last_date": None}
        assert d_mod._self_improve_pre_fire(state, "2026-07-13") is True
        assert state["last_date"] == "2026-07-13"

    def test_events_log_failure_still_defers(self, monkeypatch):
        from axi import daemon as d_mod, events, interoception
        monkeypatch.setattr(
            interoception, "heavy_work_deferral", lambda: "modo juego activo"
        )

        def boom(*a, **k):
            raise RuntimeError("events db locked")

        monkeypatch.setattr(events, "log_info", boom)
        state = {"last_date": None}
        assert d_mod._self_improve_pre_fire(state, "2026-07-13") is False
        assert state["last_date"] is None
