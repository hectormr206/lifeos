"""HTTP-level tests for /api/health/entries endpoints.

Covers:
  GET /api/health/entries (list, kind filter, days filter, q search)
  POST /api/health/entries (success + validation failures)
  DELETE /api/health/entries/{eid} (soft delete)
  PATCH /api/health/entries/{eid} (edit: success + 404 + 400)

The lifeos health DB is isolated per-test via env var monkeypatching,
mirroring the pattern in test_reminders_e2e.py's `lifeos_isolated_db` fixture.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient


# ── fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def health_isolated_db(tmp_path, monkeypatch):
    """Redirect the health encrypted DB to a throw-away temp file."""
    db_path = tmp_path / "health-test.db"
    key_path = tmp_path / "health-test.key"
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(key_path))
    from lifeos.health import store as health_store
    health_store.apply_migrations()
    yield


@pytest.fixture
def client(monkeypatch, health_isolated_db):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)
    return TestClient(dashboard.app)


# ── helpers ───────────────────────────────────────────────────────────────────


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _create(client, *, kind="note", title="test entry", ts=None, **extra):
    payload = {"kind": kind, "title": title, "ts": ts or _now_iso(), **extra}
    r = client.post("/api/health/entries", json=payload)
    assert r.status_code == 200, r.text
    return r.json()


# ── GET /api/health/entries ───────────────────────────────────────────────────


def test_list_empty(client):
    r = client.get("/api/health/entries")
    assert r.status_code == 200
    assert r.json() == {"entries": []}


def test_list_returns_created_entry(client):
    _create(client, title="headache", kind="symptom")
    r = client.get("/api/health/entries")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["title"] == "headache"
    assert entries[0]["kind"] == "symptom"


def test_list_kind_filter(client):
    _create(client, kind="symptom", title="dolor")
    _create(client, kind="note", title="nota")
    r = client.get("/api/health/entries?kind=symptom")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["kind"] == "symptom"


def test_list_days_filter_excludes_old(client):
    old_ts = (datetime.now(timezone.utc) - timedelta(days=100)).isoformat()
    recent_ts = datetime.now(timezone.utc).isoformat()
    _create(client, title="old entry", ts=old_ts)
    _create(client, title="recent entry", ts=recent_ts)
    r = client.get("/api/health/entries?days=30")
    assert r.status_code == 200
    titles = [e["title"] for e in r.json()["entries"]]
    assert "recent entry" in titles
    assert "old entry" not in titles


def test_list_q_search(client):
    _create(client, title="dolor de garganta", kind="symptom")
    _create(client, title="nota diaria", kind="note")
    r = client.get("/api/health/entries?q=garganta")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert len(entries) == 1
    assert entries[0]["title"] == "dolor de garganta"


# ── POST /api/health/entries ──────────────────────────────────────────────────


def test_create_success(client):
    payload = {
        "kind": "symptom",
        "title": "headache",
        "ts": _now_iso(),
        "body": "mild",
        "tags": ["morning"],
        "source": "manual",
    }
    r = client.post("/api/health/entries", json=payload)
    assert r.status_code == 200
    data = r.json()
    assert data["id"]
    assert data["title"] == "headache"
    assert data["kind"] == "symptom"
    assert data["tags"] == ["morning"]
    assert data["source"] == "manual"


def test_create_bad_kind_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "banana", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_create_missing_title_returns_400(client):
    r = client.post("/api/health/entries", json={"kind": "note", "ts": _now_iso()})
    assert r.status_code == 400


def test_create_missing_ts_returns_400(client):
    r = client.post("/api/health/entries", json={"kind": "note", "title": "x"})
    assert r.status_code == 400


def test_create_bad_ts_format_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": "not-a-date",
    })
    assert r.status_code == 400


def test_create_naive_ts_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": "2026-06-01T09:00:00",  # no TZ
    })
    assert r.status_code == 400


def test_create_title_too_long_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x" * 201, "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_create_bad_source_enum_returns_400(client):
    r = client.post("/api/health/entries", json={
        "kind": "note", "title": "x", "ts": _now_iso(), "source": "robot",
    })
    assert r.status_code == 400


# ── DELETE /api/health/entries/{eid} ─────────────────────────────────────────


def test_delete_soft_deletes(client):
    entry = _create(client, title="to-delete")
    eid = entry["id"]

    r = client.delete(f"/api/health/entries/{eid}")
    assert r.status_code == 200
    assert r.json()["deleted"] is True

    # No longer appears in list
    r = client.get("/api/health/entries")
    ids = [e["id"] for e in r.json()["entries"]]
    assert eid not in ids


def test_delete_nonexistent_returns_deleted_false(client):
    r = client.delete("/api/health/entries/nonexistent-id")
    assert r.status_code == 200
    assert r.json()["deleted"] is False


# ── PATCH /api/health/entries/{eid} ──────────────────────────────────────────


def test_patch_edits_fields(client):
    entry = _create(client, kind="note", title="original", ts=_now_iso())
    eid = entry["id"]

    new_ts = datetime.now(timezone.utc).isoformat()
    patch_payload = {
        "kind": "symptom",
        "title": "updated",
        "ts": new_ts,
        "body": "new body",
        "tags": ["x", "y"],
    }
    r = client.patch(f"/api/health/entries/{eid}", json=patch_payload)
    assert r.status_code == 200
    data = r.json()
    assert data["title"] == "updated"
    assert data["kind"] == "symptom"
    assert data["body"] == "new body"
    assert data["tags"] == ["x", "y"]


def test_patch_reflected_in_list(client):
    entry = _create(client, title="before")
    eid = entry["id"]

    client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "after", "ts": _now_iso(),
    })

    r = client.get("/api/health/entries")
    titles = [e["title"] for e in r.json()["entries"]]
    assert "after" in titles
    assert "before" not in titles


def test_patch_not_found_returns_404(client):
    r = client.patch("/api/health/entries/nonexistent-id", json={
        "kind": "note", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 404
    assert "not found" in r.json()["detail"].lower()


def test_patch_deleted_entry_returns_404(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    client.delete(f"/api/health/entries/{eid}")

    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "y", "ts": _now_iso(),
    })
    assert r.status_code == 404


def test_patch_bad_kind_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "banana", "title": "x", "ts": _now_iso(),
    })
    assert r.status_code == 400


def test_patch_naive_ts_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    r = client.patch(f"/api/health/entries/{eid}", json={
        "kind": "note", "title": "x", "ts": "2026-06-01T09:00:00",  # no TZ
    })
    assert r.status_code == 400


def test_patch_missing_required_fields_returns_400(client):
    entry = _create(client, title="x")
    eid = entry["id"]
    # Missing title and ts
    r = client.patch(f"/api/health/entries/{eid}", json={"kind": "note"})
    assert r.status_code == 400


# ── _try_nano_extract health branch — structured BP vitals ────────────────────
# Tests call the function directly (no HTTP) to keep setup minimal.
# The nano HTTP call is mocked via monkeypatch; the health DB is isolated
# via the health_isolated_db fixture already defined above.


def _make_extraction_result(**kwargs):
    """Build an ExtractionResult with health-domain defaults."""
    from lifeos.agents.extractor import ExtractionResult
    defaults = {
        "domain": "health",
        "kind": "vital",
        "title": None,
        "systolic": None,
        "diastolic": None,
        "pulse_bpm": None,
        "confidence": 0.65,
    }
    defaults.update(kwargs)
    return ExtractionResult(**defaults)


def test_nano_health_bp_creates_structured_vital(monkeypatch, health_isolated_db):
    """When nano returns systolic+diastolic, the health branch stores a
    structured blood_pressure vital (same data shape as the regex path)."""
    from lifeos.agents import extractor as nano_extractor
    from axi.dashboard import _try_nano_extract

    fake = _make_extraction_result(
        title="presión 122/81, pulso 53",
        systolic=122, diastolic=81, pulse_bpm=53,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("122/81 53 pulsos", None)

    assert out is not None
    assert out["domain"] == "health"
    assert "122/81" in out["answer"]

    # Verify the DB entry has the structured vital data
    from lifeos.health import entries as _he
    eid = out["entry_ids"][0]
    entry = _he.get(eid)
    assert entry is not None
    assert entry.kind == "vital"
    assert entry.data is not None
    assert entry.data["type"] == "blood_pressure"
    assert entry.data["systolic"] == 122
    assert entry.data["diastolic"] == 81
    assert entry.data["pulse_bpm"] == 53
    assert entry.data["unit"] == "mmHg"


def test_nano_health_bp_without_pulse(monkeypatch, health_isolated_db):
    """BP vital without pulse_bpm: entry data has no pulse_bpm key."""
    from lifeos.agents import extractor as nano_extractor
    from axi.dashboard import _try_nano_extract

    fake = _make_extraction_result(
        title="presión 120/80", systolic=120, diastolic=80, pulse_bpm=None,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("presión 120/80", None)

    assert out is not None
    eid = out["entry_ids"][0]
    from lifeos.health import entries as _he
    entry = _he.get(eid)
    assert entry.kind == "vital"
    assert entry.data["systolic"] == 120
    assert "pulse_bpm" not in entry.data


def test_nano_health_implausible_bp_falls_back_to_note(monkeypatch, health_isolated_db):
    """Implausible BP values (outside physiological range) must force kind="note",
    not create a vital entry with empty/missing BP data."""
    from lifeos.agents import extractor as nano_extractor
    from axi.dashboard import _try_nano_extract

    # sys=30 is below the 80 threshold; nano reports kind="vital" but values
    # fail the plausibility gate — the entry must be downgraded to "note".
    fake = _make_extraction_result(
        title="algo", kind="vital", systolic=30, diastolic=20,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("30/20", None)

    assert out is not None
    eid = out["entry_ids"][0]
    from lifeos.health import entries as _he
    entry = _he.get(eid)
    # Must be downgraded to "note" — no structured-looking vital with empty data
    assert entry.kind == "note"
    assert entry.data is None or entry.data.get("type") != "blood_pressure"


def test_nano_health_note_stays_note(monkeypatch, health_isolated_db):
    """A health note (no BP numbers) is persisted without structured data."""
    from lifeos.agents import extractor as nano_extractor
    from axi.dashboard import _try_nano_extract

    fake = _make_extraction_result(
        domain="health", kind="note", title="me siento cansado",
        systolic=None, diastolic=None,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("me siento cansado hoy", None)

    assert out is not None
    eid = out["entry_ids"][0]
    from lifeos.health import entries as _he
    entry = _he.get(eid)
    assert entry.kind == "note"
    # data is None or empty when no structured fields were set
    assert not entry.data


def test_nano_health_title_none_uses_original_text(monkeypatch, health_isolated_db):
    """When nano returns title=None for a health entry, the persisted entry title
    must use the ORIGINAL (pre-normalization) user text, not the normalized text."""
    from lifeos.agents import extractor as nano_extractor
    from axi.dashboard import _try_nano_extract

    # title=None forces the fallback; kind="note" avoids BP plausibility branch.
    fake = _make_extraction_result(
        domain="health", kind="note", title=None,
        systolic=None, diastolic=None,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    original = "Me duele la cabeza desde las 2hs"
    normalized = "me duele la cabeza desde las 02:00"  # different from original

    out = _try_nano_extract(normalized, None, original_text=original)

    assert out is not None
    from lifeos.health import entries as _he
    eid = out["entry_ids"][0]
    entry = _he.get(eid)
    # Title must be derived from original_text, not the normalized text.
    assert entry.title.startswith(original[:20])


# ── Task 2: sleep/weight/glucose nano health vitals ───────────────────────────


def test_nano_health_sleep_creates_structured_vital(monkeypatch, health_isolated_db):
    """When nano returns sleep_hours, health branch stores a structured sleep vital."""
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult
    from axi.dashboard import _try_nano_extract

    fake = ExtractionResult(
        domain="health", kind="vital", title="sueño 8h",
        sleep_hours=8.0, weight_kg=None, glucose_mg_dl=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("Me dormí a las 11 pm y acabo de despertar", None)

    assert out is not None
    assert out["domain"] == "health"
    from lifeos.health import entries as _he
    entry = _he.get(out["entry_ids"][0])
    assert entry.kind == "vital"
    assert entry.data["type"] == "sleep_hours"
    assert entry.data["value"] == 8.0
    assert entry.data["unit"] == "h"


def test_nano_health_sleep_implausible_falls_to_note(monkeypatch, health_isolated_db):
    """sleep_hours outside 0.5-16 range must downgrade to note."""
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult
    from axi.dashboard import _try_nano_extract

    fake = ExtractionResult(
        domain="health", kind="vital", title="sueño 20h",
        sleep_hours=20.0,  # implausible
        weight_kg=None, glucose_mg_dl=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("dormí 20 horas", None)

    assert out is not None
    from lifeos.health import entries as _he
    entry = _he.get(out["entry_ids"][0])
    assert entry.kind == "note"


def test_nano_health_weight_creates_structured_vital(monkeypatch, health_isolated_db):
    """When nano returns weight_kg, health branch stores a structured weight vital."""
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult
    from axi.dashboard import _try_nano_extract

    fake = ExtractionResult(
        domain="health", kind="vital", title="peso 64.5 kg",
        weight_kg=64.5, sleep_hours=None, glucose_mg_dl=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("pesé 64.5 kg hoy en ayunas", None)

    assert out is not None
    from lifeos.health import entries as _he
    entry = _he.get(out["entry_ids"][0])
    assert entry.kind == "vital"
    assert entry.data["type"] == "weight"
    assert entry.data["value"] == 64.5
    assert entry.data["unit"] == "kg"


def test_nano_health_glucose_creates_structured_vital(monkeypatch, health_isolated_db):
    """When nano returns glucose_mg_dl, health branch stores a structured glucose vital."""
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult
    from axi.dashboard import _try_nano_extract

    fake = ExtractionResult(
        domain="health", kind="vital", title="glucosa 95 mg/dL",
        glucose_mg_dl=95.0, sleep_hours=None, weight_kg=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    out = _try_nano_extract("glucosa en 95 esta mañana", None)

    assert out is not None
    from lifeos.health import entries as _he
    entry = _he.get(out["entry_ids"][0])
    assert entry.kind == "vital"
    assert entry.data["type"] == "glucose"
    assert entry.data["value"] == 95.0
    assert entry.data["unit"] == "mg/dL"


# ── Task 3: client_ts plumbing ────────────────────────────────────────────────


def test_chat_ask_client_ts_persists_as_entry_when(client, monkeypatch, health_isolated_db):
    """When client_ts is sent, the health entry is stored with that timestamp."""
    from datetime import datetime, timedelta, timezone
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult

    # Use a date RELATIVE to now (2 days ago) so the test stays inside the
    # production client_ts acceptance window (within 2min future OR 7 days
    # past). A hardcoded calendar date silently drifts out of that window as
    # real time passes and the test starts failing on a clock, not a regression.
    past_dt = (datetime.now(timezone.utc) - timedelta(days=2)).replace(microsecond=0)
    past_ts = past_dt.isoformat().replace("+00:00", "Z")

    # Intercept nano so health fast-path fires
    fake = ExtractionResult(
        domain="health", kind="vital", title="glucosa 95",
        glucose_mg_dl=95.0, sleep_hours=None, weight_kg=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    # Also mock the regex path to NOT match (so nano fires)
    from lifeos.health import ingestion as hi_mod
    monkeypatch.setattr(hi_mod, "parse_health", lambda *_a, **_kw: None)

    r = client.post("/api/chat/ask", json={
        "text": "glucosa en 95 esta mañana",
        "client_ts": past_ts,
    })
    assert r.status_code == 200

    from lifeos.health import entries as _he
    all_entries = _he.list_recent(days=30)
    # Find the glucose entry we just created
    glucose_entry = next(
        (e for e in all_entries if e.data and e.data.get("type") == "glucose"),
        None,
    )
    assert glucose_entry is not None
    assert glucose_entry.ts == past_dt


def test_chat_ask_client_ts_future_is_rejected(client, monkeypatch, health_isolated_db):
    """client_ts more than 2 minutes in the future must be silently ignored."""
    from datetime import datetime, timezone
    from lifeos.agents import extractor as nano_extractor
    from lifeos.agents.extractor import ExtractionResult

    future_ts = "2099-12-31T23:59:59Z"

    fake = ExtractionResult(
        domain="health", kind="vital", title="glucosa 80",
        glucose_mg_dl=80.0, sleep_hours=None, weight_kg=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        confidence=0.65,
    )
    monkeypatch.setattr(nano_extractor, "extract", lambda *_a, **_k: fake)

    from lifeos.health import ingestion as hi_mod
    monkeypatch.setattr(hi_mod, "parse_health", lambda *_a, **_kw: None)

    r = client.post("/api/chat/ask", json={
        "text": "glucosa en 80 esta mañana",
        "client_ts": future_ts,
    })
    assert r.status_code == 200

    from lifeos.health import entries as _he
    all_entries = _he.list_recent(days=30)
    glucose_entry = next(
        (e for e in all_entries if e.data and e.data.get("type") == "glucose"),
        None,
    )
    assert glucose_entry is not None
    # Entry timestamp must NOT be in 2099 — must use server time instead
    assert glucose_entry.ts.year != 2099
