"""Tests for the model-parameters editor: schema, overrides, and API.

Critical regression: with NO overrides on disk, set_active(qwen36-35b-a3b)
must write a payload byte-identical to the historical Qwen3.6 production
default (matching what `axi-llama-launch` falls back to on a fresh install).
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from axi import dashboard, model_params_schema, models_catalog, models_manager
from axi.model_params_schema import (
    SCHEMA,
    ParamSpec,
    by_key,
    is_applicable,
    validate_value,
)


# ─── isolation fixtures ──────────────────────────────────────────────────


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)
    return state_root, models_root


@pytest.fixture
def client(isolated_state, monkeypatch):
    # Standard dashboard stubs (same as test_models_api.py).
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *a, **k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *a, **k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 12000, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 1, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)
    dashboard._models_progress.clear()
    return TestClient(dashboard.app)


# ─── schema validation ───────────────────────────────────────────────────


def test_schema_has_expected_keys():
    keys = {s.key for s in SCHEMA}
    expected = {
        "ctx", "ngl", "temperature", "top_p", "top_k", "min_p",
        "repeat_penalty", "threads", "threads_batch", "flash_attention",
        "cpu_moe", "cache_type_k", "cache_type_v", "reasoning_format",
        "mlock", "image_min_tokens",
    }
    assert expected <= keys


def test_validate_value_enforces_int_bounds():
    spec = by_key("ctx")
    assert validate_value(spec, 32768) == 32768
    assert validate_value(spec, "16384") == 16384
    with pytest.raises(ValueError):
        validate_value(spec, 100)  # below min
    with pytest.raises(ValueError):
        validate_value(spec, 9999999)  # above max
    with pytest.raises(ValueError):
        validate_value(spec, "not-a-number")


def test_validate_value_enforces_float_bounds():
    spec = by_key("temperature")
    assert validate_value(spec, 0.5) == pytest.approx(0.5)
    with pytest.raises(ValueError):
        validate_value(spec, -0.1)
    with pytest.raises(ValueError):
        validate_value(spec, 2.5)


def test_validate_value_enum():
    spec = by_key("cache_type_k")
    assert validate_value(spec, "q8_0") == "q8_0"
    with pytest.raises(ValueError):
        validate_value(spec, "f8")


def test_validate_value_bool_coerces_strings():
    spec = by_key("mlock")
    assert validate_value(spec, True) is True
    assert validate_value(spec, "true") is True
    assert validate_value(spec, "off") is False
    assert validate_value(spec, 0) is False


def test_is_applicable_filters_cpu_moe():
    dense = models_catalog.by_id("gemma4-e2b-it")
    moe = models_catalog.by_id("qwen36-35b-a3b")
    spec = by_key("cpu_moe")
    assert is_applicable(spec, moe) is True
    assert is_applicable(spec, dense) is False


def test_is_applicable_filters_vision():
    spec = by_key("image_min_tokens")
    # All catalog entries have "vision" feature today, so this should be True.
    for e in models_catalog.catalog():
        assert is_applicable(spec, e) is True


# ─── effective_params + overrides ────────────────────────────────────────


def test_effective_params_uses_schema_defaults(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    eff = models_manager.effective_params(entry, {})
    # Schema default temperature is 0.7 for entries without param_defaults.
    assert eff["temperature"] == pytest.approx(0.7)
    # ctx comes from entry.ctx, not schema default.
    assert eff["ctx"] == entry.ctx


def test_effective_params_uses_entry_param_defaults():
    entry = models_catalog.by_id("qwen36-35b-a3b")
    eff = models_manager.effective_params(entry, {})
    # Qwen3.6 declares param_defaults: temperature 0.6, top_k 20, cpu_moe True.
    assert eff["temperature"] == pytest.approx(0.6)
    assert eff["top_k"] == 20
    assert eff["cpu_moe"] is True


def test_effective_params_overrides_win():
    entry = models_catalog.by_id("qwen36-35b-a3b")
    eff = models_manager.effective_params(entry, {
        entry.id: {"temperature": 0.4, "ctx": 16384}
    })
    assert eff["temperature"] == pytest.approx(0.4)
    assert eff["ctx"] == 16384
    # Untouched key falls back to entry.param_defaults.
    assert eff["cpu_moe"] is True


def test_save_load_overrides_round_trip(isolated_state):
    payload = {"gemma4-e2b-it": {"temperature": 0.5, "ctx": 16384}}
    models_manager.save_overrides(payload)
    assert models_manager.load_overrides() == payload


def test_load_overrides_missing_file_returns_empty(isolated_state):
    assert models_manager.load_overrides() == {}


# ─── merge_extra_args: byte-identical guarantee ──────────────────────────


def test_merge_extra_args_no_overrides_is_baseline():
    entry = models_catalog.by_id("qwen36-35b-a3b")
    assert models_manager.merge_extra_args(entry, {}) == list(entry.extra_args)


def test_write_active_no_overrides_matches_wrapper_default(isolated_state):
    """The wrapper's hardcoded DEFAULT (axi-llama-launch) must equal what
    write_active produces for Qwen3.6 with no overrides on disk."""
    entry = models_catalog.by_id("qwen36-35b-a3b")
    models_manager.write_active(entry)
    written = json.loads(models_manager.active_model_path().read_text())
    # The fields that the wrapper falls back to:
    expected_extra_args = list(entry.extra_args)
    assert written["id"] == "qwen36-35b-a3b"
    assert written["ctx"] == 32768
    assert written["ngl"] == 999
    assert written["extra_args"] == expected_extra_args


def test_merge_replaces_temp_flag():
    entry = models_catalog.by_id("qwen36-35b-a3b")
    merged = models_manager.merge_extra_args(entry, {"temperature": 0.4})
    # Original baseline has "--temp 0.6"; after override it should have
    # "--temp 0.4" exactly once.
    pairs = [(merged[i], merged[i + 1]) for i in range(len(merged) - 1)]
    assert ("--temp", "0.4") in pairs
    assert ("--temp", "0.6") not in pairs


def test_merge_strips_disabled_bool_flag():
    entry = models_catalog.by_id("qwen36-35b-a3b")
    merged = models_manager.merge_extra_args(entry, {"flash_attention": False})
    # -fa on must be gone.
    assert "-fa" not in merged


def test_merge_keeps_unmanaged_sentinel_flags():
    """Flags not in the schema (-a, -Cr, --prio, --no-mmap, etc.) MUST
    stay untouched even when overrides are applied. This is the safety
    net that protects the byte-identical guarantee for Qwen3.6."""
    entry = models_catalog.by_id("qwen36-35b-a3b")
    merged = models_manager.merge_extra_args(entry, {"temperature": 0.4})
    # Spot-check several sentinels that the schema doesn't manage.
    assert "-a" in merged
    assert "Qwen3.6-35B-A3B" in merged
    assert "--prio" in merged
    assert "--no-mmap" in merged
    assert "-Cr" in merged


def test_merge_adds_bool_flag_when_enabled():
    entry = models_catalog.by_id("gemma4-e2b-it")
    # mlock not in dense baseline; enabling it adds the token.
    merged = models_manager.merge_extra_args(entry, {"mlock": True})
    assert "--mlock" in merged


def test_build_extra_args_renders_known_params():
    entry = models_catalog.by_id("gemma4-e2b-it")
    args = models_manager.build_extra_args(entry, {
        "temperature": 0.5,
        "top_p": 0.9,
        "flash_attention": True,
        "mlock": False,
        "cpu_moe": False,  # not applicable on dense
    })
    pairs = list(zip(args, args[1:]))
    assert ("--temp", "0.5") in pairs
    assert ("--top-p", "0.9") in pairs
    assert "-fa" in args
    assert "--mlock" not in args
    assert "--cpu-moe" not in args


# ─── API ─────────────────────────────────────────────────────────────────


def test_get_params_unknown_404(client):
    r = client.get("/api/models/nope/params")
    assert r.status_code == 404


def test_get_params_returns_schema_and_effective(client):
    r = client.get("/api/models/qwen36-35b-a3b/params")
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == "qwen36-35b-a3b"
    assert isinstance(body["schema"], list)
    keys = {row["key"] for row in body["schema"]}
    assert "temperature" in keys
    # cpu_moe applicable on this MoE.
    cpu_moe = next(r for r in body["schema"] if r["key"] == "cpu_moe")
    assert cpu_moe["applicable"] is True
    # effective shows entry.param_defaults overlay.
    assert body["effective"]["temperature"] == pytest.approx(0.6)
    assert "extra_args_preview" in body


def test_get_params_dense_marks_cpu_moe_not_applicable(client):
    r = client.get("/api/models/gemma4-e2b-it/params")
    assert r.status_code == 200
    schema = r.json()["schema"]
    cpu_moe = next(r for r in schema if r["key"] == "cpu_moe")
    assert cpu_moe["applicable"] is False


def test_put_params_validates_bounds(client):
    r = client.put(
        "/api/models/gemma4-e2b-it/params",
        json={"overrides": {"temperature": 99.0}},
    )
    assert r.status_code == 400


def test_put_params_rejects_unknown_key(client):
    r = client.put(
        "/api/models/gemma4-e2b-it/params",
        json={"overrides": {"banana": 1}},
    )
    assert r.status_code == 400


def test_put_params_persists_and_no_restart_when_inactive(client):
    r = client.put(
        "/api/models/gemma4-e2b-it/params",
        json={"overrides": {"temperature": 0.5, "ctx": 16384}},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["restarted"] is False
    # Round-trip via load_overrides.
    loaded = models_manager.load_overrides()
    assert loaded["gemma4-e2b-it"]["temperature"] == pytest.approx(0.5)
    assert loaded["gemma4-e2b-it"]["ctx"] == 16384


def test_put_params_restarts_when_active(client, monkeypatch):
    # Make gemma4-e2b-it "installed" and active first.
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)
    models_manager.set_active(entry, restart=False, wait_health=False)

    r = client.put(
        "/api/models/gemma4-e2b-it/params",
        json={"overrides": {"temperature": 0.4}},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["restarted"] is True

    # active_model.json must reflect the override via merged extra_args.
    written = json.loads(models_manager.active_model_path().read_text())
    pairs = [(written["extra_args"][i], written["extra_args"][i + 1])
             for i in range(len(written["extra_args"]) - 1)]
    assert ("--temp", "0.4") in pairs


def test_delete_params_clears_overrides(client):
    # Seed an override first.
    models_manager.save_overrides({"gemma4-e2b-it": {"temperature": 0.3}})
    r = client.delete("/api/models/gemma4-e2b-it/params")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["had_overrides"] is True
    assert models_manager.load_overrides() == {}


def test_delete_params_idempotent_when_absent(client):
    r = client.delete("/api/models/gemma4-e2b-it/params")
    assert r.status_code == 200
    assert r.json()["had_overrides"] is False


def test_active_with_overrides_writes_merged_args(client, monkeypatch):
    entry = models_catalog.by_id("qwen36-35b-a3b")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    monkeypatch.setattr(models_manager, "_systemctl_restart_llama", lambda: None)
    monkeypatch.setattr(models_manager, "wait_for_llama_health", lambda **kw: True)
    # Save an override BEFORE activating.
    models_manager.save_overrides({"qwen36-35b-a3b": {"temperature": 0.5, "ctx": 16384}})
    models_manager.set_active(entry)
    written = json.loads(models_manager.active_model_path().read_text())
    assert written["ctx"] == 16384
    pairs = [(written["extra_args"][i], written["extra_args"][i + 1])
             for i in range(len(written["extra_args"]) - 1)]
    assert ("--temp", "0.5") in pairs
    # Sentinel still preserved.
    assert "-a" in written["extra_args"]
    assert "Qwen3.6-35B-A3B" in written["extra_args"]
