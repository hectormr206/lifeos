"""Axi API versioning — the `/api/v1` alias layer (M0-1).

Mirrors the extraction precedent set by `axi.obs.install_request_id_middleware`:
a small, independently testable ASGI middleware defined in its own module,
wired into the dashboard's `app` with a one-line `install_*_middleware(app)`
call — no changes to the 180+ existing `@app.*` route decorators.

Design: sdd/mobile-app design D4 ("/api/v1: wrapper, not migration"). New
mobile-facing endpoints register on a dedicated `APIRouter(prefix="/api/v1")`
(added in a later M0 task). Every OTHER existing route stays a plain
`/api/*` decorator, completely untouched. This middleware makes those same
legacy routes reachable under `/api/v1/*` too, by rewriting `scope["path"]`
from `/api/v1/X` to `/api/X` at the pure-ASGI layer — but ONLY when no
*native* v1 route already claims that exact path (probed against the
FastAPI app's `router` with Starlette's `Match.FULL`). Once native v1
endpoints exist (pairing, capabilities, sync, devices, ...) they are always
served directly and are never shadowed by the alias.
"""
from __future__ import annotations

import posixpath
from typing import Any, Awaitable, Callable

from starlette.routing import Match
from starlette.types import Receive, Scope, Send

_V1_PREFIX = "/api/v1"
_LEGACY_PREFIX = "/api"


def _v1_suffix(normalized_path: str) -> str | None:
    """Return the suffix after ``/api/v1`` (leading slash included), or None.

    None means *normalized_path* is not a genuine ``/api/v1/<something>``
    path: either the bare prefix with nothing after it, or a path that
    merely raw-prefix-matched ``/api/v1`` before normalization but no
    longer does once ``.`` / ``..`` segments and duplicate slashes are
    resolved (e.g. ``/api/v1/../legacy`` normalizes to ``/api/legacy``,
    which returns None here — it is simply not a v1 path at all).
    """
    if normalized_path == _V1_PREFIX:
        return None
    if normalized_path.startswith(_V1_PREFIX + "/"):
        return normalized_path[len(_V1_PREFIX):]
    return None


def classify(raw_path: str) -> tuple[str, str | None]:
    """Normalize *raw_path* and classify it for API auth/aliasing decisions.

    Returns ``(normalized_path, v1_suffix)`` where ``v1_suffix`` is the
    suffix after ``/api/v1`` (leading slash included) when the normalized
    path is a genuine ``/api/v1/<something>`` path, else ``None`` (a legacy
    ``/api/*`` path, the bare v1 prefix with nothing after it, or a
    look-alike that normalization proved is not really a v1 path, e.g. a
    dot-segment escape).

    This is the single source of truth for "is this request path v1 or
    legacy" — shared by :class:`V1AliasMiddleware` (M0-1) and
    ``axi.api_auth.BearerAuthMiddleware`` (M0-3) so a duplicate-slash or
    dot-segment bypass can never be classified inconsistently between the
    aliasing layer and the security-relevant auth layer.
    """
    normalized = posixpath.normpath(raw_path)
    return normalized, _v1_suffix(normalized)


