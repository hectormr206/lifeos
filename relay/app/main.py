"""The blind relay's four endpoints.

    PUT  /v1/mailbox/{uuid}            claim it, registering an auth pubkey
    POST /v1/mailbox/{uuid}/envelopes  deposit one opaque envelope
    GET  /v1/mailbox/{uuid}/envelopes  fetch what is pending
    POST /v1/mailbox/{uuid}/ack        delete one envelope by id

Everything is authenticated by an Ed25519 signature over the exact request
(see `auth.py`), which proves possession of the mailbox's key and reveals
nothing about who holds it.

The relay NEVER parses an envelope's contents. It checks the fixed 49-byte
header — version, env_id, recipient — because it has to route and dedupe, and
then treats the rest as bytes. A payload it CAN interpret is refused: that
means a client sent plaintext by mistake, and storing it would make this
service exactly the thing the design promises it is not.
"""

from __future__ import annotations

import json
from typing import Callable

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import FastAPI, Request, Response

from app.auth import FRESHNESS_SECONDS, signing_preimage
from app.store import MAX_ENVELOPE_BYTES, RelayStore

#: version(1) + env_id(32) + recipient(16)
HEADER_BYTES = 49
ENVELOPE_VERSION = 0x01


def _json(status: int, payload: dict) -> Response:
    return Response(
        content=json.dumps(payload),
        status_code=status,
        media_type="application/json",
    )


def build_app(*, store: RelayStore, now: Callable[[], float]) -> FastAPI:
    app = FastAPI(title="LifeOS blind relay", docs_url=None, redoc_url=None)

    async def _verify(request: Request, body: bytes, pubkey_hex: str) -> str | None:
        """Returns an error string, or None when the request is authentic."""
        ts = request.headers.get("X-Relay-Ts")
        nonce = request.headers.get("X-Relay-Nonce")
        sig = request.headers.get("X-Relay-Sig")
        if not (ts and nonce and sig):
            return "missing signature headers"

        try:
            skew = abs(now() - float(ts))
        except ValueError:
            return "bad timestamp"
        if skew > FRESHNESS_SECONDS:
            return "stale request"

        # The nonce is consumed BEFORE the signature verifies, so a valid
        # request cannot be replayed even once.
        if not store.remember_nonce(nonce):
            return "replayed nonce"

        try:
            Ed25519PublicKey.from_public_bytes(bytes.fromhex(pubkey_hex)).verify(
                bytes.fromhex(sig),
                signing_preimage(request.method, request.url.path, ts, nonce, body),
            )
        except (InvalidSignature, ValueError):
            return "bad signature"
        return None

    @app.put("/v1/mailbox/{mailbox}")
    async def claim(mailbox: str, request: Request) -> Response:
        body = await request.body()
        pubkey_hex = body.decode(errors="ignore").strip()

        # The claim is self-signed: the caller proves it holds the key it is
        # registering. Without that, anyone could claim any mailbox with a key
        # they do not have and lock the real owner out.
        error = await _verify(request, body, pubkey_hex)
        if error:
            return _json(401, {"error": error})

        if not store.claim(mailbox, pubkey_hex):
            return _json(409, {"error": "mailbox already claimed"})
        return _json(201, {"claimed": True})

    async def _authorised(mailbox: str, request: Request, body: bytes):
        claim_row = store.debug_claim(mailbox)
        if claim_row is None:
            # 404, not 403: an unclaimed mailbox and a mailbox that does not
            # exist are the same thing here, and saying which would let someone
            # enumerate live mailboxes.
            return None, _json(404, {"error": "no such mailbox"})

        error = await _verify(request, body, claim_row["auth_pubkey"])
        if error:
            return None, _json(401, {"error": error})

        store.touch(mailbox)  # every authenticated use extends the claim
        return claim_row, None

    @app.post("/v1/mailbox/{mailbox}/envelopes")
    async def deposit(mailbox: str, request: Request) -> Response:
        body = await request.body()

        _, refusal = await _authorised(mailbox, request, body)
        if refusal is not None:
            return refusal

        if len(body) > MAX_ENVELOPE_BYTES:
            return _json(413, {"error": "envelope too large"})
        if len(body) < HEADER_BYTES:
            return _json(400, {"error": "not an envelope"})
        if body[0] != ENVELOPE_VERSION:
            return _json(400, {"error": "unsupported envelope version"})
        if body[33:49].hex() != mailbox:
            return _json(400, {"error": "envelope addressed to another mailbox"})

        # Refuse anything the relay could read. If it parses as JSON it is
        # plaintext, and this service must never hold plaintext.
        try:
            json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass  # good: opaque
        else:
            return _json(400, {"error": "payload is not ciphertext"})

        if store.at_capacity(mailbox, len(body)):
            return _json(429, {"error": "mailbox full"})

        env_id = body[1:33].hex()
        store.deposit(mailbox, env_id, body)
        return _json(202, {"env_id": env_id})

    @app.get("/v1/mailbox/{mailbox}/envelopes")
    async def fetch(mailbox: str, request: Request) -> Response:
        _, refusal = await _authorised(mailbox, request, b"")
        if refusal is not None:
            return refusal

        return _json(
            200,
            {
                "envelopes": [
                    {"env_id": e["env_id"], "body": e["body"].hex()}
                    for e in store.pending(mailbox)
                ]
            },
        )

    @app.post("/v1/mailbox/{mailbox}/ack")
    async def ack(mailbox: str, request: Request) -> Response:
        body = await request.body()

        _, refusal = await _authorised(mailbox, request, body)
        if refusal is not None:
            return refusal

        store.ack(mailbox, body.decode(errors="ignore").strip())
        return Response(status_code=204)

    @app.get("/healthz")
    async def healthz() -> Response:
        return Response(content="ok\n", media_type="text/plain")

    return app


def sweep_forever(store: RelayStore, *, interval_seconds: int = 3600) -> None:
    """Hourly expiry, and once at startup.

    At startup matters as much as hourly: a relay that was down for a week
    would otherwise serve envelopes and claims that expired while it slept, and
    the "an idle set leaves nothing behind" promise would hold only for
    services that never restart.

    Deliberately a plain loop rather than a scheduler dependency — the whole
    service is meant to be small enough to audit in one sitting.
    """
    import threading
    import time as _time

    store.sweep()

    def _loop() -> None:
        while True:
            _time.sleep(interval_seconds)
            try:
                store.sweep()
            except Exception:  # noqa: BLE001
                # A failed sweep must never take the relay down: delivery is
                # the service's job, expiry is hygiene. It retries in an hour.
                pass

    threading.Thread(target=_loop, daemon=True, name="relay-sweep").start()
