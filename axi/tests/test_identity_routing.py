"""Tests for single-writer routing of the identity WRITE functions (Stage 2b).

The identity module does RAW ``store._tx`` writes (ensure_user_hub rename,
register_alias merge) and compound entity/edge writes that must run atomically
on the sole writer. Stage 2b forwards each WHOLE identity write function when it
is called without a ``conn``. Covered here:

  - end-to-end: with a WriteServer running + single_writer ON + client not owner,
    calling identity.<fn>(conn=None) forwards and the write lands in the per-test
    temp DB (verified by reading nodes/edges directly)
  - owner short-circuit: is_owner() True → executes directly, socket untouched
  - conn provided → NOT forwarded (runs on the given conn), even with routing ON

Style mirrors test_write_router.py.
"""
from __future__ import annotations

import pytest

from axi import identity, store, write_router


# ─────────────────────────── server fixture ──────────────────────────────────


@pytest.fixture
def write_server(tmp_path, monkeypatch):
    """A running WriteServer bound to an isolated socket under tmp_path, with the
    module-level WRITE_SOCK_PATH pointed at it so client and server agree."""
    sock_path = tmp_path / "write.sock"
    monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", sock_path)
    server = write_router.WriteServer(path=sock_path)
    server.start()
    try:
        yield server
    finally:
        server.stop()


# ─────────────────────── end-to-end forwarded writes ─────────────────────────


class TestIdentityRoutingEndToEnd:
    """single_writer ON + not owner: each identity write forwards to the server,
    which runs the REAL identity function against the temp DB. is_owner is left
    REAL — False on the client thread, flipped True inside the handler thread."""

    @pytest.fixture(autouse=True)
    def _routing_on(self, fresh_db, write_server, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        # A stable user name so the hub has a deterministic label.
        monkeypatch.setattr(identity, "user_name", lambda: "Héctor")
        assert write_router.is_owner() is False  # client thread is not the owner

    def test_ensure_user_hub_forwarded(self):
        hub = identity.ensure_user_hub()
        assert isinstance(hub, int)
        row = store._connect().execute(
            "SELECT label, data FROM nodes WHERE id = ?", (hub,)
        ).fetchone()
        assert row["label"] == "Héctor"
        import json
        assert json.loads(row["data"])["role"] == "user"

    def test_ensure_entity_forwarded(self):
        ent = identity.ensure_entity("Ana Ríos", "person")
        assert isinstance(ent, int)
        row = store._connect().execute(
            "SELECT kind, label FROM nodes WHERE id = ?", (ent,)
        ).fetchone()
        assert row["kind"] == "person"
        assert row["label"] == "Ana Ríos"

    def test_ensure_entity_idempotent_across_forwards(self):
        first = identity.ensure_entity("Ana", "person")
        second = identity.ensure_entity("Ana", "person")
        assert first == second
        n = store._connect().execute(
            "SELECT COUNT(*) AS n FROM nodes WHERE kind='person' AND label='Ana'"
        ).fetchone()["n"]
        assert n == 1

    def test_register_alias_merge_forwarded(self):
        """register_alias's compound merge (raw _tx UPDATE/DELETE) runs on the
        daemon: the duplicate node's edges move onto the canonical node and the
        duplicate is deleted."""
        canonical = identity.ensure_entity("Ana Ríos", "person")
        dup = identity.ensure_entity("Ani", "person")
        assert canonical != dup
        # Give the duplicate an edge so we can prove it is re-pointed, not lost.
        fact = store.add_node(kind="fact", label="quiere a Ani")
        store.add_edge(fact, dup, "mentions")

        identity.register_alias("Ana Ríos", "Ani", "person")

        c = store._connect()
        # Duplicate node is gone.
        assert c.execute("SELECT id FROM nodes WHERE id=?", (dup,)).fetchone() is None
        # Its edge now points at the canonical node.
        assert c.execute(
            "SELECT to_id FROM edges WHERE from_id=? AND kind='mentions'", (fact,)
        ).fetchone()["to_id"] == canonical
        # The alias is recorded on the canonical node's data.
        import json
        data = json.loads(
            c.execute("SELECT data FROM nodes WHERE id=?", (canonical,)).fetchone()["data"]
        )
        assert "Ani" in data.get("aliases", [])

    def test_add_relation_forwarded(self):
        identity.add_relation("esposa", "Ana Ríos", "person")
        c = store._connect()
        hub = c.execute(
            "SELECT id FROM nodes WHERE kind='person' AND label='Héctor'"
        ).fetchone()["id"]
        row = c.execute(
            "SELECT to_id FROM edges WHERE from_id=? AND kind='esposa'", (hub,)
        ).fetchone()
        assert row is not None
        ent = c.execute(
            "SELECT label FROM nodes WHERE id=?", (row["to_id"],)
        ).fetchone()
        assert ent["label"] == "Ana Ríos"

    def test_add_entity_relation_forwarded(self):
        identity.add_entity_relation(
            "hipertensión", "tratada_con", "losartán",
            subject_kind="condition", object_kind="medication",
        )
        c = store._connect()
        subj = c.execute(
            "SELECT id FROM nodes WHERE label='hipertensión'"
        ).fetchone()["id"]
        obj = c.execute(
            "SELECT id FROM nodes WHERE label='losartán'"
        ).fetchone()["id"]
        assert c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='tratada_con'",
            (subj, obj),
        ).fetchone() is not None

    def test_link_fact_to_user_forwarded(self):
        fact = store.add_node(kind="fact", label="me gusta el mate")
        identity.link_fact_to_user(fact)
        c = store._connect()
        hub = c.execute(
            "SELECT id FROM nodes WHERE kind='person' AND label='Héctor'"
        ).fetchone()["id"]
        assert c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='about'",
            (hub, fact),
        ).fetchone() is not None

    def test_link_fact_to_entities_forwarded(self):
        ent = identity.ensure_entity("Ana Ríos", "person")
        fact = store.add_node(kind="fact", label="cené con Ana Ríos")
        identity.link_fact_to_entities(fact, "cené con Ana Ríos")
        assert store._connect().execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='mentions'",
            (fact, ent),
        ).fetchone() is not None


