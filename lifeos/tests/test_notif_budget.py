"""Tests for lifeos.notif_budget — daily notification budget + soft coalescing.

Isolation: same pattern as test_push.py — LIFEOS_DB_PATH + LIFEOS_STATE_DIR
via monkeypatch + tmp_path; calls store.apply_migrations() in fixture.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import pytest


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    from lifeos import store
    store.apply_migrations()
    yield


# ---------------------------------------------------------------------------
# load_config
# ---------------------------------------------------------------------------

def test_load_config_defaults_when_file_missing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos.notif_budget import load_config, BudgetConfig
    cfg = load_config()
    assert cfg.max_per_day == 5
    assert cfg.dedup_window_minutes == 60


def test_load_config_honors_json_values(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import os
    state_dir = Path(os.environ["LIFEOS_STATE_DIR"])
    state_dir.mkdir(parents=True, exist_ok=True)
    config_file = state_dir / "config.json"
    config_file.write_text(json.dumps({
        "notifications": {"max_per_day": 10, "dedup_window_minutes": 30}
    }))

    from lifeos.notif_budget import load_config
    cfg = load_config()
    assert cfg.max_per_day == 10
    assert cfg.dedup_window_minutes == 30


def test_load_config_partial_json_uses_defaults(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import os
    state_dir = Path(os.environ["LIFEOS_STATE_DIR"])
    state_dir.mkdir(parents=True, exist_ok=True)
    config_file = state_dir / "config.json"
    config_file.write_text(json.dumps({"notifications": {"max_per_day": 3}}))

    from lifeos.notif_budget import load_config
    cfg = load_config()
    assert cfg.max_per_day == 3
    assert cfg.dedup_window_minutes == 60  # default


def test_load_config_malformed_json_uses_defaults(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import os
    state_dir = Path(os.environ["LIFEOS_STATE_DIR"])
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "config.json").write_text("not-valid-json{{")

    from lifeos.notif_budget import load_config
    cfg = load_config()
    assert cfg.max_per_day == 5
    assert cfg.dedup_window_minutes == 60


# ---------------------------------------------------------------------------
# evaluate — send path
# ---------------------------------------------------------------------------

def test_evaluate_first_ambient_returns_send() -> None:
    from lifeos.notif_budget import evaluate
    d = evaluate("Hello", "World", priority="ambient")
    assert d.action == "send"


def test_evaluate_five_ambient_sends_all_return_send() -> None:
    """Drive state via record(); first 5 should all evaluate to 'send'."""
    from lifeos.notif_budget import evaluate, record

    for i in range(5):
        d = evaluate(f"Title {i}", f"Body {i}", priority="ambient")
        assert d.action == "send", f"Expected 'send' on call {i+1}, got {d.action!r}"
        record(title=f"Title {i}", body=f"Body {i}", priority="ambient", outcome="sent")


# ---------------------------------------------------------------------------
# evaluate — coalesce on 6th ambient
# ---------------------------------------------------------------------------

def test_evaluate_sixth_ambient_returns_coalesce() -> None:
    from lifeos.notif_budget import evaluate, record

    for i in range(5):
        record(title=f"Title {i}", body=f"Body {i}", priority="ambient", outcome="sent")

    d = evaluate("Title 5", "Body 5", priority="ambient")
    assert d.action == "coalesce"
    assert d.title is not None
    assert "📬" in d.title
    assert d.body is not None
    assert "6" in d.body  # N = 6 (5 sent + 1 current)
    assert d.reason == "cap"


# ---------------------------------------------------------------------------
# evaluate — suppress after coalesce
# ---------------------------------------------------------------------------

def test_evaluate_seventh_ambient_returns_suppress_cap() -> None:
    from lifeos.notif_budget import evaluate, record

    for i in range(5):
        record(title=f"Title {i}", body=f"Body {i}", priority="ambient", outcome="sent")
    # Record the coalesce row (simulating what send_to_all would do)
    record(title="Title 5", body="Body 5", priority="ambient", outcome="coalesce")

    d = evaluate("Title 6", "Body 6", priority="ambient")
    assert d.action == "suppress"
    assert d.reason == "cap"


# ---------------------------------------------------------------------------
# evaluate — dedup
# ---------------------------------------------------------------------------

def test_evaluate_same_hash_within_window_returns_suppress_dedup() -> None:
    from lifeos.notif_budget import evaluate, record

    record(title="Hello", body="World", priority="ambient", outcome="sent")
    d = evaluate("Hello", "World", priority="ambient")
    assert d.action == "suppress"
    assert d.reason == "dedup"


def test_evaluate_same_hash_after_window_returns_send() -> None:
    """A row older than dedup_window_minutes should NOT trigger dedup."""
    from lifeos.notif_budget import evaluate, record
    from lifeos import store

    # Insert a row directly with an old sent_at (2 hours ago)
    old_ts = (datetime.utcnow() - timedelta(hours=2)).strftime("%Y-%m-%d %H:%M:%S")
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO notif_log(sent_at, hash, priority, outcome) VALUES (?, ?, ?, ?)",
            (old_ts, _hash("Hello", "World"), "ambient", "sent"),
        )

    d = evaluate("Hello", "World", priority="ambient")
    assert d.action == "send"


# ---------------------------------------------------------------------------
# evaluate — critical bypasses everything
# ---------------------------------------------------------------------------

def test_evaluate_critical_bypasses_cap() -> None:
    from lifeos.notif_budget import evaluate, record

    # Fill cap
    for i in range(5):
        record(title=f"Title {i}", body=f"Body {i}", priority="ambient", outcome="sent")

    d = evaluate("URGENT", "Do it now", priority="critical")
    assert d.action == "send"


def test_evaluate_critical_bypasses_dedup() -> None:
    from lifeos.notif_budget import evaluate, record

    record(title="URGENT", body="Do it now", priority="critical", outcome="sent")
    d = evaluate("URGENT", "Do it now", priority="critical")
    assert d.action == "send"


def test_evaluate_critical_bypasses_full_cap_and_dedup() -> None:
    """Critical fires even when both cap is full AND same hash exists."""
    from lifeos.notif_budget import evaluate, record

    for i in range(5):
        record(title=f"T{i}", body=f"B{i}", priority="ambient", outcome="sent")
    record(title="URGENT", body="Critical msg", priority="critical", outcome="sent")

    d = evaluate("URGENT", "Critical msg", priority="critical")
    assert d.action == "send"


# ---------------------------------------------------------------------------
# cleanup_old
# ---------------------------------------------------------------------------

def test_cleanup_old_removes_rows_older_than_n_days() -> None:
    from lifeos.notif_budget import cleanup_old
    from lifeos import store

    now = datetime.utcnow()
    rows = [
        (now - timedelta(days=8)).strftime("%Y-%m-%d %H:%M:%S"),  # old — should be deleted
        (now - timedelta(days=6)).strftime("%Y-%m-%d %H:%M:%S"),  # recent — keep
        now.strftime("%Y-%m-%d %H:%M:%S"),                         # now — keep
    ]
    with store.connect() as conn:
        for ts in rows:
            conn.execute(
                "INSERT INTO notif_log(sent_at, hash, priority, outcome) VALUES (?, 'abc', 'ambient', 'sent')",
                (ts,),
            )

    deleted = cleanup_old(days=7)
    assert deleted == 1

    with store.connect() as conn:
        count = conn.execute("SELECT COUNT(*) FROM notif_log").fetchone()[0]
    assert count == 2


def test_cleanup_old_returns_zero_when_nothing_to_delete() -> None:
    from lifeos.notif_budget import cleanup_old
    deleted = cleanup_old(days=7)
    assert deleted == 0


# ---------------------------------------------------------------------------
# Integration: push.send_to_all — 7 calls, verify outcome distribution
# ---------------------------------------------------------------------------

def test_send_to_all_budget_integration(monkeypatch: pytest.MonkeyPatch) -> None:
    """7 ambient sends → 5 sent, 1 coalesce, 1 suppressed."""
    from lifeos import push

    # Mock webpush to no-op — patch in push module's namespace (it does `from pywebpush import webpush`)
    monkeypatch.setattr(push, "webpush", lambda **kw: None)
    # Suppress OS notification
    monkeypatch.setattr(push, "send_os_notification", lambda t, b: False)

    # Add a fake subscription
    push.add_subscription(
        endpoint="https://fcm.example.com/fake/sub",
        p256dh="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        auth="AAAAAAAAAAA=",
    )

    results = []
    for i in range(7):
        r = push.send_to_all(
            f"Title {i}",
            f"Body {i}",  # different bodies → no dedup, only cap
            url="/test",
            include_os=False,
            priority="ambient",
        )
        results.append(r)

    # First 5: sent
    for i in range(5):
        assert results[i]["sent"] == 1, f"Call {i+1} should have sent 1"
        assert results[i].get("suppressed", 0) == 0

    # 6th: coalesce — webpush fires with modified title
    r6 = results[5]
    assert r6["sent"] == 1, "Coalesce should still fire webpush"
    assert r6.get("suppressed", 0) == 0
    # We verify coalesce happened by checking the notif_log
    from lifeos import store
    with store.connect() as conn:
        coalesce_rows = conn.execute(
            "SELECT * FROM notif_log WHERE outcome='coalesce'"
        ).fetchall()
    assert len(coalesce_rows) == 1

    # 7th: suppressed
    r7 = results[6]
    assert r7.get("suppressed", 0) == 1
    assert r7.get("sent", 0) == 0
    assert r7.get("reason") == "cap"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _hash(title: str, body: str) -> str:
    import hashlib
    return hashlib.sha256((title + "\n" + body).encode()).hexdigest()[:16]
