"""Tests for axi.install_nano — installer glue for the nano model."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from axi import install_nano, nano_catalog, nano_manager


@pytest.fixture()
def isolated_nano(tmp_path, monkeypatch):
    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(nano_manager, "nano_models_dir", lambda: models_root)
    return state_root, models_root


# ──────────────────── resolve_nano_entry ─────────────────────────────


def test_resolve_nano_entry_default_is_qwen35_0_8b(monkeypatch):
    monkeypatch.delenv("AXI_NANO_MODEL", raising=False)
    entry = install_nano.resolve_nano_entry()
    assert entry.id == "qwen35-0_8b"


def test_resolve_nano_entry_honors_override(monkeypatch):
    monkeypatch.setenv("AXI_NANO_MODEL", "granite-4.0-h-1b")
    entry = install_nano.resolve_nano_entry()
    assert entry.id == "granite-4.0-h-1b"


def test_resolve_nano_entry_ignores_unknown_override(monkeypatch):
    monkeypatch.setenv("AXI_NANO_MODEL", "totally-unknown-model")
    entry = install_nano.resolve_nano_entry()
    assert entry.id == "qwen35-0_8b"


# ──────────────────── download_plan ─────────────────────────────────


def test_download_plan_qwen35_0_8b(isolated_nano):
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    plan = install_nano.download_plan(entry)
    assert plan["model_id"] == "qwen35-0_8b"
    assert len(plan["files"]) == 2
    kinds = {f["kind"] for f in plan["files"]}
    assert "gguf" in kinds
    assert "mmproj" in kinds


def test_download_plan_granite_single_file(isolated_nano):
    entry = nano_catalog.by_id("granite-4.0-h-1b")
    assert entry is not None
    plan = install_nano.download_plan(entry)
    assert plan["model_id"] == "granite-4.0-h-1b"
    assert len(plan["files"]) == 1
    assert plan["files"][0]["kind"] == "gguf"


# ──────────────────── write_nano_config ──────────────────────────────


def test_write_nano_config_creates_json(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    # Plant dummy files so nano_manager can resolve paths.
    dest = models_root / entry.id
    dest.mkdir(parents=True)
    for f in entry.files:
        (dest / f.local_name).write_bytes(b"x")

    install_nano.write_nano_config(entry, restart=False)
    p = nano_manager.active_nano_model_path()
    assert p.exists()
    data = json.loads(p.read_text())
    assert data["id"] == "qwen35-0_8b"
    assert data["port"] == 8090


# ──────────────────── format_report ──────────────────────────────────


def test_format_report_contains_model_id(monkeypatch):
    monkeypatch.delenv("AXI_NANO_MODEL", raising=False)
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    report = install_nano.format_report(entry)
    assert "qwen35-0_8b" in report
    assert "8090" in report


# ──────────────────── CLI ────────────────────────────────────────────


def test_cli_report(monkeypatch, capsys):
    monkeypatch.delenv("AXI_NANO_MODEL", raising=False)
    rc = install_nano.main(["--report"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "qwen35-0_8b" in out


def test_cli_json(monkeypatch, capsys):
    monkeypatch.delenv("AXI_NANO_MODEL", raising=False)
    rc = install_nano.main(["--json"])
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    assert data["model_id"] == "qwen35-0_8b"
    assert isinstance(data["files"], list)
