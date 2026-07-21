"""Unit tests for gen_reaudit_plan.py — the FAST re-score plan generator.

Pure tests only: build_reaudit_plan takes a fake roster dict, touches no disk
and loads no model. It emits a plan in the exact shape audit_batches.py
consumes ({"notes", "jobs": [...]}).
"""
from __future__ import annotations

import pytest

import audit_batches as ab
import gen_reaudit_plan as gr


# ── fake roster (no disk, no models) ─────────────────────────────────────────

FAKE_ROSTER = [
    {"label": "tiny-mm", "gguf": "/m/tiny/model.gguf",
     "mmproj": "/m/tiny/mmproj.gguf"},
    {"label": "coder-nomm", "gguf": "/m/coder/model.gguf"},
    {"label": "big-moe", "gguf": "/m/big/model.gguf",
     "mmproj": "/m/big/mmproj.gguf", "moe": "on",
     "server_bin": "/opt/fork/llama-server",
     "extra_flags": ["--reasoning", "off"]},
    {"label": "qwen36-27b", "gguf": "/m/q27/model.gguf",
     "mmproj": "/m/q27/mmproj.gguf", "moe": "off"},
]

ROLES = ["codereview", "codegen", "vision", "routing"]


def _jobs_by_label(plan):
    return {j["label"]: j for j in plan["jobs"]}


# ── (a) every roster model produces a job ────────────────────────────────────

def test_every_roster_model_produces_a_job():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    labels = [j["label"] for j in plan["jobs"]]
    assert set(labels) == {"tiny-mm", "coder-nomm", "big-moe", "qwen36-27b"}
    assert len(plan["jobs"]) == 4


def test_plan_shape_matches_audit_batches_schema():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    assert set(plan.keys()) == {"notes", "jobs"}
    # audit_batches.parse_plan must accept it without raising
    assert ab.parse_plan(plan) == plan["jobs"]
    # and each job must build a valid model_audit argv
    for job in plan["jobs"]:
        argv = ab.build_audit_argv(job)
        assert "--roles" in argv
        assert "--use-recipe" in argv  # default fast path


# ── (b) vision dropped for no-mmproj, kept for mmproj ────────────────────────

def test_vision_dropped_for_no_mmproj_kept_for_mmproj():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    jobs = _jobs_by_label(plan)
    # mmproj models keep vision + carry mmproj
    assert "vision" in jobs["tiny-mm"]["roles"]
    assert jobs["tiny-mm"]["mmproj"] == "/m/tiny/mmproj.gguf"
    assert "vision" in jobs["big-moe"]["roles"]
    # no-mmproj model drops vision and has no mmproj key
    assert "vision" not in jobs["coder-nomm"]["roles"]
    assert "mmproj" not in jobs["coder-nomm"]
    assert jobs["coder-nomm"]["roles"] == ["codereview", "codegen", "routing"]


def test_model_skipped_when_only_role_is_vision_and_no_mmproj():
    roster = [{"label": "novision", "gguf": "/m/x/model.gguf"}]
    plan = gr.build_reaudit_plan(roster, ["vision"])
    assert plan["jobs"] == []


# ── (c) use_recipe True by default, False with tune ──────────────────────────

def test_use_recipe_true_by_default():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    assert all(j["use_recipe"] is True for j in plan["jobs"])


def test_use_recipe_false_when_tune():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES, use_recipe=False)
    assert all(j["use_recipe"] is False for j in plan["jobs"])


# ── (d) moe / server_bin / extra_flags carried through ───────────────────────

def test_moe_server_bin_extra_flags_carried_through():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    jobs = _jobs_by_label(plan)
    big = jobs["big-moe"]
    assert big["moe"] == "on"
    assert big["server_bin"] == "/opt/fork/llama-server"
    assert big["extra_flags"] == ["--reasoning", "off"]
    # absent keys are not fabricated
    assert "moe" not in jobs["tiny-mm"]
    assert "server_bin" not in jobs["tiny-mm"]
    assert "extra_flags" not in jobs["tiny-mm"]


def test_tiers_and_thinking_modes_applied():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES,
                                 tiers=("vram12",), thinking_modes=("none",))
    for job in plan["jobs"]:
        assert job["tiers"] == ["vram12"]
        assert job["thinking_modes"] == ["none"]


# ── (e) unknown role raises ──────────────────────────────────────────────────

def test_unknown_role_raises():
    with pytest.raises(ValueError):
        gr.build_reaudit_plan(FAKE_ROSTER, ["codereview", "not-a-role"])


def test_empty_roles_raises():
    with pytest.raises(ValueError):
        gr.build_reaudit_plan(FAKE_ROSTER, [])


# ── ordering: fastest first, qwen36-27b always last ──────────────────────────

def test_qwen36_27b_ordered_last():
    plan = gr.build_reaudit_plan(FAKE_ROSTER, ROLES)
    labels = [j["label"] for j in plan["jobs"]]
    assert labels[-1] == "qwen36-27b"
