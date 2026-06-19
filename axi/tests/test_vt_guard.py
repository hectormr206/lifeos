"""Tests for axi/scripts/axi-vt-guard boot-time OOM guard.

The guard exits 0 iff active_model.json has "id": "qwen35-4b".
All other cases exit 1 (clean skip — not a failure).

Uses AXI_ACTIVE_MODEL_PATH env override so no real state file is touched.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

_GUARD = Path(__file__).parent.parent / "scripts" / "axi-vt-guard"


def _run(env: dict | None = None, tmp_path: Path | None = None) -> int:
    """Run axi-vt-guard and return its exit code."""
    result = subprocess.run(
        [sys.executable, str(_GUARD)],
        env=env,
        capture_output=True,
    )
    return result.returncode


def _env_with_path(path: Path) -> dict:
    """Build a minimal env dict pointing AXI_ACTIVE_MODEL_PATH at path."""
    import os
    e = dict(os.environ)
    e["AXI_ACTIVE_MODEL_PATH"] = str(path)
    return e


# ---------------------------------------------------------------------------
# Happy path: triad primary → exit 0
# ---------------------------------------------------------------------------

def test_guard_exits_0_when_triad_primary(tmp_path):
    """active_model.json with id=qwen35-4b → guard exits 0 (allow start)."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text(json.dumps({"id": "qwen35-4b", "name": "Qwen 4B"}))

    code = _run(env=_env_with_path(model_file))
    assert code == 0, f"Expected exit 0 for qwen35-4b, got {code}"


# ---------------------------------------------------------------------------
# Non-triad primary → exit 1 (skip, not error)
# ---------------------------------------------------------------------------

def test_guard_exits_1_when_35b_active(tmp_path):
    """active_model.json with id=qwen36-35b-a3b → guard exits 1 (skip VT, OOM guard)."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text(json.dumps({"id": "qwen36-35b-a3b", "name": "Qwen 35B"}))

    code = _run(env=_env_with_path(model_file))
    assert code == 1, f"Expected exit 1 for 35B primary, got {code}"


def test_guard_exits_1_when_id_is_unknown(tmp_path):
    """id not matching qwen35-4b → guard exits 1."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text(json.dumps({"id": "some-other-model"}))

    code = _run(env=_env_with_path(model_file))
    assert code == 1, f"Expected exit 1 for unknown id, got {code}"


# ---------------------------------------------------------------------------
# Missing or corrupt file → exit 1 (fail-safe)
# ---------------------------------------------------------------------------

def test_guard_exits_1_when_file_missing(tmp_path):
    """Missing active_model.json → guard exits 1 (fail-safe: don't start VT)."""
    nonexistent = tmp_path / "does_not_exist.json"

    code = _run(env=_env_with_path(nonexistent))
    assert code == 1, f"Expected exit 1 for missing file, got {code}"


def test_guard_exits_1_when_json_corrupt(tmp_path):
    """Corrupt JSON in active_model.json → guard exits 1 (fail-safe)."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text("{not valid json: }")

    code = _run(env=_env_with_path(model_file))
    assert code == 1, f"Expected exit 1 for corrupt JSON, got {code}"


def test_guard_exits_1_when_json_empty(tmp_path):
    """Empty file → corrupt JSON → guard exits 1 (fail-safe)."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text("")

    code = _run(env=_env_with_path(model_file))
    assert code == 1, f"Expected exit 1 for empty file, got {code}"


def test_guard_exits_1_when_id_missing_from_json(tmp_path):
    """Valid JSON but no 'id' key → guard exits 1."""
    model_file = tmp_path / "active_model.json"
    model_file.write_text(json.dumps({"name": "Qwen 4B", "port": 8080}))

    code = _run(env=_env_with_path(model_file))
    assert code == 1, f"Expected exit 1 when 'id' key absent, got {code}"
