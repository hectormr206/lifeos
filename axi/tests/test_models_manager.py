"""Tests for axi.models_manager and the catalog.

These run offline — no real HF traffic and no systemctl invocation.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from axi import models_catalog, models_manager


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    """Redirect XDG_STATE_HOME + models_dir() to per-test temp paths so the
    real ~/.local/state/axi/active_model.json is never touched."""
    state_root = tmp_path / "state"
    models_root = tmp_path / "models"
    state_root.mkdir()
    models_root.mkdir()
    monkeypatch.setenv("XDG_STATE_HOME", str(state_root))
    monkeypatch.setattr(models_manager, "models_dir", lambda: models_root)
    return state_root, models_root


def test_catalog_has_expected_entries():
    entries = models_catalog.catalog()
    ids = {e.id for e in entries}
    # 3 total: qwen3.6 (prod/quality) + gemma4-e2b-it (universal small/fast/vision)
    # + qwen35-2b (game co-pilot brain, added 2026-06-17).
    # Cut (2026-06-10): gemma4-e4b-it (dominated by e2b), gemma4-26b-a4b-it (18.5 GB RSS
    # fails 22/24 GB tiers with reserve, owns no common tier).
    assert len(entries) == 3
    # All three kept models must be present.
    assert "qwen36-35b-a3b" in ids
    assert "gemma4-e2b-it" in ids
    assert "qwen35-2b" in ids  # game co-pilot brain (bench winner: 10 s/frame)
    # Cut models must be absent.
    assert "gemma4-e4b-it" not in ids
    assert "gemma4-26b-a4b-it" not in ids
    assert "nemotron3-nano-omni-30b-a3b" not in ids
    assert "qwen35-9b" not in ids
    assert "granite-4.0-h-1b" not in ids
    assert "lfm2-1.2b-extract" not in ids
    # Other Qwen3.5 dense sizes must remain absent (only 2B is the co-pilot).
    assert "qwen35-0_8b" not in ids
    assert "qwen35-4b" not in ids
    # Qwen3-VL family must be gone.
    assert "qwen3-vl-30b-a3b" not in ids
    assert "qwen3-vl-8b" not in ids
    assert "qwen3-vl-4b" not in ids


def test_catalog_ids_unique():
    ids = [e.id for e in models_catalog.catalog()]
    assert len(ids) == len(set(ids))


def test_by_id_returns_entry_or_none():
    assert models_catalog.by_id("gemma4-e2b-it") is not None
    assert models_catalog.by_id("does-not-exist") is None


def test_legacy_entry_path_uses_historical_dir(isolated_state):
    _, models_root = isolated_state
    legacy = models_catalog.by_id("qwen36-35b-a3b")
    # Even with our patched models_dir(), the legacy entry must live under
    # the historical directory name so we don't lose the 22GB local file.
    paths = models_manager.expected_paths(legacy)
    assert "Qwen3.6-35B-A3B" in str(paths["gguf"])


def test_is_installed_true_when_all_files_present(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        path = models_manager.expected_path(entry, f)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"dummy")
    assert models_manager.is_installed(entry)


def test_is_installed_false_when_files_missing(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    assert not models_manager.is_installed(entry)


def test_is_installed_false_when_only_some_present(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    # Create only the gguf, not the mmproj.
    f = entry.files[0]
    p = models_manager.expected_path(entry, f)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"x")
    assert not models_manager.is_installed(entry)


def test_write_active_round_trips(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    # Pretend files exist so set_active wouldn't refuse — but here we call
    # write_active directly which has no install-check.
    models_manager.write_active(entry)
    data = json.loads(models_manager.active_model_path().read_text())
    assert data["id"] == entry.id
    assert data["ctx"] == entry.ctx
    assert data["ngl"] == entry.ngl
    assert data["gguf"].endswith(entry.gguf_file.local_name)
    assert isinstance(data["extra_args"], list)


def test_get_active_id_reads_back(isolated_state):
    entry = models_catalog.by_id("qwen36-35b-a3b")
    models_manager.write_active(entry)
    assert models_manager.get_active_id() == "qwen36-35b-a3b"


def test_get_active_id_returns_none_when_unset(isolated_state):
    assert models_manager.get_active_id() is None


def test_download_writes_files_to_per_entry_dir(isolated_state, monkeypatch):
    """download() should hit hf_hub_download for each catalog file and end
    with the bundle marked installed. No network — hf_hub_download is mocked.
    """
    entry = models_catalog.by_id("gemma4-e2b-it")
    dest = models_manager.model_dir(entry)

    def fake_hf_download(repo_id, filename, local_dir, token=None, **kw):
        path = Path(local_dir) / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"weights-bytes-" + filename.encode())
        return str(path)

    monkeypatch.setattr(
        "huggingface_hub.hf_hub_download",
        fake_hf_download,
    )

    progress_calls = []
    models_manager.download(entry, progress_cb=lambda i, t, p: progress_calls.append((i, t, p)))

    assert models_manager.is_installed(entry)
    for f in entry.files:
        assert (dest / f.local_name).read_bytes().startswith(b"weights-bytes-")
    # progress_cb was invoked at least once per file.
    assert len(progress_calls) >= len(entry.files)


def test_download_skips_already_present_files(isolated_state, monkeypatch):
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"already-here")

    calls = []

    def fake_hf_download(**kw):
        calls.append(kw)
        raise AssertionError("should not have been called")

    monkeypatch.setattr("huggingface_hub.hf_hub_download", fake_hf_download)
    models_manager.download(entry)
    assert calls == []


def test_legacy_download_when_present_is_noop(isolated_state):
    legacy = models_catalog.by_id("qwen36-35b-a3b")
    for f in legacy.files:
        p = models_manager.expected_path(legacy, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    # Should NOT try to download — files are local-only.
    models_manager.download(legacy)


def test_legacy_download_when_missing_raises(isolated_state):
    legacy = models_catalog.by_id("qwen36-35b-a3b")
    with pytest.raises(FileNotFoundError):
        models_manager.download(legacy)


def test_set_active_refuses_uninstalled(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    with pytest.raises(FileNotFoundError):
        models_manager.set_active(entry, restart=False, wait_health=False)


def test_set_active_writes_json_without_restart(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    ok = models_manager.set_active(entry, restart=False, wait_health=False)
    assert ok is True
    assert models_manager.get_active_id() == entry.id


def test_catalog_status_marks_active(isolated_state):
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    models_manager.write_active(entry)
    rows = {s.entry.id: s for s in models_manager.catalog_status()}
    assert rows["gemma4-e2b-it"].is_active is True
    assert rows["gemma4-e2b-it"].installed is True
    assert rows["qwen36-35b-a3b"].is_active is False


def test_wait_for_llama_health_times_out_fast(monkeypatch):
    # Point at a port nothing is listening on; ensure timeout returns False
    # quickly (well under the 60s default).
    import time
    start = time.time()
    ok = models_manager.wait_for_llama_health(timeout=1.5, url="http://127.0.0.1:1/health")
    elapsed = time.time() - start
    assert ok is False
    assert elapsed < 5.0


# ────────────────────── CLI (__main__) round-trip ──────────────────────────


def test_cli_get_active_empty(isolated_state, capsys):
    """get-active prints an empty line when no active model is set."""
    import sys
    import importlib

    monkeypatch_args = ["axi.models_manager", "get-active"]
    # Invoke via _cli_main directly (avoids subprocess; same XDG patch applies).
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(monkeypatch_args):
            models_manager._cli_main()
    assert exc.value.code == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == ""


def test_cli_set_active_and_get_active_round_trip(isolated_state, capsys):
    """set-active gemma4-e2b-it → get-active must return 'gemma4-e2b-it'."""
    # Plant model files so the install guard passes.
    entry = models_catalog.by_id("gemma4-e2b-it")
    for f in entry.files:
        p = models_manager.expected_path(entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"dummy")

    # set-active
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(["axi.models_manager", "set-active", "gemma4-e2b-it"]):
            models_manager._cli_main()
    assert exc.value.code == 0
    capsys.readouterr()  # discard stdout

    # get-active
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(["axi.models_manager", "get-active"]):
            models_manager._cli_main()
    assert exc.value.code == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == "gemma4-e2b-it"

    # active_model.json must contain --reasoning off
    data = json.loads(models_manager.active_model_path().read_text())
    assert data["id"] == "gemma4-e2b-it"
    extra = data["extra_args"]
    # gemma4-e2b-it entry has `--reasoning off` in its extra_args
    assert "--reasoning" in extra
    idx = extra.index("--reasoning")
    assert extra[idx + 1] == "off"

    # Round-trip back to qwen36-35b-a3b (plant its files too so the guard passes).
    qwen_entry = models_catalog.by_id("qwen36-35b-a3b")
    for f in qwen_entry.files:
        p = models_manager.expected_path(qwen_entry, f)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"dummy")
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(["axi.models_manager", "set-active", "qwen36-35b-a3b"]):
            models_manager._cli_main()
    assert exc.value.code == 0
    data2 = json.loads(models_manager.active_model_path().read_text())
    assert data2["id"] == "qwen36-35b-a3b"


def test_cli_set_active_unknown_id_exits_nonzero(isolated_state, capsys):
    """set-active with an unknown id must exit 1 and print an error."""
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(["axi.models_manager", "set-active", "no-such-model"]):
            models_manager._cli_main()
    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "not found in catalog" in captured.err


def test_cli_set_active_uninstalled_exits_nonzero(isolated_state, capsys):
    """set-active a known-catalog model whose files are NOT on disk must exit 1."""
    # isolated_state provides an empty models dir — no files present.
    with pytest.raises(SystemExit) as exc:
        with _patch_argv(["axi.models_manager", "set-active", "gemma4-e2b-it"]):
            models_manager._cli_main()
    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert "not installed" in captured.err


# ────────────────── qwen35-2b game co-pilot catalog entry ─────────────────────


def test_qwen35_2b_entry_exists_in_catalog():
    """qwen35-2b must be registered in the catalog (game co-pilot brain)."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None, "qwen35-2b not found in catalog"


