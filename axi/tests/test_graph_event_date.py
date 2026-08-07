"""Tests for the 'todo ligado' bug fix: semantic graph linkers must use the
real event date (occurred_at) instead of the graph-insertion date (created_at).

TDD order: ALL tests in this file were written RED-first before any
implementation exists. GREEN comes after the production code changes.

Bug: backfilled entries are all inserted on the same day (created_at = now),
so same-day and happened-at linkers wrongly treat them as co-occurring, forming
a meaningless dense mesh. Fix: store the real event timestamp in occurred_at
(NULL when unknown) and use COALESCE(occurred_at, created_at) in all linkers.

Test coverage (one test file, structured by task):
  T1 — add_node stores occurred_at correctly
  T2 — domain_bridge extracts occurred_at from entry.ts
  T3 — same-day linker uses occurred_at, NOT created_at (headline)
  T4 — happened-at linker uses occurred_at, NOT created_at
  T5 — backfill_node_occurred_at: fills NULL rows from live entries
  T6 — /api/graph/full includes occurred_at; brain3d.html references it
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from unittest.mock import patch, MagicMock

import pytest
import uuid as _uuid


# ─── shared helpers ──────────────────────────────────────────────────────────


def _day_epoch(days_ago: int = 0) -> float:
    """Return the Unix epoch for midnight UTC on a day relative to today."""
    today = datetime.now(tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    target = today - timedelta(days=days_ago)
    return target.timestamp()


def _insert_node(
    conn,
    *,
    kind: str = "fact",
    label: str = "test",
    domain: str = "health",
    created_at: float | None = None,
    occurred_at: float | None = None,
    data: dict | None = None,
) -> int:
    """Insert a node with explicit created_at/occurred_at for test control."""
    now = created_at if created_at is not None else time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at, "
        "occurred_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), kind, label, json.dumps(data or {}), domain, now,
         now, occurred_at),
    )
    conn.commit()
    return cur.lastrowid


def _insert_meeting(conn, *, start_time: float, title: str = "Test Meeting") -> int:
    cur = conn.execute(
        "INSERT INTO meetings(start_time, source, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (start_time, "manual", "/tmp/test", "done", time.time()),
    )
    conn.commit()
    return cur.lastrowid


def _edge_exists(conn, from_id: int, to_id: int, kind: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM edges WHERE src_uuid=(SELECT uuid FROM nodes WHERE id=?) AND dst_uuid=(SELECT uuid FROM nodes WHERE id=?) AND relation=? LIMIT 1",
        (from_id, to_id, kind),
    ).fetchone()
    return row is not None


# ═══════════════════════════════════════════════════════════════════════════
# T1 — add_node stores occurred_at
# ═══════════════════════════════════════════════════════════════════════════


def test_add_node_stores_occurred_at_when_provided():
    """T1a RED: add_node(occurred_at=X) → nodes row has occurred_at=X."""
    import axi.store as store

    nid = store.add_node("fact", "test event", occurred_at=123456789.0)

    row = store.get_node(nid)
    assert row is not None
    # occurred_at must be stored and retrievable.
    assert row["occurred_at"] == pytest.approx(123456789.0), (
        "occurred_at column was not persisted by add_node; "
        "schema migration + add_node signature change required"
    )


def test_add_node_stores_null_occurred_at_by_default():
    """T1b RED: add_node() without occurred_at → occurred_at IS NULL."""
    import axi.store as store

    nid = store.add_node("fact", "no event date")

    row = store.get_node(nid)
    assert row is not None
    assert row["occurred_at"] is None, (
        "occurred_at should default to NULL when not provided; "
        "verify the default is None and the column exists"
    )


def test_add_node_occurred_at_does_not_change_created_at():
    """T1c: providing occurred_at must not alter created_at (insertion time)."""
    import axi.store as store

    before = time.time()
    nid = store.add_node("fact", "timestamped", occurred_at=1000.0)
    after = time.time()

    row = store.get_node(nid)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(1000.0)
    # created_at must be the actual insertion time, not occurred_at.
    assert before <= float(row["created_at"]) <= after, (
        "created_at should be the insertion timestamp, not occurred_at"
    )


# ═══════════════════════════════════════════════════════════════════════════
# T2 — domain_bridge extracts occurred_at from entry.ts
# ═══════════════════════════════════════════════════════════════════════════


@dataclass
class _FakeEntryWithTs:
    """Minimal duck-typed domain entry with a ts datetime."""
    id: str = "fake-001"
    kind: str = "vital"
    raw_utterance: str = "test entry"
    ts: object = None          # may be datetime, ISO string, or float epoch
    created_at: object = None  # fallback


def test_bridge_extracts_occurred_at_from_entry_ts_datetime():
    """T2a RED: entry.ts is a datetime → occurred_at on the node matches its epoch."""
    from axi.domain_bridge import create_fact_node_for_entry
    import axi.store as store

    known_dt = datetime(2026, 6, 11, 12, 19, 52, tzinfo=timezone.utc)
    expected_epoch = known_dt.timestamp()

    entry = _FakeEntryWithTs(id="bridge-dt-001", raw_utterance="health vital", ts=known_dt)

    node_id = create_fact_node_for_entry("health", entry)
    assert node_id is not None

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(expected_epoch, abs=1), (
        f"Bridge should store entry.ts epoch ({expected_epoch}) as occurred_at; "
        f"got {row['occurred_at']}"
    )


def test_bridge_extracts_occurred_at_from_entry_ts_iso_string():
    """T2b RED: entry.ts is an ISO string → occurred_at matches parsed epoch."""
    from axi.domain_bridge import create_fact_node_for_entry
    import axi.store as store

    iso_str = "2026-06-24 12:19:52+00:00"
    known_dt = datetime(2026, 6, 24, 12, 19, 52, tzinfo=timezone.utc)
    expected_epoch = known_dt.timestamp()

    entry = _FakeEntryWithTs(id="bridge-iso-002", raw_utterance="health bp", ts=iso_str)

    node_id = create_fact_node_for_entry("health", entry)
    assert node_id is not None

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(expected_epoch, abs=1), (
        f"Bridge should parse ISO string entry.ts to epoch; got {row['occurred_at']}"
    )


def test_bridge_falls_back_to_created_at_when_ts_absent():
    """T2c RED: entry.ts is None but entry.created_at is a datetime → occurred_at from created_at."""
    from axi.domain_bridge import create_fact_node_for_entry
    import axi.store as store

    known_dt = datetime(2026, 5, 1, 8, 0, 0, tzinfo=timezone.utc)
    expected_epoch = known_dt.timestamp()

    entry = _FakeEntryWithTs(
        id="bridge-ca-003",
        raw_utterance="health sleep",
        ts=None,
        created_at=known_dt,
    )

    node_id = create_fact_node_for_entry("health", entry)
    assert node_id is not None

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(expected_epoch, abs=1), (
        "Bridge should fall back to entry.created_at when entry.ts is absent"
    )


def test_bridge_stores_null_occurred_at_when_no_timestamp():
    """T2d RED: entry with neither ts nor created_at → occurred_at IS NULL."""
    from axi.domain_bridge import create_fact_node_for_entry
    import axi.store as store

    entry = _FakeEntryWithTs(
        id="bridge-null-004",
        raw_utterance="health no date",
        ts=None,
        created_at=None,
    )

    node_id = create_fact_node_for_entry("health", entry)
    assert node_id is not None

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] is None, (
        "occurred_at should be NULL when no timestamp is available on the entry"
    )


# ═══════════════════════════════════════════════════════════════════════════
# T3 — same-day linker uses occurred_at, NOT created_at (the headline test)
# ═══════════════════════════════════════════════════════════════════════════


def test_same_day_linker_does_not_link_same_created_at_different_occurred_at():
    """T3a RED (headline): Two nodes with SAME created_at but DIFFERENT occurred_at days
    must NOT be linked as same-day.

    This directly validates the backfill bug: all backfilled nodes share the
    same created_at (insertion day) but have different real event dates.
    Current code (links by created_at) would link them — wrong.
    After fix (links by COALESCE(occurred_at, created_at)) they must NOT link.
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Shared created_at simulates batch backfill on the same day.
    shared_created_at = _day_epoch(0) + 3600  # today 01:00 UTC

    # Fact A: really happened 5 days ago.
    day5_ago = _day_epoch(5) + 3600
    # Fact B: really happened 10 days ago.
    day10_ago = _day_epoch(10) + 3600

    nid_a = _insert_node(
        conn,
        label="Backfilled event A (5 days ago)",
        created_at=shared_created_at,
        occurred_at=day5_ago,
    )
    nid_b = _insert_node(
        conn,
        label="Backfilled event B (10 days ago)",
        created_at=shared_created_at,
        occurred_at=day10_ago,
    )

    run_same_day_linker(conn)

    # With the fix, these must NOT be linked (different occurred_at days).
    linked = (
        _edge_exists(conn, nid_a, nid_b, "same-day")
        or _edge_exists(conn, nid_b, nid_a, "same-day")
    )
    assert not linked, (
        "same-day linker wrongly linked two nodes that share created_at but have "
        "DIFFERENT occurred_at days. This is the backfill 'todo ligado' bug. "
        "Linker must use COALESCE(occurred_at, created_at) instead of created_at."
    )


