"""Tests for the low-value-entry filter in domain_bridge.py.

TDD order: RED tests written first, GREEN follows after implementation.

Covered tasks:
  LV.1 — _is_low_value: unit table (helper does not exist yet → RED)
  LV.2 — create_fact_node_for_entry skips low-value entries → returns None  (RED)
  LV.3 — create_fact_node_for_entry keeps real entries → node IS created     (regression)
  LV.4 — bridge_entry returns None for low-value, without raising             (regression)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any
from unittest.mock import patch, MagicMock

import pytest


# ─── shared stubs ──────────────────────────────────────────────────────────────


@dataclass
class _HealthStub:
    """Minimal duck-typed health entry for low-value filter tests."""
    id: str = "he-lv-001"
    kind: str = "vital"
    raw_utterance: str | None = None
    title: str | None = None
    data: dict = field(default_factory=dict)


# ═══════════════════════════════════════════════════════════════════════════════
# Task LV.1 — _is_low_value unit table
# RED: helper does not exist yet → ImportError / AttributeError
# ═══════════════════════════════════════════════════════════════════════════════


class TestIsLowValueDropCases:
    """Labels that MUST be classified as low-value (True → skip)."""

    def test_empty_string_is_low_value(self):
        """Empty string → low value."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("", _HealthStub()) is True

    def test_whitespace_only_is_low_value(self):
        """Whitespace-only string → low value."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("   ", _HealthStub()) is True

    def test_bare_keyword_dormir_is_low_value(self):
        """'dormir' — single token, short, no raw, no data → low value."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={})
        assert _is_low_value("dormir", entry) is True

    def test_bare_keyword_despertar_is_low_value(self):
        """'despertar' — single token, short, no raw, no data → low value."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={})
        assert _is_low_value("despertar", entry) is True

    def test_bare_keyword_pulsos_is_low_value(self):
        """'pulsos' — single token, short, no raw, no data → low value."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={})
        assert _is_low_value("pulsos", entry) is True

    def test_single_token_at_boundary_14_chars_no_content_is_low_value(self):
        """Single token exactly 14 chars, no raw/data → low value."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={})
        label = "a" * 14  # 14 chars, single token, no digit
        assert _is_low_value(label, entry) is True


class TestIsLowValueKeepCases:
    """Labels that MUST be kept (False → do not skip)."""

    def test_sleep_with_number_is_kept(self):
        """'dormí 10.7h' — contains digit → keep."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("dormí 10.7h", _HealthStub()) is False

    def test_presion_with_numbers_is_kept(self):
        """'presión 120/86, pulso 61' — contains digits → keep."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("presión 120/86, pulso 61", _HealthStub()) is False

    def test_multi_number_label_is_kept(self):
        """'113, 82 y 55 de pulso.' — contains digits → keep."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("113, 82 y 55 de pulso.", _HealthStub()) is False

    def test_finance_label_with_amount_is_kept(self):
        """'gasté 450 en super' — contains digit → keep."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("gasté 450 en super", _HealthStub()) is False

    def test_exercise_label_with_duration_is_kept(self):
        """'caminé 45 min' — contains digit → keep."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("caminé 45 min", _HealthStub()) is False

    def test_multi_word_label_without_digit_is_kept(self):
        """Multi-word labels without digits are kept (not bare keywords)."""
        from axi.domain_bridge import _is_low_value
        assert _is_low_value("gratitud: amanecí con salud", _HealthStub()) is False

    def test_single_token_long_is_kept(self):
        """Single token > 14 chars (no digit) is NOT a bare keyword → keep."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={})
        label = "a" * 15  # 15 chars, over the short threshold
        assert _is_low_value(label, entry) is False

    def test_single_token_short_with_raw_utterance_is_kept(self):
        """Single short token BUT entry has raw_utterance → keep (real content)."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance="dormí mal", data={})
        assert _is_low_value("dormir", entry) is False

    def test_single_token_short_with_data_is_kept(self):
        """Single short token BUT entry has non-empty data → keep."""
        from axi.domain_bridge import _is_low_value
        entry = _HealthStub(raw_utterance=None, data={"hours": 6})
        assert _is_low_value("dormir", entry) is False

    def test_single_token_with_amount_is_kept(self):
        """Single short token BUT entry has non-zero amount (finance) → keep."""
        from axi.domain_bridge import _is_low_value

        @dataclass
        class _FinanceStub:
            id: str = "fi-001"
            kind: str = "expense"
            raw_utterance: str | None = None
            title: str = "gasolina"
            amount: float = 600.0

        entry = _FinanceStub()
        # "gasolina" — single token, 8 chars, no digit in label, no raw_utterance
        # BUT amount=600 → has real content → keep.
        assert _is_low_value("gasolina", entry) is False

    def test_single_token_with_duration_minutes_is_kept(self):
        """Single short token with duration_minutes (exercise) → keep."""
        from axi.domain_bridge import _is_low_value

        @dataclass
        class _ExerciseStub:
            id: str = "ex-001"
            kind: str = "run"
            raw_utterance: str | None = None
            title: str = "correr"
            duration_minutes: int = 45

        entry = _ExerciseStub()
        assert _is_low_value("correr", entry) is False


