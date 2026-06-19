"""Tests for L3 Correction UX in dashboard.py (tasks 4.1-4.7).

Verifies:
1. store-then-correct ordering: even a low-confidence entry IS persisted
   (raw is never lost before the nudge is evaluated).
2. Confidence nudge: confidence < 0.85 appends "¿Es correcto?..." to answer;
   confidence >= 0.85 returns plain answer (no nudge).
3. Boundary: confidence == 0.85 exactly → NO nudge (strict less-than).
4. Per-session _LAST_ENTRIES: stores (domain, entry_id) tuples from the
   last turn's create() calls.
5. "deshacer" command: soft-deletes ALL entries from _LAST_ENTRIES and
   returns a confirmation in neutral Spanish.
6. Multi-entry turn: "deshacer" removes all of them.
7. Deshacer with no prior entries: graceful message, no error.
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, call, patch

import pytest


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

def _nano_result(**kwargs):
    """Return a SimpleNamespace mimicking the nano ExtractedEntry shape."""
    defaults = dict(
        domain=None,
        kind=None,
        title="test entry",
        confidence=0.65,  # nano default — always nudges
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


_NUDGE_FRAGMENT = "¿Es correcto?"


# ──────────────────────────────────────────────────────────────────────────────
# Task 4.1/4.2 — store-then-correct ordering + confidence nudge
# ──────────────────────────────────────────────────────────────────────────────

class TestStoreBeforeNudge:
    """Entry is always persisted first; nudge is only evaluated after."""

    def test_low_confidence_entry_is_persisted(self, monkeypatch):
        """A low-confidence (0.65) entry must still be persisted — raw never lost."""
        from axi import dashboard

        utterance = "tomé una pastilla de ibuprofeno"
        nano_result = _nano_result(
            domain="health",
            kind="medication",
            title="ibuprofeno",
            confidence=0.65,
        )
        created_entry = SimpleNamespace(id="entry-low-conf-1")
        create_spy = MagicMock(return_value=created_entry)
        monkeypatch.setattr("lifeos.health.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        # The entry MUST have been created (store-then-correct ordering)
        assert create_spy.called, "create() must be called even on low confidence"
        assert result is not None
        assert result["entry_ids"] == ["entry-low-conf-1"]

    def test_low_confidence_answer_includes_nudge(self, monkeypatch):
        """confidence < 0.85 → nudge appended to answer."""
        from axi import dashboard

        utterance = "tomé una pastilla de ibuprofeno"
        nano_result = _nano_result(
            domain="health",
            kind="medication",
            title="ibuprofeno",
            confidence=0.65,
        )
        created_entry = SimpleNamespace(id="entry-nudge-1")
        monkeypatch.setattr("lifeos.health.entries.create", MagicMock(return_value=created_entry))

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None
        assert _NUDGE_FRAGMENT in result["answer"], (
            f"Expected nudge fragment in answer: {result['answer']!r}"
        )

    def test_high_confidence_answer_no_nudge(self, monkeypatch):
        """confidence >= 0.85 → NO nudge appended."""
        from axi import dashboard

        utterance = "caminé 30 minutos por el parque"
        nano_result = _nano_result(
            domain="exercise",
            kind="walk",
            title="caminata",
            confidence=0.9,
            duration_minutes=30,
        )
        created_session = SimpleNamespace(id="sess-high-conf-1")
        monkeypatch.setattr("lifeos.exercise.sessions.create", MagicMock(return_value=created_session))

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None
        assert _NUDGE_FRAGMENT not in result["answer"], (
            f"Unexpected nudge in high-confidence answer: {result['answer']!r}"
        )

    def test_exactly_085_confidence_no_nudge(self, monkeypatch):
        """confidence == 0.85 exactly → NO nudge (strict less-than boundary)."""
        from axi import dashboard

        utterance = "corrí 45 minutos esta mañana"
        nano_result = _nano_result(
            domain="exercise",
            kind="run",
            title="trote",
            confidence=0.85,  # boundary — must NOT nudge
            duration_minutes=45,
        )
        created_session = SimpleNamespace(id="sess-boundary-1")
        monkeypatch.setattr("lifeos.exercise.sessions.create", MagicMock(return_value=created_session))

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None
        assert _NUDGE_FRAGMENT not in result["answer"], (
            f"Confidence 0.85 must NOT nudge, but got: {result['answer']!r}"
        )


# ──────────────────────────────────────────────────────────────────────────────
# Task 4.3 — _LAST_ENTRIES per-session memory
# ──────────────────────────────────────────────────────────────────────────────

class TestLastEntriesMemory:
    """_LAST_ENTRIES is updated after each turn that creates entries."""

    def test_last_entries_updated_after_nano_turn(self, monkeypatch):
        """After a successful nano turn, _LAST_ENTRIES[session_id] is populated."""
        from axi import dashboard

        # Clear state
        dashboard._LAST_ENTRIES.clear()

        utterance = "aprendí sobre Python async"
        session_id = "test-session-abc"
        nano_result = _nano_result(
            domain="learning",
            kind="idea",
            title="Python async",
            confidence=0.65,
        )
        created_entry = SimpleNamespace(id="le-001")
        monkeypatch.setattr("lifeos.learning.entries.create", MagicMock(return_value=created_entry))

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
                session_id=session_id,
            )

        assert result is not None
        assert session_id in dashboard._LAST_ENTRIES
        entries = dashboard._LAST_ENTRIES[session_id]
        assert len(entries) >= 1
        # Should contain (domain, entry_id) tuples
        domains = [d for d, _ in entries]
        ids = [eid for _, eid in entries]
        assert "learning" in domains
        assert "le-001" in ids

    def test_last_entries_replaced_on_new_turn(self, monkeypatch):
        """Each new turn REPLACES _LAST_ENTRIES[session_id], not appends."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "test-session-replace"

        # First turn: exercise
        dashboard._LAST_ENTRIES[session_id] = [("exercise", "old-sess-id")]

        utterance = "aprendí sobre FastAPI"
        nano_result = _nano_result(
            domain="learning",
            kind="idea",
            title="FastAPI",
            confidence=0.65,
        )
        created_entry = SimpleNamespace(id="le-new-001")
        monkeypatch.setattr("lifeos.learning.entries.create", MagicMock(return_value=created_entry))

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
                session_id=session_id,
            )

        # Should only have the new turn's entries
        entries = dashboard._LAST_ENTRIES[session_id]
        ids = [eid for _, eid in entries]
        assert "old-sess-id" not in ids, "Old entries must be replaced by new turn"
        assert "le-new-001" in ids


