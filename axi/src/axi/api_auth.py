"""Axi API bearer auth — per-device token middleware for `/api/v1` (M0-3).

Design: sdd/mobile-app design D5 ("Auth: per-device bearer, hashed in DB").
Mirrors the extraction precedent set by `axi.api_versioning` (M0-1): a
small, independently testable pure-ASGI middleware in its own module, wired
into the dashboard's `app` with a one-line `install_auth_middleware(app)`
call.

Installation order matters (see dashboard.py): this middleware must be
installed AFTER `api_versioning.install_v1_alias_middleware(app)` so it
becomes the OUTERMOST user middleware (Starlette's `add_middleware` makes
the most-recently-added middleware the outermost one) — it must see the
RAW, pre-rewrite request path, exactly as D5 specifies ("Middleware order
(outermost, sees pre-rewrite path)").

Semantics (D5):
  1. Master switch `api_auth_enabled` (ConfigField, default False). When
     False, this middleware is a complete no-op for every request — the
     dashboard behaves exactly as it does today. This is the instant
     rollback switch.
  2. PUBLIC exemptions, always allowed regardless of the switch:
       - any path that does not start with "/api" at all (Jinja pages,
         static assets, the `/axi-rootCA.crt` cert route, websockets, ...)
       - `/api/v1/pair` (the pairing exchange endpoint — added in a later
         M0 task; exempted here now so it never regresses once it lands)
  3. `/api/v1/*` (not PUBLIC): STRICT always. A valid, non-revoked device
     bearer token is required — no localhost/loopback grace, ever.
  4. legacy `/api/*` (not v1, not PUBLIC): gated by `api_auth_enforce_legacy`
     (ConfigField, default False = today's fully-open perimeter). When
     True, a valid bearer token OR a loopback client (127.0.0.1 / ::1)
     passes.

Every classification uses `api_versioning.classify()` (normalized-path
based) — the SAME classification logic the alias middleware uses — so a
duplicate-slash or dot-segment request cannot be classified as "legacy"
here while being classified as "v1" (or vice versa) a layer downstream.
"""
from __future__ import annotations

import json
import logging
from typing import Any, Awaitable, Callable

from starlette.types import Receive, Scope, Send

from axi import api_versioning, config, store

log = logging.getLogger("axi.api_auth")

_V1_PREFIX = "/api/v1"

# Native v1 endpoints that must be reachable with no device token at all,
# even when api_auth_enabled=true. Exact normalized-path match.
PUBLIC_V1_PATHS: frozenset[str] = frozenset({"/api/v1/pair"})

_LOOPBACK_HOSTS: frozenset[str] = frozenset({"127.0.0.1", "::1"})


def _bearer_token(scope: Scope) -> str | None:
    """Extract the raw bearer token from the Authorization header, or None."""
    for key, value in scope.get("headers") or []:
        if key.lower() == b"authorization":
            header = value.decode("latin-1")
            if header.startswith("Bearer "):
                token = header[len("Bearer "):].strip()
                return token or None
            return None
    return None


def _valid_device_for_token(token: str | None) -> dict[str, Any] | None:
    """Return the device row for *token* iff it is a known, non-revoked
    device bearer token. None on any miss/revocation.

    Lookup is by SHA-256 hash (never the raw token) via
    `store.device_get_by_token_hash` — the constant-time-comparison
    property comes from comparing hashes through a DB equality lookup
    rather than a per-character Python string compare of the raw secret.
    """
    if not token:
        return None
    device = store.device_get_by_token_hash(store.hash_device_token(token))
    if device is None:
        return None
    if device.get("revoked_at") is not None:
        return None
    return device


def _is_loopback(scope: Scope) -> bool:
    client = scope.get("client")
    if not client:
        return False
    host = client[0]
    return host in _LOOPBACK_HOSTS


async def _send_401(send: Send) -> None:
    body = json.dumps({"detail": "Unauthorized"}).encode("utf-8")
    await send({
        "type": "http.response.start",
        "status": 401,
        "headers": [
            (b"content-type", b"application/json"),
            (b"www-authenticate", b"Bearer"),
            (b"content-length", str(len(body)).encode("ascii")),
        ],
    })
    await send({"type": "http.response.body", "body": body})


class BearerAuthMiddleware:
    """Pure-ASGI middleware enforcing D5's per-device bearer auth rules."""

    def __init__(
        self,
        app: Callable[[Scope, Receive, Send], Awaitable[None]],
    ) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        if not config.get("api_auth_enabled", False):
            # Master switch off — zero behaviour change (default state).
            await self.app(scope, receive, send)
            return

        raw_path = scope.get("path", "")
        if not raw_path.startswith("/api"):
            # PUBLIC: Jinja pages, static assets, /axi-rootCA.crt, etc.
            await self.app(scope, receive, send)
            return

        normalized, v1_suffix = api_versioning.classify(raw_path)

        if v1_suffix is not None:
            v1_path = _V1_PREFIX + v1_suffix
            if v1_path in PUBLIC_V1_PATHS:
                await self.app(scope, receive, send)
                return
            device = _valid_device_for_token(_bearer_token(scope))
            if device is None:
                await _send_401(send)
                return
            self._touch_last_seen(device)
            await self.app(scope, receive, send)
            return

        # Legacy /api/* (not v1).
        if not config.get("api_auth_enforce_legacy", False):
            await self.app(scope, receive, send)
            return

        device = _valid_device_for_token(_bearer_token(scope))
        if device is not None:
            self._touch_last_seen(device)
            await self.app(scope, receive, send)
            return
        if _is_loopback(scope):
            await self.app(scope, receive, send)
            return
        await _send_401(send)

    @staticmethod
    def _touch_last_seen(device: dict[str, Any]) -> None:
        # Best-effort bookkeeping — a write hiccup must never turn an
        # otherwise-valid, already-authenticated request into a 500.
        try:
            store.device_touch_last_seen(device["device_id"])
        except Exception:  # noqa: BLE001
            log.debug("device_touch_last_seen failed", exc_info=True)


def install_auth_middleware(app: Any) -> None:
    """Register :class:`BearerAuthMiddleware` on *app*.

    Usage (dashboard.py) — MUST be called AFTER
    `api_versioning.install_v1_alias_middleware(app)` so this middleware
    ends up outermost (sees the pre-rewrite path):
        from axi import api_auth, api_versioning
        api_versioning.install_v1_alias_middleware(app)
        api_auth.install_auth_middleware(app)
    """
    app.add_middleware(BearerAuthMiddleware)
