"""PR3 daemon progress poller tests.

Phase 3.2 — RED tests for:
  3.2.1  Poller reads fraction 0.42 from progress file → state becomes "transcribing:42"
  3.2.2  Poller with malformed JSON → no crash, state stays "transcribing" (generic)
  3.2.3  Poller with missing file → no crash, state stays "transcribing" (generic)

W1 integration fix:
  3.2.4  _stop_and_transcribe wires _ProgressPoller end-to-end:
         state reaches "transcribing:42" DURING transcription and
         returns to "idle" after; poller thread is not alive after return.
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from tests.test_daemon import _build, FakeTranscriber, FakeRecorder


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _wait_for_state(daemon, prefix: str, timeout: float = 2.0) -> bool:
    """Poll until daemon.state starts with prefix, or timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if daemon.state.startswith(prefix):
            return True
        time.sleep(0.05)
    return False


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.2.1 — fraction 0.42 → state "transcribing:42"
# ─────────────────────────────────────────────────────────────────────────────

def test_progress_state_updates(tmp_path, monkeypatch):
    """Progress file with fraction=0.42 → daemon state becomes 'transcribing:42'.

    Phase 3.2.1 — RED. Must FAIL before _ProgressPoller exists in daemon.py.
    """
    import axi.daemon as d

    progress_path = tmp_path / "whisper_progress.json"
    monkeypatch.setattr(d, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(d, "PROGRESS_POLL_INTERVAL_S", 0.1)

    daemon = _build()

    # Manually set state to "transcribing" (as _stop_and_transcribe would do)
    daemon._set_state("transcribing")

    # Write a progress file with 42%
    progress_path.write_text(json.dumps({"fraction": 0.42, "partial_text": "hello", "ts": time.time()}))

    # Start the poller
    stop_event = threading.Event()
    poller = d._ProgressPoller(daemon, stop_event)
    poller.start()

    try:
        # Wait for the state to update to "transcribing:42"
        reached = _wait_for_state(daemon, "transcribing:42", timeout=2.0)
        assert reached, f"expected 'transcribing:42' but got '{daemon.state}'"
    finally:
        stop_event.set()
        poller.join(timeout=2.0)


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.2.2 — malformed JSON → no crash, state stays "transcribing"
# ─────────────────────────────────────────────────────────────────────────────

def test_progress_poller_malformed_json(tmp_path, monkeypatch):
    """Malformed progress file must not crash the poller; state stays 'transcribing'.

    Phase 3.2.2 — RED.
    """
    import axi.daemon as d

    progress_path = tmp_path / "whisper_progress.json"
    monkeypatch.setattr(d, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(d, "PROGRESS_POLL_INTERVAL_S", 0.05)

    # Write malformed JSON
    progress_path.write_text("{invalid json ][")

    daemon = _build()
    daemon._set_state("transcribing")

    stop_event = threading.Event()
    poller = d._ProgressPoller(daemon, stop_event)
    poller.start()

    # Let the poller run for a few cycles
    time.sleep(0.3)
    stop_event.set()
    poller.join(timeout=2.0)

    # Must not have crashed — state still "transcribing" (generic, no suffix)
    assert daemon.state.startswith("transcribing"), \
        f"expected state to start with 'transcribing', got '{daemon.state}'"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.2.3 — missing file → no crash, state stays "transcribing"
# ─────────────────────────────────────────────────────────────────────────────

def test_progress_poller_missing_file(tmp_path, monkeypatch):
    """Missing progress file must not crash the poller.

    Phase 3.2.3 — RED.
    """
    import axi.daemon as d

    progress_path = tmp_path / "whisper_progress_MISSING.json"
    monkeypatch.setattr(d, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(d, "PROGRESS_POLL_INTERVAL_S", 0.05)

    daemon = _build()
    daemon._set_state("transcribing")

    stop_event = threading.Event()
    poller = d._ProgressPoller(daemon, stop_event)
    poller.start()

    time.sleep(0.3)
    stop_event.set()
    poller.join(timeout=2.0)

    assert daemon.state.startswith("transcribing"), \
        f"expected state to start with 'transcribing', got '{daemon.state}'"


# ─────────────────────────────────────────────────────────────────────────────
# W1 Integration fix — 3.2.4
# _stop_and_transcribe must start _ProgressPoller before calling transcribe()
# ─────────────────────────────────────────────────────────────────────────────

class _BlockingTranscriber:
    """FakeTranscriber that blocks until released, writing a progress file midway.

    The ``ready`` event fires as soon as ``transcribe()`` is entered, so the
    test can wait for the daemon to be *inside* the transcription call before
    asserting state.  The ``release`` event unblocks the return.
    """

    def __init__(self, progress_path: Path, text: str = "hello world") -> None:
        self._progress_path = progress_path
        self._text = text
        self.ready = threading.Event()
        self.release = threading.Event()

    def transcribe(self, audio):  # noqa: ANN001
        # Write a 42% progress file immediately on entry.
        self._progress_path.write_text(
            json.dumps({"fraction": 0.42, "partial_text": "hello", "ts": time.time()})
        )
        self.ready.set()
        self.release.wait(timeout=5.0)
        return self._text, "en", 0.95


def test_stop_and_transcribe_wires_progress_poller(tmp_path, monkeypatch):
    """End-to-end: _stop_and_transcribe starts _ProgressPoller and state reaches
    'transcribing:42' while transcribing, then 'idle' after, and the poller
    thread is not alive after the call returns.

    Phase W1 / 3.2.4 — RED before wiring the poller in _stop_and_transcribe,
    GREEN after.
    """
    import axi.daemon as d

    progress_path = tmp_path / "whisper_progress.json"
    monkeypatch.setattr(d, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(d, "PROGRESS_POLL_INTERVAL_S", 0.05)

    transcriber = _BlockingTranscriber(progress_path)
    daemon = _build(transcriber=transcriber)

    # Run _stop_and_transcribe in a background thread so we can observe state.
    result_holder: list = []

    def _run():
        result_holder.append(daemon._stop_and_transcribe())

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()

    # Wait until the transcriber is inside transcribe() (progress file written).
    assert transcriber.ready.wait(timeout=3.0), "transcriber never entered transcribe()"

    # Give the poller a few poll cycles (≥3 × 0.05s = 0.15s).
    time.sleep(0.3)

    # ASSERT: state must be "transcribing:42" — poller fired and updated it.
    mid_state = daemon.state
    assert mid_state == "transcribing:42", (
        f"expected 'transcribing:42' mid-transcription, got '{mid_state}'. "
        "Likely cause: _ProgressPoller not started inside _stop_and_transcribe."
    )

    # Release the transcriber so _stop_and_transcribe can return.
    transcriber.release.set()
    thread.join(timeout=5.0)

    # ASSERT: state returned to "idle".
    assert daemon.state == "idle", f"expected 'idle' after transcription, got '{daemon.state}'"

    # ASSERT: poller thread is not alive (no leak).
    # We need to fish the poller reference out of d's module — instead we rely
    # on the daemon having cleaned up: if the finally block set stop_event and
    # joined, no progress-poller thread should be alive.
    alive_pollers = [
        t for t in threading.enumerate()
        if t.name == "axi-progress-poller" and t.is_alive()
    ]
    assert alive_pollers == [], (
        f"poller thread still alive after _stop_and_transcribe returned: {alive_pollers}"
    )
