"""Tests for Slice 3: backfill_all_domains + graph-hygiene fixes.

TDD order: RED tests written first, GREEN follows after implementation.

Phases covered:
  3.1 — backfill_all_domains: bounded, idempotent, skips already-bridged entries
  3.2 — store.py: backfill_domain_fact_nodes shim delegates to backfill_all_domains
  3.3 — store.py: create_fact_node_for_interaction re-export shim (import compat)
  HYG-1 — meeting.py: race-loser orphan DELETE also cleans nodes_fts
  HYG-2 — store.py: backfill_domain_fact_nodes idempotency guard uses str(id)
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any
from unittest.mock import patch, MagicMock

import pytest


# ─── helpers ────────────────────────────────────────────────────────────────


@dataclass
class FakeEntry:
    """Minimal duck-typed domain entry for testing."""
    id: Any = "e-001"
    kind: str = "test"
    raw_utterance: str | None = None
    title: str | None = "Test entry"


def _seed_meeting(conn, *, summary: str = "", status: str = "done") -> int:
    """Insert a bare meeting row (without node_id) and return its id."""
    now = time.time()
    cur = conn.execute(
        "INSERT INTO meetings(start_time, source, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (now, "test", "/tmp/test_meeting_s3", status, now),
    )
    conn.commit()
    return cur.lastrowid


# ═══════════════════════════════════════════════════════════════════════════
# HYG-1 — meeting.py: race-loser path must also DELETE FROM nodes_fts
# ═══════════════════════════════════════════════════════════════════════════


def test_meeting_bridge_race_loser_no_orphan_fts_row():
    """HYG-1 RED — race-loser path cleans up nodes_fts alongside nodes.

    Strategy: patch the UPDATE result to return rowcount=0, forcing the
    race-loser code path in bridge_meeting_node.  Then assert the orphan
    node has been removed from BOTH `nodes` AND `nodes_fts`.

    Before the fix: only `DELETE FROM nodes WHERE id=?` runs — the FTS row
    for the orphan is left behind.
    After the fix: `DELETE FROM nodes_fts WHERE rowid=?` is also executed.
    """
    import axi.store as store
    from axi.meeting import bridge_meeting_node

    conn = store._connect()
    meeting_id = _seed_meeting(conn)

    # Track which node id the race-loser path creates so we can verify cleanup.
    created_node_ids: list[int] = []
    real_add_node = store.add_node

    def _capturing_add_node(*args, **kwargs):
        nid = real_add_node(*args, **kwargs)
        created_node_ids.append(nid)
        return nid

    # We need the UPDATE to report rowcount=0 (race-loser lost).  Patch the
    # context manager returned by _tx() so that SELECT changes() → 0.
    real_tx = store._tx

    class _FakeCtx:
        def __init__(self):
            self._real_ctx = real_tx()

        def __enter__(self):
            self._conn = self._real_ctx.__enter__()
            return _WrappedConn(self._conn)

        def __exit__(self, *args):
            return self._real_ctx.__exit__(*args)

    class _WrappedConn:
        def __init__(self, conn):
            self._conn = conn
            self._last_was_update = False

        def execute(self, sql, params=()):
            stripped = sql.strip().upper()
            if stripped.startswith("UPDATE MEETINGS SET NODE_ID"):
                self._last_was_update = True
                return self._conn.execute(sql, params)
            if stripped == "SELECT CHANGES()" and self._last_was_update:
                self._last_was_update = False
                # Return a fake cursor that reports 0 changes → race-loser.
                class _FakeCursor:
                    def fetchone(self_inner):
                        return (0,)
                return _FakeCursor()
            self._last_was_update = False
            return self._conn.execute(sql, params)

    with patch.object(store, "add_node", side_effect=_capturing_add_node):
        with patch.object(store, "_tx", side_effect=lambda: _FakeCtx()):
            bridge_meeting_node(meeting_id, "Standup summary.")

    # The race-loser path MUST have created a node (and then cleaned it up).
    assert len(created_node_ids) == 1, (
        f"Expected add_node to be called exactly once, got {len(created_node_ids)}"
    )
    orphan_nid = created_node_ids[0]

    # The orphan node must be GONE from the graph. PR7 (tombstones) changed
    # what "gone" means for a node: the row survives carrying `deleted_at`, so
    # the delete can be replicated instead of a peer pushing the orphan back.
    # The claim of this test — the race loser leaves nothing readable behind —
    # is unchanged, and the FTS half below is unchanged too, because FTS rows
    # are still hard-deleted.
    node_row = conn.execute(
        "SELECT id FROM nodes WHERE id=? AND deleted_at IS NULL", (orphan_nid,)
    ).fetchone()
    assert node_row is None, (
        f"Orphan node {orphan_nid} is still live in `nodes` after race-loser cleanup"
    )
    assert conn.execute(
        "SELECT deleted_at FROM nodes WHERE id=?", (orphan_nid,)
    ).fetchone()["deleted_at"] is not None, (
        f"Orphan node {orphan_nid} was hard-deleted instead of tombstoned"
    )

    # CRITICAL (the actual fix): orphan node must also be GONE from `nodes_fts`.
    fts_count = conn.execute(
        "SELECT COUNT(*) FROM nodes_fts WHERE rowid=?", (orphan_nid,)
    ).fetchone()[0]
    assert fts_count == 0, (
        f"Stale FTS row found for orphan node {orphan_nid} after race-loser cleanup. "
        f"bridge_meeting_node must DELETE FROM nodes_fts WHERE rowid=? in the cleanup block."
    )


# ═══════════════════════════════════════════════════════════════════════════
# HYG-2 — store.py: backfill_domain_fact_nodes idempotency guard uses str(id)
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_domain_fact_nodes_idempotency_guard_uses_str_id():
    """HYG-2 RED — already-bridged interactions are skipped even when entry_id is int.

    Before the fix: get_node_for_domain_entry("relationships", interaction.id)
    passes a raw int, but the stored key is str(interaction.id) — so the guard
    always misses.  After the fix, calling backfill_domain_fact_nodes twice
    must not create a second node for an already-bridged interaction.
    """
    import axi.store as store
    from axi.domain_bridge import create_fact_node_for_entry

    @dataclass
    class FakeInteraction:
        id: int = 42
        raw_utterance: str | None = None
        title: str | None = "Met with Alice"
        kind: str = "meeting"
        body: str | None = None
        person_id: int | None = None

    interaction = FakeInteraction(id=42)

    # Pre-bridge: create a node manually (simulating a prior backfill run).
    with patch("axi.store.trigger_embed_for_node"):
        nid_first = create_fact_node_for_entry("relationships", interaction)
    assert nid_first is not None

    # Verify domain_node_map has the entry keyed by str(id).
    conn = store._connect()
    row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='relationships' AND entry_id=?",
        (str(interaction.id),),
    ).fetchone()
    assert row is not None, "domain_node_map must have a row keyed by str(id)"

    # Now run backfill — the guard must catch this pre-existing entry.
    # We fake _fetch_recent_interactions to return our single interaction.
    with patch("axi.store._fetch_recent_interactions", return_value=[interaction]), \
         patch("axi.store.trigger_embed_for_node"):
        store.backfill_domain_fact_nodes(days=90)

    # Still exactly 1 node (no duplicate created by the second pass).
    count = conn.execute(
        "SELECT COUNT(*) FROM domain_node_map WHERE domain='relationships' AND entry_id=?",
        (str(interaction.id),),
    ).fetchone()[0]
    assert count == 1, (
        f"Expected 1 domain_node_map row, found {count} (idempotency guard broken)"
    )

    # Also exactly 1 node in the nodes table.
    node_count = conn.execute(
        "SELECT COUNT(*) FROM nodes WHERE domain='relationships'",
    ).fetchone()[0]
    assert node_count == 1, (
        f"Expected 1 relationships node, found {node_count} (duplicate created)"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3.1 — backfill_all_domains: bounded, idempotent, cap-respected
# ═══════════════════════════════════════════════════════════════════════════


def _make_fake_entries(n: int, domain: str = "health") -> list[FakeEntry]:
    """Return n FakeEntry objects with unique integer ids."""
    return [FakeEntry(id=i + 1, title=f"{domain} entry {i + 1}") for i in range(n)]


def test_backfill_all_domains_creates_nodes_for_unbridged():
    """3.1.1 RED — backfill creates nodes for pre-existing un-bridged entries.

    10 un-bridged health entries, node_limit=3 → exactly 3 nodes created
    (across all domains, but since only health is mocked here it's all health).
    """
    import axi.store as store
    from axi.domain_bridge import backfill_all_domains

    entries = _make_fake_entries(10, "health")

    # Mock only health fetch; all other domains return empty.
    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        if domain == "health":
            return entries
        return []

    # Suppress embed worker to avoid cross-test connection leaks.
    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result = backfill_all_domains(node_limit=3)

    assert result["health"] == 3, (
        f"Expected 3 health nodes created (node_limit=3), got {result['health']}"
    )
    # Total across all domains must not exceed node_limit.
    total = sum(result.values())
    assert total <= 3, f"Total nodes created ({total}) exceeds node_limit=3"


def test_backfill_all_domains_fewer_entries_than_limit():
    """3.1.2 RED — node_limit=5, only 3 un-bridged entries → exactly 3 nodes."""
    import axi.store as store
    from axi.domain_bridge import backfill_all_domains

    entries = _make_fake_entries(3, "health")

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        if domain == "health":
            return entries
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result = backfill_all_domains(node_limit=5)

    assert result["health"] == 3, (
        f"Expected 3 health nodes (only 3 entries exist), got {result['health']}"
    )


def test_backfill_all_domains_idempotent():
    """3.1.3 RED — running backfill twice creates no duplicate nodes."""
    from axi.domain_bridge import backfill_all_domains
    import axi.store as store

    entries = _make_fake_entries(5, "health")

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        if domain == "health":
            return entries
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result1 = backfill_all_domains(node_limit=10)

    # Second run: same entries already bridged.
    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result2 = backfill_all_domains(node_limit=10)

    assert result1["health"] == 5, f"First run: expected 5 nodes, got {result1['health']}"
    assert result2.get("health", 0) == 0, (
        f"Second run: expected 0 new nodes (all already bridged), got {result2.get('health')}"
    )

    # Exactly 5 rows in domain_node_map.
    conn = store._connect()
    count = conn.execute(
        "SELECT COUNT(*) FROM domain_node_map WHERE domain='health'"
    ).fetchone()[0]
    assert count == 5, f"Expected 5 domain_node_map rows, found {count}"


def test_backfill_all_domains_already_bridged_entries_skipped():
    """3.1.4 RED — entries already in domain_node_map are skipped (idempotency)."""
    from axi.domain_bridge import backfill_all_domains, create_fact_node_for_entry
    import axi.store as store

    entries = _make_fake_entries(4, "health")

    # Pre-bridge the first 2 entries (suppress embed worker to avoid flake).
    with patch("axi.store.trigger_embed_for_node"):
        for entry in entries[:2]:
            create_fact_node_for_entry("health", entry)

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        if domain == "health":
            return entries
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result = backfill_all_domains(node_limit=10)

    # Only the 2 un-bridged entries should be created.
    assert result["health"] == 2, (
        f"Expected 2 new nodes (2 were already bridged), got {result['health']}"
    )


def test_backfill_all_domains_returns_dict_per_domain():
    """3.1.5 RED — return value is a dict mapping domain → nodes_created int."""
    from axi.domain_bridge import backfill_all_domains

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch):
        result = backfill_all_domains()

    assert isinstance(result, dict), f"Expected dict, got {type(result)}"
    for k, v in result.items():
        assert isinstance(k, str), f"Key {k!r} must be str"
        assert isinstance(v, int), f"Value {v!r} for domain {k!r} must be int"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3.2 — store.py: backfill_domain_fact_nodes shim
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_domain_fact_nodes_delegates_to_backfill_all_domains():
    """3.2.1 — store.backfill_domain_fact_nodes delegates to backfill_all_domains.

    After the Slice 3 refactor, backfill_domain_fact_nodes delegates to
    backfill_all_domains(domains=["relationships"], ...) so the fetch path goes
    through _fetch_domain_entries, not _fetch_recent_interactions.
    """
    import axi.store as store

    @dataclass
    class FakeInteraction:
        id: int = 99
        raw_utterance: str | None = None
        title: str | None = "Met with Bob"
        kind: str = "meeting"
        body: str | None = None
        person_id: int | None = None

    interaction = FakeInteraction(id=99)

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None):
        if domain == "relationships":
            return [interaction]
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        count = store.backfill_domain_fact_nodes(days=90)

    assert count >= 1, f"Expected at least 1 interaction bridged, got {count}"

    # Verify domain_node_map has the row.
    conn = store._connect()
    row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='relationships' AND entry_id=?",
        (str(interaction.id),),
    ).fetchone()
    assert row is not None, "domain_node_map row not found after backfill_domain_fact_nodes"


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3.3 — store.py: create_fact_node_for_interaction re-export still works
# ═══════════════════════════════════════════════════════════════════════════


def test_create_fact_node_for_interaction_importable_from_store():
    """3.3.1 RED — create_fact_node_for_interaction is still importable from axi.store."""
    from axi.store import create_fact_node_for_interaction  # noqa: F401
    assert callable(create_fact_node_for_interaction)


def test_create_fact_node_for_interaction_from_store_creates_node():
    """3.3.2 RED — importing from store and calling produces a node."""
    import axi.store as store
    from axi.store import create_fact_node_for_interaction

    @dataclass
    class FakeInteraction:
        id: int = 77
        raw_utterance: str | None = None
        title: str | None = "Lunch with friend"
        kind: str = "social"
        body: str | None = None
        person_id: int | None = None

    interaction = FakeInteraction(id=77)
    with patch("axi.store.trigger_embed_for_node"):
        nid = create_fact_node_for_interaction(interaction)
    assert isinstance(nid, int) and nid > 0

    conn = store._connect()
    row = conn.execute(
        "SELECT node_id FROM domain_node_map WHERE domain='relationships' AND entry_id=?",
        (str(interaction.id),),
    ).fetchone()
    assert row is not None


# ═══════════════════════════════════════════════════════════════════════════
# Review fixes: FIX 1 — fairness / round-robin starvation prevention
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_all_domains_no_domain_starvation():
    """FIX 1 RED — later domains are not starved when an early domain is large.

    Setup: health has N=10 entries, finance has M=5 entries, node_limit=6.
    Under the old greedy loop: health consumes all 6 slots → finance gets 0.
    Under the new fair (round-robin) loop: finance must receive at least 1 node
    on the first call to backfill_all_domains.

    This test MUST FAIL against the original order-greedy implementation.
    """
    from axi.domain_bridge import backfill_all_domains

    health_entries = _make_fake_entries(10, "health")
    finance_entries = [FakeEntry(id=100 + i, title=f"finance entry {i}") for i in range(5)]

    def _fake_fetch(domain: str, *, days: int, limit: int | None = None) -> list[Any]:
        if domain == "health":
            return health_entries
        if domain == "finance":
            return finance_entries
        return []

    with patch("axi.domain_bridge._fetch_domain_entries", side_effect=_fake_fetch), \
         patch("axi.store.trigger_embed_for_node"):
        result = backfill_all_domains(node_limit=6)

    total = sum(result.values())
    assert total <= 6, f"Total ({total}) exceeded node_limit=6"

    # Finance MUST NOT be starved: it must receive at least 1 node.
    assert result.get("finance", 0) >= 1, (
        f"finance got 0 nodes — domain starvation detected. "
        f"health={result.get('health', 0)}, finance={result.get('finance', 0)}. "
        f"backfill_all_domains must use round-robin or similar fair allocation."
    )


# ═══════════════════════════════════════════════════════════════════════════
# Review fixes: FIX 2 — real delegation test (spy on backfill_all_domains)
# ═══════════════════════════════════════════════════════════════════════════


def test_backfill_domain_fact_nodes_actually_delegates_to_backfill_all_domains():
    """FIX 2 RED — backfill_domain_fact_nodes MUST call backfill_all_domains.

    Patches backfill_all_domains and asserts it is called with the relationships
    domain in scope. This test FAILS if delegation is removed and a parallel
    loop is used instead.
    """
    import axi.store as store

    @dataclass
    class FakeInteraction:
        id: int = 55
        raw_utterance: str | None = None
        title: str | None = "Chat with Carol"
        kind: str = "chat"
        body: str | None = None
        person_id: int | None = None

    fake_result = {"relationships": 1}

    with patch("axi.store._fetch_recent_interactions", return_value=[FakeInteraction()]), \
         patch("axi.domain_bridge.backfill_all_domains", return_value=fake_result) as mock_backfill:
        result = store.backfill_domain_fact_nodes(days=90)

    # Must have delegated to backfill_all_domains.
    mock_backfill.assert_called_once()
    call_kwargs = mock_backfill.call_args

    # The call must be scoped to "relationships" domain only.
    domains_arg = (
        call_kwargs.kwargs.get("domains")
        if call_kwargs.kwargs
        else None
    )
    assert domains_arg is not None and "relationships" in domains_arg, (
        f"backfill_all_domains was called but not scoped to 'relationships'. "
        f"Call args: {call_kwargs}. "
        f"backfill_domain_fact_nodes must pass domains=['relationships'] (or equivalent)."
    )

    # Return value must reflect the relationships count.
    assert result == 1, f"Expected return value 1, got {result}"


# ═══════════════════════════════════════════════════════════════════════════
# Review fixes: FIX 3 — _fetch_domain_entries warns on unknown domain
# ═══════════════════════════════════════════════════════════════════════════


def test_fetch_domain_entries_warns_on_unknown_domain():
    """FIX 3 RED — _fetch_domain_entries logs a warning for an unrecognised domain.

    Before the fix: silently returns [].
    After the fix: calls log.warning(...) with the unknown domain name,
    then returns [].
    """
    from axi.domain_bridge import _fetch_domain_entries
    import logging

    with patch("axi.domain_bridge.log") as mock_log:
        result = _fetch_domain_entries("nonexistent-domain-xyz", days=30)

    assert result == [], f"Expected empty list, got {result!r}"
    mock_log.warning.assert_called_once()
    warning_call = mock_log.warning.call_args
    # The warning message must contain the unknown domain name.
    assert "nonexistent-domain-xyz" in str(warning_call), (
        f"Warning must mention the unknown domain. Got: {warning_call}"
    )


# ═══════════════════════════════════════════════════════════════════════════
# Family attribution: backfill must include family-subject entries
# ═══════════════════════════════════════════════════════════════════════════


def test_fetch_health_includes_family_entries():
    """Backfill fetch must pass subject='any' for health, else family entries
    created while the daemon was down would never reach the graph."""
    from axi.domain_bridge import _fetch_domain_entries

    with patch("lifeos.health.entries.list_recent") as mock_lr:
        mock_lr.return_value = []
        _fetch_domain_entries("health", days=7)

    assert mock_lr.call_args.kwargs.get("subject") == "any", (
        f"health backfill fetch must use subject='any'; got kwargs "
        f"{mock_lr.call_args.kwargs}"
    )


def test_fetch_exercise_includes_family_entries():
    """Same as health: exercise backfill must fetch subject='any'."""
    from axi.domain_bridge import _fetch_domain_entries

    with patch("lifeos.exercise.sessions.list_recent") as mock_lr:
        mock_lr.return_value = []
        _fetch_domain_entries("exercise", days=7)

    assert mock_lr.call_args.kwargs.get("subject") == "any", (
        f"exercise backfill fetch must use subject='any'; got kwargs "
        f"{mock_lr.call_args.kwargs}"
    )