def test_same_day_linker_links_different_created_at_same_occurred_at():
    """T3b RED: Two nodes with DIFFERENT created_at but SAME occurred_at day
    MUST be linked as same-day.

    Validates the positive case: nodes inserted at different times but
    representing the same real-world day should form the same-day cluster.
    Current code (links by created_at) would NOT link them — wrong.
    After fix they must be linked.
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    # Different insertion times (e.g. two separate backfill runs).
    insert_time_a = _day_epoch(0) + 3600   # today 01:00 UTC
    insert_time_b = _day_epoch(1) + 3600   # yesterday 01:00 UTC (different created_at day)

    # Both events really happened on the same day (3 days ago).
    same_event_day = _day_epoch(3) + 3600

    nid_a = _insert_node(
        conn,
        label="Event A (same real day, different insert time)",
        created_at=insert_time_a,
        occurred_at=same_event_day,
    )
    nid_b = _insert_node(
        conn,
        label="Event B (same real day, different insert time)",
        created_at=insert_time_b,
        occurred_at=same_event_day,
    )

    run_same_day_linker(conn)

    # With the fix, these MUST be linked (same occurred_at day).
    linked = (
        _edge_exists(conn, nid_a, nid_b, "same-day")
        or _edge_exists(conn, nid_b, nid_a, "same-day")
    )
    assert linked, (
        "same-day linker did not link two nodes that share occurred_at day "
        "but have different created_at. After the fix, COALESCE(occurred_at, created_at) "
        "should group them correctly."
    )


def test_same_day_linker_fallback_to_created_at_when_occurred_at_null():
    """T3c: When occurred_at is NULL, linker must fall back to created_at.

    Ensures the COALESCE logic doesn't break nodes that have no occurred_at
    (e.g. conversation nodes, manually created nodes).
    """
    import axi.store as store
    from axi.linkers import run_same_day_linker

    conn = store._connect()

    today_ts = _day_epoch(0) + 3600

    # Two nodes with NULL occurred_at, same created_at day → should still link.
    nid_a = _insert_node(
        conn,
        label="No event date A",
        created_at=today_ts,
        occurred_at=None,
    )
    nid_b = _insert_node(
        conn,
        label="No event date B",
        created_at=today_ts + 7200,  # 2h later, same day
        occurred_at=None,
    )

    run_same_day_linker(conn)

    linked = (
        _edge_exists(conn, nid_a, nid_b, "same-day")
        or _edge_exists(conn, nid_b, nid_a, "same-day")
    )
    assert linked, (
        "When occurred_at is NULL, the linker should fall back to created_at "
        "for grouping. Two NULL-occurred_at nodes on the same created_at day should link."
    )


# ═══════════════════════════════════════════════════════════════════════════
# T4 — happened-at linker uses occurred_at, NOT created_at
# ═══════════════════════════════════════════════════════════════════════════


def test_happened_at_linker_uses_occurred_at_not_created_at():
    """T4a RED: A fact with occurred_at inside the meeting window but
    created_at OUTSIDE the window must still get a happened-at edge.

    This validates the fix: the linker must check occurred_at, not created_at.
    """
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    # Meeting happened 5 days ago.
    meeting_start = _day_epoch(5) + 14 * 3600  # 5 days ago, 14:00 UTC

    mid = _insert_meeting(conn, start_time=meeting_start)
    meeting_node_id = _insert_node(
        conn,
        kind="event",
        label="Meeting from 5 days ago",
        domain="meetings",
        created_at=meeting_start,
        occurred_at=meeting_start,
    )
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact with created_at = NOW (backfilled today), but occurred_at = 30min after meeting.
    fact_occurred_at = meeting_start + 30 * 60   # 30 min into the meeting
    fact_created_at = time.time()                 # inserted today (backfill)

    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Fact from meeting (backfilled today)",
        created_at=fact_created_at,   # today — OUTSIDE the meeting window
        occurred_at=fact_occurred_at,  # 5 days ago — INSIDE the meeting window
    )

    created = run_happened_at_linker(conn)

    assert created >= 1, (
        "happened-at linker should link the fact to the meeting based on occurred_at, "
        "not created_at. Fact has occurred_at inside meeting window but created_at outside."
    )
    assert _edge_exists(conn, meeting_node_id, fact_id, "happened-at"), (
        "Expected happened-at edge from meeting_node to fact when fact.occurred_at "
        "is within ±1h of meeting.start_time"
    )


def test_happened_at_linker_no_edge_when_occurred_at_outside_window():
    """T4b RED: A fact with occurred_at OUTSIDE the meeting window must NOT link,
    even if created_at happens to be inside the window.
    """
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    # Meeting now.
    meeting_start = time.time()

    mid = _insert_meeting(conn, start_time=meeting_start)
    meeting_node_id = _insert_node(
        conn,
        kind="event",
        label="Recent meeting",
        domain="meetings",
        created_at=meeting_start,
        occurred_at=meeting_start,
    )
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact: created_at INSIDE window (tricky: could be a new note about a meeting)
    # but occurred_at is 10 days ago (different real event).
    fact_created_at = meeting_start + 20 * 60   # 20 min after meeting — inside window
    fact_occurred_at = _day_epoch(10) + 3600    # 10 days ago — outside window

    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Old event catalogued near meeting",
        created_at=fact_created_at,
        occurred_at=fact_occurred_at,
    )

    run_happened_at_linker(conn)

    assert not _edge_exists(conn, meeting_node_id, fact_id, "happened-at"), (
        "happened-at linker must NOT link a fact whose occurred_at is outside the "
        "meeting window, even if created_at falls inside the window."
    )


def test_happened_at_linker_fallback_to_created_at_when_occurred_at_null():
    """T4c: When occurred_at IS NULL, linker falls back to created_at (no regression).

    Ensures COALESCE doesn't break the existing behaviour for nodes without an
    event date (e.g. live entries created at the same moment they're recorded).
    """
    import axi.store as store
    from axi.linkers import run_happened_at_linker

    conn = store._connect()

    meeting_start = time.time()
    mid = _insert_meeting(conn, start_time=meeting_start)
    meeting_node_id = _insert_node(
        conn,
        kind="event",
        label="Live meeting",
        domain="meetings",
        created_at=meeting_start,
        occurred_at=meeting_start,
    )
    conn.execute("UPDATE meetings SET node_id=? WHERE id=?", (meeting_node_id, mid))
    conn.commit()

    # Fact with NULL occurred_at but created_at inside the meeting window.
    fact_created_at = meeting_start + 20 * 60  # 20 min after meeting
    fact_id = _insert_node(
        conn,
        kind="fact",
        label="Live fact (no occurred_at)",
        created_at=fact_created_at,
        occurred_at=None,
    )

    run_happened_at_linker(conn)

    assert _edge_exists(conn, meeting_node_id, fact_id, "happened-at"), (
        "With occurred_at IS NULL, the linker should fall back to created_at. "
        "A fact created inside the meeting window should still link."
    )


# ═══════════════════════════════════════════════════════════════════════════
# T5 — backfill_node_occurred_at: fills NULL rows from live entries
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_node_occurred_at_sets_occurred_at_from_entry():
    """T5a RED: nodes with occurred_at IS NULL + domain_node_map row → occurred_at filled."""
    import axi.store as store
    from axi.domain_bridge import backfill_node_occurred_at

    conn = store._connect()

    # Create a node with occurred_at = NULL (simulates a pre-fix backfilled node).
    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", "health vital check", "{}", "health", now, now),
    )
    conn.commit()
    node_id = cur.lastrowid

    # Register it in domain_node_map.
    entry_id = "he-backfill-001"
    conn.execute(
        "INSERT INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("health", entry_id, node_id, now),
    )
    conn.commit()

    # Real event date from the domain entry.
    real_event_dt = datetime(2026, 6, 11, 12, 0, 0, tzinfo=timezone.utc)
    real_event_epoch = real_event_dt.timestamp()

    # Stub _fetch_domain_entries to return a fake entry with that timestamp.
    @dataclass
    class _FakeEntry:
        id: str = entry_id
        kind: str = "vital"
        raw_utterance: str = "health vital"
        ts: object = real_event_dt
        created_at: object = None

    with patch("axi.domain_bridge._fetch_domain_entries", return_value=[_FakeEntry()]):
        count = backfill_node_occurred_at()

    assert count >= 1, (
        "backfill_node_occurred_at should return >= 1 when at least one node "
        "had NULL occurred_at and a domain entry with a real timestamp"
    )

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(real_event_epoch, abs=1), (
        f"backfill_node_occurred_at should set occurred_at={real_event_epoch} "
        f"from the entry's ts; got {row['occurred_at']}"
    )


def test_backfill_node_occurred_at_is_idempotent():
    """T5b RED: Running backfill twice must not change already-set occurred_at values."""
    import axi.store as store
    from axi.domain_bridge import backfill_node_occurred_at

    conn = store._connect()

    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", "health to backfill", "{}", "health", now, now),
    )
    conn.commit()
    node_id = cur.lastrowid

    entry_id = "he-backfill-002"
    conn.execute(
        "INSERT INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("health", entry_id, node_id, now),
    )
    conn.commit()

    real_event_dt = datetime(2026, 6, 15, 9, 0, 0, tzinfo=timezone.utc)

    @dataclass
    class _FakeEntry:
        id: str = entry_id
        kind: str = "vital"
        raw_utterance: str = "health vital"
        ts: object = real_event_dt
        created_at: object = None

    with patch("axi.domain_bridge._fetch_domain_entries", return_value=[_FakeEntry()]):
        count1 = backfill_node_occurred_at()
        count2 = backfill_node_occurred_at()

    # Second run: node already has occurred_at set → should return 0 updated.
    assert count2 == 0, (
        "backfill_node_occurred_at must be idempotent: second run should return 0 "
        "since occurred_at is already set"
    )


def test_backfill_node_occurred_at_skips_already_set():
    """T5c: Nodes where occurred_at is already set must not be touched."""
    import axi.store as store
    from axi.domain_bridge import backfill_node_occurred_at

    conn = store._connect()

    # Node with occurred_at already set.
    original_epoch = 1_000_000.0
    nid = store.add_node("fact", "already has date", occurred_at=original_epoch)

    entry_id = "he-already-set-003"
    conn.execute(
        "INSERT INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("health", entry_id, nid, time.time()),
    )
    conn.commit()

    # Entry with a DIFFERENT timestamp — backfill must not overwrite.
    other_dt = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)

    @dataclass
    class _FakeEntry:
        id: str = entry_id
        kind: str = "vital"
        raw_utterance: str = "health vital"
        ts: object = other_dt
        created_at: object = None

    with patch("axi.domain_bridge._fetch_domain_entries", return_value=[_FakeEntry()]):
        count = backfill_node_occurred_at()

    assert count == 0, "backfill should skip nodes where occurred_at is already set"

    row = store.get_node(nid)
    assert row["occurred_at"] == pytest.approx(original_epoch), (
        "backfill must not overwrite an already-set occurred_at value"
    )


# ═══════════════════════════════════════════════════════════════════════════
# T5d — backfill_node_occurred_at: generous default window (FIX 1)
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_default_window_covers_entries_older_than_one_year():
    """T5d RED: The DEFAULT call (no days= arg) must populate occurred_at for a
    node whose real event date is 800 days ago.

    Prior to the fix, days defaulted to 365.  An entry with event_ts = 800 days
    ago is outside that window and would NOT be returned by _fetch_domain_entries,
    leaving occurred_at NULL — the dense-mesh bug persists for >1-year-old entries.

    After the fix (days=36500 ≈ 100 years), all existing entries are reachable.
    The test uses a patched _fetch_domain_entries so the call is local and fast.
    """
    import axi.store as store
    from axi.domain_bridge import backfill_node_occurred_at

    conn = store._connect()

    now = time.time()
    cur = conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", "ancient health event", "{}", "health", now, now),
    )
    conn.commit()
    node_id = cur.lastrowid

    entry_id = "he-ancient-800d"
    conn.execute(
        "INSERT INTO domain_node_map(domain, entry_id, node_id, created_at) "
        "VALUES (?, ?, ?, ?)",
        ("health", entry_id, node_id, now),
    )
    conn.commit()

    # Real event date is 800 days ago — well outside the old 365-day default.
    ancient_dt = datetime.now(tz=timezone.utc) - timedelta(days=800)
    ancient_epoch = ancient_dt.timestamp()

    # Track the days= value that _fetch_domain_entries is actually called with.
    received_days: list[int] = []

    @dataclass
    class _FakeEntry:
        id: str = entry_id
        kind: str = "vital"
        raw_utterance: str = "ancient vital"
        ts: object = ancient_dt
        created_at: object = None

    def _fake_fetch(domain, *, days, limit=None):  # noqa: ANN001
        received_days.append(days)
        return [_FakeEntry()]

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        count = backfill_node_occurred_at()  # no days= argument — uses the default

    # The default window must be generous enough to cover 800-day-old entries.
    assert received_days, "_fetch_domain_entries was never called"
    assert received_days[0] >= 800, (
        f"backfill_node_occurred_at default days={received_days[0]} is too small to "
        f"cover an 800-day-old entry. Default should be >= 36500 (≈100 years)."
    )

    assert count >= 1, (
        "backfill_node_occurred_at did not update the ancient node; "
        "the default look-back window is too narrow."
    )

    row = store.get_node(node_id)
    assert row is not None
    assert row["occurred_at"] == pytest.approx(ancient_epoch, abs=1), (
        f"occurred_at should be the ancient event epoch ({ancient_epoch}); "
        f"got {row['occurred_at']}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# T5e — backfill_node_occurred_at: rowcount accuracy (FIX 2)
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_rowcount_reflects_actual_rows_updated():
    """T5e RED: The return value of backfill_node_occurred_at must equal the number
    of rows actually changed in the DB — NOT the number of iterations.

    Scenario:
      - Two nodes with NULL occurred_at and matching domain entries.
      - First call → both updated → count == 2.
      - Second call → both already set → count == 0 (idempotency + rowcount check).

    If the code does `updated += 1` unconditionally (without checking rowcount),
    the second call would still return 2 (the loop iterates but SQLite's
    WHERE occurred_at IS NULL prevents any actual writes).
    """
    import axi.store as store
    from axi.domain_bridge import backfill_node_occurred_at

    conn = store._connect()
    now = time.time()

    node_ids = []
    entry_ids = []
    for i in range(2):
        cur = conn.execute(
            "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (str(_uuid.uuid4()), "fact", f"rowcount test node {i}", "{}", "health", now, now),
        )
        conn.commit()
        nid = cur.lastrowid
        node_ids.append(nid)

        eid = f"he-rowcount-{i:03d}"
        entry_ids.append(eid)
        conn.execute(
            "INSERT INTO domain_node_map(domain, entry_id, node_id, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("health", eid, nid, now),
        )
        conn.commit()

    real_dt = datetime(2025, 1, 15, 10, 0, 0, tzinfo=timezone.utc)

    @dataclass
    class _FakeEntry:
        id: str = ""
        kind: str = "vital"
        raw_utterance: str = "rowcount test"
        ts: object = real_dt
        created_at: object = None

    def _fake_fetch(domain, *, days, limit=None):  # noqa: ANN001
        return [_FakeEntry(id=eid) for eid in entry_ids]

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        count_first = backfill_node_occurred_at()
        count_second = backfill_node_occurred_at()

    assert count_first == 2, (
        f"First backfill run should update exactly 2 nodes; got {count_first}. "
        "Make sure the count uses cur.rowcount, not unconditional += 1."
    )
    assert count_second == 0, (
        f"Second backfill run should return 0 (all occurred_at already set); "
        f"got {count_second}. This indicates the count does NOT reflect actual DB writes."
    )


# ═══════════════════════════════════════════════════════════════════════════
# T6 — /api/graph/full includes occurred_at; brain3d.html references it
# ═══════════════════════════════════════════════════════════════════════════


def test_graph_full_includes_occurred_at_in_node_json():
    """T6a RED: /api/graph/full node objects must include occurred_at field."""
    import axi.store as store
    from fastapi.testclient import TestClient
    from axi.dashboard import app

    client = TestClient(app)

    # Create a node with a known occurred_at.
    known_epoch = _day_epoch(3) + 3600
    nid = store.add_node("fact", "event with date", occurred_at=known_epoch)

    resp = client.get("/api/graph/full")
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"

    data = resp.json()
    nodes = {n["id"]: n for n in data["nodes"]}

    assert nid in nodes, f"Node {nid} not found in /api/graph/full response"

    node = nodes[nid]
    assert "occurred_at" in node, (
        "/api/graph/full node object is missing 'occurred_at' field; "
        "dashboard.py must include it in the graph_full response"
    )
    assert node["occurred_at"] == pytest.approx(known_epoch, abs=1), (
        f"Expected occurred_at={known_epoch}, got {node['occurred_at']}"
    )


def test_graph_full_occurred_at_null_when_not_set():
    """T6b: /api/graph/full node with no event date has occurred_at=null."""
    import axi.store as store
    from fastapi.testclient import TestClient
    from axi.dashboard import app

    client = TestClient(app)

    nid = store.add_node("fact", "event without date")

    resp = client.get("/api/graph/full")
    assert resp.status_code == 200

    data = resp.json()
    nodes = {n["id"]: n for n in data["nodes"]}
    assert nid in nodes

    node = nodes[nid]
    assert "occurred_at" in node, "/api/graph/full must include occurred_at (even if null)"
    assert node["occurred_at"] is None, "occurred_at should be null when node has no event date"


def test_brain3d_html_references_occurred_at():
    """T6c RED: brain3d.html template must reference occurred_at and display a date label.

    We check the template source directly — it must contain 'occurred_at' (to read
    the field from the API response) and a date UI label ('date' key in the LABELS
    object or a literal 'Fecha' / 'Date' string).
    """
    from pathlib import Path

    template_path = Path(__file__).parent.parent / "src" / "axi" / "templates" / "brain3d.html"
    assert template_path.exists(), f"brain3d.html not found at {template_path}"

    content = template_path.read_text()

    assert "occurred_at" in content, (
        "brain3d.html must reference 'occurred_at' to display the event date "
        "in the node-detail panel"
    )

    # Should have a date label key ('date') in the i18n LABELS or a literal label.
    has_date_label = (
        "'date'" in content
        or '"date"' in content
        or "Fecha" in content
        or "Date:" in content
        or "fecha" in content
    )
    assert has_date_label, (
        "brain3d.html must show a date label (e.g. 'Fecha:' / 'Date:') "
        "for selected nodes when occurred_at is present"
    )