# ─────────────────────────── owner short-circuit ─────────────────────────────


class TestIdentityOwnerShortCircuit:
    """is_owner() True → identity writes execute directly, socket never touched."""

    def test_ensure_entity_owner_direct(self, fresh_db, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)

        def _fail(*a, **kw):
            raise AssertionError("owner must not forward writes")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        ent = identity.ensure_entity("Bruno", "person")
        assert isinstance(ent, int)
        row = store._connect().execute(
            "SELECT label FROM nodes WHERE id=?", (ent,)
        ).fetchone()
        assert row["label"] == "Bruno"

    def test_register_alias_owner_direct(self, fresh_db, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)

        def _fail(*a, **kw):
            raise AssertionError("owner must not forward writes")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        canonical = identity.ensure_entity("Ana Ríos", "person")
        identity.register_alias("Ana Ríos", "Ani", "person")
        import json
        data = json.loads(
            store._connect().execute(
                "SELECT data FROM nodes WHERE id=?", (canonical,)
            ).fetchone()["data"]
        )
        assert "Ani" in data.get("aliases", [])


# ───────────────────────── conn provided: no forward ─────────────────────────


class TestIdentityConnProvidedNotForwarded:
    """When a conn is explicitly passed the caller owns the transaction, so the
    identity function's TOP-LEVEL forward guard is skipped even with single_writer
    ON and the client thread not the owner. (Its internal leaf store.add_node/
    add_edge calls do not take a conn, so those may still route via Stage 2 — the
    guarantee here is only that no whole ``identity.*`` op is forwarded.)

    A real server runs and forward_write is spied so leaf ops still succeed while
    we assert no ``identity.*`` op crossed the socket.
    """

    @pytest.fixture
    def _spy_forwards(self, fresh_db, write_server, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        assert write_router.is_owner() is False
        forwarded: list[str] = []
        real_forward = write_router.forward_write

        def _spy(op, args, *a, **kw):
            forwarded.append(op)
            return real_forward(op, args, *a, **kw)

        monkeypatch.setattr(write_router, "forward_write", _spy)
        return forwarded

    def test_ensure_entity_with_conn_not_forwarded(self, _spy_forwards):
        conn = store._connect()
        ent = identity.ensure_entity("Bruno", "person", conn=conn)
        assert isinstance(ent, int)
        # Top-level identity op never crossed the socket.
        assert not any(op.startswith("identity.") for op in _spy_forwards)
        row = conn.execute("SELECT label FROM nodes WHERE id=?", (ent,)).fetchone()
        assert row["label"] == "Bruno"

    def test_register_alias_with_conn_not_forwarded(self, _spy_forwards):
        conn = store._connect()
        canonical = identity.ensure_entity("Ana Ríos", "person", conn=conn)
        identity.register_alias("Ana Ríos", "Ani", "person", conn=conn)
        assert not any(op.startswith("identity.") for op in _spy_forwards)
        import json
        data = json.loads(
            conn.execute(
                "SELECT data FROM nodes WHERE id=?", (canonical,)
            ).fetchone()["data"]
        )
        assert "Ani" in data.get("aliases", [])