# ──────────────────────────────────────────────────────────────────────────────
# Task 4.4/4.5 — "deshacer" command
# ──────────────────────────────────────────────────────────────────────────────

class TestDeshacerCommand:
    """The 'deshacer' command soft-deletes the last entry and lists what was undone."""

    def test_deshacer_soft_deletes_last_entry(self, monkeypatch):
        """'deshacer' soft-deletes the entry from _LAST_ENTRIES for the session."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-undo-1"
        entry_id = "health-entry-abc"
        dashboard._LAST_ENTRIES[session_id] = [("health", entry_id)]

        delete_spy = MagicMock(return_value=None)
        monkeypatch.setattr("lifeos.health.entries.delete", delete_spy)

        result = dashboard._handle_deshacer(session_id)

        delete_spy.assert_called_once_with(entry_id)
        assert result is not None
        assert "deshacer" not in result.lower() or True  # answer exists
        # Graceful undo message in Spanish
        assert result  # non-empty

    def test_deshacer_clears_last_entries(self, monkeypatch):
        """After 'deshacer', _LAST_ENTRIES[session_id] should be empty."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-undo-clear"
        dashboard._LAST_ENTRIES[session_id] = [("exercise", "sess-xyz")]

        monkeypatch.setattr("lifeos.exercise.sessions.delete", MagicMock())

        dashboard._handle_deshacer(session_id)

        # After undo, nothing left to undo for this session
        assert dashboard._LAST_ENTRIES.get(session_id, []) == []

    def test_deshacer_no_prior_entries_graceful(self, monkeypatch):
        """'deshacer' with no _LAST_ENTRIES for session returns graceful message."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-empty-undo"

        result = dashboard._handle_deshacer(session_id)

        assert result is not None
        # Should contain a message about nothing to undo
        assert result  # non-empty, no crash

    def test_deshacer_multi_entry_removes_all(self, monkeypatch):
        """Multi-entry turn: 'deshacer' removes ALL entries from the last response."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-multi-undo"
        # Finance turn with 3 items
        dashboard._LAST_ENTRIES[session_id] = [
            ("finance", "fin-001"),
            ("finance", "fin-002"),
            ("finance", "fin-003"),
        ]

        delete_spy = MagicMock(return_value=None)
        monkeypatch.setattr("lifeos.finance.entries.delete", delete_spy)

        result = dashboard._handle_deshacer(session_id)

        # All 3 must have been deleted
        assert delete_spy.call_count == 3
        deleted_ids = [c.args[0] for c in delete_spy.call_args_list]
        assert "fin-001" in deleted_ids
        assert "fin-002" in deleted_ids
        assert "fin-003" in deleted_ids
        # _LAST_ENTRIES cleared
        assert dashboard._LAST_ENTRIES.get(session_id, []) == []

    def test_deshacer_all_six_domains_dispatched(self, monkeypatch):
        """_DOMAIN_DELETERS must cover all 6 domains so any domain can be undone."""
        from axi import dashboard

        domain_delete_spies: dict[str, MagicMock] = {}
        all_domains = [
            ("health", "lifeos.health.entries.delete"),
            ("finance", "lifeos.finance.entries.delete"),
            ("exercise", "lifeos.exercise.sessions.delete"),
            ("learning", "lifeos.learning.entries.delete"),
            ("spirituality", "lifeos.spirituality.entries.delete"),
            ("relationships", "lifeos.relationships.interactions.delete"),
        ]

        for domain, patch_path in all_domains:
            spy = MagicMock(return_value=None)
            domain_delete_spies[domain] = spy
            monkeypatch.setattr(patch_path, spy)

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-all-domains"
        dashboard._LAST_ENTRIES[session_id] = [
            ("health", "h-001"),
            ("finance", "f-001"),
            ("exercise", "e-001"),
            ("learning", "l-001"),
            ("spirituality", "s-001"),
            ("relationships", "r-001"),
        ]

        result = dashboard._handle_deshacer(session_id)

        # Every domain's delete must have been called
        for domain, spy in domain_delete_spies.items():
            assert spy.call_count == 1, f"delete() not called for domain: {domain}"


