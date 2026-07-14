"""Tests for `axi.api_versioning.V1AliasMiddleware` (M0-1).

Design D4: new mobile-facing endpoints live on a native `/api/v1`
APIRouter; every OTHER existing `/api/*` decorator route stays untouched.
This pure-ASGI middleware makes those legacy routes reachable under
`/api/v1/*` too, by rewriting `scope["path"]` — but ONLY when no native v1
route already claims the exact path (probed against `app.router` with
`Match.FULL`).

Covers:
  - legacy route aliasing: /api/v1/X reaches the same handler as /api/X
  - native v1 route wins: a real /api/v1/X endpoint is never shadowed/aliased
  - legacy-only requests (no v1 prefix) are a complete no-op (scope untouched)
  - alias-bypass RED cases demanded by the design:
      * "/api//v1/..." (duplicate slash) must still resolve as a v1 alias,
        not slip past detection
      * "/api/v1/../..." (dot-segment escape) must NOT be treated as a v1
        path at all once normalized — scope is left untouched, fail-closed
  - full dashboard.app regression: an existing legacy GET route (e.g.
    /api/facts) stays reachable at its original path unchanged, AND is now
    also reachable via /api/v1/facts with an identical response
"""
from __future__ import annotations

import asyncio

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from axi.api_versioning import V1AliasMiddleware, install_v1_alias_middleware


def _build_app() -> FastAPI:
    app = FastAPI()

    @app.get("/api/legacy")
    def legacy():
        return {"who": "legacy"}

    @app.get("/api/v1/native")
    def native():
        return {"who": "native-v1"}

    install_v1_alias_middleware(app)
    return app


@pytest.fixture
def client():
    return TestClient(_build_app())


def test_legacy_route_aliased_under_v1(client):
    r = client.get("/api/v1/legacy")
    assert r.status_code == 200
    assert r.json() == {"who": "legacy"}


def test_legacy_route_still_reachable_directly(client):
    r = client.get("/api/legacy")
    assert r.status_code == 200
    assert r.json() == {"who": "legacy"}


def test_native_v1_route_is_never_aliased_or_shadowed(client):
    r = client.get("/api/v1/native")
    assert r.status_code == 200
    assert r.json() == {"who": "native-v1"}


def test_native_v1_route_has_no_legacy_twin(client):
    """There is no /api/native handler — proves the native route truly
    served the request itself rather than being (accidentally) aliased
    somewhere and coincidentally matching."""
    r = client.get("/api/native")
    assert r.status_code == 404


def test_unknown_v1_path_with_no_legacy_twin_404s(client):
    r = client.get("/api/v1/does-not-exist")
    assert r.status_code == 404


def test_non_api_path_is_untouched(client):
    r = client.get("/does-not-exist")
    assert r.status_code == 404


def test_duplicate_slash_alias_still_resolves(client):
    """"/api//v1/legacy" must normalize to the same v1 alias decision as
    "/api/v1/legacy" — a naive string-prefix check ("/api/v1/") would miss
    this and let the request fall through unrewritten (alias-bypass)."""
    r = client.get("/api//v1/legacy")
    assert r.status_code == 200
    assert r.json() == {"who": "legacy"}


def test_duplicate_slash_native_v1_still_resolves(client):
    r = client.get("/api//v1/native")
    assert r.status_code == 200
    assert r.json() == {"who": "native-v1"}


# ─────────────────── raw-ASGI-scope tests (dot-segment bypass) ─────────────
#
# httpx/TestClient normalizes ".." out of a URL path at client-construction
# time (verified: httpx.URL("/api/v1/../legacy").path == "/api/legacy"), so a
# literal "/api/v1/../legacy" request line can never be reproduced through
# TestClient — the client already resolves it before the request is sent.
# A raw ASGI server (or a malicious proxy) is not guaranteed to do that
# resolution, so the middleware is tested directly as a plain ASGI callable
# with a hand-built scope carrying the literal, unresolved path.


class _RecordingApp:
    """Fake ASGI app that just records the scope it was called with."""

    def __init__(self):
        self.received_scope = None

    async def __call__(self, scope, receive, send):
        self.received_scope = scope
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b""})


def _make_scope(path: str) -> dict:
    return {
        "type": "http",
        "method": "GET",
        "path": path,
        "raw_path": path.encode("utf-8"),
        "headers": [],
        "query_string": b"",
    }


class _FakeRouterNoRoutes:
    routes: list = []


def test_dot_segment_path_is_never_rewritten():
    """A raw scope path of "/api/v1/../legacy" normalizes to "/api/legacy",
    which no longer starts with the v1 prefix at all — the middleware must
    leave the ORIGINAL scope["path"] completely untouched (fail-closed:
    ordinary routing decides, and a literal path containing ".." matches no
    registered route)."""
    inner = _RecordingApp()
    middleware = V1AliasMiddleware(inner, router=_FakeRouterNoRoutes())

    scope = _make_scope("/api/v1/../legacy")

    async def receive():
        return {"type": "http.disconnect"}

    async def send(message):
        pass

    asyncio.run(middleware(scope, receive, send))

    assert inner.received_scope is not None
    # Untouched: the middleware never rewrote this to "/api/legacy" — the
    # inner app sees the exact original literal path, proving no alias
    # (and no accidental grant of legacy access) was applied.
    assert inner.received_scope["path"] == "/api/v1/../legacy"


def test_bare_v1_prefix_with_nothing_after_is_never_rewritten():
    """"/api/v1" alone (no trailing suffix) must not be rewritten to "/api"."""
    inner = _RecordingApp()
    middleware = V1AliasMiddleware(inner, router=_FakeRouterNoRoutes())

    scope = _make_scope("/api/v1")

    async def receive():
        return {"type": "http.disconnect"}

    async def send(message):
        pass

    asyncio.run(middleware(scope, receive, send))

    assert inner.received_scope["path"] == "/api/v1"


# ─────────────────── regression against the real dashboard app ─────────────


@pytest.fixture
def dashboard_client(monkeypatch):
    from axi import dashboard

    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 100, "total_mb": 1000, "util_pct": 10,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 100, "total": 1000, "pct": 10.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 1.5)

    return TestClient(dashboard.app)


def test_dashboard_legacy_route_reachable_under_v1_alias(dashboard_client):
    direct = dashboard_client.get("/api/facts")
    aliased = dashboard_client.get("/api/v1/facts")

    assert direct.status_code == 200
    assert aliased.status_code == 200
    assert aliased.json() == direct.json()


def test_dashboard_legacy_route_unchanged(dashboard_client):
    """Existing clients calling the legacy path directly see zero behaviour
    change — the alias middleware must be a pure no-op for them."""
    r = dashboard_client.get("/api/facts")
    assert r.status_code == 200
    assert r.json() == []
