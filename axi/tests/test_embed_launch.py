"""Tests for axi-embed-launch argv — Slice 1, tasks 1.3 (RED) / 1.4 (GREEN).

AXI_DRY_RUN=1 must print an argv containing --embedding, --pooling last,
port 8091, -ngl 0, and must NOT contain --jinja.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


LAUNCHER = Path(__file__).parent.parent / "scripts" / "axi-embed-launch"


def _run_dry(tmp_path: Path, extra_env: dict | None = None) -> str:
    """Run axi-embed-launch with AXI_DRY_RUN=1 and return stdout."""
    env = os.environ.copy()
    env["AXI_DRY_RUN"] = "1"
    env["XDG_STATE_HOME"] = str(tmp_path)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["/bin/bash", str(LAUNCHER)],
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0, f"launcher failed: {result.stderr}"
    return result.stdout.strip()


def test_embed_launch_contains_embedding_flag(tmp_path):
    """Task 1.3 RED: dry-run argv must include --embedding."""
    argv = _run_dry(tmp_path)
    assert "--embedding" in argv


def test_embed_launch_contains_pooling_last(tmp_path):
    """Task 1.3 RED: dry-run argv must include --pooling last."""
    argv = _run_dry(tmp_path)
    assert "--pooling" in argv
    assert "last" in argv


def test_embed_launch_no_jinja(tmp_path):
    """Task 1.3 RED: dry-run argv must NOT contain --jinja."""
    argv = _run_dry(tmp_path)
    assert "--jinja" not in argv


def test_embed_launch_port_8091(tmp_path):
    """Task 1.3 RED: dry-run argv must include port 8091."""
    argv = _run_dry(tmp_path)
    assert "8091" in argv


def test_embed_launch_ngl_zero(tmp_path):
    """Task 1.3 RED: dry-run argv must include -ngl 0 (CPU-only)."""
    argv = _run_dry(tmp_path)
    assert "-ngl" in argv
    # Check -ngl is followed by 0
    parts = argv.split()
    ngl_idx = parts.index("-ngl")
    assert parts[ngl_idx + 1] == "0"


def test_embed_launch_creates_default_config(tmp_path):
    """Task 1.3 RED: launcher creates active_embed_model.json when missing."""
    _run_dry(tmp_path)
    config_path = tmp_path / "axi" / "active_embed_model.json"
    assert config_path.exists(), "active_embed_model.json was not created"
    cfg = json.loads(config_path.read_text())
    assert "gguf" in cfg
    assert cfg.get("port") == 8091