# ═══════════════════════════════════════════════════════════════════════════════
# Task LV.2 — create_fact_node_for_entry SKIPS low-value entries
# RED: current code does not have the filter → creates the node instead
# ═══════════════════════════════════════════════════════════════════════════════


def test_create_fact_node_skips_low_value_entry():
    """LV.2 RED — entry rendering to 'pulsos' (no raw, no data) → no node created, returns None."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    # Craft a health entry that renders to "pulsos" via the health renderer.
    # The renderer will try raw_utterance (None), then title ("pulsos"), and return "pulsos".
    entry = _HealthStub(id="he-lv-skip-001", raw_utterance=None, title="pulsos", data={})

    result = create_fact_node_for_entry("health", entry)

    # Filter must prevent node creation and return None.
    assert result is None, (
        f"Expected None for low-value label 'pulsos', got {result!r}. "
        "The bridge must skip entries whose rendered label is bare-keyword."
    )

    # Confirm no node or map row was created.
    conn = store._connect()
    map_row = conn.execute(
        "SELECT * FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()
    assert map_row is None, (
        "domain_node_map must NOT contain a row for the skipped low-value entry."
    )


def test_create_fact_node_skips_empty_label_entry():
    """LV.2 triangulate — entry rendering to '' → no node created, returns None."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    # An entry with whitespace-only raw_utterance AND whitespace-only title
    # AND no kind falls back to 'health: ' (has 'health' prefix with colon+space).
    # To get truly empty label we mock the renderer.
    entry = _HealthStub(id="he-lv-empty-001", raw_utterance=None, title=None, data={})

    with patch("axi.domain_bridge._DOMAIN_CONFIGS") as mock_configs:
        mock_cfg = MagicMock()
        mock_cfg.renderer.return_value = ""
        mock_cfg.extra_data_fn = None
        mock_configs.__getitem__ = lambda self, key: mock_cfg
        mock_configs.__contains__ = lambda self, key: True

        result = create_fact_node_for_entry("health", entry)

    assert result is None, (
        f"Expected None for empty rendered label, got {result!r}."
    )


# ═══════════════════════════════════════════════════════════════════════════════
# Task LV.3 — create_fact_node_for_entry KEEPS real entries (regression)
# ═══════════════════════════════════════════════════════════════════════════════


def test_create_fact_node_keeps_real_health_entry():
    """LV.3 regression — 'presión 120/86, pulso 61' → node IS created and mapped."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = _HealthStub(
        id="he-lv-keep-001",
        raw_utterance="presión 120/86, pulso 61",
        data={},
    )

    result = create_fact_node_for_entry("health", entry)

    assert result is not None, "Real health entry must produce a node."
    assert isinstance(result, int)
    assert result > 0

    conn = store._connect()
    node = conn.execute("SELECT label FROM nodes WHERE id = ?", (result,)).fetchone()
    assert node is not None
    assert "presión" in node["label"]

    map_row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='health' AND entry_id=?",
        (entry.id,),
    ).fetchone()
    assert map_row is not None, "domain_node_map must have a row for real entry."
    assert int(map_row["node_id"]) == result


def test_create_fact_node_keeps_multi_number_label():
    """LV.3 triangulate — '113, 82 y 55 de pulso.' → node IS created."""
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    entry = _HealthStub(
        id="he-lv-keep-002",
        raw_utterance="113, 82 y 55 de pulso.",
        data={},
    )

    result = create_fact_node_for_entry("health", entry)
    assert result is not None, "Multi-number health entry must produce a node."
    assert isinstance(result, int)


# ═══════════════════════════════════════════════════════════════════════════════
# Task LV.4 — bridge_entry returns None for low-value (best-effort, no raise)
# ═══════════════════════════════════════════════════════════════════════════════


def test_bridge_entry_returns_none_for_low_value():
    """LV.4 — bridge_entry('health', low-value-entry) returns None without raising."""
    from axi.domain_bridge import bridge_entry

    entry = _HealthStub(id="he-lv-be-001", raw_utterance=None, title="dormir", data={})

    result = bridge_entry("health", entry)

    assert result is None, (
        f"bridge_entry must return None for low-value entry, got {result!r}."
    )


def test_bridge_entry_returns_int_for_real_entry():
    """LV.4 regression — bridge_entry for real entry still returns int."""
    from axi.domain_bridge import bridge_entry

    entry = _HealthStub(
        id="he-lv-be-002",
        raw_utterance="dormí 8.5h muy bien",
        data={},
    )

    result = bridge_entry("health", entry)
    assert isinstance(result, int), f"Expected int node_id, got {result!r}."
    assert result > 0