def test_qwen35_2b_has_vision_feature():
    """qwen35-2b must advertise 'vision' so the UI/selector knows it supports images."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert "vision" in entry.features, f"Expected 'vision' in features, got {entry.features}"


def test_qwen35_2b_has_tools_feature():
    """qwen35-2b must advertise 'tools' for function-calling co-pilot scenarios."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert "tools" in entry.features, f"Expected 'tools' in features, got {entry.features}"


def test_qwen35_2b_has_gguf_file():
    """qwen35-2b must declare the Q4_K_M gguf weights file."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    gguf = entry.gguf_file
    assert gguf.local_name == "Qwen3.5-2B-Q4_K_M.gguf", (
        f"Expected 'Qwen3.5-2B-Q4_K_M.gguf', got '{gguf.local_name}'"
    )


def test_qwen35_2b_has_mmproj_file():
    """qwen35-2b must declare an mmproj file for vision support."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    mmproj = entry.mmproj_file
    assert mmproj is not None, "mmproj file missing from qwen35-2b entry"
    assert mmproj.local_name == "mmproj-F16.gguf", (
        f"Expected 'mmproj-F16.gguf', got '{mmproj.local_name}'"
    )


def test_qwen35_2b_ngl_is_zero():
    """qwen35-2b is CPU-only (game co-pilot); ngl must be 0."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert entry.ngl == 0, f"Expected ngl=0 (CPU-only), got {entry.ngl}"


def test_qwen35_2b_vram_estimate_reflects_cpu_model():
    """qwen35-2b runs on CPU; vram_estimate_gb must be <= 2.5 GB."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert entry.vram_estimate_gb <= 2.5, (
        f"Expected vram <= 2.5, got {entry.vram_estimate_gb}"
    )


