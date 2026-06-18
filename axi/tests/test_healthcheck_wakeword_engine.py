"""TDD tests for healthcheck.check_wakeword_engine.

Tests that:
1. engine=openwakeword, model file exists (size > 0), openwakeword importable → PASS.
2. engine=openwakeword, model file missing → WARN.
3. engine=openwakeword, model file too small (size == 0) → WARN.
4. engine=openwakeword, openwakeword not importable → WARN.
5. engine=vad_whisper → PASS (no OWW model check needed).
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from axi.healthcheck import CheckStatus, check_wakeword_engine


# ──────────────────────────────────────────────────────────────────────────────
# TEST 1: openwakeword configured + model present + importable → PASS
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_configured_model_present_importable(tmp_path):
    """check_wakeword_engine returns PASS when OWW is configured, model exists, importable."""
    model_file = tmp_path / "axi.onnx"
    model_file.write_bytes(b"\x00" * 2_000_000)  # 2 MB — above 1 MB threshold

    config_data = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": str(model_file),
    }

    def fake_config_reader(path: Path) -> dict:
        return config_data

    def fake_import(name: str) -> None:
        pass  # succeeds — openwakeword is importable

    result = check_wakeword_engine(
        config_reader_fn=fake_config_reader,
        import_fn=fake_import,
    )

    assert result.status == CheckStatus.PASS, f"Expected PASS, got {result.status}: {result.detail}"
    assert "openwakeword" in result.detail.lower() or "oww" in result.detail.lower() or "pass" in result.detail.lower()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 2: openwakeword configured but model file missing → WARN
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_configured_model_missing():
    """check_wakeword_engine returns WARN when model file does not exist."""
    config_data = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/nonexistent/axi.onnx",
    }

    def fake_config_reader(path: Path) -> dict:
        return config_data

    def fake_import(name: str) -> None:
        pass

    result = check_wakeword_engine(
        config_reader_fn=fake_config_reader,
        import_fn=fake_import,
    )

    assert result.status == CheckStatus.WARN, f"Expected WARN, got {result.status}: {result.detail}"
    assert "missing" in result.detail.lower() or "model" in result.detail.lower()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 3: openwakeword configured, model exists but is empty (0 bytes) → WARN
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_configured_model_empty(tmp_path):
    """check_wakeword_engine returns WARN when model file is 0 bytes (truncated)."""
    model_file = tmp_path / "axi.onnx"
    model_file.write_bytes(b"")  # 0 bytes

    config_data = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": str(model_file),
    }

    def fake_config_reader(path: Path) -> dict:
        return config_data

    def fake_import(name: str) -> None:
        pass

    result = check_wakeword_engine(
        config_reader_fn=fake_config_reader,
        import_fn=fake_import,
    )

    assert result.status == CheckStatus.WARN, f"Expected WARN for empty file, got {result.status}: {result.detail}"
    assert "small" in result.detail.lower() or "bytes" in result.detail.lower() or "tiny" in result.detail.lower() or "model" in result.detail.lower()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 4: openwakeword configured but openwakeword not importable → WARN
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_configured_not_importable(tmp_path):
    """check_wakeword_engine returns WARN when openwakeword package is not importable."""
    model_file = tmp_path / "axi.onnx"
    model_file.write_bytes(b"\x00" * 2_000_000)

    config_data = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": str(model_file),
    }

    def fake_config_reader(path: Path) -> dict:
        return config_data

    def fake_import(name: str) -> None:
        if name == "openwakeword":
            raise ImportError("openwakeword not installed")

    result = check_wakeword_engine(
        config_reader_fn=fake_config_reader,
        import_fn=fake_import,
    )

    assert result.status == CheckStatus.WARN, f"Expected WARN when not importable, got {result.status}: {result.detail}"
    assert "import" in result.detail.lower() or "openwakeword" in result.detail.lower()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 5: engine=vad_whisper → PASS (no model check needed)
# ──────────────────────────────────────────────────────────────────────────────

def test_vad_whisper_engine_always_passes():
    """check_wakeword_engine returns PASS for vad_whisper engine (no OWW model needed)."""
    config_data = {
        "wakeword_engine": "vad_whisper",
    }

    def fake_config_reader(path: Path) -> dict:
        return config_data

    def fake_import(name: str) -> None:
        pass

    result = check_wakeword_engine(
        config_reader_fn=fake_config_reader,
        import_fn=fake_import,
    )

    assert result.status == CheckStatus.PASS, f"Expected PASS for vad_whisper, got {result.status}: {result.detail}"
    assert "vad" in result.detail.lower() or "whisper" in result.detail.lower() or "legacy" in result.detail.lower()
