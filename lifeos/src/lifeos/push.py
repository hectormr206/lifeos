"""Web Push (RFC 8030) — VAPID keypair, subscriptions, send.

A single VAPID keypair is generated on first run and persisted as JSON at
`~/.local/state/lifeos/vapid.json` (chmod 600). Subscriptions from the PWA
are stored in the `push_subscriptions` table.

Per PRD §5.3: push payloads carry titles only. The PWA receives a generic
"Recordatorio" and fetches details from the dashboard *after* the user taps
the notification (under HTTPS + VPN, the only network we trust).
"""

from __future__ import annotations

import base64
import json
import logging
import os
import shutil
import stat
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.asymmetric import ec
from pywebpush import WebPushException, webpush

from lifeos import store, notif_budget

log = logging.getLogger("lifeos.push")


def _vapid_path() -> Path:
    base = Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    return base / "vapid.json"


@dataclass(frozen=True, slots=True)
class VapidKeys:
    # Raw 32-byte EC private scalar, base64url-encoded (no padding).
    # This is the form `pywebpush.webpush(vapid_private_key=...)` accepts.
    private_b64url: str
    # Uncompressed P-256 public point (0x04 || X(32) || Y(32)), base64url-encoded.
    # This is what the browser's PushManager.subscribe() applicationServerKey needs.
    public_b64url: str
    subject: str = "mailto:hectormr@example.local"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _generate_vapid_keys() -> VapidKeys:
    priv = ec.generate_private_key(ec.SECP256R1())
    private_value = priv.private_numbers().private_value
    raw_priv = private_value.to_bytes(32, "big")
    pub_numbers = priv.public_key().public_numbers()
    raw_pub = (
        b"\x04"
        + pub_numbers.x.to_bytes(32, "big")
        + pub_numbers.y.to_bytes(32, "big")
    )
    return VapidKeys(
        private_b64url=_b64url(raw_priv),
        public_b64url=_b64url(raw_pub),
    )


def get_vapid_keys() -> VapidKeys:
    """Load existing keys or generate-and-persist a fresh pair.

    Migrates old PEM-based vapid.json (from the first bad attempt) by
    regenerating — the public key changes too, so any subscriptions made
    against the old key need to be re-registered. Logged loudly.
    """
    path = _vapid_path()
    if path.exists():
        try:
            data = json.loads(path.read_text())
            if "private_b64url" in data:
                return VapidKeys(
                    private_b64url=data["private_b64url"],
                    public_b64url=data["public_b64url"],
                    subject=data.get("subject", "mailto:hectormr@example.local"),
                )
            # Old PEM-format file — regenerate and warn. Existing subscriptions
            # become invalid; the PWA will re-subscribe on next "Habilitar push".
            log.warning(
                "vapid.json is in old PEM format — regenerating. Existing "
                "subscriptions will be invalidated."
            )
        except Exception as e:  # noqa: BLE001
            log.warning("vapid file corrupt (%s) — regenerating", e)
    keys = _generate_vapid_keys()
    path.write_text(json.dumps({
        "private_b64url": keys.private_b64url,
        "public_b64url": keys.public_b64url,
        "subject": keys.subject,
    }))
    try:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except Exception:  # noqa: BLE001
        pass
    log.info("generated new VAPID keypair at %s", path)
    return keys


def add_subscription(*, endpoint: str, p256dh: str, auth: str,
                     user_agent: str | None = None) -> int:
    """Insert or refresh a subscription. Returns the row id."""
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO push_subscriptions(endpoint, p256dh, auth, user_agent) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(endpoint) DO UPDATE SET "
            "  p256dh=excluded.p256dh, "
            "  auth=excluded.auth, "
            "  user_agent=excluded.user_agent, "
            "  last_seen_at=datetime('now')",
            (endpoint, p256dh, auth, user_agent),
        )
        row = conn.execute(
            "SELECT id FROM push_subscriptions WHERE endpoint = ?", (endpoint,)
        ).fetchone()
    return int(row["id"])