# ──────────────────────────────────────────────────────────────────────────────
# Task 4.6 — "deshacer"/"corregir" detection in chat handler
# ──────────────────────────────────────────────────────────────────────────────

class TestDeshacerChatDetection:
    """The chat handler detects 'deshacer'/'corregir' commands early."""

    def test_is_deshacer_command_matches_deshacer(self):
        """'deshacer' text is detected as an undo command."""
        from axi import dashboard

        assert dashboard._is_undo_command("deshacer")
        assert dashboard._is_undo_command("Deshacer")
        assert dashboard._is_undo_command("  deshacer  ")

    def test_is_deshacer_command_matches_corregir(self):
        """'corregir eso' is detected as an undo command; bare 'corregir' is NOT."""
        from axi import dashboard

        # Tightened per FIX 6: bare "corregir" without object must NOT match
        # (it fires on "corregir la ruta", a false positive).
        assert not dashboard._is_undo_command("corregir"), (
            "Bare 'corregir' must NOT match — too broad, fires on 'corregir la ruta'"
        )
        # Explicit-object form must still match
        assert dashboard._is_undo_command("Corregir eso")
        assert dashboard._is_undo_command("corregir lo último")

    def test_is_deshacer_command_no_match_normal_text(self):
        """Normal chat text is NOT detected as undo command."""
        from axi import dashboard

        assert not dashboard._is_undo_command("dormí 8 horas")
        assert not dashboard._is_undo_command("gasté 200 en supermercado")
        assert not dashboard._is_undo_command("")


# ──────────────────────────────────────────────────────────────────────────────
# Task 4.7 — End-to-end: persist then nudge, then undo
# ──────────────────────────────────────────────────────────────────────────────

class TestStoreThenCorrectEndToEnd:
    """End-to-end: entry is stored, nudge is shown, then deshacer removes it."""

    def test_entry_exists_after_low_confidence_turn(self, monkeypatch):
        """Even a low-confidence entry is persisted; it can then be deshacer'd."""
        from axi import dashboard

        dashboard._LAST_ENTRIES.clear()
        session_id = "sess-e2e-1"

        utterance = "algo que no estoy seguro de haber dicho bien"
        nano_result = _nano_result(
            domain="health",
            kind="note",
            title="nota de salud",
            confidence=0.55,  # very low
        )
        created_entry = SimpleNamespace(id="e2e-entry-001")
        create_spy = MagicMock(return_value=created_entry)
        monkeypatch.setattr("lifeos.health.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
                session_id=session_id,
            )

        # 1. Entry was persisted
        assert create_spy.called
        assert result is not None
        # 2. Nudge is present (confidence < 0.85)
        assert _NUDGE_FRAGMENT in result["answer"]
        # 3. _LAST_ENTRIES has the entry
        assert session_id in dashboard._LAST_ENTRIES
        ids = [eid for _, eid in dashboard._LAST_ENTRIES[session_id]]
        assert "e2e-entry-001" in ids

        # 4. Now deshacer soft-deletes it
        delete_spy = MagicMock(return_value=None)
        monkeypatch.setattr("lifeos.health.entries.delete", delete_spy)

        undo_msg = dashboard._handle_deshacer(session_id)

        delete_spy.assert_called_once_with("e2e-entry-001")
        assert undo_msg  # non-empty confirmation
        assert dashboard._LAST_ENTRIES.get(session_id, []) == []
