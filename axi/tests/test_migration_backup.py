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


def test_a_write_landing_during_the_snapshot_does_not_condemn_it(tmp_path):
    """Measured on a real run, not imagined: the rebuild aborted under load.

    `VACUUM INTO` snapshots the database as of when it starts. The parity
    check then counted the LIVE table afterwards with no lock held, so any
    write arriving in between made live > snapshot and the snapshot was
    declared "missing data".

    That is not a torn copy — it is a snapshot doing exactly its job. And in
    production it is fatal: axi's daemon starts alongside the recorder,
    wakeword and write-router threads, so `init_db()` would raise on startup,
    the daemon would refuse to boot, and every restart would repeat it. The
    user meets that as "axi is dead", forever, with a message about row counts.

    A torn copy loses ARBITRARY rows; concurrent writes only ADD rows with
    higher ids. Comparing within the snapshot's own id range separates them.
    """
    store.add_node("person", "Héctor")
    store.add_node("fact", "una memoria previa")

    real_vacuum = store._vacuum_into

    def _snapshot_then_write(dest):
        result = real_vacuum(dest)
        # The concurrent writer, made deterministic: it lands AFTER the
        # snapshot is taken and BEFORE parity is checked.
        store.add_node("fact", "escrito mientras se respaldaba")
        return result

    store._vacuum_into = _snapshot_then_write
    try:
        snapshot = store.verified_pre_rebuild_backup()
    finally:
        store._vacuum_into = real_vacuum

    assert Path(snapshot).exists(), "a good snapshot was rejected"


def test_a_genuinely_torn_snapshot_is_still_rejected(tmp_path):
    """The other half. Tolerating concurrent growth must not tolerate loss.

    Without this, the fix above degrades into "never complain", which is the
    silent-failure shape this codebase refuses — and on the one file that is
    the entire rollback plan.
    """
    for i in range(6):
        store.add_node("fact", f"memoria {i}")

    real_vacuum = store._vacuum_into

    def _lossy_snapshot(dest):
        result = real_vacuum(dest)
        # `_open_snapshot` loads sqlite-vec; a bare sqlcipher3.connect cannot
        # even DELETE here, because the vec0 virtual table fails to attach.
        snap = _open_snapshot(dest, store.load_key())
        # Drop a row from the MIDDLE of the snapshot's own id range — exactly
        # what a torn copy looks like, and invisible to a count that derives
        # its range from the snapshot itself.
        snap.execute("DELETE FROM nodes WHERE id = 3")
        snap.close()
        return result

    store._vacuum_into = _lossy_snapshot
    try:
        with pytest.raises(store.MigrationBackupError, match="missing data"):
            store.verified_pre_rebuild_backup()
    finally:
        store._vacuum_into = real_vacuum


def test_a_full_disk_tells_the_user_what_to_do_about_it(monkeypatch):
    """This failure reaches the user as "axi will not start".

    init_db lets `MigrationBackupError` propagate on purpose — migrating with
    no recovery path is worse than not starting — so the daemon really does
    refuse to boot. That makes the MESSAGE the whole user experience, and
    "database or disk is full" alone leaves them looking at a dead daemon
    rather than at a disk.
    """
    _seed_graph()

    def _full_disk(dest: Path) -> None:
        raise sqlcipher3.OperationalError("database or disk is full")

    monkeypatch.setattr(store, "_vacuum_into", _full_disk)
    with pytest.raises(store.MigrationBackupError) as exc:
        store.verified_pre_rebuild_backup()

    message = str(exc.value)
    assert "MB" in message, "the message does not say how much space is needed"
    assert "free" in message.lower(), "the message does not say what to do"
    assert "untouched" in message, (
        "the message does not say the graph is safe, which is the first thing "
        "the user needs to know when the daemon will not start"
    )


def test_a_broken_space_probe_never_hides_the_real_error(monkeypatch):
    """The diagnostic must not become the failure.

    Adding "how much space you need" means calling stat() and disk_usage() on
    a filesystem that just failed a write. If either raises, the user must
    still get the backup error, not a traceback about disk_usage.
    """
    _seed_graph()

    def _full_disk(dest: Path) -> None:
        raise sqlcipher3.OperationalError("database or disk is full")

    def _broken_usage(_path):
        raise OSError("cannot stat the filesystem either")

    monkeypatch.setattr(store, "_vacuum_into", _full_disk)
    monkeypatch.setattr(store.shutil, "disk_usage", _broken_usage)

    with pytest.raises(store.MigrationBackupError, match="disk is full"):
        store.verified_pre_rebuild_backup()
