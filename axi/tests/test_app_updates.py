"""Unit tests for `axi.app_updates` — the OTA publish engine.

Design: sdd OTA app-update (engine side). A pure, testable `publish_apk`
extracts the versionCode/versionName from the real APK binary (via an
injectable aapt extractor), computes sha256 + size, copies the APK into a
configurable updates dir under a stable name, writes `manifest.json`, and
returns the manifest dict.

The aapt extractor and the filesystem are injected/redirected so these
tests never touch the developer's real Android SDK or ~/.local/state.
"""
from __future__ import annotations

import hashlib
import json

import pytest

from axi import app_updates


# ─────────────────────────── updates-dir resolution ─────────────────────────


def test_updates_dir_default_under_xdg_state(monkeypatch, tmp_path):
    monkeypatch.delenv("LIFEOS_APP_UPDATES_DIR", raising=False)
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    assert app_updates.resolve_updates_dir() == tmp_path / "axi" / "app-updates"


def test_updates_dir_env_override_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("LIFEOS_APP_UPDATES_DIR", str(tmp_path / "custom"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "ignored"))
    assert app_updates.resolve_updates_dir() == tmp_path / "custom"


def test_updates_dir_explicit_arg_wins_over_env(monkeypatch, tmp_path):
    monkeypatch.setenv("LIFEOS_APP_UPDATES_DIR", str(tmp_path / "env"))
    assert app_updates.resolve_updates_dir(tmp_path / "explicit") == tmp_path / "explicit"


# ─────────────────────────────── publish_apk ────────────────────────────────


def _fake_extractor(version_code=42, version_name="1.2.3"):
    def _extract(_apk_path):
        return version_code, version_name
    return _extract


def test_publish_extracts_version_computes_hash_and_copies(tmp_path):
    apk = tmp_path / "app-release.apk"
    payload = b"PK\x03\x04 fake-apk-bytes"
    apk.write_bytes(payload)
    updates = tmp_path / "updates"

    manifest = app_updates.publish_apk(
        apk,
        notes="first drop",
        updates_dir=updates,
        extractor=_fake_extractor(7, "0.9.0"),
    )

    assert manifest["versionCode"] == 7
    assert manifest["versionName"] == "0.9.0"
    assert manifest["apkFilename"] == "lifeos-0.9.0-7.apk"
    assert manifest["sha256"] == hashlib.sha256(payload).hexdigest()
    assert manifest["sizeBytes"] == len(payload)
    assert manifest["notes"] == "first drop"
    assert manifest["publishedAt"]  # ISO timestamp present

    # APK copied under the stable name; bytes identical to the source.
    copied = updates / "lifeos-0.9.0-7.apk"
    assert copied.is_file()
    assert copied.read_bytes() == payload


def test_publish_writes_manifest_that_round_trips(tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"abc")
    updates = tmp_path / "updates"

    manifest = app_updates.publish_apk(
        apk, updates_dir=updates, extractor=_fake_extractor()
    )

    on_disk = json.loads((updates / "manifest.json").read_text())
    assert on_disk == manifest
    # load_manifest reads back exactly what publish wrote.
    assert app_updates.load_manifest(updates) == manifest


def test_publish_missing_apk_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        app_updates.publish_apk(
            tmp_path / "nope.apk",
            updates_dir=tmp_path / "updates",
            extractor=_fake_extractor(),
        )


def test_publish_defaults_notes_to_empty(tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    manifest = app_updates.publish_apk(
        apk, updates_dir=tmp_path / "u", extractor=_fake_extractor()
    )
    assert manifest["notes"] == ""


def test_publish_is_idempotent_and_keeps_prior_apks(tmp_path):
    updates = tmp_path / "updates"
    apk1 = tmp_path / "v1.apk"
    apk1.write_bytes(b"one")
    apk2 = tmp_path / "v2.apk"
    apk2.write_bytes(b"two")

    app_updates.publish_apk(apk1, updates_dir=updates, extractor=_fake_extractor(1, "1.0.0"))
    manifest2 = app_updates.publish_apk(apk2, updates_dir=updates, extractor=_fake_extractor(2, "2.0.0"))

    # Prior APK kept; manifest points at the newest.
    assert (updates / "lifeos-1.0.0-1.apk").is_file()
    assert (updates / "lifeos-2.0.0-2.apk").is_file()
    assert app_updates.load_manifest(updates) == manifest2
    assert manifest2["apkFilename"] == "lifeos-2.0.0-2.apk"


def test_publish_republish_same_version_overwrites_cleanly(tmp_path):
    updates = tmp_path / "updates"
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"first")
    app_updates.publish_apk(apk, updates_dir=updates, extractor=_fake_extractor(5, "1.1.0"))
    apk.write_bytes(b"second-build-same-version")
    manifest = app_updates.publish_apk(apk, updates_dir=updates, extractor=_fake_extractor(5, "1.1.0"))

    copied = updates / "lifeos-1.1.0-5.apk"
    assert copied.read_bytes() == b"second-build-same-version"
    assert manifest["sha256"] == hashlib.sha256(b"second-build-same-version").hexdigest()


def test_publish_sanitizes_version_name_in_filename(tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"x")
    # A malicious/odd versionName must not escape the updates dir.
    manifest = app_updates.publish_apk(
        apk, updates_dir=tmp_path / "u", extractor=_fake_extractor(9, "../../evil")
    )
    assert "/" not in manifest["apkFilename"]
    assert manifest["apkFilename"].endswith("-9.apk")


# ───────────────────────────── load_manifest ────────────────────────────────


def test_load_manifest_none_when_missing(tmp_path):
    assert app_updates.load_manifest(tmp_path / "empty") is None


def test_load_manifest_none_on_corrupt_json(tmp_path):
    updates = tmp_path / "u"
    updates.mkdir()
    (updates / "manifest.json").write_text("{not valid json")
    assert app_updates.load_manifest(updates) is None


# ─────────────────────────── resolve_apk_path (path-safety) ─────────────────


def test_resolve_apk_path_returns_file_inside_dir(tmp_path):
    updates = tmp_path / "u"
    updates.mkdir()
    apk = updates / "lifeos-1.0.0-1.apk"
    apk.write_bytes(b"x")
    resolved = app_updates.resolve_apk_path("lifeos-1.0.0-1.apk", updates)
    assert resolved == apk.resolve()


def test_resolve_apk_path_rejects_escape(tmp_path):
    updates = tmp_path / "u"
    updates.mkdir()
    (tmp_path / "secret.txt").write_bytes(b"top secret")
    assert app_updates.resolve_apk_path("../secret.txt", updates) is None


def test_resolve_apk_path_none_when_missing(tmp_path):
    updates = tmp_path / "u"
    updates.mkdir()
    assert app_updates.resolve_apk_path("nope.apk", updates) is None


# ─────────────────────────── aapt badging parser ───────────────────────────


def test_parse_badging_extracts_code_and_name():
    sample = (
        "package: name='com.lifeos.axi' versionCode='31' "
        "versionName='1.4.0' platformBuildVersionName='14'\n"
        "application-label:'Axi'\n"
    )
    assert app_updates._parse_badging(sample) == (31, "1.4.0")


def test_parse_badging_raises_on_unparseable():
    with pytest.raises(ValueError):
        app_updates._parse_badging("no version info here")
