"""Notification budget + soft coalescing for LifeOS ambient notifications.

Rules:
- Default cap: 5 ambient notifications per calendar day.
- Dedup window: 1 hour — same title+body hash within the window is suppressed.
- critical priority bypasses cap and dedup entirely.
- ambient priority respects both.
- Soft coalescing: when the cap is hit, fire ONE "📬 N updates pendientes"
  digest per dedup_window. Subsequent suppressed ambients in that window are
  recorded silently.
- Config: ~/.local/state/lifeos/config.json (key: notifications).
  Honors LIFEOS_STATE_DIR env var for the parent dir.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from lifeos import store

log = logging.getLogger("lifeos.notif_budget")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

@dataclass
class BudgetConfig:
    max_per_day: int = 5
    dedup_window_minutes: int = 60


def _config_path() -> Path:
    base = Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )
    return base / "config.json"


def load_config() -> BudgetConfig:
    """Read config.json; return defaults on missing/malformed file."""
    path = _config_path()
    defaults = BudgetConfig()
    try:
        data = json.loads(path.read_text())
        notif = data.get("notifications", {})
        return BudgetConfig(
            max_per_day=int(notif.get("max_per_day", defaults.max_per_day)),
            dedup_window_minutes=int(
                notif.get("dedup_window_minutes", defaults.dedup_window_minutes)
            ),
        )
    except FileNotFoundError:
        return defaults
    except Exception as exc:  # noqa: BLE001
        log.warning("notif_budget: could not load config (%s) — using defaults", exc)
        return defaults


# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------

@dataclass
class Decision:
    action: str  # "send" | "suppress" | "coalesce"
    title: str | None = None
    body: str | None = None
    reason: str | None = None


# ---------------------------------------------------------------------------
# Hash
# ---------------------------------------------------------------------------

def _notif_hash(title: str, body: str) -> str:
    return hashlib.sha256((title + "\n" + body).encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

def evaluate(title: str, body: str, priority: str = "ambient") -> Decision:
    """Pure decision: read notif_log, apply rules. Does NOT write."""
    if priority == "critical":
        return Decision("send")

    if priority == "proactive":
        # 1 guaranteed slot/day, OUTSIDE the 5/day ambient cap.
        # Second proactive push in the same calendar day is suppressed.
        now = datetime.now(timezone.utc)
        today = now.date()
        with store.connect() as conn:
            rows = conn.execute(
                """
                SELECT sent_at FROM notif_log
                WHERE priority = 'proactive'
                  AND outcome = 'sent'
                  AND sent_at >= ?
                """,
                ((now - timedelta(hours=24)).strftime("%Y-%m-%d %H:%M:%S"),),
            ).fetchall()
        spoke = sum(
            1 for r in rows
            if datetime.strptime(r["sent_at"], "%Y-%m-%d %H:%M:%S").date() == today
        )
        if spoke >= 1:
            return Decision("suppress", reason="proactive-cap")
        return Decision("send")

    cfg = load_config()
    now = datetime.now(timezone.utc)
    window_cutoff = now - timedelta(minutes=cfg.dedup_window_minutes)
    today = now.date()

    h = _notif_hash(title, body)

    with store.connect() as conn:
        # Dedup: same hash within window AND outcome in (sent, coalesce)
        dedup_row = conn.execute(
            """
            SELECT id FROM notif_log
            WHERE hash = ?
              AND sent_at >= ?
              AND outcome IN ('sent', 'coalesce')
            LIMIT 1
            """,
            (h, window_cutoff.strftime("%Y-%m-%d %H:%M:%S")),
        ).fetchone()

        if dedup_row:
            return Decision("suppress", reason="dedup")

        # Cap: count today's ambient 'sent' rows
        rows_today = conn.execute(
            """
            SELECT sent_at FROM notif_log
            WHERE priority = 'ambient'
              AND outcome = 'sent'
              AND sent_at >= ?
            """,
            ((now - timedelta(hours=24)).strftime("%Y-%m-%d %H:%M:%S"),),
        ).fetchall()

        # Filter to same calendar day (local date)
        sent_today = sum(
            1 for r in rows_today
            if datetime.strptime(r["sent_at"], "%Y-%m-%d %H:%M:%S").date() == today
        )

        if sent_today >= cfg.max_per_day:
            # Check if a coalesce row was already written within dedup_window
            coalesce_row = conn.execute(
                """
                SELECT id FROM notif_log
                WHERE outcome = 'coalesce'
                  AND sent_at >= ?
                LIMIT 1
                """,
                (window_cutoff.strftime("%Y-%m-%d %H:%M:%S"),),
            ).fetchone()

            if coalesce_row:
                return Decision("suppress", reason="cap")

            # Fire the coalesce digest
            n = sent_today + 1
            return Decision(
                "coalesce",
                title="📬 Updates pendientes",
                body=f"Tenés {n} actualizaciones — abrí el dashboard",
                reason="cap",
            )

    return Decision("send")


def record(*, title: str, body: str, priority: str, outcome: str) -> None:
    """Write a row to notif_log. Also opportunistically purges old rows."""
    h = _notif_hash(title, body)
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO notif_log(hash, priority, outcome) VALUES (?, ?, ?)",
            (h, priority, outcome),
        )
    # Opportunistic cleanup
    try:
        cleanup_old()
    except Exception as exc:  # noqa: BLE001
        log.debug("notif_budget: cleanup_old failed: %s", exc)


def cleanup_old(days: int = 7) -> int:
    """Delete notif_log rows older than `days` days. Returns count deleted."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
    with store.connect() as conn:
        cursor = conn.execute(
            "DELETE FROM notif_log WHERE sent_at < ?", (cutoff,)
        )
        return cursor.rowcount
