"""Tests for the model-audit dashboard page: /api/bench/audit and /models/audit.

The bench harness (scripts/bench/model_audit.py) owns model_audit.jsonl and
model_recipes.json — this suite never writes to those files, only to tmp
fixtures whose directory is monkeypatched in via bench_audit.results_dir().
"""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Pure-function unit tests (axi.bench_audit) — no FastAPI, no mocks.
# ---------------------------------------------------------------------------

def test_summarize_roles_uses_headline_key():
    from axi import bench_audit

    roles = {
        "extraction": {"case_pass_rate": 0.42, "total": 10},
        "domain": {"overall_accuracy": 0.9},
    }
    summary = bench_audit.summarize_roles(roles)
    assert summary["extraction"] == 0.42
    assert summary["domain"] == 0.9


def test_summarize_roles_ignores_sampling_used_record():
    """sampling_used (2026-07-16 seed era) is a config record, not a metric —
    headline extraction must skip it and still find the numeric key."""
    from axi import bench_audit

    sampling_used = {"temperature": 0.6, "top_p": 0.95, "top_k": 20,
                     "seed_policy": "per-case-crc32", "thinking": "off"}
    roles = {
        "brain": {"final": None, "det": 0.51, "sampling_used": sampling_used},
        "toolstress": {"pass_rate": 0.9, "sampling_used": sampling_used},
        "speed": {"decode_p50_toks_s": 40.0,
                  "sampling_used": {"temperature": None, "top_p": None,
                                    "top_k": None, "seed_policy": "n/a",
                                    "thinking": "n/a"}},
    }
    summary = bench_audit.summarize_roles(roles)
    assert summary["brain"] == 0.51
    assert summary["toolstress"] == 0.9
    assert summary["speed"] == 40.0
    # a role dict containing ONLY sampling_used yields None, never the dict
    assert bench_audit._role_headline(
        {"sampling_used": sampling_used}, ("pass_rate",)) is None
    overall, counted = bench_audit.compute_overall(summary)
    assert counted == 2                      # speed excluded, as always
    assert overall == pytest.approx((0.51 + 0.9) / 2)


def test_summarize_roles_brain_falls_back_to_det_when_final_missing():
    from axi import bench_audit

    roles = {"brain": {"det": 0.33, "subj": None, "final": None}}
    summary = bench_audit.summarize_roles(roles)
    assert summary["brain"] == 0.33


def test_summarize_roles_prefers_final_over_det_when_both_present():
    from axi import bench_audit

    roles = {"brain": {"det": 0.1, "final": 0.77}}
    summary = bench_audit.summarize_roles(roles)
    assert summary["brain"] == 0.77


def test_summarize_roles_skipped_role_is_none():
    from axi import bench_audit

    roles = {"vision": {"skipped": "no vision cases for this recipe"}}
    summary = bench_audit.summarize_roles(roles)
    assert summary["vision"] is None


def test_summarize_roles_missing_role_is_none():
    from axi import bench_audit

    summary = bench_audit.summarize_roles({})
    assert summary["codegen"] is None
    assert summary["speed"] is None


def test_compute_overall_excludes_speed_and_skips_missing():
    from axi import bench_audit

    summary = {
        "brain": 0.5,
        "extraction": None,
        "domain": 0.8,
        "toolcall": None,
        "speed": 999.0,  # must NOT be averaged in — different scale (tok/s)
    }
    overall, roles_counted = bench_audit.compute_overall(summary)
    assert overall == pytest.approx(0.65)
    assert roles_counted == 2


def test_compute_overall_none_when_no_quality_role_scored():
    from axi import bench_audit

    summary = {"brain": None, "extraction": None, "speed": 50.0}
    overall, roles_counted = bench_audit.compute_overall(summary)
    assert overall is None
    assert roles_counted == 0


