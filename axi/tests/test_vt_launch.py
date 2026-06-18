"""Smoke tests for axi-vt-launch via AXI_DRY_RUN=1.

Mirrors test_nano_launch.py but for the VibeThinker-3B reasoning sibling
(port 8082, GPU-resident, no CUDA_VISIBLE_DEVICES override).
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

LAUNCHER = Path(__file__).parent.parent / "scripts" / "axi-vt-launch"


@pytest.fixture()
def isolated_vt_env(tmp_path):
    """Provide a temp XDG_STATE_HOME and AXI_DRY_RUN=1 env for subprocess calls."""
    state_root = tmp_path / "state"
    state_root.mkdir()
    env = os.environ.copy()
    env["XDG_STATE_HOME"] = str(state_root)
    env["AXI_DRY_RUN"] = "1"
    return env, state_root


def _run_launcher(env: dict) -> str:
    result = subprocess.run(
        ["/usr/bin/bash", str(LAUNCHER)],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


# ── Mandatory argv assertions per VRAM measurement #565 ──────────────────────


def test_vt_launcher_emits_correct_port(isolated_vt_env):
    """VT launcher must start llama-server on port 8082."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--port" in cmd
    assert "8082" in cmd


def test_vt_launcher_emits_correct_ctx(isolated_vt_env):
    """VT launcher must pass -c 61440 (60K context per VRAM measurement #565)."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "-c 61440" in cmd


def test_vt_launcher_emits_ngl_999(isolated_vt_env):
    """VT launcher must pass -ngl 999 (full GPU offload)."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "-ngl 999" in cmd


def test_vt_launcher_emits_np1(isolated_vt_env):
    """-np 1 is MANDATORY: n_parallel=4 default would 4x the KV cache → OOM."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "-np 1" in cmd


def test_vt_launcher_emits_cache_type_k_q8(isolated_vt_env):
    """--cache-type-k q8_0 is required for the 60K/60K VRAM budget."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--cache-type-k q8_0" in cmd


def test_vt_launcher_emits_cache_type_v_q8(isolated_vt_env):
    """--cache-type-v q8_0 is required for the 60K/60K VRAM budget."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--cache-type-v q8_0" in cmd


def test_vt_launcher_emits_flash_attention(isolated_vt_env):
    """-fa on is required for the 60K/60K VRAM budget."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "-fa on" in cmd


def test_vt_launcher_emits_vibethinker_gguf(isolated_vt_env):
    """Default config must use the VibeThinker-3B gguf path."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "VibeThinker-3B-Q4_K_M.gguf" in cmd


def test_vt_launcher_does_not_emit_mmproj(isolated_vt_env):
    """VibeThinker-3B has NO vision — --mmproj must NOT appear in default argv."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--mmproj" not in cmd


def test_vt_launcher_uses_llama_server(isolated_vt_env):
    """Launcher must exec /usr/bin/llama-server."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "/usr/bin/llama-server" in cmd


def test_vt_launcher_no_cuda_visible_devices_override(isolated_vt_env):
    """VT is GPU-resident; the script must NOT set CUDA_VISIBLE_DEVICES=""."""
    env, _ = isolated_vt_env
    # The systemd unit intentionally omits CUDA_VISIBLE_DEVICES (unlike nano).
    # The script itself should not override it either.
    cmd = _run_launcher(env)
    # The emitted argv should not contain the env-var assignment string.
    assert "CUDA_VISIBLE_DEVICES" not in cmd


def test_vt_launcher_creates_default_config(isolated_vt_env):
    """On first run, the launcher must create active_vt_model.json with defaults."""
    env, state_root = isolated_vt_env
    _run_launcher(env)
    cfg_path = state_root / "axi" / "active_vt_model.json"
    assert cfg_path.exists(), "active_vt_model.json must be created on first run"
    data = json.loads(cfg_path.read_text())
    assert data["id"] == "vibethinker-3b"
    assert data["port"] == 8082
    assert data["ctx"] == 61440


def test_vt_launcher_reads_existing_config(isolated_vt_env):
    """If active_vt_model.json already exists, the launcher must use it."""
    env, state_root = isolated_vt_env
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True)
    home = str(Path.home())
    custom_cfg = {
        "id": "vibethinker-3b",
        "gguf": f"{home}/LifeOS/models/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf",
        "ctx": 61440,
        "ngl": 999,
        "port": 8082,
        "extra_args": ["-a", "VibeThinker-3B"],
    }
    (axi_state / "active_vt_model.json").write_text(json.dumps(custom_cfg))
    cmd = _run_launcher(env)
    assert "VibeThinker-3B-Q4_K_M.gguf" in cmd
    assert "--mmproj" not in cmd


def test_vt_launcher_jinja_deduplicated(isolated_vt_env):
    """--jinja in a hand-crafted extra_args must appear exactly once."""
    env, state_root = isolated_vt_env
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True)
    home = str(Path.home())
    cfg = {
        "id": "vibethinker-3b",
        "gguf": f"{home}/LifeOS/models/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf",
        "ctx": 61440,
        "ngl": 999,
        "port": 8082,
        "extra_args": ["--jinja", "-a", "VibeThinker-3B"],
    }
    (axi_state / "active_vt_model.json").write_text(json.dumps(cfg))
    cmd = _run_launcher(env)
    assert cmd.count("--jinja") == 1


def test_vt_launcher_ngl_appears_once(isolated_vt_env):
    """-ngl must appear exactly once (not duplicated in extra_args)."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert cmd.count("-ngl") == 1


