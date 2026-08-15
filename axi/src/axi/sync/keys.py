"""The key hierarchy derived from the twelve words.

    twelve words --BIP-39--> entropy (16 B)
                               | HKDF-SHA256  info="lifeos/sync/root/v1"
                               v
                            RK (32 B)                  never leaves the device
                  +------------+---------------------------+
                  v                                        v
    DK = HKDF(RK, info="lifeos/sync/data/v1")   per mailbox m:
    one AES-256 data key shared by the           seed = HKDF(RK, salt=uuid_m,
    whole device set                                    info="lifeos/sync/mbauth/v1")
                                                 -> Ed25519 keypair from seed

WHY HKDF AND NOT ARGON2ID. `mesh_trust.py` uses argon2id, correctly: it
hardens a passphrase a HUMAN chose, which lives in a small searchable space.
Our input is 128 bits of machine-generated entropy. No work factor improves a
2^128 search, so argon2 would buy exactly zero security here while adding a
heavy dependency and — the real risk — argon2 version/memory parameters that
must match byte-for-byte across five platforms. HKDF-SHA256 is deterministic,
present in both Python's `cryptography` and Dart's `cryptography`, and
trivially test-vectored. This is a deliberate divergence from `_derive_kek`,
not an oversight.

WHY ONE SHARED DATA KEY, NOT PER-DEVICE ASYMMETRIC. Every recipient is the
same person's device. Sealing per device would cost N encryptions per change,
leave envelopes unreadable to a device that joins later, and break the
recovery contract: with one DK, entering the phrase restores the ability to
decrypt everything, which is exactly what the twelve words promise.

WHY PER-MAILBOX AUTH KEYS. The relay has to reject deposits into mailboxes the
caller does not own, so it must verify a signature. If every mailbox in a
device set shared one auth key, the relay could group them and would learn the
shape of the user's device set for free. Deriving per mailbox with the UUID as
salt gives the relay one random-looking pubkey per mailbox and no way to link
them.

FORWARD SECRECY: NONE, ACCEPTED. Whoever obtains the phrase can decrypt every
envelope they ever recorded, past and future. Ratcheting would need per-pair
session state that cannot be re-derived from twelve words — it would destroy
the recovery property that makes the phrase worth writing down. Envelopes are
transient (delete-on-ack + 30-day TTL), so an adversary must tap the relay
continuously rather than seize it once. Stated here, and surfaced to the user
in the sync settings screen.
"""

from __future__ import annotations

from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
)

#: Domain-separation strings. These are part of the wire format: change one and
#: every existing device derives a different key and can no longer read its own
#: data. The `/v1` suffix is the escape hatch — a future scheme bumps it rather
#: than redefining these.
INFO_ROOT = b"lifeos/sync/root/v1"
INFO_DATA = b"lifeos/sync/data/v1"
INFO_MAILBOX_AUTH = b"lifeos/sync/mbauth/v1"

KEY_BYTES = 32


def _hkdf(ikm: bytes, *, info: bytes, salt: bytes = b"") -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=KEY_BYTES,
        salt=salt,
        info=info,
    ).derive(ikm)


@dataclass(frozen=True)
class SyncKeys:
    """Everything derivable from one recovery phrase.

    Frozen because these are secrets with a single correct value: a caller that
    could mutate `data_key` in place would silently produce envelopes nothing
    else can open.
    """

    root_key: bytes
    data_key: bytes

    def mailbox_auth_private(self, mailbox_uuid: str) -> Ed25519PrivateKey:
        """The Ed25519 key that proves ownership of one relay mailbox.

        Derived, never stored: any device in the set can re-derive the key for
        any of the set's mailboxes from the phrase alone, which is what lets a
        newly joined device deposit into a peer's mailbox without a key
        exchange.
        """
        seed = _hkdf(
            self.root_key,
            info=INFO_MAILBOX_AUTH,
            salt=mailbox_uuid.encode("utf-8"),
        )
        return Ed25519PrivateKey.from_private_bytes(seed)

    def mailbox_auth_public(self, mailbox_uuid: str) -> bytes:
        """The 32 raw bytes the relay stores when the mailbox is claimed."""
        return self.mailbox_auth_private(mailbox_uuid).public_key().public_bytes(
            encoding=Encoding.Raw,
            format=PublicFormat.Raw,
        )


def derive(entropy: bytes) -> SyncKeys:
    """Entropy from the twelve words -> the whole key hierarchy.

    Takes ENTROPY, not the mnemonic string, so that the only path into this
    function runs through `phrase.decode` and its checksum. A caller cannot
    hand a mistyped phrase straight to key derivation, because this signature
    does not accept one.
    """
    if len(entropy) != 16:
        raise ValueError(f"expected 16 bytes of entropy; got {len(entropy)}")

    root_key = _hkdf(entropy, info=INFO_ROOT)
    data_key = _hkdf(root_key, info=INFO_DATA)
    return SyncKeys(root_key=root_key, data_key=data_key)
