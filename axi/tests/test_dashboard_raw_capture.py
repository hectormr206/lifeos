"""Tests for raw_utterance plumbing in dashboard.py (PR 1c, tasks 1.22-1.26).

Verifies that:
- Every domain create() call inside _try_nano_extract receives
  raw_utterance=<original user text> and source_conv_id=None.
- The regex fast-path call sites also receive raw_utterance=text and
  source_conv_id=None.
- Manual/UI API create() callers (no chat text) still work with
  raw_utterance=NULL (backward-compat — tested separately in domain tests).
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, call, patch

import pytest


# ──────────────────────────────────────────────────────────────────────────────
# Helpers to build a minimal ExtractedEntry-like object for each domain.
# ──────────────────────────────────────────────────────────────────────────────

def _nano_result(**kwargs):
    """Return a SimpleNamespace mimicking the nano ExtractedEntry shape."""
    defaults = dict(
        domain=None,
        kind=None,
        title="test entry",
        confidence=0.9,
        people=[],
        dates_text=None,
        items=None,
        amount=None,
        merchant=None,
        currency="MXN",
        duration_minutes=None,
        systolic=None,
        diastolic=None,
        pulse_bpm=None,
        sleep_hours=None,
        weight_kg=None,
        glucose_mg_dl=None,
    )
    defaults.update(kwargs)
    return SimpleNamespace(**defaults)


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: health domain
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoHealthRawUtterance:
    """Health create() inside _try_nano_extract must receive raw_utterance."""

    def test_health_create_receives_raw_utterance(self, monkeypatch):
        """RED: _he.create called with raw_utterance=body_text and source_conv_id=None."""
        from axi import dashboard

        utterance = "dormí 7 horas anoche"
        nano_result = _nano_result(domain="health", kind="note", title="dormí 7 horas")

        created_entry = SimpleNamespace(id="health-id-1", kind="note")
        create_spy = MagicMock(return_value=created_entry)

        monkeypatch.setattr(
            "lifeos.health.entries.create", create_spy
        )

        # Patch the extractor so it never hits GPU
        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None, "Expected a dict result, got None"
        assert result["domain"] == "health"

        # Verify raw_utterance and source_conv_id were passed
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance, (
            f"raw_utterance not passed to health create(). kwargs={kwargs}"
        )
        assert kwargs.get("source_conv_id") is None, (
            f"source_conv_id should be None. kwargs={kwargs}"
        )

    def test_health_create_raw_utterance_is_original_text_not_normalized(self, monkeypatch):
        """When original_text differs from text (normalized), raw_utterance=original_text."""
        from axi import dashboard

        original = "DORMÍ 7 HORAS ANOCHE"   # raw
        normalized = "dormí 7 horas anoche"  # normalized form passed as text

        nano_result = _nano_result(domain="health", kind="note", title="dormí 7h")
        created_entry = SimpleNamespace(id="health-id-2", kind="note")
        create_spy = MagicMock(return_value=created_entry)

        monkeypatch.setattr("lifeos.health.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=normalized,
                location_tag=None,
                original_text=original,
            )

        assert result is not None
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == original, (
            "raw_utterance must be original_text, not the normalized text"
        )


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: finance domain (single + multi-item)
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoFinanceRawUtterance:

    def test_finance_single_create_receives_raw_utterance(self, monkeypatch):
        """Single finance entry: raw_utterance=body_text and source_conv_id=None."""
        from axi import dashboard

        utterance = "gasté 250 pesos en gasolina"
        nano_result = _nano_result(
            domain="finance", kind="expense", title="gasolina",
            amount=250.0, merchant="gasolinera",
        )
        created_entry = SimpleNamespace(id="fin-1")
        create_spy = MagicMock(return_value=created_entry)

        monkeypatch.setattr("lifeos.finance.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "finance"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None

    def test_finance_multi_item_each_create_receives_raw_utterance(self, monkeypatch):
        """Multi-item finance: EVERY per-item create() gets raw_utterance."""
        from axi import dashboard

        utterance = "compré leche por 30 y pan por 20"
        items = [
            {"name": "leche", "amount": 30.0, "category": "groceries"},
            {"name": "pan", "amount": 20.0, "category": "groceries"},
        ]
        nano_result = _nano_result(
            domain="finance", kind="expense", title="compras",
            amount=None, merchant="tienda", items=items,
        )
        entry_a = SimpleNamespace(id="fin-a")
        entry_b = SimpleNamespace(id="fin-b")
        create_spy = MagicMock(side_effect=[entry_a, entry_b])

        monkeypatch.setattr("lifeos.finance.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert create_spy.call_count == 2, "Expected 2 per-item create() calls"
        for c in create_spy.call_args_list:
            _, kw = c
            assert kw.get("raw_utterance") == utterance, (
                f"Multi-item create missing raw_utterance: {kw}"
            )
            assert kw.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: exercise domain
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoExerciseRawUtterance:

    def test_exercise_create_receives_raw_utterance(self, monkeypatch):
        from axi import dashboard

        utterance = "corrí 30 minutos en el parque"
        nano_result = _nano_result(
            domain="exercise", kind="run", title="trote",
            duration_minutes=30,
        )
        created_sess = SimpleNamespace(id="ex-1")
        create_spy = MagicMock(return_value=created_sess)

        monkeypatch.setattr("lifeos.exercise.sessions.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "exercise"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: learning domain
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoLearningRawUtterance:

    def test_learning_create_receives_raw_utterance(self, monkeypatch):
        from axi import dashboard

        utterance = "leí 'Clean Code' de Robert Martin"
        nano_result = _nano_result(
            domain="learning", kind="book", title="Clean Code",
            people=["Robert Martin"],
        )
        created_entry = SimpleNamespace(id="learn-1")
        create_spy = MagicMock(return_value=created_entry)

        monkeypatch.setattr("lifeos.learning.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "learning"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: spirituality domain
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoSpiritualityRawUtterance:

    def test_spirituality_create_receives_raw_utterance(self, monkeypatch):
        from axi import dashboard

        utterance = "hoy agradezco mi familia y salud"
        nano_result = _nano_result(
            domain="spirituality", kind="gratitude",
            title="agradecimiento familiar",
        )
        created_entry = SimpleNamespace(id="spirit-1")
        create_spy = MagicMock(return_value=created_entry)

        monkeypatch.setattr("lifeos.spirituality.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "spirituality"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.22 — nano path: relationships domain
# ──────────────────────────────────────────────────────────────────────────────

class TestNanoRelationshipsRawUtterance:

    def test_relationships_create_receives_raw_utterance(self, monkeypatch):
        from axi import dashboard

        utterance = "hablé con María sobre el proyecto"
        nano_result = _nano_result(
            domain="relationships", kind="conversation",
            title="conversación sobre proyecto",
            people=["María"],
        )

        mock_person = SimpleNamespace(id="person-1", name="María", role=None)
        created_inter = SimpleNamespace(id="inter-1")
        create_spy = MagicMock(return_value=created_inter)

        monkeypatch.setattr("lifeos.relationships.interactions.create", create_spy)
        # Patch people lookup: find_by_name returns an existing person
        monkeypatch.setattr(
            "lifeos.relationships.people.find_by_name",
            lambda name: mock_person,
        )

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance, location_tag=None, original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "relationships"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: relationships
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathRelationshipsRawUtterance:
    """The regex fast-path for relationships must also pass raw_utterance=text."""

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_relationships_fast_path_passes_raw_utterance(self, monkeypatch):
        """Relationships regex fast-path: create() must receive raw_utterance=text."""
        from axi import dashboard
        from lifeos.relationships import ingestion as rel_ingestion

        client = self._make_client(monkeypatch)

        utterance = "hablé con Juan"
        mock_ri = SimpleNamespace(
            person_name="Juan", kind="conversation", title="conversación",
            tags=None, confidence=0.95,
        )
        mock_person = SimpleNamespace(id="p-1", name="Juan", role=None)
        mock_interaction = SimpleNamespace(id="inter-fast-1")
        create_spy = MagicMock(return_value=mock_interaction)

        monkeypatch.setattr(rel_ingestion, "parse_interaction", lambda t: mock_ri)
        monkeypatch.setattr(dashboard.rel_people, "get_or_create", lambda name: mock_person)
        monkeypatch.setattr(dashboard.rel_interactions, "create", create_spy)
        # Skip the edge creation to avoid extra setup
        monkeypatch.setattr(dashboard.lifeos_edges, "create", lambda **_: None)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "rel_interactions.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance, (
            f"raw_utterance not passed to relationships fast-path create(). kwargs={kwargs}"
        )
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: health
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathHealthRawUtterance:

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_health_fast_path_passes_raw_utterance(self, monkeypatch):
        """Health regex fast-path: health_entries.create() gets raw_utterance=text."""
        from axi import dashboard
        from lifeos.health import ingestion as health_ingestion

        client = self._make_client(monkeypatch)

        utterance = "presión 120/80"
        mock_hi = SimpleNamespace(
            kind="vital", title="presión 120/80",
            data={"type": "blood_pressure", "systolic": 120, "diastolic": 80},
            tags=None, confidence=0.99,
        )
        mock_entry = SimpleNamespace(id="h-fast-1", kind="vital")
        create_spy = MagicMock(return_value=mock_entry)

        monkeypatch.setattr(health_ingestion, "parse_health", lambda t, now=None: mock_hi)
        monkeypatch.setattr(dashboard.health_entries, "create", create_spy)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "health_entries.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance, (
            f"raw_utterance not in health fast-path kwargs: {kwargs}"
        )
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: finance
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathFinanceRawUtterance:

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_finance_fast_path_passes_raw_utterance(self, monkeypatch):
        """Finance regex fast-path: finance_entries.create() gets raw_utterance=text."""
        from axi import dashboard
        from lifeos.finance import ingestion as finance_ingestion

        client = self._make_client(monkeypatch)

        utterance = "gasté 150 pesos en tacos"
        mock_fi = SimpleNamespace(
            kind="expense", title="tacos", amount=150.0,
            currency="MXN", category="food", merchant=None, tags=[],
            confidence=0.99,
        )
        mock_entry = SimpleNamespace(id="fin-fast-1", kind="expense")
        create_spy = MagicMock(return_value=mock_entry)

        monkeypatch.setattr(finance_ingestion, "parse_finance", lambda t: mock_fi)
        monkeypatch.setattr(dashboard.finance_entries, "create", create_spy)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "finance_entries.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: exercise
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathExerciseRawUtterance:

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_exercise_fast_path_passes_raw_utterance(self, monkeypatch):
        """Exercise regex fast-path: ex_sessions.create() gets raw_utterance=text."""
        from axi import dashboard
        from lifeos.exercise import ingestion as ex_ingestion

        client = self._make_client(monkeypatch)

        utterance = "caminé 45 minutos"
        mock_ei = SimpleNamespace(
            kind="walk", title="caminata",
            duration_minutes=45, location=None,
            data=None, confidence=0.99,
        )
        mock_sess = SimpleNamespace(id="ex-fast-1")
        create_spy = MagicMock(return_value=mock_sess)

        monkeypatch.setattr(ex_ingestion, "parse_exercise", lambda t: mock_ei)
        monkeypatch.setattr(dashboard.ex_sessions, "create", create_spy)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "ex_sessions.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: spirituality
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathSpiritualityRawUtterance:

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_spirituality_fast_path_passes_raw_utterance(self, monkeypatch):
        """Spirituality regex fast-path: spirit_entries.create() gets raw_utterance=text."""
        from axi import dashboard
        from lifeos.spirituality import ingestion as spirit_ingestion

        client = self._make_client(monkeypatch)

        utterance = "hoy agradezco mi trabajo y salud"
        mock_si = SimpleNamespace(
            kind="gratitude", title="agradecimiento",
            body=utterance, data=None, confidence=0.95,
        )
        mock_entry = SimpleNamespace(id="spirit-fast-1")
        create_spy = MagicMock(return_value=mock_entry)

        monkeypatch.setattr(spirit_ingestion, "parse_spirituality", lambda t: mock_si)
        monkeypatch.setattr(dashboard.spirit_entries, "create", create_spy)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "spirit_entries.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# 1.23 — regex fast-path: learning
# ──────────────────────────────────────────────────────────────────────────────

class TestFastPathLearningRawUtterance:

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_learning_fast_path_passes_raw_utterance(self, monkeypatch):
        """Learning regex fast-path: learn_entries.create() gets raw_utterance=text."""
        from axi import dashboard
        from lifeos.learning import ingestion as learn_ingestion

        client = self._make_client(monkeypatch)

        utterance = "empecé a leer 'Clean Architecture'"
        mock_li = SimpleNamespace(
            kind="book", title="Clean Architecture",
            status="active", body=None, author=None,
            data=None, confidence=0.95,
        )
        mock_entry = SimpleNamespace(id="learn-fast-1")
        create_spy = MagicMock(return_value=mock_entry)

        monkeypatch.setattr(learn_ingestion, "parse_learning", lambda t: mock_li)
        monkeypatch.setattr(dashboard.learn_entries, "create", create_spy)

        r = client.post("/api/chat/ask", json={"text": utterance, "logging_mode": False})

        assert r.status_code == 200
        assert create_spy.called, "learn_entries.create() was not called"
        _, kwargs = create_spy.call_args
        assert kwargs.get("raw_utterance") == utterance
        assert kwargs.get("source_conv_id") is None


# ──────────────────────────────────────────────────────────────────────────────
# Backward-compat: manual API create() must still work with raw_utterance=NULL
# (tested here as a sanity check; core tested in domain test_*_raw_capture.py)
# ──────────────────────────────────────────────────────────────────────────────

class TestManualAPIBackwardCompat:
    """Manual/UI API endpoints (no chat context) must still work without raw_utterance."""

    def _make_client(self, monkeypatch):
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

        from fastapi.testclient import TestClient
        return TestClient(dashboard.app)

    def test_health_manual_create_succeeds_without_raw_utterance(self, monkeypatch):
        """POST /api/health/entries (manual UI) succeeds; raw_utterance is NULL."""
        client = self._make_client(monkeypatch)
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc).isoformat()
        r = client.post("/api/health/entries", json={
            "kind": "note",
            "title": "dolor de cabeza",
            "ts": ts,
            "source": "manual",
        })
        assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
        data = r.json()
        assert data["kind"] == "note"
        assert data["title"] == "dolor de cabeza"
        # raw_utterance is NOT in the health entries response dict — that's fine
        # The important thing is the endpoint didn't fail.
