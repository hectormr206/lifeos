"""Tests for axi.nano_catalog — the nano-model catalog and its structure."""
from __future__ import annotations

import pytest

from axi import nano_catalog


def test_nano_catalog_has_entries():
    entries = nano_catalog.catalog()
    assert len(entries) >= 1


def test_nano_catalog_default_is_qwen35_0_8b():
    """The first / default entry must always be qwen35-0_8b."""
    entries = nano_catalog.catalog()
    assert entries[0].id == "qwen35-0_8b"


def test_nano_catalog_ids_are_unique():
    ids = [e.id for e in nano_catalog.catalog()]
    assert len(ids) == len(set(ids))


def test_nano_catalog_by_id_returns_entry():
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    assert entry.id == "qwen35-0_8b"


def test_nano_catalog_by_id_returns_none_for_unknown():
    assert nano_catalog.by_id("does-not-exist") is None


def test_qwen35_0_8b_has_gguf_and_mmproj():
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    kinds = {f.kind for f in entry.files}
    assert "gguf" in kinds
    assert "mmproj" in kinds


def test_qwen35_0_8b_gguf_path_resolves():
    """gguf_file property must not raise."""
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    gf = entry.gguf_file
    assert gf.filename.endswith(".gguf")


def test_qwen35_0_8b_mmproj_is_present():
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    assert entry.mmproj_file is not None


def test_granite_entry_has_no_mmproj():
    """Granite is text-only — no mmproj file."""
    entry = nano_catalog.by_id("granite-4.0-h-1b")
    if entry is None:
        pytest.skip("granite entry not in nano catalog")
    assert entry.mmproj_file is None


def test_lfm2_entry_has_no_mmproj():
    """LFM2 is text-only — no mmproj file."""
    entry = nano_catalog.by_id("lfm2-1.2b-extract")
    if entry is None:
        pytest.skip("lfm2 entry not in nano catalog")
    assert entry.mmproj_file is None


def test_qwen35_2b_entry_present_and_text_only():
    """The recommended 2B extractor must exist, be text-only, and be a
    proper extraction entry (won the 2026-07-14 bake-off)."""
    entry = nano_catalog.by_id("qwen35-2b")
    assert entry is not None
    assert entry.params == "2B"
    # Text-only: benchmarked without vision; mmproj would inflate RSS.
    assert entry.mmproj_file is None
    assert entry.gguf_file.filename.endswith(".gguf")
    # Must still expose the alias like every other entry.
    assert "-a" in entry.extra_args


def test_all_entries_have_ctx_and_port():
    """Every nano entry must have a ctx and the nano port defined."""
    for entry in nano_catalog.catalog():
        assert entry.ctx > 0, f"{entry.id} missing ctx"
        assert entry.port == 8090, f"{entry.id} wrong port"


def test_all_entries_have_alias_in_extra_args():
    """Every nano entry must set -a (alias) in extra_args."""
    for entry in nano_catalog.catalog():
        args = list(entry.extra_args)
        assert "-a" in args, f"{entry.id} missing -a in extra_args"


def test_iter_files_yields_all_files():
    entry = nano_catalog.by_id("qwen35-0_8b")
    assert entry is not None
    files = list(nano_catalog.iter_files(entry))
    assert len(files) == len(entry.files)