def test_ctxprobe_headline_scalar_and_overall_exclusion():
    """ctxprobe's headline is ctx_max_current (max context in tokens), a
    capacity number on a different scale — like speed, it must never be
    averaged into the 0-1 quality overall."""
    from axi import bench_audit

    roles = {
        "brain": {"det": 0.5},
        "domain": {"overall_accuracy": 0.9},
        "ctxprobe": {"ctx_max_current": 139264,
                     "ctx_max": {"vram12": 139264}},
    }
    summary = bench_audit.summarize_roles(roles)
    assert summary["ctxprobe"] == 139264
    assert "ctxprobe" not in bench_audit._OVERALL_ROLES
    overall, counted = bench_audit.compute_overall(summary)
    assert counted == 2                          # brain + domain only
    assert overall == pytest.approx(0.7)
    # a skipped probe (cpu tier) yields None, exactly like other roles
    assert bench_audit.summarize_roles(
        {"ctxprobe": {"skipped": "cpu tier — no VRAM ceiling"}}
    )["ctxprobe"] is None


def test_load_audit_rows_skips_malformed_lines(tmp_path):
    from axi import bench_audit

    p = tmp_path / "model_audit.jsonl"
    p.write_text(
        "not json at all\n"
        + json.dumps({"label": "m1", "tier": "cpu", "timestamp_utc": "2026-01-01T00:00:00+00:00", "roles": {}}) + "\n"
        + "{broken\n"
    )
    rows = bench_audit.load_audit_rows(p)
    assert len(rows) == 1
    assert rows[0]["label"] == "m1"


def test_load_audit_rows_missing_file_returns_empty(tmp_path):
    from axi import bench_audit

    rows = bench_audit.load_audit_rows(tmp_path / "does_not_exist.jsonl")
    assert rows == []


def test_load_audit_rows_keeps_newest_per_label_tier(tmp_path):
    from axi import bench_audit

    p = tmp_path / "model_audit.jsonl"
    old_row = {
        "label": "qwen35-0_8b", "tier": "cpu",
        "timestamp_utc": "2026-01-01T00:00:00+00:00",
        "roles": {"brain": {"final": 0.1}},
    }
    new_row = {
        "label": "qwen35-0_8b", "tier": "cpu",
        "timestamp_utc": "2026-02-01T00:00:00+00:00",
        "roles": {"brain": {"final": 0.9}},
    }
    other_tier_row = {
        "label": "qwen35-0_8b", "tier": "gpu",
        "timestamp_utc": "2026-01-15T00:00:00+00:00",
        "roles": {"brain": {"final": 0.5}},
    }
    p.write_text("\n".join(json.dumps(r) for r in (old_row, new_row, other_tier_row)) + "\n")

    rows = bench_audit.load_audit_rows(p)
    by_tier = {r["tier"]: r for r in rows}
    assert len(rows) == 2  # (label,cpu) deduped to 1 + (label,gpu) kept separate
    assert by_tier["cpu"]["roles"]["brain"]["final"] == 0.9  # newest wins, not oldest
    assert by_tier["gpu"]["roles"]["brain"]["final"] == 0.5


# ---------------------------------------------------------------------------
# API-level tests (FastAPI TestClient, tmp results dir monkeypatched in)
# ---------------------------------------------------------------------------

@pytest.fixture
def bench_client(tmp_path, monkeypatch):
    from axi import bench_audit, dashboard

    results_root = tmp_path / "results"
    results_root.mkdir()
    monkeypatch.setattr(bench_audit, "results_dir", lambda: results_root)

    # Same dashboard stubs used by test_models_api.py — keeps this suite from
    # touching the live system if any shared route/startup path is exercised.
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

    return TestClient(dashboard.app), results_root


def _write_jsonl(path, rows):
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")


def test_api_bench_audit_empty_when_files_missing(bench_client):
    client, _results_root = bench_client
    r = client.get("/api/bench/audit")
    assert r.status_code == 200
    body = r.json()
    assert body["audits"] == []
    assert "generated_at" in body


