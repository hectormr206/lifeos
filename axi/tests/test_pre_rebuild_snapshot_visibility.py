"""The pre-rebuild snapshot must be DISCOVERABLE, not just correct.

PR8's `migrate_rebuild_graph_tables()` writes `memory.db.pre-rebuild-<epoch>.db`
beside the live database and never removes it. That is right — it is the entire
rollback plan, and a process that deleted its own only rollback would be worse
than one that leaves a file behind.

What was missing is that NOTHING told the user it exists. Measured on a
realistic graph (8k nodes, 20k edges): live 20.6 MB grew to 36.3 MB and the
snapshot added 19.8 MB — 56.1 MB where there had been 20.6, about 2.7x. A user
who never learns about the file either loses the disk permanently or, worse,
finds a mysterious `memory.db.*.db` months later and deletes the one copy that
would have saved them.

So: the file is never deleted automatically, and its existence is reported at
every startup — to the log for whoever reads logs, AND as an event, which is
the surface the dashboard already shows the user.
"""
from __future__ import annotations

import time

from axi import events, store


def _make_snapshot(epoch: int, size: int = 1024) -> "store.Path":
    path = store.DB_PATH.parent / f"{store.DB_PATH.name}.pre-rebuild-{epoch}.db"
    path.write_bytes(b"x" * size)
    return path


def test_no_snapshot_means_nothing_to_report():
    """Empty because the directory genuinely holds no snapshot — the companion
    test below proves the same call finds one when it is there."""
    assert store.report_pre_rebuild_snapshots() == []


def test_every_snapshot_is_reported_with_its_real_cost_on_disk():
    older = _make_snapshot(1_700_000_000, size=2048)
    newer = _make_snapshot(1_800_000_000, size=4096)

    found = store.report_pre_rebuild_snapshots()

    assert [f["path"] for f in found] == [str(newer), str(older)], (
        "newest first — the most recent snapshot is the one that matches the "
        "current database"
    )
    assert found[0]["bytes"] == 4096
    assert found[1]["bytes"] == 2048
    # The number that tells the user what it is COSTING them, not just that a
    # file exists.
    assert found[0]["live_db_bytes"] == store.DB_PATH.stat().st_size


def test_the_glob_and_the_writer_agree_on_the_name():
    """The discoverer and `verified_pre_rebuild_backup` name the same file in
    two places. If they ever drift, the report goes quietly blind — which is
    the exact failure mode this whole file exists to prevent."""
    import inspect

    writer_source = inspect.getsource(store.verified_pre_rebuild_backup)

    assert ".pre-rebuild-" in writer_source, (
        "the snapshot's filename changed; report_pre_rebuild_snapshots' glob "
        "must be updated with it"
    )
    assert ".pre-rebuild-" in store._PRE_REBUILD_SNAPSHOT_GLOB


def test_init_db_tells_the_user_the_snapshot_is_there_and_when_it_is_safe_to_delete(
    caplog,
):
    """Asserting the FUNCTION works says nothing about whether anything calls
    it — the mistake task 7.14 already made once in this same file."""
    snapshot = _make_snapshot(1_800_000_001, size=4096)

    with caplog.at_level("WARNING"):
        store.init_db()

    messages = [r.getMessage() for r in caplog.records]
    assert any(str(snapshot) in m for m in messages), (
        "startup never named the snapshot file; the report is unwired"
    )
    named = next(m for m in messages if str(snapshot) in m)
    assert "delete" in named.lower(), (
        "the user is told the file exists but not when they may remove it, "
        "which is the half that makes it actionable"
    )


def test_the_snapshot_report_reaches_the_user_facing_event_feed():
    """A log line is for whoever reads logs. The dashboard's event feed is
    where the user actually looks."""
    events._reset_for_tests()
    snapshot = _make_snapshot(1_800_000_002, size=4096)

    store.init_db()
    events._flush_for_tests()

    matching = [
        e
        for e in events.recent_events(limit=50)
        if str(snapshot) in e.get("message", "")
    ]
    assert matching, "no event names the snapshot; the user is never told"
    assert matching[0]["level"] == "warning", (
        "not an error — nothing is broken — but not info either: it is disk "
        "the user is paying for and a decision only they can make"
    )


def test_a_report_that_cannot_run_never_takes_the_daemon_down(monkeypatch, caplog):
    """Same shape as the dangling-edge report: losing the report is bad,
    losing the daemon because the report broke is worse. It is still LOUD."""

    def _boom(*_a, **_k):
        raise OSError("permission denied")

    monkeypatch.setattr(store, "report_pre_rebuild_snapshots", _boom)

    with caplog.at_level("ERROR"):
        store.init_db()  # must NOT raise

    assert any(
        "pre-rebuild snapshot" in r.getMessage().lower() for r in caplog.records
    ), "the failure of the report itself was swallowed"


def test_the_report_ignores_files_that_are_not_snapshots():
    """A glob that matched the live database or the WAL would tell the user to
    delete their memory."""
    (store.DB_PATH.parent / "memory.db.backup-manual.db").write_bytes(b"x")
    (store.DB_PATH.parent / "notes.txt").write_bytes(b"x")
    kept = _make_snapshot(int(time.time()))

    found = store.report_pre_rebuild_snapshots()

    assert [f["path"] for f in found] == [str(kept)]
