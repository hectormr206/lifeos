"""Unit tests for onboard_model.py — one-command NEW-model onboarding.

Pure tests: the roster upsert and onboard-plan builders take fake dicts and
tmp_path; no disk beyond tmp_path, no models loaded, real roster.json and
model_recipes.json are never touched.
"""
from __future__ import annotations

import json

import pytest

import onboard_model as om


# ── roster upsert (pure, idempotent) ─────────────────────────────────────────

BASE_ROSTER = [
    {"label": "a", "gguf": "/m/a.gguf"},
    {"label": "b", "gguf": "/m/b.gguf", "mmproj": "/m/b-mm.gguf"},
]


def test_upsert_appends_new_label():
    entry = {"label": "c", "gguf": "/m/c.gguf"}
    out = om.upsert_roster(BASE_ROSTER, entry)
    assert [e["label"] for e in out] == ["a", "b", "c"]
    assert out[-1] == entry


def test_upsert_updates_existing_in_place():
    entry = {"label": "b", "gguf": "/m/b-new.gguf", "moe": "on"}
    out = om.upsert_roster(BASE_ROSTER, entry)
    assert [e["label"] for e in out] == ["a", "b"]  # order preserved
    assert out[1] == entry  # updated in place


def test_upsert_does_not_mutate_input():
    before = json.dumps(BASE_ROSTER)
    om.upsert_roster(BASE_ROSTER, {"label": "c", "gguf": "/m/c.gguf"})
    assert json.dumps(BASE_ROSTER) == before


def test_upsert_is_idempotent():
    entry = {"label": "c", "gguf": "/m/c.gguf"}
    once = om.upsert_roster(BASE_ROSTER, entry)
    twice = om.upsert_roster(once, entry)
    assert once == twice


# ── entry builder: only-present keys ─────────────────────────────────────────

def test_build_entry_minimal():
    e = om.build_entry("x", "/m/x.gguf")
    assert e == {"label": "x", "gguf": "/m/x.gguf"}


def test_build_entry_all_fields():
    e = om.build_entry("x", "/m/x.gguf", mmproj="/m/x-mm.gguf", moe="on",
                       server_bin="/opt/llama-server",
                       extra_flags=["--reasoning", "off"])
    assert e == {
        "label": "x", "gguf": "/m/x.gguf", "mmproj": "/m/x-mm.gguf",
        "moe": "on", "server_bin": "/opt/llama-server",
        "extra_flags": ["--reasoning", "off"],
    }


# ── canonical roles come from model_audit's argparse default ──────────────────

def test_canonical_roles_match_model_audit_default():
    import model_audit as ma
    roles = om.canonical_audit_roles()
    # every canonical role is a real VALID_ROLE
    assert all(r in ma.VALID_ROLES for r in roles)
    # and it mirrors the CLI --roles default (source of truth)
    for action in ma.build_parser()._actions:
        if action.dest == "roles":
            expected = [r.strip() for r in action.default.split(",")
                        if r.strip()]
            assert roles == expected
            break
    else:
        pytest.fail("model_audit has no --roles argument")


# ── onboard plan: tune-to-peak, this model only ──────────────────────────────

def test_onboard_plan_is_tune_to_peak_single_model():
    entry = om.build_entry("newmm", "/m/new.gguf", mmproj="/m/new-mm.gguf")
    plan = om.build_onboard_plan(entry, ["codereview", "vision"])
    assert len(plan["jobs"]) == 1
    job = plan["jobs"][0]
    assert job["label"] == "newmm"
    assert job["use_recipe"] is False  # tune-to-peak creates the recipe
    assert "vision" in job["roles"]
    assert job["mmproj"] == "/m/new-mm.gguf"


def test_onboard_plan_drops_vision_without_mmproj():
    entry = om.build_entry("nomm", "/m/nomm.gguf")
    plan = om.build_onboard_plan(entry, ["codereview", "vision"])
    job = plan["jobs"][0]
    assert "vision" not in job["roles"]
    assert "mmproj" not in job


def test_onboard_plan_carries_moe_serverbin_extraflags():
    entry = om.build_entry("big", "/m/big.gguf", moe="on",
                           server_bin="/opt/llama-server",
                           extra_flags=["--reasoning", "off"])
    job = om.build_onboard_plan(entry, ["codereview"])["jobs"][0]
    assert job["moe"] == "on"
    assert job["server_bin"] == "/opt/llama-server"
    assert job["extra_flags"] == ["--reasoning", "off"]


# ── file validation ──────────────────────────────────────────────────────────

def test_validate_paths_ok(tmp_path):
    gguf = tmp_path / "m.gguf"
    gguf.write_text("x")
    om.validate_paths(str(gguf), None)  # no raise


def test_validate_paths_missing_gguf_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        om.validate_paths(str(tmp_path / "missing.gguf"), None)


def test_validate_paths_missing_mmproj_raises(tmp_path):
    gguf = tmp_path / "m.gguf"
    gguf.write_text("x")
    with pytest.raises(FileNotFoundError):
        om.validate_paths(str(gguf), str(tmp_path / "missing-mm.gguf"))


# ── end-to-end onboard via run(): roster written + plan written ──────────────

def _write_roster(path, roster):
    path.write_text(json.dumps(roster, ensure_ascii=False, indent=2) + "\n")


def test_run_writes_roster_and_plan(tmp_path, capsys):
    gguf = tmp_path / "new.gguf"
    gguf.write_text("x")
    roster_path = tmp_path / "roster.json"
    _write_roster(roster_path, BASE_ROSTER)
    out_path = tmp_path / "onboard_new.json"

    rc = om.run([
        "--label", "new", "--gguf", str(gguf),
        "--roles", "codereview,codegen",
        "--roster", str(roster_path), "--out", str(out_path),
    ])
    assert rc == 0

    roster = json.loads(roster_path.read_text())
    assert [e["label"] for e in roster] == ["a", "b", "new"]
    plan = json.loads(out_path.read_text())
    assert len(plan["jobs"]) == 1
    assert plan["jobs"][0]["label"] == "new"
    assert plan["jobs"][0]["use_recipe"] is False
    # launch command is printed, not executed
    out = capsys.readouterr().out
    assert "systemd-run" in out
    assert "axi-onboard-new" in out


def test_run_is_idempotent_on_roster(tmp_path):
    gguf = tmp_path / "new.gguf"
    gguf.write_text("x")
    roster_path = tmp_path / "roster.json"
    _write_roster(roster_path, BASE_ROSTER)
    out_path = tmp_path / "onboard_new.json"
    args = ["--label", "new", "--gguf", str(gguf), "--roles", "codereview",
            "--roster", str(roster_path), "--out", str(out_path)]
    om.run(args)
    first = roster_path.read_text()
    om.run(args)
    assert roster_path.read_text() == first


def test_run_missing_gguf_errors(tmp_path):
    roster_path = tmp_path / "roster.json"
    _write_roster(roster_path, BASE_ROSTER)
    rc = om.run([
        "--label", "new", "--gguf", str(tmp_path / "nope.gguf"),
        "--roles", "codereview", "--roster", str(roster_path),
        "--out", str(tmp_path / "o.json"),
    ])
    assert rc != 0
