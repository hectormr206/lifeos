"""Sealing a change set so the relay can carry it without reading it.

    version(1) ‖ env_id(32) ‖ recipient_uuid(16) ‖ AES-256-GCM ciphertext

Fixed offsets, no length prefixes, no self-describing structure. The relay
needs exactly three things to route and dedupe — a version to parse by, an id
to acknowledge, and an address — and it gets nothing else. Everything past byte
49 is opaque.

NONCE REUSE IS IMPOSSIBLE BY CONSTRUCTION, NOT BY DISCIPLINE. The long-lived
data key never encrypts anything. Each envelope derives its own single-use key
from a fresh 256-bit random `env_id`, so the AEAD nonce can be twelve zero
bytes and still never repeat: a repeat would require an env_id collision at a
2^128 birthday bound. The alternative — a random 96-bit nonce under one
long-lived key — carries a 2^32 birthday bound and a standing obligation to
count how many envelopes have ever been sealed. This design has no counter to
persist, and nothing to desynchronise across devices.

The 49-byte header is AUTHENTICATED as AAD. A relay that re-addressed an
envelope, or replayed it into a different mailbox, produces a decryption
failure rather than a change applied to the wrong graph.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

VERSION = 0x01
ENV_ID_BYTES = 32
RECIPIENT_BYTES = 16
HEADER_BYTES = 1 + ENV_ID_BYTES + RECIPIENT_BYTES  # 49

INFO_ENVELOPE = b"lifeos/sync/envelope/v1"

#: Twelve zero bytes. Safe ONLY because the key is single-use — see the module
#: docstring. Never reuse this pattern with a long-lived key.
_NONCE = b"\x00" * 12


class SealError(ValueError):
    """The envelope could not be opened: wrong key, wrong mailbox, or tampered."""


@dataclass(frozen=True)
class OpenedEnvelope:
    env_id: str
    recipient: str
    payload: dict[str, Any]


def _envelope_key(data_key: bytes, env_id: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=env_id,
        info=INFO_ENVELOPE,
    ).derive(data_key)


def seal(
    *,
    data_key: bytes,
    recipient_uuid: str,
    payload: dict[str, Any],
    env_id: bytes | None = None,
) -> bytes:
    """Encrypt one change set for one mailbox.

    `env_id` exists ONLY so the cross-language vectors can be deterministic —
    Dart and Python cannot be shown to produce identical bytes while each picks
    its own random id. Production never passes it; the default is 32 fresh
    CSPRNG bytes, and that randomness is what makes the fixed nonce safe.
    """
    if len(data_key) != 32:
        raise ValueError(f"the data key is 32 bytes; got {len(data_key)}")

    recipient = bytes.fromhex(recipient_uuid)
    if len(recipient) != RECIPIENT_BYTES:
        raise ValueError("a recipient uuid is 16 bytes of hex")

    if env_id is not None and len(env_id) != ENV_ID_BYTES:
        raise ValueError(f"env_id is {ENV_ID_BYTES} bytes; got {len(env_id)}")
    env_id = env_id or os.urandom(ENV_ID_BYTES)
    header = bytes([VERSION]) + env_id + recipient

    body = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ciphertext = AESGCM(_envelope_key(data_key, env_id)).encrypt(_NONCE, body, header)

    return header + ciphertext


def open_envelope(*, data_key: bytes, blob: bytes) -> OpenedEnvelope:
    """Decrypt one envelope, or raise [SealError].

    Every failure — wrong key, altered header, truncated body — surfaces as one
    exception type. A caller's only correct response is "this envelope is not
    for me / not intact", and offering finer distinctions would invite code
    that tries to salvage something from a tampered envelope.
    """
    if len(blob) < HEADER_BYTES:
        raise SealError("too short to be an envelope")
    if blob[0] != VERSION:
        raise SealError(f"unsupported envelope version {blob[0]}")

    header = blob[:HEADER_BYTES]
    env_id = blob[1 : 1 + ENV_ID_BYTES]
    recipient = blob[1 + ENV_ID_BYTES : HEADER_BYTES]

    try:
        body = AESGCM(_envelope_key(data_key, env_id)).decrypt(
            _NONCE, blob[HEADER_BYTES:], header
        )
    except Exception as exc:  # noqa: BLE001 - cryptography raises several types
        raise SealError("could not open the envelope") from exc

    return OpenedEnvelope(
        env_id=env_id.hex(),
        recipient=recipient.hex(),
        payload=json.loads(body.decode("utf-8")),
    )
