"""Tests for PR8's pre-rebuild backup gate (tasks 8.1-8.5).

PR8 rebuilds `nodes`/`edges` and drops `from_id`/`to_id`/`kind`. From that
commit on there is NO code-level revert: `git revert` gives you code that
queries columns which no longer exist on disk. The ONLY recovery path is
restore-from-verified-backup, which is why this gate has to be complete and
green before a single line of the rebuild is written.

`design-schema.md`'s VERIFIED section already MEASURED that `VACUUM INTO` on
SQLCipher carries the key into the snapshot and does not emit plaintext. This
file does not re-spike that; it PINS both halves as regression tests so a
future SQLCipher upgrade that changes either one fails loudly instead of
silently producing an unrestorable — or worse, unencrypted — safety backup.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import sqlcipher3

from axi import store


def _seed_graph() -> tuple[int, int, int]:
    """Two nodes and an edge between them, through the production writers."""
    a = store.add_node("person", "Ana")
    b = store.add_node("fact", "Ana takes losartan")
    e = store.add_edge(a, b, "about")
    return a, b, e


def _open_snapshot(path: Path, key: str | None) -> sqlcipher3.Connection:
    conn = sqlcipher3.connect(str(path), isolation_level=None)
    if key is not None:
        conn.execute(f"PRAGMA key = \"x'{key}'\"")
        # The snapshot carries a vec0 virtual table and a trigger referencing
        # it; without the extension any statement SQLite must compile against
        # them fails with "no such module: vec0".
        try:
            store._load_sqlite_vec(conn)
        except Exception:  # noqa: BLE001
            pass
    return conn


# ── 8.1 / 8.2: the two halves of the VACUUM INTO measurement, pinned ────────


def test_snapshot_opens_with_the_key_and_carries_every_row():
    """8.1 — the snapshot is RESTORABLE: same key, all rows present."""
    a, b, e = _seed_graph()
    path = Path(store.verified_pre_rebuild_backup())

    assert path.exists()
    snap = _open_snapshot(path, store.load_key())
    try:
        assert snap.execute("SELECT COUNT(*) FROM nodes").fetchone()[0] == \
            store._connect().execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
        labels = {r[0] for r in snap.execute("SELECT label FROM nodes").fetchall()}
        assert {"Ana", "Ana takes losartan"} <= labels
        assert snap.execute(
            "SELECT COUNT(*) FROM edges WHERE id = ?", (e,)
        ).fetchone()[0] == 1
    finally:
        snap.close()


def test_snapshot_stays_encrypted_without_the_key():
    """8.2 — the half nobody asked about, and the one that would have hurt.

    Had `VACUUM INTO` emitted plaintext, the safety backup taken before the
    irreversible step would itself be an unencrypted dump of the entire memory
    graph sitting on disk: a privacy failure hiding inside a safety mechanism.
    """
    _seed_graph()
    path = Path(store.verified_pre_rebuild_backup())

    snap = _open_snapshot(path, key=None)
    try:
        with pytest.raises(sqlcipher3.DatabaseError):
            snap.execute("SELECT COUNT(*) FROM nodes").fetchone()
    finally:
        snap.close()


# ── 8.3 / 8.4: the gate rejects a snapshot it cannot prove restorable ───────


def test_gate_aborts_when_the_snapshot_fails_integrity_check(monkeypatch):
    """8.3 — a snapshot that was WRITTEN is not the same as one that RESTORES.

    The real verification code runs against a real, genuinely damaged file:
    the snapshot is taken for real and then truncated, exactly the torn-copy
    shape this gate exists to catch.
    """
    _seed_graph()
    real_vacuum = store._vacuum_into

    def _torn_vacuum(dest: Path) -> None:
        real_vacuum(dest)
        size = dest.stat().st_size
        with dest.open("r+b") as fh:
            fh.truncate(size // 3)

    monkeypatch.setattr(store, "_vacuum_into", _torn_vacuum)
    with pytest.raises(store.MigrationBackupError):
        store.verified_pre_rebuild_backup()


def test_gate_aborts_on_row_count_mismatch(monkeypatch):
    """8.4 — a structurally sound snapshot missing rows still passes
    `integrity_check`. Row-count parity is what catches it."""
    a, b, e = _seed_graph()
    real_vacuum = store._vacuum_into

    def _lossy_vacuum(dest: Path) -> None:
        real_vacuum(dest)
        snap = _open_snapshot(dest, store.load_key())
        snap.execute("DELETE FROM nodes WHERE id = ?", (b,))
        snap.close()

    monkeypatch.setattr(store, "_vacuum_into", _lossy_vacuum)
    with pytest.raises(store.MigrationBackupError) as exc:
        store.verified_pre_rebuild_backup()
    assert "nodes" in str(exc.value)


def test_gate_aborts_when_a_sampled_id_uuid_pair_disagrees(monkeypatch):
    """8.4 — row COUNTS can match while the rows themselves are wrong. The
    sampled `(id, uuid)` spot-check is the half that notices."""
    a, _b, _e = _seed_graph()
    real_vacuum = store._vacuum_into

    def _scrambled_vacuum(dest: Path) -> None:
        real_vacuum(dest)
        snap = _open_snapshot(dest, store.load_key())
        snap.execute("UPDATE nodes SET uuid = ? WHERE id = ?", ("not-the-uuid", a))
        snap.close()

    monkeypatch.setattr(store, "_vacuum_into", _scrambled_vacuum)
    with pytest.raises(store.MigrationBackupError) as exc:
        store.verified_pre_rebuild_backup()
    assert "uuid" in str(exc.value)


# ── 8.5: the gate is an injected callable on the migration entry point ──────


def test_rebuild_refuses_to_start_when_the_injected_backup_fails(pre_pr8_graph):
    """8.5 — fake failure. Nothing may touch `nodes`/`edges` when the only
    recovery path this migration will ever have could not be established."""
    before = {r[1] for r in store._connect().execute(
        "PRAGMA table_xinfo(edges)").fetchall()}

    def _failing_backup() -> str:
        raise store.MigrationBackupError("no space left on device")

    with pytest.raises(store.MigrationBackupError):
        store.migrate_rebuild_graph_tables(backup=_failing_backup)

    after = {r[1] for r in store._connect().execute(
        "PRAGMA table_xinfo(edges)").fetchall()}
    assert after == before
    assert store._connect().execute("PRAGMA user_version").fetchone()[0] == 0


def test_rebuild_runs_with_an_injected_successful_backup(pre_pr8_graph):
    """8.5 — fake success: no real device, no real key ceremony needed."""
    calls: list[str] = []

    def _fake_backup() -> str:
        calls.append("taken")
        return "/tmp/does-not-need-to-exist.db"

    assert store.migrate_rebuild_graph_tables(backup=_fake_backup) is True
    assert calls == ["taken"]


def test_default_backup_callable_is_the_verified_one(monkeypatch, pre_pr8_graph):
    """8.6 — the gate is not opt-in. Calling the migration with no `backup`
    argument at all must still take (and verify) a snapshot first."""
    seen: list[str] = []
    monkeypatch.setattr(
        store, "verified_pre_rebuild_backup",
        lambda: seen.append("default") or "/tmp/x.db",
    )
    store.migrate_rebuild_graph_tables()
    assert seen == ["default"]