class V1AliasMiddleware:
    """Pure-ASGI middleware aliasing ``/api/v1/X`` to legacy ``/api/X``.

    No-op (scope entirely untouched, zero extra work beyond one string
    comparison) for:
      - non-HTTP scopes (websocket, lifespan)
      - any path that does not even raw-prefix-match ``/api`` — the cheap
        fast path every Jinja page route and static asset takes,
        guaranteeing zero behaviour change for non-API traffic.

    Every path under ``/api`` (legacy or v1-look-alike) is normalized
    before classification — intentionally broader than raw-prefix-matching
    ``/api/v1`` specifically, because that narrower check is itself
    bypassable: a raw path like ``/api//v1/x`` does not literally start
    with the string ``/api/v1``, so classifying on the RAW string would
    wrongly treat it as ordinary legacy traffic and skip the alias
    entirely. Classifying every ``/api/*`` path on its NORMALIZED form
    closes that hole, and is still safe for true legacy paths: their
    normalized form never starts with ``/api/v1/...``, so `_v1_suffix`
    returns None and the ORIGINAL (unmodified) scope is passed through —
    legacy behaviour is unaffected either way.

    For paths that DO resolve to a genuine v1 path, the same normalized
    `posixpath.normpath` BEFORE any decision is made. This closes the
    alias-bypass hole where a raw path like ``/api//v1/x`` (duplicate
    slash) or ``/api/v1/../x`` (dot-segment escape) could otherwise dodge
    or smuggle past a naive string-prefix check: only the NORMALIZED form
    is ever used to decide whether to alias and what the rewritten path
    is. A path that normalizes away from ``/api/v1/...`` entirely is
    passed through completely unrewritten — fail-closed, ordinary routing
    decides, which 404s any literal weird path with no matching route.
    """

    def __init__(
        self,
        app: Callable[[Scope, Receive, Send], Awaitable[None]],
        router: Any,
    ) -> None:
        self.app = app
        # Captured explicitly at installation time (see
        # install_v1_alias_middleware) rather than read off `self.app`,
        # because `self.app` is just the next callable in the ASGI
        # middleware chain — it is NOT guaranteed to expose `.router`
        # regardless of where in the stack this middleware is installed.
        # `app.router` on the FastAPI application object itself is stable
        # for the app's lifetime, so a direct reference is always correct.
        self._router = router

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        raw_path = scope.get("path", "")
        if not raw_path.startswith(_LEGACY_PREFIX):
            # Cheapest fast path: not even under /api at all (dashboard
            # pages, static assets, etc). Zero extra work, scope untouched.
            await self.app(scope, receive, send)
            return

        normalized, suffix = classify(raw_path)
        if suffix is None:
            # Either genuinely legacy /api/* traffic, or a look-alike that
            # normalization proved is not really a v1 path (e.g.
            # "/api/v1/../legacy" -> "/api/legacy"). Never rewrite — pass
            # the ORIGINAL scope through completely unchanged. Legacy
            # behaviour is 100% preserved: the normalized form was used
            # only to CLASSIFY the request, never to mutate its scope.
            await self.app(scope, receive, send)
            return

        # Genuine (possibly duplicate-slash) v1 path from here on. Work on
        # a shallow copy with the canonical (normalized) path so downstream
        # routing/probing sees it consistently.
        scope = dict(scope)
        scope["path"] = normalized
        if "raw_path" in scope:
            scope["raw_path"] = normalized.encode("utf-8")

        if self._native_v1_route_matches(scope):
            # A real v1 endpoint (pair, capabilities, sync, devices, ...)
            # already owns this path — serve it directly, never alias.
            await self.app(scope, receive, send)
            return

        # No native v1 route claims this path: alias to the legacy route.
        aliased_path = _LEGACY_PREFIX + suffix
        scope["path"] = aliased_path
        if "raw_path" in scope:
            scope["raw_path"] = aliased_path.encode("utf-8")
        await self.app(scope, receive, send)

    def _native_v1_route_matches(self, scope: Scope) -> bool:
        """True iff some route on the wrapped app fully matches *scope*.

        Implements D4's "probe app.router with Match.FULL" instruction.
        """
        routes = getattr(self._router, "routes", None)
        if not routes:
            return False
        for route in routes:
            try:
                match, _child_scope = route.matches(scope)
            except Exception:  # noqa: BLE001 — a malformed probe must never 500
                continue
            if match == Match.FULL:
                return True
        return False


def install_v1_alias_middleware(app: Any) -> None:
    """Register :class:`V1AliasMiddleware` on *app*.

    Usage (dashboard.py):
        from axi import api_versioning
        api_versioning.install_v1_alias_middleware(app)
    """
    app.add_middleware(V1AliasMiddleware, router=app.router)
