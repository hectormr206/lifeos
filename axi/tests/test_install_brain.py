"""Tests for axi.install_brain — the installer-facing glue that turns a
hardware recommendation into (a) a printable detection report, (b) the set of
files to download, and (c) the active_model.json + overrides the launcher
reads.

Fully offline: no HF traffic, no systemctl, detection monkeypatched.
"""
from __future__ import annotations

import json

import pytest

from axi import install_brain, models_manager, hardware_profile as hp


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)
    return state_root, models_root


def _cuda_12gb(monkeypatch):
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: (12227, "RTX 5070 Ti"))
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: 98567848)


def _cpu_only(monkeypatch, ram_kib):
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: None)
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: ram_kib)


# ────────────────────────── detection report ─────────────────────


def test_report_mentions_detected_hardware_and_choice(monkeypatch):
    _cuda_12gb(monkeypatch)
    rec = hp.recommend()
    text = install_brain.format_report(rec)
    assert "RTX 5070 Ti" in text
    assert "qwen36-35b-a3b" in text or "Qwen3.6" in text
    # The proven 12 GB tier label should surface.
    assert "12 GB" in text


def test_report_cpu_machine_explains_cpu_fallback(monkeypatch):
    _cpu_only(monkeypatch, 32 * 1024 * 1024)
    rec = hp.recommend()
    text = install_brain.format_report(rec)
    assert "CPU" in text


# ────────────────────────── override resolution ──────────────────


def test_recommended_overrides_round_trip_through_manager(monkeypatch, isolated_state):
    """The tuned params must be writable as overrides and produce a coherent
    active_model.json the launcher can read."""
    _cuda_12gb(monkeypatch)
    rec = hp.recommend()

    # Persist the recommended overrides + activate (no download, no restart).
    install_brain.write_recommended_config(rec, restart=False)

    overrides = models_manager.load_overrides()
    assert rec.model_id in overrides
    # ctx/ngl land in the override for the model.
    assert overrides[rec.model_id]["ngl"] == rec.params["ngl"]

    active = models_manager.read_active()
    assert active is not None
    assert active["id"] == rec.model_id
    assert active["ngl"] == rec.params["ngl"]
    assert active["ctx"] == rec.params["ctx"]


def test_cpu_config_sets_ngl_zero_in_active(monkeypatch, isolated_state):
    _cpu_only(monkeypatch, 64 * 1024 * 1024)
    rec = hp.recommend()
    assert rec.params["ngl"] == 0

    install_brain.write_recommended_config(rec, restart=False)
    active = models_manager.read_active()
    assert active["ngl"] == 0


# ────────────────────────── download plan ────────────────────────


def test_download_plan_lists_recommended_entry_files(monkeypatch):
    _cuda_12gb(monkeypatch)
    rec = hp.recommend()
    plan = install_brain.download_plan(rec)
    # The plan names the catalog entry and its repo files (or flags legacy/local).
    assert plan["model_id"] == rec.model_id
    assert "files" in plan
    assert isinstance(plan["files"], list)


def test_download_plan_for_downloadable_model_has_repo_ids(monkeypatch):
    """A non-legacy recommendation (CPU mid-RAM → gemma4-e2b-it) yields real HF
    repo ids the installer's hf_get can pull."""
    _cpu_only(monkeypatch, 16 * 1024 * 1024)
    rec = hp.recommend()
    assert rec.model_id == "gemma4-e2b-it"
    plan = install_brain.download_plan(rec)
    assert all(f["repo_id"] != "local" for f in plan["files"])
    assert any(f["filename"].endswith(".gguf") for f in plan["files"])


# ────────────────────────── CLI (--report / --json) ──────────────


def test_cli_report_prints_and_exits_zero(monkeypatch, capsys):
    _cuda_12gb(monkeypatch)
    rc = install_brain.main(["--report"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "qwen36-35b-a3b" in out or "Qwen3.6" in out


def test_env_override_forces_specific_model(monkeypatch):
    """AXI_BRAIN_MODEL overrides hardware detection so an advanced user can
    pin any catalog model — but the tier still supplies sane tuned params."""
    _cuda_12gb(monkeypatch)
    monkeypatch.setenv("AXI_BRAIN_MODEL", "gemma4-e2b-it")
    rec = install_brain.resolve_recommendation()
    assert rec.model_id == "gemma4-e2b-it"
    # params are still a coherent dict (ngl/ctx present).
    assert rec.params["ngl"] == 999


def test_env_override_unknown_model_is_ignored(monkeypatch):
    _cuda_12gb(monkeypatch)
    monkeypatch.setenv("AXI_BRAIN_MODEL", "no-such-model")
    rec = install_brain.resolve_recommendation()
    # Falls back to hardware detection.
    assert rec.model_id == "qwen36-35b-a3b"


def test_cli_json_emits_machine_readable_recommendation(monkeypatch, capsys):
    _cuda_12gb(monkeypatch)
    rc = install_brain.main(["--json"])
    out = capsys.readouterr().out
    assert rc == 0
    data = json.loads(out)
    assert data["model_id"] == "qwen36-35b-a3b"
    assert data["compute_kind"] == "cuda"
    assert data["params"]["ngl"] == 999
    assert "files" in data


# ────────────────────────── Gemma 4 forced-override plan ────────


def test_forced_gemma4_e2b_produces_valid_download_plan(monkeypatch):
    """AXI_BRAIN_MODEL=gemma4-e2b-it must resolve to real HF repo ids."""
    _cuda_12gb(monkeypatch)
    monkeypatch.setenv("AXI_BRAIN_MODEL", "gemma4-e2b-it")
    rec = install_brain.resolve_recommendation()
    assert rec.model_id == "gemma4-e2b-it"
    plan = install_brain.download_plan(rec)
    assert plan["model_id"] == "gemma4-e2b-it"
    assert plan["local"] is False
    assert any(f["filename"].endswith(".gguf") and f["kind"] == "gguf" for f in plan["files"])
    # mmproj must be present (vision model)
    assert any(f["kind"] == "mmproj" for f in plan["files"])
    # repos must not be placeholder values
    for f in plan["files"]:
        assert f["repo_id"] not in ("", "local")


def test_forced_unknown_model_falls_back_to_hardware(monkeypatch):
    """AXI_BRAIN_MODEL=gemma4-e4b-it (cut model) falls back to hardware detection."""
    _cuda_12gb(monkeypatch)
    monkeypatch.setenv("AXI_BRAIN_MODEL", "gemma4-e4b-it")
    rec = install_brain.resolve_recommendation()
    # e4b is no longer in catalog — env override is ignored, hardware wins.
    assert rec.model_id == "qwen36-35b-a3b"