def test_qwen35_2b_extra_args_no_jinja():
    """qwen35-2b extra_args must NOT contain --jinja (axi-llama-launch adds it
    globally; adding it again would conflict with Qwen's chat template)."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert "--jinja" not in entry.extra_args, (
        "--jinja must not appear in qwen35-2b extra_args (it's injected by axi-llama-launch)"
    )


def test_qwen35_2b_extra_args_no_reasoning_off():
    """qwen35-2b must NOT have '--reasoning off' (that's Gemma-specific)."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    args = list(entry.extra_args)
    if "--reasoning" in args:
        idx = args.index("--reasoning")
        assert args[idx + 1] != "off", (
            "'--reasoning off' is Gemma-specific; Qwen3.5-2B does not need it"
        )


def test_qwen35_2b_is_installed_when_files_present(isolated_state):
    """is_installed returns True when both gguf and mmproj exist on disk."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    for f in entry.files:
        path = models_manager.expected_path(entry, f)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"dummy")
    assert models_manager.is_installed(entry)


def test_qwen35_2b_write_active_includes_mmproj(isolated_state):
    """write_active for qwen35-2b must include the mmproj path in the JSON."""
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    # write_active does not check is_installed; call it directly.
    models_manager.write_active(entry)
    data = models_manager.active_model_path().read_text()
    parsed = __import__("json").loads(data)
    assert "mmproj" in parsed, "active_model.json must include 'mmproj' for vision"
    assert "mmproj-F16.gguf" in parsed["mmproj"]


def test_qwen35_2b_model_dir_uses_entry_id(isolated_state):
    """qwen35-2b is NOT a legacy entry; its dir must use the catalog id."""
    _, models_root = isolated_state
    entry = models_catalog.by_id("qwen35-2b")
    assert entry is not None
    d = models_manager.model_dir(entry)
    assert d == models_root / "qwen35-2b", (
        f"Expected models/<id>/qwen35-2b, got {d}"
    )


class _patch_argv:
    """Context manager: temporarily replace sys.argv."""

    def __init__(self, args: list[str]):
        self._args = args
        self._orig: list[str] = []

    def __enter__(self):
        import sys
        self._orig = sys.argv[:]
        sys.argv = self._args
        return self

    def __exit__(self, *_):
        import sys
        sys.argv = self._orig
