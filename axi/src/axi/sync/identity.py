"""Who this install is: a local UUID, a human nickname, and a proven key.

Built on the EXISTING `devices` table (`store.py`), whose `device_pubkey` and
`pubkey_proven` columns have sat unused since the pairing work. That is
deliberate: the codebase already carries two identity concepts —
`mesh_trust.py`'s mesh nodes and this table's pairing tokens — and a third
would guarantee they drift apart. We extend what is already wired.

Three properties this module exists to hold:

  * The UUID is generated ON DEVICE, offline, with no server. LifeOS is
    autonomous; a fresh install must be able to name itself on a plane.
  * The nickname is unique WITHIN one device set, never globally. Global
    uniqueness needs a registry on the VPS, and a registry is exactly the
    persistent linkable state the blind relay exists to avoid.
  * A public key is a CLAIM until it is proven. `pubkey_proven` is the whole
    difference, and `is_trusted` is the only thing callers should read — so
    nobody can accidentally treat an unproven claim as a proof.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass

from axi import store

#: What `nickname` uniqueness is scoped to. Returned by [nickname_scope] so the
#: scope is assertable rather than folklore.
NICKNAME_SCOPE = "device-set"


class DeviceExists(ValueError):
    """That UUID is already registered in this device set."""


class NicknameTaken(ValueError):
    """Another device in THIS set already uses that nickname."""


class NoPublicKey(ValueError):
    """Cannot mark a key proven when no key was ever supplied."""


@dataclass(frozen=True)
class Device:
    uuid: str
    nickname: str
    public_key: str | None
    pubkey_proven: bool
    revoked: bool

    @property
    def is_trusted(self) -> bool:
        """The ONLY question callers should ask about a device's key.

        Three ways to be untrusted, and all three are easy to get wrong when
        read separately: no key at all, a key that was never proven, and a
        device whose access was revoked after proving one. Revocation
        deliberately does NOT erase `pubkey_proven` — the proof did happen and
        the history is worth keeping — so a caller reading that flag alone
        would still consider a revoked device good.
        """
        return self.public_key is not None and self.pubkey_proven and not self.revoked


def new_device_uuid() -> str:
    """128 bits of CSPRNG, lowercase hex, no dashes.

    Per INSTALL, not per machine: never derived from hardware. A hardware
    fingerprint would follow a user across the wipe they performed precisely to
    be rid of it, and would collide across cloned VMs. A wiped install is a new
    device; the old mailbox simply expires at the relay.

    No network, no clock, no machine identifier — `secrets.token_hex` reads the
    OS CSPRNG and nothing else, which is what makes offline first-run work.
    """
    return secrets.token_hex(16)


def normalise_nickname(nickname: str) -> str:
    """Fold what a human types. "Laptop " and "laptop" name the same device."""
    return " ".join(nickname.split()).lower()


def nickname_scope() -> str:
    return NICKNAME_SCOPE


def registered_nicknames(conn=None) -> set[str]:
    """Every nickname taken in THIS device set. Never leaves the device."""
    conn = conn or store._connect()  # noqa: SLF001
    rows = conn.execute("SELECT name FROM devices").fetchall()
    return {normalise_nickname(r["name"]) for r in rows}


def register_device(
    *,
    uuid: str,
    nickname: str,
    public_key: str | None = None,
    conn=None,
) -> Device:
    """Add this install to the device set.

    A supplied `public_key` is stored UNPROVEN. Proving it is a separate,
    explicit step ([mark_pubkey_proven]) that happens only after the device has
    signed a challenge — storing and trusting must never be the same call.
    """
    conn = conn or store._connect()  # noqa: SLF001
    folded = normalise_nickname(nickname)

    if not folded:
        raise ValueError("a device nickname cannot be empty")

    existing = conn.execute(
        "SELECT 1 FROM devices WHERE device_id = ?", (uuid,)
    ).fetchone()
    if existing:
        raise DeviceExists(f"device {uuid} is already registered")

    if folded in registered_nicknames(conn):
        raise NicknameTaken(
            f"another device in this set is already called '{nickname.strip()}'"
        )

    now = time.time()
    conn.execute(
        """
        INSERT INTO devices
            (device_id, name, token_hash, device_pubkey, pubkey_proven, created_at)
        VALUES (?, ?, ?, ?, 0, ?)
        """,
        # `token_hash` is NOT NULL UNIQUE and belongs to the pairing flow, which
        # a sync-only device never runs. A per-device random placeholder keeps
        # the constraint honest without pretending a bearer token exists.
        (uuid, nickname.strip(), f"sync:{uuid}", public_key, now),
    )
    conn.commit()

    return Device(
        uuid=uuid,
        nickname=nickname.strip(),
        public_key=public_key,
        pubkey_proven=False,
        revoked=False,
    )


def get_device(uuid: str, conn=None) -> Device | None:
    conn = conn or store._connect()  # noqa: SLF001
    row = conn.execute(
        """
        SELECT device_id, name, device_pubkey, pubkey_proven, revoked_at
        FROM devices WHERE device_id = ?
        """,
        (uuid,),
    ).fetchone()
    if row is None:
        return None

    return Device(
        uuid=row["device_id"],
        nickname=row["name"],
        public_key=row["device_pubkey"],
        pubkey_proven=bool(row["pubkey_proven"]),
        revoked=row["revoked_at"] is not None,
    )


def mark_pubkey_proven(uuid: str, conn=None) -> None:
    """Record that this device signed a challenge with its private key.

    Refuses when there is no key: marking "proven" on an absent key would leave
    a row that reads as trusted with nothing behind it.
    """
    conn = conn or store._connect()  # noqa: SLF001
    device = get_device(uuid, conn=conn)
    if device is None:
        raise ValueError(f"unknown device {uuid}")
    if device.public_key is None:
        raise NoPublicKey(f"device {uuid} has no public key to prove")

    conn.execute(
        "UPDATE devices SET pubkey_proven = 1 WHERE device_id = ?", (uuid,)
    )
    conn.commit()


def revoke_device(uuid: str, conn=None) -> None:
    """Revoke a device's access, keeping the record of what it once proved."""
    conn = conn or store._connect()  # noqa: SLF001
    conn.execute(
        "UPDATE devices SET revoked_at = ? WHERE device_id = ?", (time.time(), uuid)
    )
    conn.commit()
