"""API tests for the OTA app-update endpoints on the dashboard.

Endpoints (dashboard.py):
  * GET /api/app/manifest  → current manifest JSON, or 404 when none published
  * GET /api/app/download  → streams the current APK bytes with the right
    content-type / Content-Disposition / Content-Length, or 404 when none

Auth: these are legacy `/api/*` routes reachable by the mobile app through the
`/api/v1/*` alias (V1AliasMiddleware) — which is subject to the SAME strict
per-device bearer rule as every other v1 route once `api_auth_enabled=true`
(BearerAuthMiddleware, design D5). No new auth scheme is invented. The auth
tests therefore drive the app-facing `/api/v1/app/*` path and assert 401 with
no/garbage token and 200 with a valid device token.

The updates dir is redirected to a per-test tmp dir via monkeypatch so no test
touches the developer's real ~/.local/state/axi/app-updates.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from axi import app_updates, config, dashboard, store


@pytest.fixture
def updates_dir(tmp_path, monkeypatch):
    """Redirect the app-updates dir at the resolver so both the module and the
    dashboard endpoints (which call the same resolver) see the tmp dir."""
    d = tmp_path / "app-updates"
    monkeypatch.setenv("LIFEOS_APP_UPDATES_DIR", str(d))
    return d


@pytest.fixture
def client(updates_dir):
    return TestClient(dashboard.app)


def _fake_extractor(version_code=3, version_name="1.0.0"):
    return lambda _apk: (version_code, version_name)


def _publish(tmp_path, updates_dir, *, code=3, name="1.0.0", body=b"PK\x03\x04apk", notes=""):
    apk = tmp_path / "src.apk"
    apk.write_bytes(body)
    return app_updates.publish_apk(
        apk, notes=notes, updates_dir=updates_dir, extractor=_fake_extractor(code, name)
    )


# ─────────────────────────────── /api/app/manifest ─────────────────────────


def test_manifest_404_when_nothing_published(client):
    r = client.get("/api/app/manifest")
    assert r.status_code == 404


def test_manifest_returns_published_manifest(client, tmp_path, updates_dir):
    manifest = _publish(tmp_path, updates_dir, code=7, name="0.9.0", notes="hello")
    r = client.get("/api/app/manifest")
    assert r.status_code == 200
    assert r.json() == manifest
    assert r.json()["versionCode"] == 7
    assert r.json()["notes"] == "hello"


# ─────────────────────────────── /api/app/download ─────────────────────────


def test_download_404_when_nothing_published(client):
    r = client.get("/api/app/download")
    assert r.status_code == 404


def test_download_streams_apk_with_headers(client, tmp_path, updates_dir):
    body = b"PK\x03\x04 the-real-apk-bytes-here"
    manifest = _publish(tmp_path, updates_dir, code=5, name="1.2.0", body=body)

    r = client.get("/api/app/download")
    assert r.status_code == 200
    assert r.content == body
    assert r.headers["content-type"] == "application/vnd.android.package-archive"
    assert r.headers["content-length"] == str(len(body))
    assert manifest["apkFilename"] in r.headers["content-disposition"]


def test_download_404_when_manifest_present_but_apk_missing(client, tmp_path, updates_dir):
    _publish(tmp_path, updates_dir, name="1.0.0", code=1)
    # Delete the APK but keep the manifest — endpoint must not crash.
    (updates_dir / "lifeos-1.0.0-1.apk").unlink()
    r = client.get("/api/app/download")
    assert r.status_code == 404


# ─────────────────────────────── auth (reuse D5 bearer) ────────────────────


def _add_device(token: str) -> None:
    store.device_add("dev-app-ota", "Test Phone", token)


def test_manifest_rejects_unauthenticated_via_v1(client, tmp_path, updates_dir):
    _publish(tmp_path, updates_dir)
    config.save({"api_auth_enabled": True})
    r = client.get("/api/v1/app/manifest")  # app-facing path, no token
    assert r.status_code == 401


def test_manifest_allows_authenticated_via_v1(client, tmp_path, updates_dir):
    manifest = _publish(tmp_path, updates_dir)
    config.save({"api_auth_enabled": True})
    _add_device("tok-app-ota")
    r = client.get("/api/v1/app/manifest", headers={"Authorization": "Bearer tok-app-ota"})
    assert r.status_code == 200
    assert r.json() == manifest


def test_download_rejects_unauthenticated_via_v1(client, tmp_path, updates_dir):
    _publish(tmp_path, updates_dir)
    config.save({"api_auth_enabled": True})
    r = client.get("/api/v1/app/download")  # no token
    assert r.status_code == 401


def test_download_allows_authenticated_via_v1(client, tmp_path, updates_dir):
    body = b"authed-apk"
    _publish(tmp_path, updates_dir, body=body)
    config.save({"api_auth_enabled": True})
    _add_device("tok-dl")
    r = client.get("/api/v1/app/download", headers={"Authorization": "Bearer tok-dl"})
    assert r.status_code == 200
    assert r.content == body
