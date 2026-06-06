"""Tests for axi.hardware_profile — hardware detection + automatic, tier-based
model selection for a fresh install.

All tests run offline and deterministic: detection is fully monkeypatched, so
no real nvidia-smi / /proc/meminfo access happens here. The selection logic is
pure and asserts the recommended model id + tuned llama-server params per tier.

The 12 GB VRAM tier is the empirically PROVEN anchor (the config Hector runs
today on a 12 GB RTX 5070 Ti). Every other tier is DERIVED from catalog VRAM
estimates + llama.cpp budget math and is marked as such in the module.
"""
from __future__ import annotations

import pytest

from axi import hardware_profile as hp
from axi import models_catalog


# ────────────────────────── detection ──────────────────────────────


def test_detect_hardware_parses_nvidia_and_meminfo(monkeypatch):
    """detect_hardware() must combine VRAM (nvidia-smi) + RAM (/proc/meminfo)."""
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: (12227, "NVIDIA GeForce RTX 5070 Ti"))
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: 98567848)

    prof = hp.detect_hardware()

    assert prof.has_nvidia is True
    assert prof.gpu_name == "NVIDIA GeForce RTX 5070 Ti"
    # 12227 MiB → ~11.9 GiB
    assert 11.5 < prof.vram_gb < 12.5
    # 98567848 KiB → ~94 GiB
    assert 90 < prof.ram_gb < 96
    assert prof.compute_kind == "cuda"


def test_detect_hardware_no_gpu_falls_back_to_ram(monkeypatch):
    """No NVIDIA GPU → compute_kind is 'cpu' and vram_gb is 0."""
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: None)
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: 16 * 1024 * 1024)

    prof = hp.detect_hardware()

    assert prof.has_nvidia is False
    assert prof.vram_gb == 0.0
    assert prof.compute_kind == "cpu"
    assert 15 < prof.ram_gb < 17


def test_detect_hardware_zero_vram_treated_as_cpu(monkeypatch):
    """A GPU that reports 0 (or near-0) usable VRAM falls back to CPU."""
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: (0, "weird"))
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: 32 * 1024 * 1024)

    prof = hp.detect_hardware()

    assert prof.compute_kind == "cpu"


def test_query_nvidia_vram_handles_missing_binary(monkeypatch):
    """_query_nvidia_vram_mib returns None when nvidia-smi is absent."""
    monkeypatch.setattr(hp.shutil, "which", lambda _b: None)
    assert hp._query_nvidia_vram_mib() is None


# ────────────────────────── tier table integrity ──────────────────


def test_every_tier_references_a_real_catalog_model():
    catalog_ids = {e.id for e in models_catalog.catalog()}
    for tier in hp.HARDWARE_TIERS:
        assert tier.model_id in catalog_ids, f"tier {tier!r} -> unknown model"


def test_tiers_sorted_descending_per_compute_kind():
    """Within each compute_kind, tiers must be ordered high→low budget so the
    'first tier that fits' scan is correct."""
    for kind in ("cuda", "cpu"):
        budgets = [t.min_budget_gb for t in hp.HARDWARE_TIERS if t.compute_kind == kind]
        assert budgets == sorted(budgets, reverse=True), kind


def test_tier_params_are_consumable_overrides():
    """Each tier's params must only use keys the model_params schema knows
    (plus ctx/ngl), so install can write them straight into overrides."""
    from axi import model_params_schema as mps

    known = {s.key for s in mps.SCHEMA}
    for tier in hp.HARDWARE_TIERS:
        for key in tier.params:
            assert key in known, f"tier {tier.label}: unknown param {key!r}"


# ────────────────────────── selection: VRAM tiers ─────────────────


def _cuda_profile(vram_gb: float, ram_gb: float = 64.0):
    return hp.HardwareProfile(
        has_nvidia=True,
        gpu_name="test-gpu",
        vram_gb=vram_gb,
        ram_gb=ram_gb,
        compute_kind="cuda",
    )


def _cpu_profile(ram_gb: float):
    return hp.HardwareProfile(
        has_nvidia=False,
        gpu_name="",
        vram_gb=0.0,
        ram_gb=ram_gb,
        compute_kind="cpu",
    )


def test_select_12gb_returns_proven_qwen36_moe_config():
    """The PROVEN anchor: 12 GB → qwen36-35b-a3b with cpu-moe, full ngl, 32k ctx."""
    model_id, params = hp.select_model(_cuda_profile(11.9))
    assert model_id == "qwen36-35b-a3b"
    assert params["ngl"] == 999
    assert params["ctx"] == 32768
    assert params["cpu_moe"] is True


def test_select_24gb_returns_big_brain_with_headroom():
    model_id, params = hp.select_model(_cuda_profile(24.0))
    assert model_id == "qwen36-35b-a3b"
    # More VRAM → we can afford a larger context window.
    assert params["ctx"] >= 32768


def test_select_8gb_uses_moe_offload():
    """8 GB still runs the MoE brain via --cpu-moe (attention+KV fit in 8 GB)."""
    model_id, params = hp.select_model(_cuda_profile(8.0))
    assert model_id == "qwen36-35b-a3b"
    assert params["cpu_moe"] is True


