"""Unit tests for bench_model.py — PURE logic only.

No process is spawned, no network is hit, no heavy model is loaded. Covers:
  - registry append + newest-per-label dedup (for --list)
  - the 0.7/0.3 final-score formula
  - the comparison-table builder
  - argument parsing
  - the server-argv builder (--server-bin honoured as argv[0])

Run:
  cd /home/hectormr/LifeOS/lifeos/axi && \
      .venv/bin/python -m pytest scripts/bench/test_bench_model.py -q
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import bench_model as bm


# ── final-score formula (0.7*det + 0.3*subj) ─────────────────────────────────

@pytest.mark.parametrize("det,subj,expected", [
    (1.0, 1.0, 1.0),
    (0.0, 0.0, 0.0),
    (1.0, 0.0, 0.7),
    (0.0, 1.0, 0.3),
    (0.8, 0.6, 0.74),   # 0.56 + 0.18
    (0.5, 0.5, 0.5),
])
def test_final_score_formula(det, subj, expected):
    assert bm.final_score(det, subj) == pytest.approx(expected)


def test_final_score_weights_are_070_030():
    # Isolate each weight.
    assert bm.final_score(1.0, 0.0) == pytest.approx(bm.FINAL_DET_WEIGHT)
    assert bm.final_score(0.0, 1.0) == pytest.approx(bm.FINAL_SUBJ_WEIGHT)
    assert bm.FINAL_DET_WEIGHT + bm.FINAL_SUBJ_WEIGHT == pytest.approx(1.0)


# ── server-argv builder (the key new capability: --server-bin) ───────────────

def test_build_server_argv_honours_server_bin_as_argv0():
    fork = "/home/hectormr/LifeOS/PrismML-llama.cpp/build/bin/llama-server"
    argv = bm.build_server_argv(
        server_bin=fork, gguf="/models/m.gguf", ngl=0, cpu_moe=False,
        ctx=32768, port=18080,
    )
    assert argv[0] == fork                      # fork build is argv[0]
    assert argv[1:3] == ["-m", "/models/m.gguf"]
    # core flags present and correctly valued
    assert argv[argv.index("-ngl") + 1] == "0"
    assert argv[argv.index("-c") + 1] == "32768"
    assert argv[argv.index("--port") + 1] == "18080"
    assert "--jinja" in argv
    assert "--cpu-moe" not in argv              # not requested


def test_build_server_argv_cpu_moe_and_mmproj_and_extra_flags():
    argv = bm.build_server_argv(
        server_bin="/usr/bin/llama-server", gguf="/m.gguf", ngl=999,
        cpu_moe=True, ctx=8192, port=18080, mmproj="/mm.gguf",
        extra_flags=["--cache-type-k", "q8_0", "--mlock"],
    )
    assert argv[argv.index("--mmproj") + 1] == "/mm.gguf"
    assert argv[argv.index("-ngl") + 1] == "999"
    assert "--cpu-moe" in argv
    # extra flags appended verbatim at the tail, order preserved
    assert argv[-3:] == ["--cache-type-k", "q8_0", "--mlock"]


def test_build_server_argv_default_binary():
    argv = bm.build_server_argv(
        server_bin="/usr/bin/llama-server", gguf="/m.gguf", ngl=0,
        cpu_moe=False, ctx=1024, port=18080,
    )
    assert argv[0] == "/usr/bin/llama-server"
    assert "--mmproj" not in argv


# ── registry append + newest-per-label dedup ─────────────────────────────────

def _row(label, ts, **metrics):
    r = {"label": label, "timestamp_utc": ts,
         "gguf": f"/m/{label}.gguf", "server_bin": "/usr/bin/llama-server"}
    r.update(metrics)
    return r


def test_append_and_load_registry_roundtrip(tmp_path):
    path = tmp_path / "reg.jsonl"
    assert bm.load_registry(path) == []       # missing file → empty
    bm.append_registry_row(path, _row("a", "2026-07-13T00:00:00+00:00"))
    bm.append_registry_row(path, _row("b", "2026-07-13T01:00:00+00:00"))
    rows = bm.load_registry(path)
    assert [r["label"] for r in rows] == ["a", "b"]
    # each row is one physical JSON line
    assert len(path.read_text().splitlines()) == 2


def test_append_preserves_history_for_same_label(tmp_path):
    path = tmp_path / "reg.jsonl"
    bm.append_registry_row(path, _row("a", "2026-07-13T00:00:00+00:00"))
    bm.append_registry_row(path, _row("a", "2026-07-14T00:00:00+00:00"))
    rows = bm.load_registry(path)
    assert len(rows) == 2                      # history kept, not overwritten


def test_newest_per_label_prefers_newest_timestamp():
    rows = [
        _row("a", "2026-07-13T00:00:00+00:00", brain={"det": 0.1}),
        _row("a", "2026-07-14T00:00:00+00:00", brain={"det": 0.9}),  # newer
        _row("b", "2026-07-13T00:00:00+00:00", brain={"det": 0.5}),
    ]
    latest = bm.newest_per_label(rows)
    by_label = {r["label"]: r for r in latest}
    assert len(latest) == 2
    assert by_label["a"]["brain"]["det"] == 0.9   # newest 'a' won
    assert by_label["b"]["brain"]["det"] == 0.5


def test_newest_per_label_tie_breaks_on_file_order():
    rows = [
        _row("a", "2026-07-13T00:00:00+00:00", brain={"det": 0.1}),
        _row("a", "2026-07-13T00:00:00+00:00", brain={"det": 0.2}),  # same ts, later
    ]
    latest = bm.newest_per_label(rows)
    assert len(latest) == 1
    assert latest[0]["brain"]["det"] == 0.2


def test_newest_per_label_empty():
    assert bm.newest_per_label([]) == []


def test_load_registry_skips_blank_and_bad_lines(tmp_path):
    path = tmp_path / "reg.jsonl"
    path.write_text(
        json.dumps(_row("a", "2026-07-13T00:00:00+00:00")) + "\n"
        + "\n"                                  # blank
        + "{not json}\n"                        # malformed
        + json.dumps(_row("b", "2026-07-13T01:00:00+00:00")) + "\n"
    )
    rows = bm.load_registry(path)
    assert [r["label"] for r in rows] == ["a", "b"]


# ── comparison-table builder ─────────────────────────────────────────────────

def test_comparison_table_empty_registry():
    out = bm.build_comparison_table([])
    assert "registry is empty" in out


def test_comparison_table_shows_newest_and_metrics():
    rows = [
        _row("alpha", "2026-07-13T00:00:00+00:00",
             brain={"det": 0.10, "subj": 0.20, "final": 0.13},
             speed={"decode_p50_toks_s": 11.1, "ttft_p50_ms": 222.0, "idle_rss_mb": 3300},
             extraction={"case_pass_rate": 0.5}),
        _row("alpha", "2026-07-14T00:00:00+00:00",   # newer → this one shows
             brain={"det": 0.90, "subj": 0.80, "final": 0.87},
             speed={"decode_p50_toks_s": 42.0, "ttft_p50_ms": 100.0, "idle_rss_mb": 4096},
             extraction={"case_pass_rate": 0.837}),
        _row("beta", "2026-07-13T00:00:00+00:00", brain={"det": 0.5}),
    ]
    out = bm.build_comparison_table(rows)
    assert "alpha" in out and "beta" in out
    assert "0.870" in out          # newest alpha final
    assert "0.130" not in out      # stale alpha final must NOT appear
    assert "42.0" in out           # newest alpha tok/s
    assert "83.7%" in out          # extraction pass rate formatted


def test_comparison_table_tolerates_missing_metrics():
    # A row with only brain.det — everything else must render as a dash, not crash.
    rows = [_row("x", "2026-07-13T00:00:00+00:00", brain={"det": 0.5})]
    out = bm.build_comparison_table(rows)
    assert "x" in out
    assert "0.500" in out


# ── argument parsing ─────────────────────────────────────────────────────────

def test_parser_defaults():
    args = bm.build_parser().parse_args(["--gguf", "/m.gguf", "--label", "m"])
    assert args.server_bin == "/usr/bin/llama-server"
    assert args.ngl == 0
    assert args.ctx == 32768
    assert args.port == 18080
    assert args.n_runs == 10
    assert args.cpu_moe is False
    assert args.roles == "speed,brain,extraction"
    assert args.list is False


def test_parser_server_bin_and_roles_and_cpu_moe():
    fork = "/home/hectormr/LifeOS/PrismML-llama.cpp/build/bin/llama-server"
    args = bm.build_parser().parse_args([
        "--gguf", "/m.gguf", "--label", "prism",
        "--server-bin", fork, "--roles", "speed,extraction",
        "--ngl", "999", "--cpu-moe", "--ctx", "8192", "--port", "18081",
    ])
    assert args.server_bin == fork
    assert args.roles == "speed,extraction"
    assert args.ngl == 999
    assert args.cpu_moe is True
    assert args.port == 18081


def test_parser_extra_flags_remainder_passthrough():
    args = bm.build_parser().parse_args([
        "--gguf", "/m.gguf", "--label", "m",
        "--extra-flags", "--cache-type-k", "q8_0", "--mlock",
    ])
    assert args.extra_flags == ["--cache-type-k", "q8_0", "--mlock"]


def test_parser_list_mode():
    args = bm.build_parser().parse_args(["--list"])
    assert args.list is True


def test_parse_roles_valid_and_invalid():
    assert bm.parse_roles("speed,brain,extraction") == ["speed", "brain", "extraction"]
    assert bm.parse_roles("brain") == ["brain"]
    with pytest.raises(ValueError):
        bm.parse_roles("speed,bogus")


# ── percentile helper (used by the speed role) ───────────────────────────────

def test_percentile_helper():
    assert bm._percentile([], 0.5) == 0.0
    assert bm._percentile([10.0], 0.5) == 10.0
    xs = [1.0, 2.0, 3.0, 4.0, 5.0]
    assert bm._percentile(xs, 0.5) == 3.0
    assert bm._percentile(xs, 0.95) == 5.0
