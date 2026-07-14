"""In-memory pairing-code sessions for QR device pairing (M0-5).

Design D6 ("Pairing + TLS pinning"): the `/setup` page mints a short-lived,
single-use pairing code that a phone exchanges (via `POST /api/v1/pair`,
`axi.api_v1`) for a per-device bearer token. Codes themselves are NEVER
persisted to disk — only the resulting device token's SHA-256 hash is
(via `axi.store.device_add`). Losing this table on process restart is
intentional and harmless: the `/setup` page simply mints a fresh code on
its next load.

Pure, dependency-free, thread-safe (single lock guarding a plain dict) —
mirrors the "small, independently testable" precedent set by
`axi.api_versioning` / `axi.api_auth`.
"""
from __future__ import annotations

import secrets
import threading
import time
from typing import Any

_TTL_SECONDS = 300  # 5 minutes (design D6)

_lock = threading.Lock()
_codes: dict[str, dict[str, Any]] = {}


def create_code() -> dict[str, Any]:
    """Mint a new pairing code. Returns {"code": str, "expires_at": float}.

    Multiple codes may be outstanding at once (e.g. multiple browser tabs on
    `/setup`) — minting a new one never invalidates a previously minted,
    still-valid code.
    """
    code = secrets.token_urlsafe(16)
    now = time.time()
    expires_at = now + _TTL_SECONDS
    with _lock:
        _codes[code] = {"created_at": now, "expires_at": expires_at, "used": False}
    return {"code": code, "expires_at": expires_at}


def redeem_code(code: str | None) -> bool:
    """Atomically validate and consume *code*.

    Returns True iff *code* is known, unexpired, and not already used — and
    in that case marks it used so it can never be redeemed a second time
    (D6: single-use). Returns False for None/empty/unknown/expired/reused
    codes, with no side effect.
    """
    if not code:
        return False
    with _lock:
        entry = _codes.get(code)
        if entry is None:
            return False
        if entry["used"]:
            return False
        if time.time() > entry["expires_at"]:
            return False
        entry["used"] = True
        return True


def _reset_for_tests() -> None:
    """Test-only seam: clear all in-memory pairing sessions."""
    with _lock:
        _codes.clear()
