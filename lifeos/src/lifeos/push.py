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
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pywebpush import WebPushException, webpush

from lifeos import store

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
    private_pem: str
    public_b64url: str   # the form the PWA needs (uncompressed P-256 point, 65 bytes, base64url)
    subject: str = "mailto:hectormr@example.local"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _generate_vapid_keys() -> VapidKeys:
    priv = ec.generate_private_key(ec.SECP256R1())
    pub_numbers = priv.public_key().public_numbers()
    # Uncompressed point: 0x04 || X (32) || Y (32) = 65 bytes
    raw_pub = (
        b"\x04"
        + pub_numbers.x.to_bytes(32, "big")
        + pub_numbers.y.to_bytes(32, "big")
    )
    pem = priv.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")
    return VapidKeys(private_pem=pem, public_b64url=_b64url(raw_pub))


def get_vapid_keys() -> VapidKeys:
    """Load existing keys or generate-and-persist a fresh pair."""
    path = _vapid_path()
    if path.exists():
        try:
            data = json.loads(path.read_text())
            return VapidKeys(
                private_pem=data["private_pem"],
                public_b64url=data["public_b64url"],
                subject=data.get("subject", "mailto:hectormr@example.local"),
            )
        except Exception as e:  # noqa: BLE001
            log.warning("vapid file corrupt (%s) — regenerating", e)
    keys = _generate_vapid_keys()
    path.write_text(json.dumps({
        "private_pem": keys.private_pem,
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


def send_to_all(title: str, body: str, *, url: str = "/reminders",
                tag: str | None = None) -> dict[str, int]:
    """Push to every stored subscription.

    Returns {"sent": N, "failed": M, "gone": G}. `gone` = 404/410 endpoints
    were auto-removed from the DB (the PWA was uninstalled or session expired).
    """
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
                vapid_private_key=keys.private_pem,
                vapid_claims={"sub": keys.subject},
                ttl=86400,
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
    return {"sent": sent, "failed": failed, "gone": gone}
