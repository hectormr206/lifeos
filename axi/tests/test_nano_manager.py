"""Tests for axi.nano_manager — active-nano-model state + launcher args.

All tests run offline — no systemctl, no real file system outside tmp_path.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from axi import nano_catalog, nano_manager


@pytest.fixture()
def isolated_nano(tmp_path, monkeypatch):
    """Redirect XDG_STATE_HOME and nano models_dir to per-test temps."""
    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(nano_manager, "nano_models_dir", lambda: models_root)
    return state_root, models_root


def _plant_files(entry, models_root: Path) -> None:
    """Create dummy files for every file in the entry bundle."""
    dest = models_root / entry.id
    dest.mkdir(parents=True, exist_ok=True)
    for f in entry.files:
        (dest / f.local_name).write_bytes(b"dummy")


# ──────────────────────────── path helpers ────────────────────────────


def test_active_nano_path_is_under_state(isolated_nano):
    state_root, _ = isolated_nano
    p = nano_manager.active_nano_model_path()
    assert str(p).startswith(str(state_root))
    assert p.name == "active_nano_model.json"


def test_nano_model_dir_default_uses_entry_id(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    d = nano_manager.nano_model_dir(entry)
    assert d == models_root / entry.id


# ──────────────────────────── is_installed ────────────────────────────


def test_is_nano_installed_false_when_files_missing(isolated_nano):
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    assert not nano_manager.is_nano_installed(entry)


def test_is_nano_installed_true_when_files_present(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)
    assert nano_manager.is_nano_installed(entry)


# ──────────────────────────── read/write active ──────────────────────


def test_read_active_nano_returns_none_when_missing(isolated_nano):
    assert nano_manager.read_active_nano() is None


def test_write_and_read_active_nano_roundtrip(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    data = nano_manager.read_active_nano()
    assert data is not None
    assert data["id"] == "qwen35-0_8b"
    assert "gguf" in data
    assert "ctx" in data
    assert "port" in data
    assert data["port"] == 8090


def test_write_active_nano_includes_mmproj_when_present(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    data = nano_manager.read_active_nano()
    assert data is not None
    assert "mmproj" in data


def test_write_active_nano_no_mmproj_for_text_only(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("granite-4.0-h-1b")
    if entry is None:
        pytest.skip("granite not in nano catalog")
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    data = nano_manager.read_active_nano()
    assert data is not None
    assert "mmproj" not in data


def test_write_active_nano_is_atomic(isolated_nano):
    """Atomic write: .tmp never replaces if write fails mid-way."""
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    p = nano_manager.active_nano_model_path()
    # .tmp must not exist after a successful write
    assert not p.with_suffix(".json.tmp").exists()
    assert p.exists()


def test_get_active_nano_id_returns_id(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)
    nano_manager.write_active_nano(entry)
    assert nano_manager.get_active_nano_id() == "qwen35-0_8b"


def test_get_active_nano_id_returns_none_when_missing(isolated_nano):
    assert nano_manager.get_active_nano_id() is None


# ──────────────────────────── _entry_to_nano_dict ────────────────────


def test_entry_to_nano_dict_qwen35_0_8b(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    d = nano_manager._entry_to_nano_dict(entry)
    assert d["id"] == "qwen35-0_8b"
    assert d["port"] == 8090
    assert d["ctx"] == entry.ctx
    # extra_args must be a list
    assert isinstance(d["extra_args"], list)
    # -a (alias) sentinel must appear
    assert "-a" in d["extra_args"]


# ──────────────────────────── build_nano_launch_args ─────────────────


def test_build_nano_launch_args_qwen35_0_8b(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    cfg = nano_manager.read_active_nano()
    assert cfg is not None
    args = nano_manager.build_nano_launch_args(cfg)

    # Must include llama-server binary
    assert args[0] == "/usr/bin/llama-server"
    # -m flag with path
    assert "-m" in args
    m_idx = args.index("-m")
    assert args[m_idx + 1].endswith(".gguf")
    # --mmproj because qwen has vision
    assert "--mmproj" in args
    # port 8090
    assert "--port" in args
    port_idx = args.index("--port")
    assert args[port_idx + 1] == "8090"
    # host loopback
    assert "--host" in args
    host_idx = args.index("--host")
    assert args[host_idx + 1] == "127.0.0.1"
    # ngl=0 (CPU only for nano)
    assert "-ngl" in args
    ngl_idx = args.index("-ngl")
    assert args[ngl_idx + 1] == "0"
    # --jinja and -c from config fields (not duplicated in extra_args)
    assert "--jinja" in args
    assert "-c" in args
    c_idx = args.index("-c")
    assert args[c_idx + 1] == str(entry.ctx)
    # -ngl must appear exactly once
    assert args.count("-ngl") == 1


def test_build_nano_launch_args_text_only_no_mmproj(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("granite-4.0-h-1b")
    if entry is None:
        pytest.skip("granite not in nano catalog")
    _plant_files(entry, models_root)

    nano_manager.write_active_nano(entry)
    cfg = nano_manager.read_active_nano()
    assert cfg is not None
    args = nano_manager.build_nano_launch_args(cfg)
    assert "--mmproj" not in args


# ──────────────────────────── default fallback ────────────────────────


def test_default_nano_payload_matches_qwen35_0_8b(isolated_nano):
    """Absent any config file, the default constant must describe qwen35-0_8b."""
    default = nano_manager.DEFAULT_NANO
    assert default["id"] == "qwen35-0_8b"
    assert default["port"] == 8090
    # Must reference the historical model path
    assert "qwen35-0_8b" in default["gguf"]
    assert "Qwen3.5-0.8B-Q4_K_M.gguf" in default["gguf"]
    # mmproj is intentionally absent in the default: historical service never
    # loaded it and the runtime only does text (chat/completions).
    assert "mmproj" not in default


def test_default_args_cpu_only():
    """The default config must yield ngl=0 (CPU-only nano)."""
    args = nano_manager.build_nano_launch_args(nano_manager.DEFAULT_NANO)
    assert "-ngl" in args
    ngl_idx = args.index("-ngl")
    assert args[ngl_idx + 1] == "0"


# ──────────────────────────── set_active_nano ────────────────────────


def test_set_active_nano_writes_json_no_restart(isolated_nano):
    _, models_root = isolated_nano
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    _plant_files(entry, models_root)

    # restart=False skips systemctl — safe in CI.
    result = nano_manager.set_active_nano(entry, restart=False)
    assert result is True
    assert nano_manager.get_active_nano_id() == "qwen35-0_8b"


def test_set_active_nano_raises_if_not_installed(isolated_nano):
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    # Files NOT planted → must raise.
    with pytest.raises(FileNotFoundError):
        nano_manager.set_active_nano(entry, restart=False)
