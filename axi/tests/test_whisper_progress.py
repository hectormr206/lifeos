"""PR3 progress tests: _progress_fraction + _write_progress atomic write.

Phase 3.1 — RED tests for:
  3.1.1  _progress_fraction(0, 100) → 0.0
  3.1.2  _progress_fraction(30, 100) → 0.3
  3.1.3  _progress_fraction(120, 100) → 1.0  (clamp above 1)
  3.1.4  _progress_fraction(0, 0) → 0.0  (zero-duration guard)
  3.1.5  _progress_fraction(-5, 100) → 0.0  (negative clamp)
  3.1.6  write_read progress roundtrip — atomic tmp+rename, json shape

All tests use tmp filesystem (tmp_path fixture) — no real state dir touched.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.1.1–3.1.5 — _progress_fraction pure function
# ─────────────────────────────────────────────────────────────────────────────

def test_progress_fraction_zero_end():
    """0 / 100 = 0.0."""
    from axi.whisper_server import _progress_fraction
    assert _progress_fraction(0.0, 100.0) == 0.0


def test_progress_fraction_mid():
    """30 / 100 = 0.3."""
    from axi.whisper_server import _progress_fraction
    result = _progress_fraction(30.0, 100.0)
    assert abs(result - 0.3) < 1e-9


def test_progress_fraction_clamp_above_one():
    """seg.end > duration (e.g. VAD rounding) → clamp to 1.0."""
    from axi.whisper_server import _progress_fraction
    assert _progress_fraction(120.0, 100.0) == 1.0


def test_progress_fraction_zero_duration():
    """duration=0 must return 0.0 (no division by zero crash)."""
    from axi.whisper_server import _progress_fraction
    assert _progress_fraction(0.0, 0.0) == 0.0


def test_progress_fraction_negative_end():
    """Negative end → clamp to 0.0."""
    from axi.whisper_server import _progress_fraction
    assert _progress_fraction(-5.0, 100.0) == 0.0


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.1.6 — write/read progress roundtrip (atomic)
# ─────────────────────────────────────────────────────────────────────────────

def test_write_read_progress_roundtrip(tmp_path, monkeypatch):
    """_write_progress writes a valid JSON file via atomic tmp+rename.

    Asserts:
    - The final path contains valid JSON with fraction, partial_text, ts.
    - No leftover .tmp file after the call.
    - The write is atomic (tmp file replaced, not written in-place).
    """
    import axi.whisper_server as ws

    progress_path = tmp_path / "whisper_progress.json"
    tmp_progress_path = tmp_path / "whisper_progress.json.tmp"

    # Redirect the module-level constant to tmp_path
    monkeypatch.setattr(ws, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(ws, "PROGRESS_TMP_FILE", tmp_progress_path)

    ws._write_progress(0.42, "partial text here")

    # No leftover tmp file
    assert not tmp_progress_path.exists(), "tmp file must not remain after atomic rename"

    # Final file has correct shape
    data = json.loads(progress_path.read_text())
    assert abs(data["fraction"] - 0.42) < 1e-9
    assert data["partial_text"] == "partial text here"
    assert "ts" in data
    assert isinstance(data["ts"], float)


def test_write_progress_clear(tmp_path, monkeypatch):
    """_clear_progress unlinks the progress file; missing file is OK (no crash)."""
    import axi.whisper_server as ws

    progress_path = tmp_path / "whisper_progress.json"
    tmp_progress_path = tmp_path / "whisper_progress.json.tmp"

    monkeypatch.setattr(ws, "PROGRESS_FILE", progress_path)
    monkeypatch.setattr(ws, "PROGRESS_TMP_FILE", tmp_progress_path)

    # Write then clear
    ws._write_progress(0.5, "hello")
    assert progress_path.exists()
    ws._clear_progress()
    assert not progress_path.exists()

    # Clear again with no file → no crash
    ws._clear_progress()
