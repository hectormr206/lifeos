"""Tests for the posture domain (P6.2).

Brain is mocked — we don't need a real camera or LLM for the logic.
We test:
  - DAO: encryption, roundtrip, cooldown, summary.
  - Analyze: parses good JSON, falls back to 'error' on bad JSON / no image.
  - Cron run_scan_now: end-to-end happy path + cooldown suppression.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_POSTURE_DB_PATH", str(tmp_path / "posture.db"))
    monkeypatch.setenv("LIFEOS_POSTURE_KEY_PATH", str(tmp_path / "posture.key"))
    from lifeos.posture import store
    store.apply_migrations()
    yield


# ─── DAO ─────────────────────────────────────────────────────────────


def test_db_is_encrypted() -> None:
    from lifeos.posture import store, scans
    scans.create(when=datetime.now(timezone.utc), state="good", confidence=0.9)
    raw = store.db_path().read_bytes()
    assert not raw.startswith(b"SQLite format 3"), "encryption broken"


def test_create_roundtrip() -> None:
    from lifeos.posture import scans
    s = scans.create(
        when=datetime.now(timezone.utc),
        state="slouched", confidence=0.85,
        suggestion="hombros atrás, espalda recta",
        nudge_sent=True, source="scheduled",
        raw_response='{"state":"slouched"}',
    )
    fetched = scans.get(s.id)
    assert fetched is not None
    assert fetched.state == "slouched"
    assert fetched.is_problematic is True
    assert fetched.nudge_sent is True


def test_create_rejects_invalid_state() -> None:
    from lifeos.posture import scans
    with pytest.raises(ValueError):
        scans.create(when=datetime.now(timezone.utc), state="purple", confidence=0.5)


def test_create_rejects_confidence_out_of_range() -> None:
    from lifeos.posture import scans
    with pytest.raises(ValueError):
        scans.create(when=datetime.now(timezone.utc), state="good", confidence=1.5)


def test_cooldown_after_nudge() -> None:
    from lifeos.posture import scans
    scans.create(when=datetime.now(timezone.utc), state="slouched",
                 confidence=0.9, nudge_sent=True)
    assert scans.in_cooldown(minutes=30) is True
    assert scans.in_cooldown(minutes=0) is False  # zero-minute cooldown is always elapsed


def test_no_cooldown_without_nudge() -> None:
    from lifeos.posture import scans
    scans.create(when=datetime.now(timezone.utc), state="good", confidence=0.9)
    assert scans.in_cooldown(minutes=30) is False


def test_summary_aggregates() -> None:
    from lifeos.posture import scans
    now = datetime.now(timezone.utc)
    scans.create(when=now, state="good", confidence=0.9)
    scans.create(when=now, state="slouched", confidence=0.8, nudge_sent=True)
    scans.create(when=now, state="good", confidence=0.95)
    s = scans.summary(days=7)
    assert s["total_scans"] == 3
    assert s["nudges_sent"] == 1
    assert s["by_state"]["good"] == 2
    assert s["by_state"]["slouched"] == 1


# ─── Analyze (mocked brain) ──────────────────────────────────────────


def test_analyze_parses_good_json() -> None:
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return '{"state":"slouched","confidence":0.82,"suggestion":"sentate derecho"}'
    r = analyze_frame(image_b64="fakeimg", brain_ask=fake_brain)
    assert r.state == "slouched"
    assert r.confidence == 0.82
    assert "sentate" in r.suggestion.lower()
    assert r.error is None


def test_analyze_parses_json_in_codefence() -> None:
    """Models often wrap JSON in markdown code fences."""
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return '```json\n{"state":"good","confidence":0.95,"suggestion":""}\n```'
    r = analyze_frame(image_b64="x", brain_ask=fake_brain)
    assert r.state == "good"


def test_analyze_parses_json_with_prose_around() -> None:
    """Sometimes the model adds explanatory text before/after the JSON."""
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return ('Analizando la imagen... '
                '{"state":"forward_head","confidence":0.7,"suggestion":"acercá la pantalla"} '
                'eso es todo.')
    r = analyze_frame(image_b64="x", brain_ask=fake_brain)
    assert r.state == "forward_head"
    assert r.confidence == 0.7


def test_analyze_returns_error_on_bad_json() -> None:
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return "no soy json"
    r = analyze_frame(image_b64="x", brain_ask=fake_brain)
    assert r.state == "error"
    assert r.error is not None


def test_analyze_returns_error_on_unknown_state() -> None:
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return '{"state":"jumping","confidence":0.9,"suggestion":""}'
    r = analyze_frame(image_b64="x", brain_ask=fake_brain)
    assert r.state == "error"


def test_analyze_returns_error_on_empty_image() -> None:
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return '{}'
    r = analyze_frame(image_b64="", brain_ask=fake_brain)
    assert r.state == "error"
    assert "empty" in (r.error or "").lower()


def test_analyze_clamps_confidence_to_range() -> None:
    from lifeos.posture.analyze import analyze_frame
    def fake_brain(prompt: str, **kw: Any) -> str:
        return '{"state":"good","confidence":2.5,"suggestion":""}'
    r = analyze_frame(image_b64="x", brain_ask=fake_brain)
    assert r.state == "good"
    assert r.confidence == 1.0


# ─── Cron run_scan_now ────────────────────────────────────────────────


def test_cron_run_records_scan_with_nudge() -> None:
    from lifeos.posture import cron, scans
    pushes: list[tuple[str, str]] = []
    cron.configure(
        capture_fn=lambda: "fake-image-b64",
        brain_ask=lambda prompt, **kw: '{"state":"slouched","confidence":0.85,"suggestion":"estírate"}',
        push_fn=lambda title, body: pushes.append((title, body)),
        is_enabled_fn=lambda: True,
        cooldown_minutes=30,
        confidence_threshold=0.6,
    )
    s = cron.run_scan_now(source="manual")
    assert s.state == "slouched"
    assert s.nudge_sent is True
    assert len(pushes) == 1
    assert "estírate" in pushes[0][1].lower() or "estirate" in pushes[0][1].lower()


def test_cron_run_records_no_nudge_when_state_good() -> None:
    from lifeos.posture import cron
    pushes: list = []
    cron.configure(
        capture_fn=lambda: "x",
        brain_ask=lambda prompt, **kw: '{"state":"good","confidence":0.95,"suggestion":""}',
        push_fn=lambda title, body: pushes.append((title, body)),
        is_enabled_fn=lambda: True,
    )
    s = cron.run_scan_now()
    assert s.state == "good"
    assert s.nudge_sent is False
    assert len(pushes) == 0


def test_cron_respects_cooldown() -> None:
    """If a recent nudge was sent, subsequent problematic scans don't re-nudge."""
    from lifeos.posture import cron, scans
    pushes: list = []
    cron.configure(
        capture_fn=lambda: "x",
        brain_ask=lambda prompt, **kw: '{"state":"slouched","confidence":0.9,"suggestion":"x"}',
        push_fn=lambda title, body: pushes.append((title, body)),
        is_enabled_fn=lambda: True,
        cooldown_minutes=60,
    )
    s1 = cron.run_scan_now()
    s2 = cron.run_scan_now()
    assert s1.nudge_sent is True
    assert s2.nudge_sent is False
    assert len(pushes) == 1


def test_cron_records_capture_error() -> None:
    from lifeos.posture import cron
    cron.configure(
        capture_fn=lambda: "",   # empty frame
        brain_ask=lambda prompt, **kw: '{}',
        push_fn=lambda t, b: None,
        is_enabled_fn=lambda: True,
    )
    s = cron.run_scan_now()
    assert s.state == "error"
    assert "no camera" in (s.error or "").lower()