def test_select_6gb_returns_gemma4_e4b():
    """6 GB tier: Gemma 4 E4B fits (≈5.5 GB budget) and adds vision over qwen35-9b."""
    model_id, params = hp.select_model(_cuda_profile(6.0))
    assert model_id == "gemma4-e4b-it"
    assert params["ngl"] == 999
    assert params.get("cpu_moe", False) is False


def test_select_4gb_returns_gemma4_e2b():
    """4 GB tier: Gemma 4 E2B Q4_K_M ≈ 2.8 GB — fits with headroom, adds vision."""
    model_id, params = hp.select_model(_cuda_profile(4.0))
    assert model_id == "gemma4-e2b-it"
    assert params["ngl"] == 999


def test_select_between_tiers_picks_lower_fitting_tier():
    """5 GB is below the 6 GB tier → must fall back to the 4 GB (gemma4-e2b-it) tier."""
    model_id, _ = hp.select_model(_cuda_profile(5.0))
    assert model_id == "gemma4-e2b-it"


def test_select_tiny_vram_falls_back_to_gemma4_e2b():
    """2 GB GPU: Gemma 4 E2B Q4_K_M ≈ 2.8 GB — floor model, multimodal, fits tight VRAM."""
    model_id, params = hp.select_model(_cuda_profile(2.0))
    assert model_id == "gemma4-e2b-it"
    assert params["ngl"] == 999


# ────────────────────────── selection: CPU/RAM tiers ─────────────


def test_select_cpu_high_ram_runs_moe_brain_on_cpu():
    """No GPU but lots of RAM → run the MoE brain fully on CPU (ngl=0)."""
    model_id, params = hp.select_model(_cpu_profile(32.0))
    assert model_id == "qwen36-35b-a3b"
    assert params["ngl"] == 0
    assert params["cpu_moe"] is True


def test_select_cpu_mid_ram_runs_gemma4_e4b():
    """CPU 12 GB: Gemma 4 E4B ≈ 4.5 GB RAM — better quality + vision vs qwen35-4b."""
    model_id, params = hp.select_model(_cpu_profile(16.0))
    assert model_id == "gemma4-e4b-it"
    assert params["ngl"] == 0


def test_select_cpu_low_ram_runs_gemma4_e2b():
    """CPU constrained floor: Gemma 4 E2B ≈ 2.8 GB — multimodal, beats qwen35-0_8b."""
    model_id, params = hp.select_model(_cpu_profile(8.0))
    assert model_id == "gemma4-e2b-it"
    assert params["ngl"] == 0


def test_select_cpu_tiny_ram_still_returns_gemma4_e2b():
    """Even with very little RAM we return the smallest model (gemma4-e2b-it), never None."""
    model_id, params = hp.select_model(_cpu_profile(2.0))
    assert model_id == "gemma4-e2b-it"
    assert params["ngl"] == 0


# ────────────────────────── Gemma 4 catalog presence ────────────


def test_gemma4_e2b_in_catalog():
    """gemma4-e2b-it must be resolvable from the catalog."""
    entry = models_catalog.by_id("gemma4-e2b-it")
    assert entry is not None
    assert entry.gguf_file.repo_id != ""
    assert entry.gguf_file.filename.endswith(".gguf")
    assert entry.mmproj_file is not None


def test_gemma4_e4b_in_catalog():
    """gemma4-e4b-it must be resolvable from the catalog."""
    entry = models_catalog.by_id("gemma4-e4b-it")
    assert entry is not None
    assert entry.gguf_file.repo_id != ""
    assert entry.gguf_file.filename.endswith(".gguf")
    assert entry.mmproj_file is not None


def test_gemma4_e2b_has_vision_feature():
    entry = models_catalog.by_id("gemma4-e2b-it")
    assert "vision" in entry.features


def test_gemma4_e4b_has_vision_feature():
    entry = models_catalog.by_id("gemma4-e4b-it")
    assert "vision" in entry.features


# ────────────────────────── select_model contract ────────────────


def test_select_model_always_returns_known_model():
    catalog_ids = {e.id for e in models_catalog.catalog()}
    for prof in (
        _cuda_profile(24), _cuda_profile(12), _cuda_profile(8),
        _cuda_profile(6), _cuda_profile(4), _cuda_profile(1),
        _cpu_profile(64), _cpu_profile(16), _cpu_profile(8), _cpu_profile(1),
    ):
        model_id, params = hp.select_model(prof)
        assert model_id in catalog_ids
        assert isinstance(params, dict)
        assert "ngl" in params and "ctx" in params


def test_recommend_returns_profile_model_and_tier(monkeypatch):
    """recommend() is the install entry point: detect + select in one call."""
    monkeypatch.setattr(hp, "_query_nvidia_vram_mib", lambda: (12227, "RTX 5070 Ti"))
    monkeypatch.setattr(hp, "_query_system_ram_kib", lambda: 98567848)

    rec = hp.recommend()

    assert rec.profile.compute_kind == "cuda"
    assert rec.model_id == "qwen36-35b-a3b"
    assert rec.params["cpu_moe"] is True
    assert rec.tier.label  # a human-readable tier label for the installer UI
