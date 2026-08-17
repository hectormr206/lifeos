"""The only state the relay keeps: pending envelopes and live mailbox claims.

BOTH EXPIRE. That is the design, not an optimisation. A claim table that
outlives use would slowly become a permanent, pseudonymous census of every
device set that ever synced — precisely the linkable residue this architecture
exists to avoid. An active set refreshes its claim on every authenticated
request and keeps its anti-spam protection forever; an abandoned one leaves
zero rows behind.

Accepted consequence: a set idle for over 30 days can find its mailbox UUID
squatted by someone who already knew it. The UUID is 128-bit random, so that
requires prior knowledge, and the impact is denial of delivery — never
disclosure, since a squatter cannot decrypt. Recovery is to claim a fresh UUID
and announce it through the roster.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any, Callable

TTL_SECONDS = 30 * 86400
MAX_ENVELOPE_BYTES = 1024 * 1024
DEFAULT_MAX_ENVELOPES = 1024
DEFAULT_MAX_MAILBOX_BYTES = 256 * 1024 * 1024


class RelayStore:
    def __init__(
        self,
        *,
        path: Path | str,
        now: Callable[[], float],
    ) -> None:
        self._now = now
        self._max_envelopes = DEFAULT_MAX_ENVELOPES
        self._max_bytes = DEFAULT_MAX_MAILBOX_BYTES
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._create_schema()

    def _create_schema(self) -> None:
        self._conn.executescript(
            """
            -- One row per claimed mailbox. `auth_pubkey` is the ONLY thing that
            -- identifies anything, and it is a random-looking curve point
            -- derived per mailbox: two mailboxes of one device set share no
            -- field that could group them.
            CREATE TABLE IF NOT EXISTS claims (
                mailbox      TEXT PRIMARY KEY,
                auth_pubkey  TEXT NOT NULL,
                claimed_at   REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );

            -- Opaque ciphertext, awaiting collection. Never parsed.
            CREATE TABLE IF NOT EXISTS envelopes (
                env_id       TEXT PRIMARY KEY,
                mailbox      TEXT NOT NULL,
                body         BLOB NOT NULL,
                deposited_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_envelopes_mailbox
                ON envelopes(mailbox);

            -- Seen nonces, so a captured request cannot be replayed inside the
            -- freshness window. Swept with everything else.
            CREATE TABLE IF NOT EXISTS nonces (
                nonce   TEXT PRIMARY KEY,
                seen_at REAL NOT NULL
            );
            """
        )
        self._conn.commit()

    # -- limits ---------------------------------------------------------

    def set_limits(self, *, max_envelopes: int | None = None, max_bytes: int | None = None) -> None:
        if max_envelopes is not None:
            self._max_envelopes = max_envelopes
        if max_bytes is not None:
            self._max_bytes = max_bytes

    # -- claims ---------------------------------------------------------

    def claim(self, mailbox: str, auth_pubkey: str) -> bool:
        """Claim a mailbox. False when someone else already holds it."""
        existing = self.debug_claim(mailbox)
        if existing is not None:
            # Re-claiming with the SAME key is idempotent — a device that
            # reinstalled from the phrase derives the identical key and must
            # not be locked out of its own mailbox.
            return existing["auth_pubkey"] == auth_pubkey

        now = self._now()
        self._conn.execute(
            "INSERT INTO claims (mailbox, auth_pubkey, claimed_at, last_seen_at)"
            " VALUES (?, ?, ?, ?)",
            (mailbox, auth_pubkey, now, now),
        )
        self._conn.commit()
        return True

    def claim_exists(self, mailbox: str) -> bool:
        return self.debug_claim(mailbox) is not None

    def debug_claim(self, mailbox: str) -> dict[str, Any] | None:
        row = self._conn.execute(
            "SELECT mailbox, auth_pubkey, claimed_at, last_seen_at"
            " FROM claims WHERE mailbox = ?",
            (mailbox,),
        ).fetchone()
        return dict(row) if row else None

    def touch(self, mailbox: str) -> None:
        """Every successful authenticated request extends the claim by 30 days."""
        self._conn.execute(
            "UPDATE claims SET last_seen_at = ? WHERE mailbox = ?",
            (self._now(), mailbox),
        )
        self._conn.commit()

    # -- envelopes ------------------------------------------------------

    def deposit(self, mailbox: str, env_id: str, body: bytes) -> None:
        self._conn.execute(
            "INSERT OR IGNORE INTO envelopes (env_id, mailbox, body, deposited_at)"
            " VALUES (?, ?, ?, ?)",
            (env_id, mailbox, body, self._now()),
        )
        self._conn.commit()

    def pending(self, mailbox: str) -> list[dict[str, Any]]:
        cutoff = self._now() - TTL_SECONDS
        rows = self._conn.execute(
            "SELECT env_id, body FROM envelopes"
            " WHERE mailbox = ? AND deposited_at > ?"
            " ORDER BY deposited_at ASC",
            (mailbox, cutoff),
        ).fetchall()
        return [{"env_id": r["env_id"], "body": r["body"]} for r in rows]

    def ack(self, mailbox: str, env_id: str) -> None:
        """Delete on acknowledgement. The recipient has it; we are done."""
        self._conn.execute(
            "DELETE FROM envelopes WHERE mailbox = ? AND env_id = ?",
            (mailbox, env_id),
        )
        self._conn.commit()

    def envelope_count(self, mailbox: str) -> int:
        return self._conn.execute(
            "SELECT COUNT(*) AS n FROM envelopes WHERE mailbox = ?", (mailbox,)
        ).fetchone()["n"]

    def mailbox_bytes(self, mailbox: str) -> int:
        row = self._conn.execute(
            "SELECT COALESCE(SUM(LENGTH(body)), 0) AS n FROM envelopes WHERE mailbox = ?",
            (mailbox,),
        ).fetchone()
        return row["n"]

    def at_capacity(self, mailbox: str, incoming: int) -> bool:
        return (
            self.envelope_count(mailbox) >= self._max_envelopes
            or self.mailbox_bytes(mailbox) + incoming > self._max_bytes
        )

    # -- nonces ---------------------------------------------------------

    def remember_nonce(self, nonce: str) -> bool:
        """False when this nonce was already used — that is a replay."""
        try:
            self._conn.execute(
                "INSERT INTO nonces (nonce, seen_at) VALUES (?, ?)",
                (nonce, self._now()),
            )
            self._conn.commit()
            return True
        except sqlite3.IntegrityError:
            return False

    # -- sweep ----------------------------------------------------------

    def sweep(self) -> None:
        """Drop everything past its TTL: envelopes, claims and nonces.

        Claims go on the SAME clock as envelopes, refreshed by use. This is the
        line between "a relay that forgets" and "a registry of everyone who
        ever synced".
        """
        cutoff = self._now() - TTL_SECONDS
        self._conn.execute("DELETE FROM envelopes WHERE deposited_at <= ?", (cutoff,))
        self._conn.execute("DELETE FROM claims WHERE last_seen_at <= ?", (cutoff,))
        # Nonces only need to outlive the freshness window; a day is generous.
        self._conn.execute(
            "DELETE FROM nonces WHERE seen_at <= ?", (self._now() - 86400,)
        )
        self._conn.commit()

    def rows_for(self, mailbox: str) -> int:
        """Every row anywhere that mentions this mailbox. Used to prove that an
        idle device set leaves NOTHING behind — not an envelope, not a claim."""
        return (
            self.envelope_count(mailbox)
            + (1 if self.claim_exists(mailbox) else 0)
        )

    def debug_dump(self) -> dict[str, Any]:
        return {
            "claims": [dict(r) for r in self._conn.execute("SELECT * FROM claims")],
            "envelope_ids": [
                r["env_id"] for r in self._conn.execute("SELECT env_id FROM envelopes")
            ],
        }