def list_subscriptions() -> list[dict[str, Any]]:
    with store.connect() as conn:
        rows = conn.execute("SELECT * FROM push_subscriptions").fetchall()
    return [dict(r) for r in rows]


def remove_subscription(endpoint: str) -> None:
    with store.connect() as conn:
        conn.execute(
            "DELETE FROM push_subscriptions WHERE endpoint = ?", (endpoint,)
        )


def _absolute_dashboard_url(url: str) -> str:
    """Turn a relative dashboard path (e.g. ``/briefings#id``) into an absolute
    URL that ``xdg-open`` can hand to the browser.

    Already-absolute http(s) URLs pass through untouched. The base is read from
    ``LIFEOS_DASHBOARD_URL`` (default ``https://127.0.0.1:8081``) so desktop and
    web-push deep-links agree on the destination.
    """
    u = (url or "").strip()
    if u.startswith("http://") or u.startswith("https://"):
        return u
    base = os.environ.get("LIFEOS_DASHBOARD_URL", "https://127.0.0.1:8081").rstrip("/")
    if not u:
        return base
    if not u.startswith("/"):
        u = "/" + u
    return base + u


def _resolve_notify_icon() -> str:
    # Resolve icon without coupling `lifeos` to `axi`'s filesystem layout.
    # `LIFEOS_NOTIFY_ICON` lets the embedder (the axi dashboard / systemd unit)
    # point at axi/static/axi-192.png; absent that, fall back to a themed icon.
    icon = os.environ.get("LIFEOS_NOTIFY_ICON", "").strip()
    if not icon or not Path(icon).exists():
        icon = "dialog-information"  # themed icon name (always renderable)
    return icon


def _notify_click_worker(binary: str, icon: str, title: str, body: str,
                         abs_url: str) -> None:
    """Run a clickable `notify-send` and open `abs_url` if the user clicks.

    `notify-send --action=default=...` BLOCKS until the notification is closed
    and prints the invoked action id (``default``) to stdout on click. This
    runs in a detached daemon thread, so blocking here never stalls the caller
    (scheduler worker). Never raises — a desktop notification must not take the
    briefing dispatcher down.
    """
    try:
        proc = subprocess.run(
            [binary, "--app-name=Axi", "--icon", icon, "--urgency=normal",
             "--action=default=Abrir", title, body],
            check=False, timeout=300, capture_output=True, text=True,
        )
        if (getattr(proc, "stdout", "") or "").strip() == "default":
            opener = shutil.which("xdg-open")
            if opener:
                subprocess.run([opener, abs_url], check=False, timeout=10)
            else:
                log.warning("xdg-open not found — cannot open %s", abs_url)
    except Exception as e:  # noqa: BLE001
        log.warning("clickable desktop notification failed: %s", e)


def send_os_notification(title: str, body: str, url: str | None = None) -> bool:
    """Fire a desktop notification on the user's session (KDE/GNOME/etc.).

    Uses `notify-send` (libnotify). Available out-of-the-box on most Linux
    desktops. Returns True if the command launched OK. The notification
    daemon decides how to render (toast, persistent, etc.).

    When `url` is provided, the notification carries a default action ("Abrir")
    and, on click, opens the (absolutized) url with `xdg-open`. Because
    `notify-send --action` blocks until the toast is closed, that path runs in
    a detached daemon thread and returns immediately, so the caller (the
    scheduler worker) is never blocked. When `url` is None the original
    non-blocking behavior is preserved for existing callers.

    This is fired from inside the dashboard service, which runs under the
    user's systemd --user instance, so the DBus session is the user's own.
    """
    binary = shutil.which("notify-send")
    if not binary:
        log.warning("notify-send not found — skipping OS notification")
        return False
    icon = _resolve_notify_icon()
    if url is None:
        # Legacy non-blocking path — unchanged for existing callers.
        try:
            subprocess.run(
                [binary, "--app-name=Axi", "--icon", icon, "--urgency=normal",
                 title, body],
                check=False, timeout=5,
            )
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("notify-send failed: %s", e)
            return False
    # Clickable path: spawn a detached daemon thread so the blocking
    # `notify-send --action` never stalls the caller.
    abs_url = _absolute_dashboard_url(url)
    try:
        threading.Thread(
            target=_notify_click_worker,
            args=(binary, icon, title, body, abs_url),
            daemon=True,
        ).start()
    except Exception as e:  # noqa: BLE001
        log.warning("could not spawn notify-send thread: %s", e)
        return False
    return True


