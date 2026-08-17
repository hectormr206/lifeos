"""Proving a caller holds a mailbox's key, without learning who they are.

The relay verifies a signature over the exact request it received. That proves
possession of the private key for one mailbox — and nothing else. No account,
no device name, no user id. The mailbox UUID is the only identifier involved,
and it is random.

The preimage binds method, path, timestamp, nonce and a hash of the body, so a
captured request cannot be replayed against a different endpoint, with
different content, or tomorrow.
"""

from __future__ import annotations

import hashlib

#: How far a request's timestamp may be from the relay's clock. Wide enough for
#: a phone with a lazy NTP sync, narrow enough that a captured request is not
#: useful for long. Paired with the nonce cache, which is what actually stops a
#: replay inside the window.
FRESHNESS_SECONDS = 300


def signing_preimage(
    method: str, path: str, ts: str, nonce: str, body: bytes
) -> bytes:
    """The exact bytes a client signs.

    Every field is separated by a byte that cannot appear in the others, so
    `("POST", "/a/b")` and `("POST/a", "/b")` cannot produce the same preimage —
    a concatenation without separators is a signature-confusion bug waiting to
    be found.

    The BODY is hashed rather than included: envelopes reach 1 MiB and signing
    over the whole thing would mean buffering it twice.
    """
    return b"\x00".join(
        [
            method.upper().encode(),
            path.encode(),
            ts.encode(),
            nonce.encode(),
            hashlib.sha256(body).hexdigest().encode(),
        ]
    )