def test_api_bench_audit_skips_malformed_line(bench_client):
    client, results_root = bench_client
    (results_root / "model_audit.jsonl").write_text(
        "garbage\n"
        + json.dumps({
            "label": "qwen35-0_8b", "tier": "cpu",
            "timestamp_utc": "2026-01-01T00:00:00+00:00",
            "roles": {"brain": {"final": 0.5}},
        }) + "\n"
    )
    r = client.get("/api/bench/audit")
    assert r.status_code == 200
    audits = r.json()["audits"]
    assert len(audits) == 1
    assert audits[0]["label"] == "qwen35-0_8b"


def test_api_bench_audit_ranks_by_overall_desc_and_excludes_speed(bench_client):
    client, results_root = bench_client
    rows = [
        {
            "label": "low-scorer", "tier": "cpu",
            "timestamp_utc": "2026-01-01T00:00:00+00:00",
            "roles": {
                "brain": {"final": 0.1},
                "extraction": {"case_pass_rate": 0.1},
                "speed": {"decode_p50_toks_s": 500.0},  # huge, must not skew ranking
            },
        },
        {
            "label": "high-scorer", "tier": "cpu",
            "timestamp_utc": "2026-01-01T00:00:00+00:00",
            "roles": {
                "brain": {"final": 0.9},
                "extraction": {"case_pass_rate": 0.9},
                "speed": {"decode_p50_toks_s": 5.0},  # tiny, must not skew ranking
            },
        },
    ]
    _write_jsonl(results_root / "model_audit.jsonl", rows)

    r = client.get("/api/bench/audit")
    assert r.status_code == 200
    audits = r.json()["audits"]
    assert [a["label"] for a in audits] == ["high-scorer", "low-scorer"]
    assert audits[0]["overall"] == pytest.approx(0.9)
    assert audits[0]["roles_counted"] == 2


def test_api_bench_audit_includes_recipes(bench_client):
    client, results_root = bench_client
    _write_jsonl(results_root / "model_audit.jsonl", [{
        "label": "qwen35-0_8b", "tier": "cpu",
        "timestamp_utc": "2026-01-01T00:00:00+00:00",
        "roles": {},
    }])
    recipes = {"qwen35-0_8b": {"cpu": {"launch": {"ngl": 0}}}}
    (results_root / "model_recipes.json").write_text(json.dumps(recipes))

    r = client.get("/api/bench/audit")
    assert r.status_code == 200
    assert r.json()["recipes"] == recipes


def test_models_audit_page_renders_matrix_and_spanish_title(bench_client):
    client, _results_root = bench_client
    r = client.get("/models/audit")
    assert r.status_code == 200
    assert 'id="audit-matrix"' in r.text
    assert "Auditoría de modelos" in r.text


def test_load_audit_rows_merges_roles_per_label_tier(tmp_path):
    """A targeted backfill row (single role) must FILL the card, not clobber it."""
    import json as _json
    from axi import bench_audit

    p = tmp_path / "model_audit.jsonl"
    full = {"label": "m", "tier": "cpu", "timestamp_utc": "2026-07-15T01:00:00+00:00",
            "roles": {"brain": {"final": 0.7}, "visionclass": {"skipped": "no assets"}}}
    backfill = {"label": "m", "tier": "cpu", "timestamp_utc": "2026-07-15T02:00:00+00:00",
                "roles": {"visionclass": {"pass_rate": 0.5}}}
    p.write_text(_json.dumps(full) + "\n" + _json.dumps(backfill) + "\n")

    rows = bench_audit.load_audit_rows(p)
    assert len(rows) == 1
    roles = rows[0]["roles"]
    # brain preserved from the full audit, visionclass overlaid by the backfill
    assert roles["brain"] == {"final": 0.7}
    assert roles["visionclass"] == {"pass_rate": 0.5}