def send_to_all(title: str, body: str, *, url: str = "/reminders",
                tag: str | None = None,
                include_os: bool = True,
                priority: str = "ambient") -> dict[str, int]:
    """Send `title`/`body` to all push subscriptions + optionally the local OS.

    Returns {"sent": N, "failed": M, "gone": G, "os": 0|1, "suppressed": 0|1}.
      sent       = web push successes
      failed     = web push errors (other than 404/410)
      gone       = 404/410 endpoints (subscription auto-removed)
      os         = 1 if the local OS notification fired, 0 otherwise
      suppressed = 1 if the notification was suppressed by budget rules, 0 otherwise
    """
    # --- Budget check ---
    original_title, original_body = title, body
    decision = notif_budget.evaluate(title, body, priority)

    if decision.action == "suppress":
        notif_budget.record(
            title=original_title,
            body=original_body,
            priority=priority,
            outcome=f"suppressed_{decision.reason}",
        )
        log.info(
            "notification suppressed (reason=%s): %r", decision.reason, title[:60]
        )
        return {"sent": 0, "failed": 0, "gone": 0, "os": 0,
                "suppressed": 1, "reason": decision.reason}

    if decision.action == "coalesce":
        title = decision.title  # type: ignore[assignment]
        body = decision.body    # type: ignore[assignment]
        outcome = "coalesce"
        log.info("notification coalesced — digest: %r", title)
    else:
        outcome = "sent"

    # --- Fanout ---
    keys = get_vapid_keys()
    subs = list_subscriptions()
    sent = failed = gone = 0
    payload = json.dumps({"title": title, "body": body, "url": url, "tag": tag})
    for sub in subs:
        subscription_info = {
            "endpoint": sub["endpoint"],
            "keys": {"p256dh": sub["p256dh"], "auth": sub["auth"]},
        }
        try:
            webpush(
                subscription_info=subscription_info,
                data=payload,
                vapid_private_key=keys.private_b64url,
                vapid_claims={"sub": keys.subject},
                ttl=86400,
                # Without a timeout, requests hangs FOREVER when the first
                # resolved address is unreachable (e.g. an ISP that advertises
                # IPv6 but blackholes it — getaddrinfo returns IPv6 first, the
                # connect never fails, and every push stalls the caller). With a
                # timeout, each address attempt fails fast and the connect falls
                # through to the working IPv4 address.
                timeout=10,
            )
            sent += 1
        except WebPushException as e:
            status = getattr(e.response, "status_code", None) if e.response else None
            if status in (404, 410):
                remove_subscription(sub["endpoint"])
                gone += 1
                log.info("removed dead subscription %s (status %s)",
                         sub["endpoint"][:60], status)
            else:
                failed += 1
                log.warning("push failed (status %s): %s", status, e)
        except Exception as e:  # noqa: BLE001
            failed += 1
            log.exception("push send unexpected error: %s", e)
    os_fired = 1 if (include_os and send_os_notification(title, body, url=url)) else 0

    # Record with original title/body so dedup hashes against caller intent
    notif_budget.record(
        title=original_title,
        body=original_body,
        priority=priority,
        outcome=outcome,
    )

    return {"sent": sent, "failed": failed, "gone": gone, "os": os_fired,
            "suppressed": 0}
