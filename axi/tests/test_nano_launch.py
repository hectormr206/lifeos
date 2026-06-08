"""Smoke tests for the axi-nano-launch script via AXI_DRY_RUN=1."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

LAUNCHER = Path(__file__).parent.parent / "scripts" / "axi-nano-launch"


@pytest.fixture()
def isolated_nano_env(tmp_path):
    """Provide a temp XDG_STATE_HOME and a fresh env for subprocess calls."""
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


def test_launcher_dry_run_uses_default_model(isolated_nano_env):
    """Without any config, the launcher must emit the Qwen3.5-0.8B command."""
    env, _ = isolated_nano_env
    cmd = _run_launcher(env)
    assert "/usr/bin/llama-server" in cmd
    assert "Qwen3.5-0.8B-Q4_K_M.gguf" in cmd
    assert "--port" in cmd
    assert "8090" in cmd
    assert "-ngl 0" in cmd
    # -ngl must appear exactly once (not duplicated in extra_args)
    assert cmd.count("-ngl") == 1
    # --jinja must appear exactly once (not duplicated) and -c must appear
    assert cmd.count("--jinja") == 1
    assert "-c 4096" in cmd


def test_launcher_creates_default_config(isolated_nano_env):
    """On first run, the launcher must create active_nano_model.json."""
    env, state_root = isolated_nano_env
    _run_launcher(env)
    cfg_path = state_root / "axi" / "active_nano_model.json"
    assert cfg_path.exists()
    data = json.loads(cfg_path.read_text())
    assert data["id"] == "qwen35-0_8b"
    assert data["port"] == 8090


def test_launcher_reads_existing_config(isolated_nano_env, tmp_path):
    """If active_nano_model.json already exists, the launcher must use it."""
    env, state_root = isolated_nano_env
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True)
    home = str(Path.home())
    custom_cfg = {
        "id": "granite-4.0-h-1b",
        "gguf": f"{home}/LifeOS/models/granite-4.0-h-1b/granite-4.0-h-1b-Q4_K_M.gguf",
        "ctx": 8192,
        "ngl": 0,
        "port": 8090,
        # --jinja is NOT in extra_args: the catalog never produces it there;
        # the launcher injects it from the fixed block.
        "extra_args": ["-a", "granite-4.0-h-1b"],
    }
    (axi_state / "active_nano_model.json").write_text(json.dumps(custom_cfg))

    cmd = _run_launcher(env)
    assert "granite-4.0-h-1b-Q4_K_M.gguf" in cmd
    assert "--mmproj" not in cmd  # granite is text-only
    assert cmd.count("--jinja") == 1


def test_launcher_includes_mmproj_when_config_has_it(isolated_nano_env):
    """If the config contains mmproj, the launcher must include --mmproj."""
    env, state_root = isolated_nano_env
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True)
    home = str(Path.home())
    cfg = {
        "id": "qwen35-0_8b",
        "gguf": f"{home}/LifeOS/models/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf",
        "mmproj": f"{home}/LifeOS/models/qwen35-0_8b/mmproj-F16.gguf",
        "ctx": 4096,
        "ngl": 0,
        "port": 8090,
        # --jinja is NOT in extra_args: the catalog never produces it there;
        # the launcher injects it from the fixed block.
        "extra_args": ["-a", "Qwen3.5-0.8B-nano"],
    }
    (axi_state / "active_nano_model.json").write_text(json.dumps(cfg))

    cmd = _run_launcher(env)
    assert "--mmproj" in cmd
    assert cmd.count("--jinja") == 1


def test_launcher_dedupes_jinja_from_manual_extra_args(isolated_nano_env):
    """--jinja in a hand-crafted extra_args must be deduped to exactly one occurrence."""
    env, state_root = isolated_nano_env
    axi_state = state_root / "axi"
    axi_state.mkdir(parents=True)
    home = str(Path.home())
    # Simulate a hand-edited config that accidentally includes --jinja in extra_args.
    cfg = {
        "id": "qwen35-0_8b",
        "gguf": f"{home}/LifeOS/models/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf",
        "ctx": 4096,
        "ngl": 0,
        "port": 8090,
        "extra_args": ["--jinja", "-a", "Qwen3.5-0.8B-nano"],
    }
    (axi_state / "active_nano_model.json").write_text(json.dumps(cfg))

    cmd = _run_launcher(env)
    assert cmd.count("--jinja") == 1
