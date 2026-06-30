"""Tests for the learned schedule-parse cache + miss log.

TDD — written before implementation. Covers:
  - normalize_schedule_text: accents/case/whitespace/punctuation collapse.
  - schedule_cache_put/get round-trip, hits increment, upsert update.
  - schedule_miss_log_add append + the >1000 row cap pruning oldest.

All DB access is isolated to a per-test encrypted tmp DB.
"""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Each test gets its own tmp DB + key path, completely isolated."""
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    from lifeos import store

    store.apply_migrations()


# ---------------------------------------------------------------------------
# normalize_schedule_text
# ---------------------------------------------------------------------------


def test_normalize_collapses_accents_case_whitespace_punct() -> None:
    from lifeos.parser import normalize_schedule_text

    a = normalize_schedule_text("Quiero que todos los días me mandes X")
    b = normalize_schedule_text("quiero  que todos los dias me mandes x.")
    assert a == b
    assert a == "quiero que todos los dias me mandes x"


def test_normalize_strips_leading_trailing_punctuation() -> None:
    from lifeos.parser import normalize_schedule_text

    assert normalize_schedule_text("  ¡Hola!  ") == "hola"
    assert normalize_schedule_text("...recordame algo...") == "recordame algo"


def test_normalize_handles_empty_and_non_str() -> None:
    from lifeos.parser import normalize_schedule_text

    assert normalize_schedule_text("") == ""
    assert normalize_schedule_text(None) == ""  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# schedule_cache_put / get
# ---------------------------------------------------------------------------


def test_cache_put_get_round_trip() -> None:
    from lifeos import store

    store.schedule_cache_put(
        "todos los dias x", kind="agentic", recurrence="0 9 * * *", content="las noticias"
    )
    got = store.schedule_cache_get("todos los dias x")
    assert got == {"kind": "agentic", "recurrence": "0 9 * * *", "content": "las noticias"}


def test_cache_get_miss_returns_none() -> None:
    from lifeos import store

    assert store.schedule_cache_get("nope nothing here") is None


def test_cache_get_increments_hits() -> None:
    from lifeos import store

    store.schedule_cache_put(
        "daily key", kind="message", recurrence="0 8 * * *", content="tomar agua"
    )
    store.schedule_cache_get("daily key")
    store.schedule_cache_get("daily key")
    store.schedule_cache_get("daily key")

    with store.connect() as conn:
        hits = conn.execute(
            "SELECT hits FROM schedule_cache WHERE norm_text = ?", ("daily key",)
        ).fetchone()[0]
    assert hits == 3


def test_cache_put_upsert_updates_content() -> None:
    from lifeos import store

    store.schedule_cache_put(
        "same key", kind="message", recurrence="0 8 * * *", content="old"
    )
    store.schedule_cache_put(
        "same key", kind="agentic", recurrence="0 9 * * *", content="new"
    )
    got = store.schedule_cache_get("same key")
    assert got == {"kind": "agentic", "recurrence": "0 9 * * *", "content": "new"}

    # Still a single row (upsert, not insert).
    with store.connect() as conn:
        n = conn.execute("SELECT COUNT(*) FROM schedule_cache").fetchone()[0]
    assert n == 1


# ---------------------------------------------------------------------------
# schedule_miss_log_add
# ---------------------------------------------------------------------------


def test_miss_log_appends_rows() -> None:
    from lifeos import store

    store.schedule_miss_log_add(
        raw_text="raw 1", norm_text="norm 1", resolved=True,
        kind="agentic", recurrence="0 9 * * *",
    )
    store.schedule_miss_log_add(
        raw_text="raw 2", norm_text="norm 2", resolved=False,
        kind=None, recurrence=None,
    )
    with store.connect() as conn:
        rows = conn.execute(
            "SELECT raw_text, resolved FROM schedule_miss_log ORDER BY id"
        ).fetchall()
    assert len(rows) == 2
    assert rows[0]["raw_text"] == "raw 1"
    assert rows[0]["resolved"] == 1
    assert rows[1]["resolved"] == 0


def test_miss_log_caps_at_1000_pruning_oldest() -> None:
    from lifeos import store

    for i in range(1005):
        store.schedule_miss_log_add(
            raw_text=f"raw {i}", norm_text=f"norm {i}", resolved=True,
            kind="message", recurrence="0 8 * * *",
        )
    with store.connect() as conn:
        n = conn.execute("SELECT COUNT(*) FROM schedule_miss_log").fetchone()[0]
        oldest = conn.execute(
            "SELECT raw_text FROM schedule_miss_log ORDER BY id ASC LIMIT 1"
        ).fetchone()[0]
    assert n == 1000
    # The first five (raw 0..4) must have been pruned.
    assert oldest == "raw 5"