# ---------------------------------------------------------------------------
# FIX 4 — _FIXED_FLAGS expansion: -ngl, -c, --host, --port deduplication
# ---------------------------------------------------------------------------

def _write_cfg_with_extra(state_root, extra_args: list) -> None:
    """Write a custom active_vt_model.json with given extra_args."""
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True, exist_ok=True)
    home = str(Path.home())
    cfg = {
        "id": "vibethinker-3b",
        "gguf": f"{home}/LifeOS/models/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf",
        "ctx": 61440,
        "ngl": 999,
        "port": 8082,
        "extra_args": extra_args,
    }
    (axi_state / "active_vt_model.json").write_text(json.dumps(cfg))


def test_fixed_flags_ngl_not_duplicated(isolated_vt_env):
    """FIX 4 RED: -ngl in extra_args must be deduped — appears exactly once in argv."""
    env, state_root = isolated_vt_env
    _write_cfg_with_extra(state_root, ["-ngl", "999", "-a", "VibeThinker-3B"])
    cmd = _run_launcher(env)
    assert cmd.count("-ngl") == 1, f"Expected -ngl once, got: {cmd}"


def test_fixed_flags_ctx_not_duplicated(isolated_vt_env):
    """FIX 4 RED: -c in extra_args must be deduped — appears exactly once in argv."""
    env, state_root = isolated_vt_env
    _write_cfg_with_extra(state_root, ["-c", "61440", "-a", "VibeThinker-3B"])
    cmd = _run_launcher(env)
    assert cmd.count(" -c ") == 1, f"Expected -c once, got: {cmd}"


def test_fixed_flags_port_not_duplicated(isolated_vt_env):
    """FIX 4 RED: --port in extra_args must be deduped — appears exactly once in argv."""
    env, state_root = isolated_vt_env
    _write_cfg_with_extra(state_root, ["--port", "8082", "-a", "VibeThinker-3B"])
    cmd = _run_launcher(env)
    assert cmd.count("--port") == 1, f"Expected --port once, got: {cmd}"


# ---------------------------------------------------------------------------
# FIX 6 — VT server default sampling: --temp 1.0 --top-k -1
# ---------------------------------------------------------------------------

def test_vt_default_sampling_temp(isolated_vt_env):
    """FIX 6 RED: default argv must use --temp 1.0 (VibeThinker production param), not 0.7."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--temp 1.0" in cmd, f"Expected '--temp 1.0', got: {cmd}"


def test_vt_default_sampling_top_k(isolated_vt_env):
    """FIX 6 RED: default argv must use --top-k -1 (disabled), not top-k 20."""
    env, _ = isolated_vt_env
    cmd = _run_launcher(env)
    assert "--top-k -1" in cmd, f"Expected '--top-k -1', got: {cmd}"


def test_fixed_flags_value_not_orphaned(isolated_vt_env):
    """FIX 4 RED: deduping -ngl must also skip its value token (no orphaned '999')."""
    env, state_root = isolated_vt_env
    # Put -ngl 42 in extra_args; the fixed block already has -ngl 999.
    # After dedup: only -ngl 999 should appear, not both ngl values nor orphaned 42.
    _write_cfg_with_extra(state_root, ["-ngl", "42", "-a", "VibeThinker-3B"])
    cmd = _run_launcher(env)
    tokens = cmd.split()
    ngl_positions = [i for i, t in enumerate(tokens) if t == "-ngl"]
    assert len(ngl_positions) == 1, f"Expected exactly one -ngl, got: {cmd}"
    # The value after the surviving -ngl must be 999 (from the fixed block, not 42 from extra_args)
    assert tokens[ngl_positions[0] + 1] == "999", f"Expected -ngl 999 from fixed block, got: {cmd}"
