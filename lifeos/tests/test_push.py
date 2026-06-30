"""Tests for lifeos.push — keypair persistence + subscriptions DAO.

The actual webpush network calls are not exercised here (would require a real
PWA endpoint). The wiring around storage and key generation is.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    from lifeos import store
    store.apply_migrations()
    yield


def test_vapid_keys_generated_once_and_persisted() -> None:
    import base64
    from lifeos.push import get_vapid_keys, _vapid_path

    k1 = get_vapid_keys()
    assert k1.public_b64url
    assert k1.private_b64url
    # Private key is the raw 32-byte EC scalar, b64url-encoded
    pad = "=" * (-len(k1.private_b64url) % 4)
    assert len(base64.urlsafe_b64decode(k1.private_b64url + pad)) == 32

    # Same call returns same keys
    k2 = get_vapid_keys()
    assert k1.public_b64url == k2.public_b64url
    assert k1.private_b64url == k2.private_b64url

    # On-disk JSON exists
    p = _vapid_path()
    assert p.exists()
    data = json.loads(p.read_text())
    assert data["public_b64url"] == k1.public_b64url
    assert data["private_b64url"] == k1.private_b64url


def test_vapid_public_key_decodes_to_65_bytes() -> None:
    """Uncompressed P-256 point format expected by browsers."""
    import base64
    from lifeos.push import get_vapid_keys

    k = get_vapid_keys()
    # b64url decode, padding-tolerant
    pad = "=" * (-len(k.public_b64url) % 4)
    raw = base64.urlsafe_b64decode(k.public_b64url + pad)
    assert len(raw) == 65
    assert raw[0] == 0x04  # uncompressed point marker


def test_subscription_upsert_and_list() -> None:
    from lifeos.push import add_subscription, list_subscriptions

    rid1 = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/A",
        p256dh="key1", auth="auth1", user_agent="ua-A",
    )
    rid2 = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/B",
        p256dh="key2", auth="auth2",
    )
    assert rid1 != rid2

    subs = list_subscriptions()
    assert len(subs) == 2

    # Upsert: same endpoint just refreshes p256dh/auth
    rid1_again = add_subscription(
        endpoint="https://fcm.googleapis.com/fcm/send/A",
        p256dh="key1_NEW", auth="auth1_NEW",
    )
    assert rid1_again == rid1
    subs = list_subscriptions()
    assert len(subs) == 2  # still 2 — upsert, not new
    a = [s for s in subs if s["endpoint"].endswith("/A")][0]
    assert a["p256dh"] == "key1_NEW"


def test_remove_subscription() -> None:
    from lifeos.push import add_subscription, list_subscriptions, remove_subscription

    add_subscription(endpoint="https://x/y", p256dh="k", auth="a")
    assert len(list_subscriptions()) == 1
    remove_subscription("https://x/y")
    assert len(list_subscriptions()) == 0


# ---------------------------------------------------------------------------
# Clickable desktop notifications (FIX 3)
# ---------------------------------------------------------------------------


def test_absolute_dashboard_url_prefixes_relative(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    monkeypatch.setenv("LIFEOS_DASHBOARD_URL", "https://host:9000")
    assert push._absolute_dashboard_url("/briefings#abc") == "https://host:9000/briefings#abc"
    # Already absolute → untouched.
    assert push._absolute_dashboard_url("https://x/y") == "https://x/y"
    # Default base when env unset.
    monkeypatch.delenv("LIFEOS_DASHBOARD_URL", raising=False)
    assert push._absolute_dashboard_url("/p").startswith("https://127.0.0.1:8081")


def test_os_notification_without_url_has_no_action(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    monkeypatch.setattr(push.shutil, "which", lambda _b: "/usr/bin/notify-send")
    calls: list[list[str]] = []
    monkeypatch.setattr(push.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd))

    assert push.send_os_notification("T", "B") is True
    assert len(calls) == 1
    assert not any(str(a).startswith("--action") for a in calls[0])


def test_os_notification_with_url_spawns_thread_and_returns_immediately(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from lifeos import push

    monkeypatch.setattr(push.shutil, "which", lambda _b: "/usr/bin/notify-send")
    started: list[bool] = []

    class _FakeThread:
        def __init__(self, *a, **kw):
            self.daemon = kw.get("daemon", False)

        def start(self):
            started.append(self.daemon)

    monkeypatch.setattr(push.threading, "Thread", _FakeThread)
    # Returns immediately (does not block on notify-send) and spawns a daemon thread.
    assert push.send_os_notification("T", "B", url="/briefings#x") is True
    assert started == [True]


def test_click_worker_includes_action_in_command(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    calls: list[list[str]] = []

    class _Proc:
        stdout = ""

    monkeypatch.setattr(push.subprocess, "run",
                        lambda cmd, **kw: (calls.append(cmd), _Proc())[1])
    monkeypatch.setattr(push.shutil, "which", lambda _b: None)

    push._notify_click_worker("/usr/bin/notify-send", "icon", "T", "B",
                              "https://host/briefings#x")
    assert len(calls) == 1  # only notify-send, no xdg-open (stdout empty)
    assert any(str(a).startswith("--action=default=") for a in calls[0])


def test_click_worker_opens_url_when_action_clicked(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    calls: list[list[str]] = []

    class _Proc:
        stdout = "default\n"

    monkeypatch.setattr(push.subprocess, "run",
                        lambda cmd, **kw: (calls.append(cmd), _Proc())[1])
    monkeypatch.setattr(push.shutil, "which",
                        lambda b: "/usr/bin/xdg-open" if b == "xdg-open" else None)

    push._notify_click_worker("/usr/bin/notify-send", "icon", "T", "B",
                              "https://host/briefings#x")
    assert len(calls) == 2
    assert calls[1] == ["/usr/bin/xdg-open", "https://host/briefings#x"]


def test_click_worker_no_open_on_other_stdout(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    calls: list[list[str]] = []

    class _Proc:
        stdout = "closed"

    monkeypatch.setattr(push.subprocess, "run",
                        lambda cmd, **kw: (calls.append(cmd), _Proc())[1])
    monkeypatch.setattr(push.shutil, "which", lambda b: "/usr/bin/xdg-open")

    push._notify_click_worker("/usr/bin/notify-send", "icon", "T", "B",
                              "https://host/briefings#x")
    assert len(calls) == 1  # no xdg-open


def test_click_worker_never_raises_when_xdg_open_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    class _Proc:
        stdout = "default"

    monkeypatch.setattr(push.subprocess, "run", lambda cmd, **kw: _Proc())
    monkeypatch.setattr(push.shutil, "which", lambda _b: None)  # xdg-open absent

    # Must not raise even though the user clicked but xdg-open is unavailable.
    push._notify_click_worker("/usr/bin/notify-send", "icon", "T", "B", "https://h/x")


def test_send_os_notification_returns_false_when_notify_send_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from lifeos import push

    monkeypatch.setattr(push.shutil, "which", lambda _b: None)
    assert push.send_os_notification("T", "B", url="/p") is False


def test_send_to_all_passes_url_to_os_notification(monkeypatch: pytest.MonkeyPatch) -> None:
    from lifeos import push

    captured: dict = {}

    def _fake_os(title, body, url=None):
        captured["url"] = url
        return True

    monkeypatch.setattr(push, "send_os_notification", _fake_os)
    push.send_to_all("Boletín", "cuerpo", url="/briefings#abc", tag="briefing:abc")
    assert captured["url"] == "/briefings#abc"
